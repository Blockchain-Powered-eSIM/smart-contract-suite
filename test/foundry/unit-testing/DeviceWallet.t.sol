// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

contract DeviceWalletTest is DeployerBase {

    MockDeviceWallet deviceWallet;
    MockDeviceWallet deviceWallet2;
    MockDeviceWallet deviceWallet3; // [C-01]: Carol's (Malicious actor) device wallet
    MockESIMWallet eSIMWallet1;     // has access to ETH, has eSIM identifier set, belongs to deviceWallet1        
    MockESIMWallet eSIMWallet2;     // no access to ETH, no eSIM identifier set, belongs to deviceWallet1
    MockESIMWallet eSIMWallet3;     // has access to ETH, has eSIM identifier set, belongs to deviceWallet2

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
        vm.expectRevert(bytes4(keccak256("OnlyDeviceWalletFactoryOrOwner()")));
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

        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "eSIM wallet should have been set to standby");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(0), "Device wallet associated with the eSIM wallet should have been set to address(0)");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "ESIM wallet should not be allowed to pull ETH");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "ESIM wallet should have been set to invalid for the device wallet");
    }

    function test_removeESIMWallet_noETHToCallBack() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 10 ether, "Device wallet balance should have been the same, 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have been the same, 0 ETH");

        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "eSIM wallet should have been set to standby");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(0), "Device wallet associated with the eSIM wallet should have been set to address(0)");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "ESIM wallet should not be allowed to pull ETH");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "ESIM wallet should have been set to invalid for the device wallet");
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
        // 1. deviceWallet requests transfer of ownership
        deployWallets();

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");

        // 2. deviceWallet unbinds/removes eSIMWallet1
        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "eSIM wallet should have been set to standby");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(0), "Device wallet associated with the eSIM wallet should have been set to address(0)");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "ESIM wallet should not be allowed to pull ETH");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "ESIM wallet should have been set to invalid for the device wallet");

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

        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "eSIM wallet should have no longer been set as standby");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet2), "Device wallet associated with the eSIM wallet should have been set to address(0)");
        assertEq(deviceWallet2.canPullETH(address(eSIMWallet1)), false, "ESIM wallet should not be allowed to pull ETH from deviceWallet2");
        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet1)), true, "ESIM wallet should have been set to valid for the deviceWallet2");

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
        // 1. deviceWallet requests transfer of ownership
        deployWallets();

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");

        // 2. Alice (deviceWallet) unbinds/removes eSIMWallet1
        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "eSIM wallet should have been set to standby");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(0), "Device wallet associated with the eSIM wallet should have been set to address(0)");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "ESIM wallet should not be allowed to pull ETH");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "ESIM wallet should have been set to invalid for the device wallet");

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

        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "eSIM wallet should have no longer been set as standby");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet2), "Device wallet associated with the eSIM wallet should have been set to address(0)");
        assertEq(deviceWallet2.canPullETH(address(eSIMWallet1)), false, "ESIM wallet should not be allowed to pull ETH from deviceWallet2");
        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet1)), true, "ESIM wallet should have been set to valid for the deviceWallet2");

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
}
