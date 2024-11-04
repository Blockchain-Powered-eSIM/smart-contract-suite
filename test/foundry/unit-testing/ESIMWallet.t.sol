// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

contract ESIMWalletTest is DeployerBase {

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

    function test_setESIMUniqueIdentifier_unauthorised() public {
        deployWallets();

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyDeviceWallet()")));
        eSIMWallet2.setESIMUniqueIdentifier("ESIM_0_2");
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifier_callTwiceFail() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert("Already initialised");
        eSIMWallet1.setESIMUniqueIdentifier("ESIM_0_2");
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifier() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        eSIMWallet2.setESIMUniqueIdentifier("ESIM_0_2");
        vm.stopPrank();

        assertEq(eSIMWallet2.eSIMUniqueIdentifier(), "ESIM_0_2", "ESIM identifier should have been initialised");
    }

    function test_populateHistory() public {
        deployWallets();

        vm.startPrank(address(registry));
        bool historyPopulated = eSIMWallet1.populateHistory(
            customDataBundleDetails[0]
        );
        vm.stopPrank();

        assertEq(historyPopulated, true, "History should have been populated");
        assertNotEq(eSIMWallet1.getTransactionHistory().length, 0, "Transaction history should have neen non-zero");
    }
    
    function test_populateHistory_callTwiceFail() public {
        deployWallets();

        vm.startPrank(address(registry));
        bool historyPopulated = eSIMWallet1.populateHistory(
            customDataBundleDetails[0]
        );
        vm.stopPrank();

        assertEq(historyPopulated, true, "History should have been populated");
        assertNotEq(eSIMWallet1.getTransactionHistory().length, 0, "Transaction history should have neen non-zero");

        vm.startPrank(address(registry));
        vm.expectRevert("Wallet already in use");
        eSIMWallet1.populateHistory(
            customDataBundleDetails[0]
        );
        vm.stopPrank();
    }

    function test_owner() public {
        deployWallets();
        address owner = eSIMWallet1.owner();

        assertEq(owner, address(deviceWallet), "Device wallet should have been the owner");
    }

    function test_requestTransferOwnership_withoutOwner() public {
        deployWallets();
        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyDeviceWallet()")));
        eSIMWallet1.requestTransferOwnership(user1);
        vm.stopPrank();
    }

    function test_requestTransferOwnership_toRandomAddress() public {
        deployWallets();
        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        vm.expectRevert("Invalid _newOwner");
        eSIMWallet1.requestTransferOwnership(user1);
        vm.stopPrank();
    }

    function test_requestTransferOwnership() public {
        deployWallets();

        address admin = deviceWalletFactory.eSIMWalletAdmin();

        // Deploy new device wallet
        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletAsAdmin(
            customDeviceUniqueIdentifiers[1],
            pubKey2,
            919,
            0
        );
        vm.stopPrank();

        deviceWallet2 = MockDeviceWallet(payable(wallet.deviceWallet));

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");
    }

    function test_requestTransferOwnership_revoke() public {
        test_requestTransferOwnership();

        address currentOwner = eSIMWallet1.owner();

        vm.startPrank(currentOwner);
        eSIMWallet1.requestTransferOwnership(currentOwner);
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "newRequestedOwner should be reset to address(0)");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");
    }

    function test_acceptOwnershipTransfer_withoutRequest() public {
        deployWallets();

        vm.startPrank(user2);
        vm.expectRevert("Not approved");
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();
    }

    function test_acceptOwnershipTransfer_currentOwner() public {
        test_requestTransferOwnership();

        address currentOwner = eSIMWallet1.owner();
        vm.startPrank(currentOwner);
        vm.expectRevert("Not approved");
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();
    }

    function test_acceptOwnershipTransfer() public {
        test_requestTransferOwnership();

        address requestedOwner = eSIMWallet1.newRequestedOwner();

        vm.startPrank(requestedOwner);
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address newOwner = eSIMWallet1.owner();
        assertEq(newOwner, requestedOwner, "newOwner should have accepted the ownership");

        requestedOwner = eSIMWallet1.newRequestedOwner();
        assertEq(requestedOwner, address(0), "newRequestedOwner should have reset to address(0)");
    }

    function test_acceptOwnershipTransfer_afterRevoke() public {
        test_requestTransferOwnership_revoke();

        // Previous requested owner tries to accept ownership after revocation
        vm.startPrank(address(deviceWallet2));
        vm.expectRevert("Not approved");
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address owner = eSIMWallet1.owner();
        assertEq(owner, address(deviceWallet), "Owner should not have updated");
    }

    function test_transferOwnership() public {
        deployWallets();

        vm.startPrank(user1);
        vm.expectRevert("Use acceptOwnershipTransfer instead.");
        eSIMWallet1.transferOwnership(user1);
        vm.stopPrank();
    }

    function test_acceptOwnershipTransfer_addESIMWallet() public {
        // Current owner requests transfer of ownership to the new owner
        test_requestTransferOwnership();

        // Current owner sets the eSIM wallet to standby before the new owner accepts the ownership
        vm.startPrank(address(deviceWallet));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet1), true);
        vm.stopPrank();
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "ESIMWallet1 should have been on standBy");

        // New owner accepts transfer of ownership to themselves
        address requestedOwner = eSIMWallet1.newRequestedOwner();
        vm.startPrank(requestedOwner);
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address newOwner = address(deviceWallet2);
        assertEq(newOwner, requestedOwner, "newOwner should have accepted the ownership");

        requestedOwner = eSIMWallet1.newRequestedOwner();
        assertEq(requestedOwner, address(0), "newRequestedOwner should have reset to address(0)");

        // New owner adds eSIM wallet to their device wallet, and removes eSIM wallet from standBy
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet1)), true, "eSIM wallet added should have been set to valid");
        assertEq(deviceWallet2.canPullETH(address(eSIMWallet1)), true, "eSIM wallet should have ability to pull ETH");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "ESIMWallet1 should not have been on standBy");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet2), "Registry should have updated the eSIM wallet to the new device wallet");
    }
}
