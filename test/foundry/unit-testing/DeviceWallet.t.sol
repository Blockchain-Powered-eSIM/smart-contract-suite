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
    MockESIMWallet eSIMWallet1;     // has access to ETH, has eSIM identifier set        
    MockESIMWallet eSIMWallet2;     // no access to ETH, no eSIM identifier set

    function deployWallets() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletAsAdmin(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999,
            0
        );
        vm.stopPrank();

        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        deviceWallet = MockDeviceWallet(payable(wallet.deviceWallet));
        eSIMWallet1 = MockESIMWallet(payable(wallet.eSIMWallet));

        vm.startPrank(admin);
        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(address(eSIMWallet1), "ESIM_0_1");
        vm.stopPrank();

        vm.startPrank(admin);
        // eSIMWallet2 -> no access to ETH, no eSIM identifier set
        address newESIMWallet = deviceWallet.deployESIMWallet(false, 919);
        vm.stopPrank();

        // eSIMWallet2 -> no access to ETH, no eSIM identifier set
        eSIMWallet2 = MockESIMWallet(payable(newESIMWallet));

        assertNotEq(address(deviceWallet), address(0), "Device wallet address cannot be address(0)");
        assertNotEq(address(eSIMWallet1), address(0), "ESIM wallet address cannot be address(0)");
        assertNotEq(address(eSIMWallet2), address(0), "ESIM wallet address cannot be address(0)");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet), "ESIM wallet1 should have been associated with device wallet");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet2)), address(deviceWallet), "ESIM wallet2 should have been associated with device wallet");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "ESIM wallet1 should not have been on standby");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet2)), false, "ESIM wallet2 should not have been on standby");
        
        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), true, "ESIMWallet1 should have been set to valid");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet2)), true, "ESIMWallet2 should have been set to valid");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "ESIMWallet1 should be able to pull ETH");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "ESIMWallet2 should not be able to pull ETH");
        assertEq(address(deviceWallet.entryPoint()), address(entryPoint), "Entry point address should have been initialised");
        assertEq(address(deviceWallet.verifier()), address(p256Verifier), "P256Verifier address should have been initialised");
        assertEq(address(deviceWallet.getVaultAddress()), address(vault), "Vault address should have matched");

        bytes32[2] memory deviceWalletOwner = deviceWallet.getOwner();
        assertEq(deviceWalletOwner[0], pubKey1[0], "X co-ordinate of device wallet owner should have matched");
        assertEq(deviceWalletOwner[1], pubKey1[1], "Y co-ordinate of device wallet owner should have matched");

        // Check storage variables in eSIM wallet
        assertEq(address(eSIMWallet1.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet1 should have matched");
        assertEq(address(eSIMWallet2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet2 should have matched");
        assertEq(address(eSIMWallet1.deviceWallet()), address(deviceWallet), "ESIM wallet1 should have correct device wallet");
        assertEq(address(eSIMWallet2.deviceWallet()), address(deviceWallet), "ESIM wallet2 should have correct device wallet");
        assertEq(eSIMWallet1.eSIMUniqueIdentifier(), "ESIM_0_1", "ESIM unique identifier should not be empty");
        assertEq(bytes(eSIMWallet2.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "ESIM wallet1's new requested owner should have been address(0)");
        assertEq(eSIMWallet2.newRequestedOwner(), address(0), "ESIM wallet2's new requested owner should have been address(0)");
        assertEq(eSIMWallet1.getTransactionHistory().length, 0, "Transaction history1 should have been empty");
        assertEq(eSIMWallet2.getTransactionHistory().length, 0, "Transaction history2 should have been empty");
        assertEq(eSIMWallet1.owner(), address(deviceWallet), "ESIMWallet1 owner should have been device wallet");
        assertEq(eSIMWallet2.owner(), address(deviceWallet), "ESIMWallet2 owner should have been device wallet");
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
}
