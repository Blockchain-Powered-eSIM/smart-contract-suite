// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFactoryFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFactoryFixture.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

/// @notice The permissionless deploy path and the admin call that promotes what it deployed.
/// @dev createAccount deploys a wallet and touches nothing else. postCreateAccount is the separate
///      call that writes it into the registry, and the split is what makes the two testable apart.
contract DeviceWalletFactoryCreateAccountTest is DeviceWalletFactoryFixture {

    function test_getCounterFactualAddress() public {
        uint256 salt = 999;

        // Check for device wallet address before its deployed
        address calculatedDeviceWalletAddress1 = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );
        assertNotEq(calculatedDeviceWalletAddress1, address(0), "Device wallet address cannot be address(0)");

        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[0];
        listOfKeys[0] = listOfOwnerKeys[0];
        salts[0] = salt;
        deposits[0] = 0;

        // Deploy the device wallet
        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        )[0];
        vm.stopPrank();

        // Check if the actual device wallet address matches the calculated device wallet address
        address actualDeviceWalletAddress1 = registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]);
        assertEq(actualDeviceWalletAddress1, calculatedDeviceWalletAddress1, "Calculated device wallet address should have matched the actual device wallet address");

        // Check if the calculated device wallet address changes after device wallet deployment
        address calculatedDeviceWalletAddress2 = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );
        assertEq(calculatedDeviceWalletAddress1, calculatedDeviceWalletAddress2, "Device wallet address before and after deployment should have matched");
    }

    /// @notice createAccount is permissionless by design.
    /// During a real UserOperation the caller is the EntryPoint's SenderCreator helper, not the
    /// EntryPoint itself, so gating on the EntryPoint address would break userOp deployment.
    /// Deploying is safe for anyone to do because the owner key and device identifier are part of
    /// the counterfactual address, so a caller can only ever deploy the wallet those params describe.
    function test_createAccount_byArbitraryCaller() public {
        uint256 salt = 999;

        // Check for device wallet address before its deployed
        address calculatedDeviceWalletAddress1 = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );
        assertNotEq(calculatedDeviceWalletAddress1, address(0), "Device wallet address cannot be address(0)");

        // Deploy the device wallet from an EOA that is not the entry point
        vm.startPrank(user1);
        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        )));
        vm.stopPrank();

        assertEq(address(deviceWallet), calculatedDeviceWalletAddress1, "Wallet should be deployed at the counterfactual address");

        // The wallet is owned by pubKey1, not by the caller
        assertEq(deviceWallet.owner(0), pubKey1[0], "X co-ordinate should have matched");
        assertEq(deviceWallet.owner(1), pubKey1[1], "Y co-ordinate should have matched");
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");

        // createAccount must not touch external storage, regardless of who called it
        bytes32 keyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));
        assertEq(registry.registeredP256Keys(keyHash), address(0), "P256 key hash should NOT have been tied to the device wallet address");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), false, "isDeviceWalletValid mapping should NOT have been updated");
        assertEq(deviceWalletFactory.deviceWalletInfoAdded(address(deviceWallet)), false, "Device wallet info should NOT have been added");
    }

    /// @notice An arbitrary caller cannot promote a wallet they deployed into the registry
    function test_createAccount_byArbitraryCaller_cannotCallPostCreateAccount() public {
        uint256 salt = 999;

        vm.startPrank(user1);
        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        )));

        vm.expectRevert(bytes4(keccak256("OnlyAdminOrRegistry()")));
        deviceWalletFactory.postCreateAccount(
            address(deviceWallet),
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        );
        vm.stopPrank();
    }

    function test_createAccount() public {
        uint256 salt = 999;

        // Check for device wallet address before its deployed
        address calculatedDeviceWalletAddress1 = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );
        assertNotEq(calculatedDeviceWalletAddress1, address(0), "Device wallet address cannot be address(0)");

        // Deploy the device wallet
        vm.startPrank(address(typeCastEntryPoint));
        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        )));
        vm.stopPrank();

        // Check if the actual device wallet address matches the calculated device wallet address
        assertEq(address(deviceWallet), calculatedDeviceWalletAddress1, "Calculated device wallet address should have matched the actual device wallet address");

        // Check storage variables in registry without calling postCreateAccount function
        bytes32 keyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));
        assertEq(registry.registeredP256Keys(keyHash), address(0), "P256 key hash should NOT have been tied to the device wallet address");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), false, "isDeviceWalletValid mapping should NOT have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "uniqueIdentifierToDeviceWallet should NOT have been updated");
        // Check storage variable in Device Wallet Factory
        assertEq(deviceWalletFactory.deviceWalletInfoAdded(address(deviceWallet)), false, "Device wallet info should NOT have been added");

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(
            address(deviceWallet),
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        );
        vm.stopPrank();

        // Check storage variables in registry after calling postCreateAccount function
        assertEq(registry.registeredP256Keys(keyHash), address(deviceWallet), "P256 key hash should have been tied to the device wallet address");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated");
        // Check storage variable in Device Wallet Factory
        assertEq(deviceWalletFactory.deviceWalletInfoAdded(address(deviceWallet)), true, "Device wallet info should have been added");

        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
    }

    function test_createAccount_callTwice() public {
        uint256 salt = 999;

        // Check for device wallet address before its deployed
        address calculatedDeviceWalletAddress1 = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );
        assertNotEq(calculatedDeviceWalletAddress1, address(0), "Device wallet address cannot be address(0)");

        // Deploy the device wallet
        vm.startPrank(address(typeCastEntryPoint));
        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        )));
        vm.stopPrank();

        // Check if the actual device wallet address matches the calculated device wallet address
        assertEq(address(deviceWallet), calculatedDeviceWalletAddress1, "Calculated device wallet address should have matched the actual device wallet address");

        // Check storage variables in registry without calling postCreateAccount function
        bytes32 keyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));
        assertEq(registry.registeredP256Keys(keyHash), address(0), "P256 key hash should NOT have been tied to the device wallet address");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), false, "isDeviceWalletValid mapping should NOT have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "uniqueIdentifierToDeviceWallet should NOT have been updated");
        // Check storage variable in Device Wallet Factory
        assertEq(deviceWalletFactory.deviceWalletInfoAdded(address(deviceWallet)), false, "Device wallet info should NOT have been added");

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(
            address(deviceWallet),
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        );
        vm.stopPrank();

        // Check storage variables in registry after calling postCreateAccount function
        assertEq(registry.registeredP256Keys(keyHash), address(deviceWallet), "P256 key hash should have been tied to the device wallet address");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated");
        // Check storage variable in Device Wallet Factory
        assertEq(deviceWalletFactory.deviceWalletInfoAdded(address(deviceWallet)), true, "Device wallet info should have been added");

        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");

        // Check if the calculated device wallet address changes after device wallet deployment
        address calculatedDeviceWalletAddress2 = deviceWalletFactory.getCounterFactualAddress(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            salt
        );
        assertEq(calculatedDeviceWalletAddress1, calculatedDeviceWalletAddress2, "Device wallet address before and after deployment should have matched");

        // Trying to deploy the same device identifier again should not deploy a new wallet
        vm.startPrank(address(typeCastEntryPoint));
        MockDeviceWallet deviceWallet2 = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        )));
        vm.stopPrank();

        // Check if the actual device wallet address matches the calculated device wallet address
        assertEq(address(deviceWallet2), address(deviceWallet), "New device wallet should not have been deployed again");
    }

    /// @notice ETH sent with createAccount belongs to the wallet, not to the entry point. Held as a
    /// deposit it would only ever pay for gas, which defeats sending it in the first place: the
    /// owner cannot spend it on a data bundle, a transfer or anything else.
    function test_createAccount_fundsTheWalletAndNotTheDeposit() public {
        uint256 salt = 1001;

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        address deviceWallet = address(deviceWalletFactory.createAccount{value: 1 ether}(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));

        _assertDepositHeldByWallet(deviceWallet, 1 ether);
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
    }

    /// @notice The wallet is only deployed on the first call, and the second returns early. Funding
    /// used to happen before that check, so it has to be repeated on the early return or the ETH is
    /// stranded in the factory, which has no function that can send it anywhere.
    function test_createAccount_forwardsValueToAnAlreadyDeployedWallet() public {
        uint256 salt = 1002;

        vm.deal(user1, 3 ether);
        vm.startPrank(user1);
        address deviceWallet = address(deviceWalletFactory.createAccount{value: 1 ether}(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));

        address sameWallet = address(deviceWalletFactory.createAccount{value: 2 ether}(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));
        vm.stopPrank();

        assertEq(sameWallet, deviceWallet, "The second call must return the wallet already deployed");
        _assertDepositHeldByWallet(deviceWallet, 3 ether);
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
    }

    /// @notice The EntryPoint calls the factory with no value on the deployment path, so the funding
    /// branch has to stay skippable. A wallet deployed that way holds nothing anywhere.
    function test_createAccount_withoutValueLeavesTheWalletUnfunded() public {
        uint256 salt = 1003;

        vm.prank(address(typeCastEntryPoint));
        address deviceWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            salt
        ));

        _assertDepositHeldByWallet(deviceWallet, 0);
    }

    /// @notice A second wallet honestly deployed against an identifier that is already registered
    /// must not take it over. The registry binding survives the attempt untouched.
    /// @dev The salt is the only argument that differs, which is what makes this reachable at all
    /// now that the identifier is bound to the wallet address. Both wallets really carry the
    /// identifier, so the derivation is satisfied and the registry's own duplicate guard is what
    /// refuses the second one.
    function test_postCreateAccount_revertsOnRegisteredIdentifier() public {
        vm.prank(user1);
        address firstWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            111
        ));
        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(firstWallet, customDeviceUniqueIdentifiers[0], pubKey1, 111);

        vm.prank(user2);
        address secondWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey2,
            222
        ));
        assertTrue(secondWallet != firstWallet, "A different salt must reach a different address");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DeviceIdentifierAlreadyRegistered.selector,
                customDeviceUniqueIdentifiers[0]
            )
        );
        deviceWalletFactory.postCreateAccount(secondWallet, customDeviceUniqueIdentifiers[0], pubKey2, 222);

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]),
            firstWallet,
            "Identifier must still resolve to the wallet that claimed it first"
        );
    }

    /// @notice The same case reached through the P256 key rather than the identifier. A key that
    /// already resolves to a wallet must keep resolving to it.
    function test_postCreateAccount_revertsOnRegisteredOwnerKey() public {
        vm.prank(user1);
        address firstWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            111
        ));
        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(firstWallet, customDeviceUniqueIdentifiers[0], pubKey1, 111);

        vm.prank(user2);
        address secondWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[1],
            pubKey1,
            222
        ));

        bytes32 reusedKeyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyAlreadyRegistered.selector, reusedKeyHash)
        );
        deviceWalletFactory.postCreateAccount(secondWallet, customDeviceUniqueIdentifiers[1], pubKey1, 222);

        assertEq(
            registry.registeredP256Keys(reusedKeyHash),
            firstWallet,
            "Owner key must still resolve to the wallet that registered it first"
        );
    }
}
