// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {SIG_VALIDATION_FAILED} from "@account-abstraction/contracts/core/Helpers.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import {ReentrantESIMWallet} from "test/utils/mocks/ReentrantESIMWallet.sol";

contract DeviceWalletTest is DeployerBase {

    MockDeviceWallet deviceWallet;
    MockDeviceWallet deviceWallet2;
    MockDeviceWallet deviceWallet3;     // [C-01]: Carol's (Malicious actor) device wallet
    MockESIMWallet eSIMWallet1;         // has access to ETH, has eSIM identifier set, belongs to deviceWallet1        
    MockESIMWallet eSIMWallet2;         // no access to ETH, no eSIM identifier set, belongs to deviceWallet1
    MockESIMWallet eSIMWallet3;         // has access to ETH, has eSIM identifier set, belongs to deviceWallet2
    MockDeviceWallet userDeviceWallet;  // Custom device wallet deployed with user defined x and y keys
    MockESIMWallet userESIMWallet;      // eSIM wallet associated with user's custom device wallet

    function deployCustomWallet(
        string memory _deviceIdentifier,
        bytes32 _x,
        bytes32 _y,
        uint256 _salt
    ) public {
        bytes32[2] memory pubKey = [
            bytes32(_x),
            bytes32(_y)
        ];

        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = _deviceIdentifier;
        listOfKeys[0] = pubKey;
        salts[0] = _salt;
        deposits[0] = 0;

        vm.startPrank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        );
        vm.stopPrank();

        userDeviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        userESIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        vm.startPrank(admin);
        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        userDeviceWallet.setESIMUniqueIdentifierForAnESIMWallet(address(userESIMWallet), "ESIM_0_0");
        vm.stopPrank();

        assertNotEq(address(userDeviceWallet), address(0), "deviceWallet address cannot be address(0)");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(userDeviceWallet)), true, "isDeviceWalletValid mapping should have been updated for userDeviceWallet");
        assertEq(registry.uniqueIdentifierToDeviceWallet(_deviceIdentifier), address(userDeviceWallet), "uniqueIdentifierToDeviceWallet should have been updated for userDeviceWallet");
        assertEq(registry.isESIMWalletValid(address(userESIMWallet)), address(userDeviceWallet), "userESIMWallet should have been associated with userDeviceWallet");
        assertEq(registry.isESIMWalletOnStandby(address(userESIMWallet)), false, "userESIMWallet should not have been on standby");

        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(userDeviceWallet));
        assertEq(ownerKeys[0], pubKey[0], "X co-ordinate should have matched for ownerKeys");
        assertEq(ownerKeys[1], pubKey[1], "Y co-ordinate should have matched for ownerKeys");

        // Check storage variables in device wallet
        assertEq(userDeviceWallet.deviceUniqueIdentifier(), _deviceIdentifier, "Device unique identifier should have matched with userDeviceWallet");
        assertEq(address(userDeviceWallet.registry()), address(registry), "Registry should have been correct for userDeviceWallet");
        assertEq(address(userDeviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in userDeviceWallet should have matched");
        assertEq(userDeviceWallet.isValidESIMWallet(address(userESIMWallet)), true, "userESIMWallet should have been set to valid");
        assertEq(userDeviceWallet.canPullETH(address(userESIMWallet)), true, "userESIMWallet should be able to pull ETH");
        assertEq(address(userDeviceWallet.entryPoint()), address(entryPoint), "Entry point address should have been initialised in userDeviceWallet");
        assertEq(address(userDeviceWallet.verifier()), address(p256Verifier), "P256Verifier address should have been initialised in userDeviceWallet");

        bytes32[2] memory deviceWalletOwner = userDeviceWallet.getOwner();
        assertEq(deviceWalletOwner[0], pubKey[0], "X co-ordinate of userDeviceWallet owner should have matched");
        assertEq(deviceWalletOwner[1], pubKey[1], "Y co-ordinate of userDeviceWallet owner should have matched");

        // Check storage variables in eSIM wallet
        assertEq(userESIMWallet.eSIMUniqueIdentifier(), "ESIM_0_0", "ESIM unique identifier should not be empty for userESIMWallet");
        assertEq(userESIMWallet.newRequestedOwner(), address(0), "userESIMWallet's new requested owner should have been address(0)");
        assertEq(userESIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(userESIMWallet.owner(), address(userDeviceWallet), "userESIMWallet owner should have been device wallet");
    }

    function deployWallets() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](3);
        bytes32[2][] memory listOfKeys = new bytes32[2][](3);
        uint256[] memory salts = new uint256[](3);
        uint256[] memory deposits = new uint256[](3);

        deviceUniqueIdentifiers[0] = "Device_1";
        deviceUniqueIdentifiers[1] = "Device_2";
        deviceUniqueIdentifiers[2] = "Device_3";
        listOfKeys[0] = listOfOwnerKeys[0];
        listOfKeys[1] = listOfOwnerKeys[1];
        listOfKeys[2] = listOfOwnerKeys[2];
        salts[0] = 999;
        salts[1] = 919;
        salts[2] = 910;
        deposits[0] = 0;
        deposits[1] = 0;
        deposits[2] = 0;

        vm.startPrank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        );
        vm.stopPrank();

        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        deviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        deviceWallet2 = MockDeviceWallet(payable(wallets[1].deviceWallet));
        deviceWallet3 = MockDeviceWallet(payable(wallets[2].deviceWallet));
        eSIMWallet1 = MockESIMWallet(payable(wallets[0].eSIMWallet));
        eSIMWallet3 = MockESIMWallet(payable(wallets[1].eSIMWallet));

        vm.startPrank(admin);
        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(address(eSIMWallet1), "ESIM_0_1");
        deviceWallet2.setESIMUniqueIdentifierForAnESIMWallet(address(eSIMWallet3), "ESIM_1_1");
        vm.stopPrank();

        vm.startPrank(admin);
        // eSIMWallet2 -> no access to ETH, no eSIM identifier set
        address newESIMWallet = deviceWallet.deployESIMWallet(false, 919);
        vm.stopPrank();

        // eSIMWallet2 -> no access to ETH, no eSIM identifier set
        eSIMWallet2 = MockESIMWallet(payable(newESIMWallet));

        assertNotEq(address(deviceWallet), address(0), "deviceWallet address cannot be address(0)");
        assertNotEq(address(deviceWallet2), address(0), "deviceWallet2 address cannot be address(0)");
        assertNotEq(address(eSIMWallet1), address(0), "ESIMWallet1 address cannot be address(0)");
        assertNotEq(address(eSIMWallet2), address(0), "ESIMWallet2 address cannot be address(0)");
        assertNotEq(address(eSIMWallet2), address(0), "ESIMWallet3 address cannot be address(0)");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated for deviceWallet");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet2)), true, "isDeviceWalletValid mapping should have been updated for deviceWallet2");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated for deviceWallet1");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[1]), address(deviceWallet2), "uniqueIdentifierToDeviceWallet should have been updated for deviceWallet2");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet), "ESIM wallet1 should have been associated with deviceWallet");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet2)), address(deviceWallet), "ESIM wallet2 should have been associated with deviceWallet");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet3)), address(deviceWallet2), "ESIM wallet3 should have been associated with deviceWallet2");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "ESIMWallet1 should not have been on standby");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet2)), false, "ESIMWallet2 should not have been on standby");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet3)), false, "ESIMWallet3 should not have been on standby");

        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched for ownerKeys");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched for ownerKeys");

        bytes32[2] memory ownerKeys2 = registry.getDeviceWalletToOwner(address(deviceWallet2));
        assertEq(ownerKeys2[0], pubKey2[0], "X co-ordinate should have matched for ownerKeys2");
        assertEq(ownerKeys2[1], pubKey2[1], "Y co-ordinate should have matched for ownerKeys2");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched with deviceWallet");
        assertEq(deviceWallet2.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[1], "Device unique identifier should have matched with deviceWallet2");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct for deviceWallet");
        assertEq(address(deviceWallet2.registry()), address(registry), "Registry should have been correct for deviceWallet2");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in deviceWallet should have matched");
        assertEq(address(deviceWallet2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in deviceWallet2 should have matched");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), true, "ESIMWallet1 should have been set to valid");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet2)), true, "ESIMWallet2 should have been set to valid");
        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet3)), true, "ESIMWallet3 should have been set to valid");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "ESIMWallet1 should be able to pull ETH");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "ESIMWallet2 should not be able to pull ETH");
        assertEq(deviceWallet2.canPullETH(address(eSIMWallet3)), true, "ESIMWallet3 should be able to pull ETH");
        assertEq(address(deviceWallet.entryPoint()), address(entryPoint), "Entry point address should have been initialised in deviceWallet");
        assertEq(address(deviceWallet2.entryPoint()), address(entryPoint), "Entry point address should have been initialised in deviceWallet2");
        assertEq(address(deviceWallet.verifier()), address(p256Verifier), "P256Verifier address should have been initialised in deviceWallet");
        assertEq(address(deviceWallet2.verifier()), address(p256Verifier), "P256Verifier address should have been initialised in deviceWallet2");
        assertEq(address(deviceWallet.getVaultAddress()), address(vault), "Vault address should have matched in deviceWallet");
        assertEq(address(deviceWallet2.getVaultAddress()), address(vault), "Vault address should have matched in deviceWallet2");

        bytes32[2] memory deviceWalletOwner = deviceWallet.getOwner();
        assertEq(deviceWalletOwner[0], pubKey1[0], "X co-ordinate of deviceWallet owner should have matched");
        assertEq(deviceWalletOwner[1], pubKey1[1], "Y co-ordinate of deviceWallet owner should have matched");

        bytes32[2] memory deviceWalletOwner2 = deviceWallet2.getOwner();
        assertEq(deviceWalletOwner2[0], pubKey2[0], "X co-ordinate of deviceWallet2 owner should have matched");
        assertEq(deviceWalletOwner2[1], pubKey2[1], "Y co-ordinate of deviceWallet2 owner should have matched");

        // Check storage variables in eSIM wallet
        assertEq(address(eSIMWallet1.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet1 should have matched");
        assertEq(address(eSIMWallet2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet2 should have matched");
        assertEq(address(eSIMWallet3.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet3 should have matched");
        assertEq(address(eSIMWallet1.deviceWallet()), address(deviceWallet), "ESIM wallet1 should have correct device wallet");
        assertEq(address(eSIMWallet2.deviceWallet()), address(deviceWallet), "ESIM wallet2 should have correct device wallet");
        assertEq(address(eSIMWallet3.deviceWallet()), address(deviceWallet2), "ESIM wallet3 should have correct device wallet");
        assertEq(eSIMWallet1.eSIMUniqueIdentifier(), "ESIM_0_1", "ESIM unique identifier should not be empty for eSIMWallet1");
        assertEq(eSIMWallet3.eSIMUniqueIdentifier(), "ESIM_1_1", "ESIM unique identifier should not be empty for eSIMWallet3");
        assertEq(bytes(eSIMWallet2.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "ESIM wallet1's new requested owner should have been address(0)");
        assertEq(eSIMWallet2.newRequestedOwner(), address(0), "ESIM wallet2's new requested owner should have been address(0)");
        assertEq(eSIMWallet3.newRequestedOwner(), address(0), "ESIM wallet3's new requested owner should have been address(0)");
        assertEq(eSIMWallet1.getTransactionHistory().length, 0, "Transaction history1 should have been empty");
        assertEq(eSIMWallet2.getTransactionHistory().length, 0, "Transaction history2 should have been empty");
        assertEq(eSIMWallet3.getTransactionHistory().length, 0, "Transaction history3 should have been empty");
        assertEq(eSIMWallet1.owner(), address(deviceWallet), "ESIMWallet1 owner should have been device wallet");
        assertEq(eSIMWallet2.owner(), address(deviceWallet), "ESIMWallet2 owner should have been device wallet");
        assertEq(eSIMWallet3.owner(), address(deviceWallet2), "ESIMWallet3 owner should have been device wallet");
    }

    /// @notice Checks the registry and device wallet view of a single eSIM wallet binding.
    /// Kept as a helper rather than four inline assertions because the via-IR pipeline runs out
    /// of stack slots when this many consecutive assertions are fused into one test body.
    function _assertESIMWalletBinding(
        MockDeviceWallet _deviceWallet,
        MockESIMWallet _eSIMWallet,
        bool _onStandby,
        address _associatedDeviceWallet,
        bool _canPullETH,
        bool _isValidForDeviceWallet
    ) internal view {
        assertEq(registry.isESIMWalletOnStandby(address(_eSIMWallet)), _onStandby, "Unexpected standby status for the eSIM wallet");
        assertEq(registry.isESIMWalletValid(address(_eSIMWallet)), _associatedDeviceWallet, "Unexpected device wallet associated with the eSIM wallet");
        assertEq(_deviceWallet.canPullETH(address(_eSIMWallet)), _canPullETH, "Unexpected ETH pull access for the eSIM wallet");
        assertEq(_deviceWallet.isValidESIMWallet(address(_eSIMWallet)), _isValidForDeviceWallet, "Unexpected eSIM wallet validity for the device wallet");
    }

    function test_deployESIMWallet() public {
        deployWallets();
    }

    function test_setESIMUniqueIdentifierForAnESIMWallet_empty() public {
        deployWallets();

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("_eSIMUniqueIdentifier 0");
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(
            address(eSIMWallet2),
            ""
        );
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifierForAnESIMWallet_deviceWallet() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert(bytes4(keccak256("OnlyESIMWalletAdminOrRegistry()")));
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(
            address(eSIMWallet2),
            "ESIM_0_2"
        );
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifierForAnESIMWallet() public {
        deployWallets();

        vm.startPrank(eSIMWalletAdmin);
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(
            address(eSIMWallet2),
            "ESIM_0_2"
        );
        vm.stopPrank();

        assertEq(eSIMWallet2.eSIMUniqueIdentifier(), "ESIM_0_2", "ESIM unique identifier should have been initialised");
    }

    function test_payETHForDataBundles_unauthorised() public {
        deployWallets();

        vm.deal(user1, 0.1 ether);
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAssociatedESIMWallets()")));
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();
    }

    function test_payETHForDataBundles_revokedESIMWallet() public {
        deployWallets();

        vm.deal(address(deviceWallet), 0.1 ether);
        vm.startPrank(address(eSIMWallet2));
        vm.expectRevert("Access revoked");
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();
    }

    function test_payETHForDataBundles_noFunds() public {
        deployWallets();

        vm.startPrank(address(eSIMWallet1));
        vm.expectRevert();
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();
    }

    function test_payETHForDataBundles() public {
        deployWallets();

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(address(eSIMWallet1));
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 0.9 ether, "Device wallet balance should have reduced to 0.9 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have increased to 0.2 ether");
    }

    function test_pullETH_unauthorise() public {
        deployWallets();

        vm.deal(address(deviceWallet), 2 ether);
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAssociatedESIMWallets()")));
        deviceWallet.pullETH(1000000000000000000);  // 1 ETH
        vm.stopPrank();
    }

    function test_pullETH_revokedESIMWallet() public {
        deployWallets();

        vm.deal(address(deviceWallet), 2 ether);
        vm.startPrank(address(eSIMWallet2));
        vm.expectRevert("Access revoked");
        deviceWallet.pullETH(1000000000000000000);  // 1 ETH
        vm.stopPrank();
    }

    function test_pullETH() public {
        deployWallets();

        vm.deal(address(deviceWallet), 2 ether);
        vm.startPrank(address(eSIMWallet1));
        deviceWallet.pullETH(1000000000000000000);  // 1 ETH
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 1 ether, "Device wallet balance should have been 1 ETH");
        assertEq(address(eSIMWallet1).balance, 1 ether, "ESIM wallet balance should have been 1 ETH");
    }

    function test_getVaultAddress() public {
        deployWallets();

        vm.startPrank(user1);
        address vaultAddress = deviceWallet.getVaultAddress();
        vm.stopPrank();

        assertEq(vaultAddress, vault, "Vault address should have matched");
    }

    function test_removeESIMWallet_unauthorised() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlySelfOrAssociatedESIMWallet()")));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();
    }

    function test_removeESIMWallet() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(0), false, false);
    }

    function test_removeESIMWallet_noETHToCallBack() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 10 ether, "Device wallet balance should have been the same, 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have been the same, 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(0), false, false);
    }

    /// @notice An associated eSIM wallet may remove itself but not a sibling
    function test_removeESIMWallet_siblingCannotRemoveAnother() public {
        deployWallets();

        vm.deal(address(eSIMWallet2), 1 ether);

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.OnlySelfOrAssociatedESIMWallet.selector);
        deviceWallet.removeESIMWallet(address(eSIMWallet2), true);

        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet2)), true, "The sibling must still be bound");
        assertEq(address(eSIMWallet2).balance, 1 ether, "The sibling must keep its ETH");

        // The same caller removing itself is still allowed
        vm.prank(address(eSIMWallet1));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), false);
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "A wallet must still be able to remove itself");
    }

    /// @notice A wallet whose logic re-enters the device wallet during its own removal must find
    /// that it has already lost both its association and its right to pull ETH
    function test_removeESIMWallet_reentrantCallbackCannotPullETH() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);

        ReentrantESIMWallet handlerImpl = new ReentrantESIMWallet(DeviceWallet(payable(address(deviceWallet))));
        vm.etch(address(eSIMWallet1), address(handlerImpl).code);
        ReentrantESIMWallet handler = ReentrantESIMWallet(payable(address(eSIMWallet1)));

        vm.prank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);

        assertEq(address(deviceWallet).balance, 10 ether, "Device wallet must not have lost any ETH to the callback");
        assertEq(handler.pullETHSucceededDuringRemoval(), false, "pullETH must not succeed from inside the removal");
        assertEq(handler.wasStillValidDuringRemoval(), false, "The wallet must already be unbound when the callback runs");
        assertEq(handler.couldStillPullETHDuringRemoval(), false, "The wallet must already have lost ETH access when the callback runs");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(0), false, false);
    }

    function test_toggleAccessToETH_unauthorised() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(user1);
        vm.expectRevert("Only self");
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();
    }

    function test_toggleAccessToETH_revoke_deviceWalletHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert("Access revoked");
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();
    }

    function test_toggleAccessToETH_revoke_eSIMWalletHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(eSIMWallet1), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(eSIMWallet1).balance, 0.9 ether, "ESIMWalletAdmin balance should have been decreased to 0.9 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        
        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_toggleAccessToETH_revoke_userHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle{value: 0.2 ether}(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(eSIMWallet1).balance, 0.1 ether, "ESIMWallet balance should have been increased to 0.1 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        assertEq(eSIMWalletAdmin.balance, 0.8 ether, "User balance should have been decreased to 0.8 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_toggleAccessToETH_grant_deviceWalletHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "eSIMWallet2 should not be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet2),
            true
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), true, "eSIMWallet2 should be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet2.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        assertEq(address(deviceWallet).balance, 0.9 ether, "Device wallet balance should have been decreased to 0.9 ETH");
        
        DataBundleDetails[] memory history = eSIMWallet2.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_toggleAccessToETH_grant_userHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "eSIMWallet2 should not be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet2),
            true
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), true, "eSIMWallet2 should be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet2.buyDataBundle{value: 0.2 ether}(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(eSIMWallet2).balance, 0.1 ether, "ESIMWallet balance should have been increased to 0.1 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        assertEq(eSIMWalletAdmin.balance, 0.8 ether, "User balance should have been decreased to 0.8 ETH");
        
        DataBundleDetails[] memory history = eSIMWallet2.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_addESIMWallet_unauthorised() public {
        deployWallets();

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyRegistryOrDeviceWalletFactoryOrOwner()")));
        deviceWallet.addESIMWallet(
            address(eSIMWallet1),
            true
        );
        vm.stopPrank();
    }

    function test_addESIMWallet_withoutTransferringOwnership() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert("Accept ownership first");
        deviceWallet.addESIMWallet(
            address(eSIMWallet3),
            true
        );
        vm.stopPrank();
    }

    function test_addESIMWallet_alreadyOwnedBySelf() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert("ESIM wallet already owned");
        deviceWallet.addESIMWallet(
            address(eSIMWallet1),
            true
        );
        vm.stopPrank();
    }

    function test_addESIMWallet_afterRemoveESIMWallet_andETHCallback() public {
        deployWallets();
        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        // 1. deviceWallet requests transfer of ownership
        // 2. remove eSIM wallet from the device wallet
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(0), false, false);
        
        vm.startPrank(currentOwner);
        vm.expectRevert("Unauthorised caller");
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet1), false);

        vm.expectRevert("Unauthorised action");
        registry.updateDeviceWalletAssociatedWithESIMWallet(address(eSIMWallet1), currentOwner);
        vm.stopPrank();

        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(0), "Previous owner should not be able to change the device wallet");

        // Since the eSIM wallet was already removed, the user cannot do the operation again
        vm.startPrank(address(deviceWallet));
        vm.expectRevert("Unknown eSIM wallet");
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        // 3. deviceWallet2 accepts ownership of eSIMWallet1
        vm.deal(address(deviceWallet2), 5 ether);
        vm.startPrank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address newOwner = eSIMWallet1.owner();
        assertEq(newOwner, address(deviceWallet2), "newOwner should have accepted the ownership");

        address requestedOwner = eSIMWallet1.newRequestedOwner();
        assertEq(requestedOwner, address(0), "newRequestedOwner should have reset to address(0)");

        // 4. deviceWallet2 adds/binds eSIMWallet1
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), false);
        vm.stopPrank();

        assertEq(address(deviceWallet2).balance, 5 ether, "Device wallet balance should have been the same");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet2, eSIMWallet1, false, address(deviceWallet2), false, true);

        // 5. deviceWallet2 grants access to eSIMWallet1 to pull ETH (This could also be done in a single step during addESIMWallet function call)
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.toggleAccessToETH(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(deviceWallet2.canPullETH(address(eSIMWallet1)), true, "ESIMWallet1 should have access to ETH for deviceWallet2");
        assertEq(address(eSIMWallet1).balance, 0, "eSIMWallet1 balance should have been 0 ETH");

        // 6. Add ETH to deviceWallet2, and buy data bundle for eSIMWallet1
        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            1 ether
        );

        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(deviceWallet2).balance, 4 ether, "Device wallet balance should have been 4 ETH");
        assertEq((deviceWallet2.getVaultAddress()).balance, 1 ether, "Vault balance should have increased by 1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Transaction history's data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 1 ether, "Transaction history's data bundle price should have been correct");
    }

    // FIXED [C-01]: Malicious but registered Device Wallet can steal an eSIM Wallet
    /**
        1. Alice owns an eSIM Wallet (0xESIM1), linked to her device (0xDeviceAlice)**.
        2. Alice requests ownership transfer of 0xESIM1 to Bob
        3. Before Bob could accept ownership; Carol, a malicious actor tries to claim 0xESIM1
        3. Carol calls: updateDeviceWalletAssociatedWithESIMWallet(0xESIM1, 0xDeviceCarol);
        4. Aliceʼs eSIM Wallet is now controlled by Carolʼs device.
        5. Carol gains control over Aliceʼs eSIM wallet.
     */
    function test_transferESIMWallet_frontrun() public {
        deployWallets();
        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        // 1. deviceWallet requests transfer of ownership
        // 2. Alice (deviceWallet) unbinds/removes eSIMWallet1
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");

        vm.startPrank(address(deviceWallet));
        vm.expectRevert("Unknown eSIM wallet");
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(0), false, false);

        // 3. Carol (deviceWallet3) tries to steal standby eSIMWallet (eSIMWallet1)
        vm.startPrank(address(deviceWallet3));
        vm.expectRevert("Unauthorise caller or already assigned");
        registry.updateDeviceWalletAssociatedWithESIMWallet(
            address(eSIMWallet1),
            address(deviceWallet3)
        );
        vm.stopPrank();

        currentOwner = eSIMWallet1.owner();
        assertNotEq(address(deviceWallet3), eSIMWallet1.owner(), "Critical Error: ESIMWallet stolen");

        // 4. deviceWallet2 accepts ownership of eSIMWallet1
        vm.deal(address(deviceWallet2), 5 ether);
        vm.startPrank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address newOwner = eSIMWallet1.owner();
        assertEq(newOwner, address(deviceWallet2), "newOwner should have accepted the ownership");

        address requestedOwner = eSIMWallet1.newRequestedOwner();
        assertEq(requestedOwner, address(0), "newRequestedOwner should have reset to address(0)");

        // 5. deviceWallet2 adds/binds eSIMWallet1
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), false);
        vm.stopPrank();

        assertEq(address(deviceWallet2).balance, 5 ether, "Device wallet balance should have been the same");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet2, eSIMWallet1, false, address(deviceWallet2), false, true);

        // 6. deviceWallet2 grants access to eSIMWallet1 to pull ETH (This could also be done in a single step during addESIMWallet function call)
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.toggleAccessToETH(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(deviceWallet2.canPullETH(address(eSIMWallet1)), true, "ESIMWallet1 should have access to ETH for deviceWallet2");
        assertEq(address(eSIMWallet1).balance, 0, "eSIMWallet1 balance should have been 0 ETH");

        // 7. Add ETH to deviceWallet2, and buy data bundle for eSIMWallet1
        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            1 ether
        );

        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(deviceWallet2).balance, 4 ether, "Device wallet balance should have been 4 ETH");
        assertEq((deviceWallet2.getVaultAddress()).balance, 1 ether, "Vault balance should have increased by 1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Transaction history's data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 1 ether, "Transaction history's data bundle price should have been correct");
    }

    /// @notice A real assertion captured from a device, checked against the verifier directly.
    /// It is the only evidence the client data checks agree with what authenticators actually
    /// emit: challengeIndex 23 lands on the real `"challenge":"` key, the type field sits where
    /// the library expects it, and the flags byte carries user verification. It cannot go through
    /// isValidSignature, whose challenge is derived from the message rather than being it, because
    /// the key that signed this is not in the repo and the assertion cannot be remade.
    function test_verifySignature_acceptsACapturedDeviceAssertion() public view {
        WebAuthnSignature memory assertion = abi.decode(
            hex"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000001700000000000000000000000000000000000000000000000000000000000000016e45bdb082f70af9ae84d4fe8a7d1bf69e59389ca10b52504d6abb7fa664ba137051a8ff68e294989e5287df16f036f581d838468abf2680611ea9bc18386943000000000000000000000000000000000000000000000000000000000000002593613e408a25dbfc09d33b17fdc30d43e4b61f59a2ff388f28dd4e073ba058fb1d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000be7b2274797065223a22776562617574686e2e676574222c226368616c6c656e6765223a224b364e437358484c632d5a4b69455a37733561526b524955655f384139687646374451486f642d686b7177222c226f726967696e223a22616e64726f69643a61706b2d6b65792d686173683a53447852554851355957742d6475656744537a4766515f4757455f4146314556796e6d2d6b73544e474755222c22616e64726f69645061636b6167654e616d65223a226170702e6b6f6b696f227d0000",
            (WebAuthnSignature)
        );

        bool valid = p256Verifier.verifySignature({
            message: hex"2ba342b171cb73e64a88467bb396919112147bff00f61bc5ec3407a1dfa192ac",
            requireUserVerification: true,
            webAuthnSignature: assertion,
            x: uint256(bytes32(hex"827b60c4e33f9796284180b39a6e02d7442b2d5189eb3c7d21f384e787104655")),
            y: uint256(bytes32(hex"0dbb6683c742e4d0a03c004e55a0c7c1c241ac30bf59711f7c8d2d51cf41f4df"))
        });

        assertTrue(valid, "A real device assertion must verify");
    }

    /// @notice The challenge the wallet expects for a given message, chain and expiry. A test that
    /// signs has to derive this the same way the wallet does, which is the point: the two
    /// derivations agreeing is what the format guarantees.
    function _erc1271Challenge(
        address _wallet,
        uint48 _validUntil,
        bytes32 _messageHash
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n91",
                    uint8(1),
                    _validUntil,
                    block.chainid,
                    _wallet,
                    _messageHash
                )
            )
        );
    }

    function test_isValidSignature_acceptsAnAssertionSignedForThisMessage() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(_erc1271Challenge(address(userDeviceWallet), validUntil, messageHash))
        );

        bytes4 returnValue = userDeviceWallet.isValidSignature(messageHash, signature);
        assertEq(hex"1626ba7e", returnValue, "An assertion signed for this message hash must be accepted");
    }

    /// @notice Holding the owner key is not enough. An assertion made for a different message
    /// carries a different challenge in its clientDataJSON, and the comparison has to catch that.
    function test_isValidSignature_rejectsAnAssertionSignedForAnotherMessage() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(
                _erc1271Challenge(
                    address(userDeviceWallet),
                    validUntil,
                    keccak256("a message the wallet was never asked about")
                )
            )
        );

        bytes4 returnValue = userDeviceWallet.isValidSignature(
            keccak256("a message the wallet was asked to sign"),
            signature
        );
        assertEq(hex"ffffffff", returnValue, "An assertion made for another message must be rejected");
    }

    /// @notice validUntil is checked against the clock but was not part of what the authenticator
    /// signed, so rewriting those six bytes used to extend any expired signature indefinitely.
    function test_isValidSignature_rejectsATamperedValidUntil() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory assertion = WebAuthnSigner.sign(
            _erc1271Challenge(address(userDeviceWallet), validUntil, messageHash)
        );

        assertEq(
            hex"1626ba7e",
            userDeviceWallet.isValidSignature(messageHash, abi.encodePacked(uint8(1), validUntil, assertion)),
            "The expiry it was made under must be accepted"
        );
        assertEq(
            hex"ffffffff",
            // The same assertion, presented with a later expiry than the one it was made under
            userDeviceWallet.isValidSignature(messageHash, abi.encodePacked(uint8(1), validUntil + 1 days, assertion)),
            "A rewritten expiry must invalidate the signature"
        );
    }

    /// @notice createAccount is public and does not touch the registry, so a second wallet can be
    /// deployed at another salt holding the same owner key. Its address has to be part of what was
    /// signed, otherwise one wallet's signatures are accepted by the other.
    function test_isValidSignature_rejectsASignatureMadeForAnotherWallet() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        DeviceWallet siblingWallet = deviceWalletFactory.createAccount("Device_Sibling", ownerKey, 25042026);
        assertTrue(address(siblingWallet) != address(userDeviceWallet), "The two wallets must be distinct");

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(_erc1271Challenge(address(userDeviceWallet), validUntil, messageHash))
        );

        assertEq(
            hex"1626ba7e",
            userDeviceWallet.isValidSignature(messageHash, signature),
            "The wallet it was signed for must accept it"
        );
        assertEq(
            hex"ffffffff",
            siblingWallet.isValidSignature(messageHash, signature),
            "A sibling holding the same owner key must reject it"
        );
    }

    function test_webAuthn_encodeDecode() public {
        // WebAuthnSignature memory webAuthnSignatureData = WebAuthnSignature(
        //     "0x93613e408a25dbfc09d33b17fdc30d43e4b61f59a2ff388f28dd4e073ba058fb1d00000000",
        //     '{"type":"webauthn.get","challenge":"MTgyNmU2NmUxMzI0ZWVjNTk5M2E2OGE5YTZmMDdhMzIwNWM5MjVhMmVhMDNhYWEzMTI1MzEwZjQwM2E1MzVjZA","origin":"android:apk-key-hash:SDxRUHQ5YWt-duegDSzGfQ_GWE_AF1EVynm-ksTNGGU","androidPackageName":"app.kokio"}',
        //     23,
        //     1,
        //     45961455800004125052396584148558921233963633569227808536744376686154150690997,
        //     21146418585897763519974678241940796266068219257824371122281587248552492377525
        // );
        
        // bytes memory encodedData = abi.encode(webAuthnSignatureData);
        // console.logBytes(encodedData);

        // WebAuthnSignature memory decodedWebAuthn = abi.decode(encodedData, (WebAuthnSignature));
        // console.logBytes(decodedWebAuthn.authenticatorData);
        // console.logString(decodedWebAuthn.clientDataJSON);
        // console.logUint(decodedWebAuthn.challengeIndex);
        // console.logUint(decodedWebAuthn.typeIndex);
        // console.logUint(decodedWebAuthn.r);
        // console.logUint(decodedWebAuthn.s);
    }

    /// @notice A signature too short to carry a header and a challenge must fail the operation,
    /// not the bundle. validateUserOp returns packed validationData whose low 160 bits the
    /// EntryPoint reads as an authorizer, so anything other than 0 or SIG_VALIDATION_FAILED names
    /// an aggregator. 0xffffffff named one that does not exist.
    function test_validateUserOp_shortSignatureFailsGracefully() public {
        deployWallets();

        PackedUserOperation memory userOp;
        userOp.sender = address(deviceWallet);
        // Exactly a version byte, six validUntil bytes and a 32 byte challenge, which the guard
        // rejects because it leaves no room for the WebAuthn assertion itself
        userOp.signature = new bytes(39);

        vm.prank(address(deviceWallet.entryPoint()));
        uint256 validationData = deviceWallet.validateUserOp(userOp, bytes32(0), 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "A short signature must fail the operation");
        assertEq(
            validationData >> 160,
            0,
            "Failure must carry no validity window, otherwise the EntryPoint reads a time range"
        );
    }
}
