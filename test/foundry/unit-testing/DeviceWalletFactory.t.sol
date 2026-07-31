// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/device-wallet/DeviceWalletFactory.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockRegistry.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockDeviceWalletV2.sol";
import "test/utils/mocks/MockESIMWallet.sol";

contract DeviceWalletFactoryTest is DeployerBase {

    function test_addRegistryAddress_withoutOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    /// @notice The admin cannot wire up the registry, because the admin is read out of it
    /// @dev Gating this on the admin would be circular: with no registry set there is no admin to
    ///      check the caller against, so the call could never be made.
    function test_addRegistryAddress_withoutAdmin() public {
        vm.startPrank(deviceWalletFactory.eSIMWalletAdmin());
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin));
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    function test_addRegistryAddress_onlyOnce() public {
        vm.startPrank(deviceWalletFactory.owner());
        vm.expectRevert("Already added");
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    function test_updateVaultAddress_withoutAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAdmin()")));
        deviceWalletFactory.updateVaultAddress(user2);
        vm.stopPrank();
    }

    function test_updateVaultAddress_sameAddress() public {
        address currentVault = deviceWalletFactory.vault();
        assertNotEq(currentVault, address(0), "Vault cannot be address(0)");

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Cannot update to same address");
        deviceWalletFactory.updateVaultAddress(currentVault);
        vm.stopPrank();
    }

    function test_updateVaultAddress_zeroAddress() public {
        address currentVault = deviceWalletFactory.vault();
        assertNotEq(currentVault, address(0), "Vault cannot be address(0)");

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Vault address cannot be zero");
        deviceWalletFactory.updateVaultAddress(address(0));
        vm.stopPrank();
    }

    function test_updateVaultAddress() public {
        address currentVault = deviceWalletFactory.vault();
        assertNotEq(currentVault, address(0), "Vault cannot be address(0)");

        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.updateVaultAddress(user2);
        vm.stopPrank();

        address newVault = deviceWalletFactory.vault();
        assertEq(newVault, user2, "Vault should have updated");
    }

    function test_updateDeviceWalletImplementation_admin() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.startPrank(admin);
        vm.expectRevert();
        deviceWalletFactory.updateDeviceWalletImplementation(user2);
        vm.stopPrank();
    }

    function test_updateDeviceWalletImplementation() public {
        // First deploy a device wallet
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[0];
        listOfKeys[0] = listOfOwnerKeys[0];
        salts[0] = 999;
        deposits[0] = 0;

        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        )[0];
        vm.stopPrank();

        // Now upgrade the Device Wallet implementation contract
        address owner = deviceWalletFactory.owner();
        assertEq(owner, upgradeManager, "Upgrade manager should have been the owner");

        MockDeviceWalletV2 newDeviceWalletImpl = new MockDeviceWalletV2(
            typeCastEntryPoint,
            p256Verifier
        );
        assertNotEq(address(newDeviceWalletImpl), deviceWalletFactory.getCurrentDeviceWalletImplementation(), "Should have been different implementations");

        vm.prank(owner);
        deviceWalletFactory.updateDeviceWalletImplementation(address(newDeviceWalletImpl));
        vm.stopPrank();

        address currentImpl = deviceWalletFactory.getCurrentDeviceWalletImplementation();
        assertEq(currentImpl, address(newDeviceWalletImpl), "Device wallet implementation should have been updated");

        // Check if the new implementation works
        MockDeviceWalletV2 upgradedDeviceWallet = MockDeviceWalletV2(payable(wallet.deviceWallet));
        uint256 result = upgradedDeviceWallet.addTwoNumbers(2, 3);
        assertEq(result, 5, "Device wallet should have been upgraded");

        // Check storage variables in device wallet are still the same
        assertEq(upgradedDeviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(upgradedDeviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(upgradedDeviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
        assertEq(upgradedDeviceWallet.isValidESIMWallet(wallet.eSIMWallet), true, "ESIMWallet should have been set to valid");
        assertEq(upgradedDeviceWallet.canPullETH(wallet.eSIMWallet), true, "ESIMWallet should be able to pull ETH");
    }

    function test_getCounterFactualAddress() public {
        uint256 salt = 999;
        // uint256 uniqueSalt = uint256(keccak256(abi.encode(admin, salt)));

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
            pubKey1
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
            pubKey1
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
            pubKey1
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
            salts,      // [uint256(1), uint256(2), uint256(3), uint256(4), uint256(5)],
            deposits    // [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)]
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
            salts,      // [uint256(1), uint256(2), uint256(3), uint256(4), uint256(5)],
            deposits    // [1 ether, 2 ether, 3 ether, 4 ether, 5 ether]
        );
        vm.stopPrank();

        assertEq(wallets.length, 5, "5 device and eSIM wallets should have been deployed");
        assertEq(eSIMWalletAdmin.balance, 1 ether, "Admin should have got their 1 ETH back");

        for(uint256 i=0; i<5; ++i) {
            MockDeviceWallet deviceWallet = MockDeviceWallet(payable(wallets[i].deviceWallet));
            MockESIMWallet eSIMWallet = MockESIMWallet(payable(wallets[i].eSIMWallet));

            assertNotEq(address(deviceWallet), address(0), "Device wallet address cannot be address(0)");
            assertNotEq(address(eSIMWallet), address(0), "ESIM wallet address cannot be address(0)");
            _assertDepositHeldByEntryPoint(address(deviceWallet), (i+1) * oneEther);

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

    /// @notice postCreateAccount only checks that the wallet address is new, so a second wallet
    /// used to be able to take over a device identifier that already belonged to another. The
    /// registry binding must survive the attempt untouched.
    function test_postCreateAccount_revertsOnRegisteredIdentifier() public {
        vm.prank(user1);
        address firstWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            111
        ));
        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(firstWallet, customDeviceUniqueIdentifiers[0], pubKey1);

        vm.prank(user2);
        address secondWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[1],
            pubKey2,
            222
        ));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.DeviceIdentifierAlreadyRegistered.selector,
                customDeviceUniqueIdentifiers[0]
            )
        );
        deviceWalletFactory.postCreateAccount(secondWallet, customDeviceUniqueIdentifiers[0], pubKey2);

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]),
            firstWallet,
            "Identifier must still resolve to the wallet that claimed it first"
        );
    }

    /// @notice The same hole reached through the P256 key rather than the identifier. A key that
    /// already resolves to a wallet must keep resolving to it.
    function test_postCreateAccount_revertsOnRegisteredOwnerKey() public {
        vm.prank(user1);
        address firstWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            111
        ));
        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(firstWallet, customDeviceUniqueIdentifiers[0], pubKey1);

        vm.prank(user2);
        address secondWallet = address(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[1],
            pubKey2,
            222
        ));

        bytes32 reusedKeyHash = keccak256(abi.encode(pubKey1[0], pubKey1[1]));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyAlreadyRegistered.selector, reusedKeyHash)
        );
        deviceWalletFactory.postCreateAccount(secondWallet, customDeviceUniqueIdentifiers[1], pubKey1);

        assertEq(
            registry.registeredP256Keys(reusedKeyHash),
            firstWallet,
            "Owner key must still resolve to the wallet that registered it first"
        );
    }

    /// @notice The happy path still forwards the full deposit, asserted against the EntryPoint's own
    /// accounting rather than the wallet balance, which the mock reaches by forwarding the ETH on.
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

        assertEq(entryPoint.balanceOf(wallets[0].deviceWallet), 2 ether, "Full deposit should have reached the EntryPoint");
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 1 ether, "Admin should have been refunded the surplus");
    }

    /// @notice A zero deposit inside a funded batch must not reach the EntryPoint at all.
    /// The guard has to read the per-wallet amount, not the batch total in msg.value.
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

        assertEq(entryPoint.balanceOf(wallets[0].deviceWallet), 0, "A zero deposit should not create an EntryPoint balance");
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 5 ether, "Admin should have been refunded everything");
    }

    /// @notice PoC for the front-run denial of service. createAccount is permissionless, so anyone
    /// watching the mempool can deploy a wallet the admin is about to deploy, leaving it with code
    /// but no registry record. The batch must absorb that wallet instead of reverting.
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

        // Nothing was deposited for a wallet that already existed, so the ETH comes back
        assertEq(address(deviceWalletFactory).balance, 0, "Factory must not retain any ETH");
        assertEq(eSIMWalletAdmin.balance, 1 ether, "Admin should have been refunded");
    }

    /// @notice A zero P256 key can never sit on the curve, so the wallet it produces could never
    /// authorise anything while still consuming its device identifier permanently.
    function test_deployDeviceWalletForUsers_revertsOnZeroOwnerKey() public {
        bytes32[2] memory zeroKey = [bytes32(0), bytes32(0)];
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], zeroKey, uint256(781), 1 ether);

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "Identifier must not have been consumed");
        assertEq(registry.registeredP256Keys(keccak256(abi.encode(zeroKey[0], zeroKey[1]))), address(0), "Zero key must not have been registered");
    }

    /// @notice The permissionless deploy path has to reject the same key, and a single zero
    /// coordinate is already off the curve.
    function test_createAccount_revertsOnZeroOwnerKeyComponent() public {
        bytes32[2] memory halfZeroKey = [pubKey1[0], bytes32(0)];

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], halfZeroKey, uint256(782));

        address counterfactual = deviceWalletFactory.getCounterFactualAddress(
            halfZeroKey,
            customDeviceUniqueIdentifiers[0],
            uint256(782)
        );
        assertEq(counterfactual.code.length, 0, "No wallet should have been deployed");
    }

    /// @notice The off-chain pre-check for the userop deploy path must agree with the deploy path.
    function test_preCreateAccountValidation_revertsOnZeroOwnerKey() public {
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.preCreateAccountValidation(
            customDeviceUniqueIdentifiers[0],
            [bytes32(0), bytes32(0)]
        );
    }

    /// @notice Both coordinates are non-zero and inside the field, and the pair still fails
    /// y^2 = x^3 - 3x + b, so signature verification would reject it for the wallet's whole life.
    function _offCurveKey() internal pure returns (bytes32[2] memory) {
        return [bytes32(uint256(1)), bytes32(uint256(1))];
    }

    /// @notice A coordinate at or above the field prime is not a field element at all
    function _outOfFieldKey() internal view returns (bytes32[2] memory) {
        return [bytes32(type(uint256).max), pubKey1[1]];
    }

    /// @notice The admin batch path must refuse a key that is not on the curve
    function test_deployDeviceWalletForUsers_revertsOnOffCurveOwnerKey() public {
        bytes32[2] memory offCurveKey = _offCurveKey();
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], offCurveKey, uint256(783), 1 ether);

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "Identifier must not have been consumed");
        assertEq(registry.registeredP256Keys(keccak256(abi.encode(offCurveKey[0], offCurveKey[1]))), address(0), "Off-curve key must not have been registered");
    }

    /// @notice The permissionless deploy path must refuse the same key
    function test_createAccount_revertsOnOffCurveOwnerKey() public {
        bytes32[2] memory offCurveKey = _offCurveKey();

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], offCurveKey, uint256(783));

        address counterfactual = deviceWalletFactory.getCounterFactualAddress(
            offCurveKey,
            customDeviceUniqueIdentifiers[0],
            uint256(783)
        );
        assertEq(counterfactual.code.length, 0, "No wallet should have been deployed");
    }

    /// @notice A coordinate outside the field is refused rather than reduced into it
    function test_createAccount_revertsOnOutOfFieldOwnerKey() public {
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], _outOfFieldKey(), uint256(784));

        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "Identifier must not have been consumed");
    }

    /// @notice The off-chain pre-check must agree with the deploy paths on an off-curve key too
    function test_preCreateAccountValidation_revertsOnOffCurveOwnerKey() public {
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.preCreateAccountValidation(
            customDeviceUniqueIdentifiers[0],
            _offCurveKey()
        );
    }

    /// @dev Builds a one-entry batch, since the four arrays have to agree in length
    function _singleEntryBatch(
        string memory _identifier,
        bytes32[2] memory _key,
        uint256 _salt,
        uint256 _deposit
    ) internal pure returns (
        string[] memory identifiers,
        bytes32[2][] memory keys,
        uint256[] memory salts,
        uint256[] memory deposits
    ) {
        identifiers = new string[](1);
        keys = new bytes32[2][](1);
        salts = new uint256[](1);
        deposits = new uint256[](1);

        identifiers[0] = _identifier;
        keys[0] = _key;
        salts[0] = _salt;
        deposits[0] = _deposit;
    }

    /// @notice A deposit made on a wallet's behalf is held by the entry point, not by the wallet
    /// @dev The wallet only reaches this ETH by spending it on an operation or withdrawing it,
    ///      so a balance on the wallet itself would mean the deposit never happened.
    function _assertDepositHeldByEntryPoint(address _deviceWallet, uint256 _deposit) internal view {
        assertEq(_deviceWallet.balance, 0, "The wallet should not hold the deposit itself");
        assertEq(
            entryPoint.balanceOf(_deviceWallet),
            _deposit,
            "The entry point should hold the deposit made for the wallet"
        );
    }
}
