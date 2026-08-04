// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {IStakeManager} from "@account-abstraction/contracts/interfaces/IStakeManager.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFactoryFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFactoryFixture.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice The admin batch that deploys wallets and funds them in one call.
/// @dev The ETH accounting is where this differs from createAccount: the batch takes one msg.value
///      covering per-wallet deposits that may each be skipped, so what it funds and what it refunds
///      have to be tracked apart. Almost every case here asserts the factory kept nothing.
contract DeviceWalletFactoryBatchDeployTest is DeviceWalletFactoryFixture {

    function test_deployDeviceWalletForUsers_withoutAdminOrRegistry() public {
        uint256[] memory salts = new uint256[](5);
        uint256[] memory deposits = new uint256[](5);
        for(uint256 i=0; i<5; ++i) {
            salts[i] = uint256(i);
            deposits[i] = uint256(0);
        }

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAdminOrRegistry()")));
        deviceWalletFactory.deployDeviceWalletForUsers(
            customDeviceUniqueIdentifiers,
            listOfOwnerKeys,
            salts,
            deposits
        );
        vm.stopPrank();
    }

    function test_deployDeviceWalletForUsers() public {
        uint256[] memory salts = new uint256[](5);
        uint256[] memory deposits = new uint256[](5);
        uint256 oneEther = 1000000000000000000;

        for(uint256 i=0; i<5; ++i) {
            salts[i] = uint256(i);
            deposits[i] = uint256((i+1) * oneEther);
        }

        vm.deal(eSIMWalletAdmin, 16 ether);
        vm.startPrank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers{value: 16 ether}(
            customDeviceUniqueIdentifiers,
            listOfOwnerKeys,
            salts,
            deposits
        );
        vm.stopPrank();

        assertEq(wallets.length, 5, "5 device and eSIM wallets should have been deployed");
        assertEq(eSIMWalletAdmin.balance, 1 ether, "Admin should have got their 1 ETH back");

        for(uint256 i=0; i<5; ++i) {
            MockDeviceWallet deviceWallet = MockDeviceWallet(payable(wallets[i].deviceWallet));
            MockESIMWallet eSIMWallet = MockESIMWallet(payable(wallets[i].eSIMWallet));

            assertNotEq(address(deviceWallet), address(0), "Device wallet address cannot be address(0)");
            assertNotEq(address(eSIMWallet), address(0), "ESIM wallet address cannot be address(0)");
            _assertDepositHeldByWallet(address(deviceWallet), (i+1) * oneEther);

            // Check storage variables in registry
            bytes32 keyHash = keccak256(abi.encode(listOfOwnerKeys[i][0], listOfOwnerKeys[i][1]));
            assertEq(registry.registeredP256Keys(keyHash), address(deviceWallet), "P256 key hash should have been tied to the device wallet address");
            assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated");
            assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[i]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated");
            assertEq(registry.isESIMWalletValid(address(eSIMWallet)), address(deviceWallet), "ESIM wallet should have been associated with device wallet");
            assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet)), false, "ESIM wallet should not have been on standby");

            bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
            assertEq(ownerKeys[0], listOfOwnerKeys[i][0], "X co-ordinate should have matched");
            assertEq(ownerKeys[1], listOfOwnerKeys[i][1], "Y co-ordinate should have matched");

            // Check storage variables in device wallet factory
            assertEq(deviceWalletFactory.deviceWalletInfoAdded(address(deviceWallet)), true, "Device wallet info should have been added");

            // Check storage variables in device wallet
            assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[i], "Device unique identifier should have matched");
            assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
            assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
            assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet)), true, "ESIMWallet should have been set to valid");
            assertEq(deviceWallet.canPullETH(address(eSIMWallet)), true, "ESIMWallet should be able to pull ETH");

            // Check storage variables in eSIM wallet
            assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
            assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
            assertEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
            assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
            assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
            assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
        }
    }

    /// @notice A device identifier already present in the registry makes the batch return the
    /// existing wallet without depositing. The requested ETH must still be refundable.
    /// Reached through createAccount followed by postCreateAccount, which registers a wallet
    /// without deploying an eSIM wallet against that salt.
    function test_deployDeviceWalletForUsers_existingIdentifierRefundsItsDeposit() public {
        uint256 salt = 777;

        vm.prank(user1);
        address deployedWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(deployedWallet, customDeviceUniqueIdentifiers[0], pubKey1);
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), deployedWallet, "Registry should now hold the wallet");

        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, salt, 1 ether);

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        assertEq(wallets[0].deviceWallet, deployedWallet, "Batch should have returned the existing wallet");
        assertEq(entryPoint.balanceOf(deployedWallet), 0, "Nothing should have been deposited for an existing wallet");
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 1 ether, "Admin should have been refunded the undeposited ETH");
    }

    /// @notice The happy path forwards the full deposit into the wallet's own balance, and refunds
    /// the rest. The requested amount and the surplus have to be accounted separately, so a batch
    /// that funds less than msg.value must not leave the difference in the factory.
    function test_deployDeviceWalletForUsers_depositsAndRefundsExactly() public {
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, uint256(778), 2 ether);

        vm.deal(eSIMWalletAdmin, 3 ether);
        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers{value: 3 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        _assertDepositHeldByWallet(wallets[0].deviceWallet, 2 ether);
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 1 ether, "Admin should have been refunded the surplus");
    }

    /// @notice A zero deposit inside a funded batch must leave the wallet unfunded and the entry
    /// point untouched. The guard has to read the per-wallet amount, not the batch total in
    /// msg.value, otherwise a wallet asking for nothing would receive the whole batch.
    function test_deployDeviceWalletForUsers_zeroDepositSkipsEntryPoint() public {
        uint256 salt = 779;
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, salt, 0);

        address expectedWallet = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );

        vm.deal(eSIMWalletAdmin, 5 ether);
        vm.expectCall(
            address(entryPoint),
            abi.encodeCall(IStakeManager.depositTo, (expectedWallet)),
            0
        );
        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers{value: 5 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        _assertDepositHeldByWallet(wallets[0].deviceWallet, 0);
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 5 ether, "Admin should have been refunded everything");
    }

    /// @notice PoC for the front-run denial of service. createAccount is permissionless, so anyone
    /// watching the mempool can deploy a wallet the admin is about to deploy, leaving it with code
    /// but no registry record. The batch must absorb that wallet instead of reverting, and the
    /// deposit must follow it rather than being refunded, since a caller that cannot receive ETH
    /// would lose the whole batch to the refund.
    function test_deployDeviceWalletForUsers_survivesCreateAccountFrontRun() public {
        uint256 salt = 780;

        // The attacker deploys the wallet the admin is about to deploy
        vm.prank(user2);
        address frontRunWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));
        assertEq(registry.isDeviceWalletValid(frontRunWallet), false, "Front-run wallet should hold no registry record");

        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, salt, 1 ether);

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        // The batch completes and the front-run wallet is now a first-class wallet
        assertEq(wallets[0].deviceWallet, frontRunWallet, "Batch should have adopted the front-run wallet");
        assertEq(registry.isDeviceWalletValid(frontRunWallet), true, "Adopted wallet should be valid in the registry");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), frontRunWallet, "Identifier should resolve to the adopted wallet");
        assertEq(deviceWalletFactory.deviceWalletInfoAdded(frontRunWallet), true, "Factory should record the adopted wallet");
        assertEq(registry.isESIMWalletValid(wallets[0].eSIMWallet), frontRunWallet, "ESIM wallet should be bound to the adopted wallet");

        bytes32 keyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));
        assertEq(registry.registeredP256Keys(keyHash), frontRunWallet, "Owner key should resolve to the adopted wallet");

        // The deposit follows the adopted wallet rather than coming back
        assertEq(frontRunWallet.balance, 1 ether, "Adopted wallet should hold the deposit");
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 0, "Nothing should have come back to the admin");
    }

    /// @notice Replaying an entry the batch already deployed reverts on the eSIM wallet salt.
    /// @dev The device wallet address binds the owner key, the identifier and the salt together, so
    ///      the registry lookup can only return the recorded wallet when the salt is the original
    ///      one. That salt has already produced an eSIM wallet, and the batch does not stop at the
    ///      existing device wallet: it goes on to deploy an eSIM wallet against the same salt. The
    ///      collision is what makes a replay loud instead of a silent success, so it is pinned here.
    function test_deployDeviceWalletForUsers_rejectsAReplayOfTheSameEntry() public {
        uint256 salt = 781;
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, salt, 0);

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.SaltAlreadyUsed.selector, wallets[0].deviceWallet, salt)
        );
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);
    }

    /// @notice Retrying a deployed entry under a fresh salt is refused by the identifier check.
    /// @dev This is the shape an admin retry takes after a batch reverted partway. A new salt moves
    ///      the counterfactual address away from the wallet the registry holds, so the identifier
    ///      arm rejects it. The message names a different owner even though the key is unchanged,
    ///      which is worth knowing before reading a failed retry as a key collision.
    function test_deployDeviceWalletForUsers_rejectsARetryUnderANewSalt() public {
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, uint256(782), 0);

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);

        salts[0] = 783;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert("Wallet already exists with different owner");
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);
    }

    /// @notice A wallet registered without an eSIM wallet gets one from the batch.
    /// @dev createAccount followed by postCreateAccount leaves a registered device wallet whose
    ///      salt was never spent on an eSIM wallet. The batch returns that device wallet untouched
    ///      and still deploys the eSIM wallet, which is the reason the deploy does not stop at the
    ///      existing-wallet return. Without this the path would hand back a device wallet and an
    ///      eSIM wallet address that nothing binds together.
    function test_deployDeviceWalletForUsers_bindsAnESIMWalletToAnAlreadyRegisteredWallet() public {
        uint256 salt = 784;

        vm.prank(user1);
        address deployedWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(deployedWallet, customDeviceUniqueIdentifiers[0], pubKey1);

        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], pubKey1, salt, 0);

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        );

        MockESIMWallet eSIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        assertEq(wallets[0].deviceWallet, deployedWallet, "Batch should have returned the registered wallet");
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWallet)), true, "ESIM wallet should be known to its factory");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet)), deployedWallet, "Registry should bind the eSIM wallet to the device wallet");
        assertEq(MockDeviceWallet(payable(deployedWallet)).isValidESIMWallet(address(eSIMWallet)), true, "Device wallet should hold the eSIM wallet");
        assertEq(eSIMWallet.owner(), deployedWallet, "ESIM wallet owner should be the device wallet");
    }
}
