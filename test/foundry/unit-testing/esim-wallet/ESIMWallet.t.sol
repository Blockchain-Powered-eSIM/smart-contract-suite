// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

contract ESIMWalletTest is DeployerBase {

    /// @notice A rotated admin has to reach buyDataBundle, which the factory alone does not
    /// @dev This path pulls whatever price it is given out of the device wallet and sends it to
    ///      the vault, so an admin address that changes only on the factory leaves the retired key
    ///      able to drain wallets and leaves the new key unable to do its job.
    function test_buyDataBundle_followsTheRotatedAdmin() public {
        deployWallets();
        address retiredAdmin = registry.eSIMWalletAdmin();

        vm.prank(retiredAdmin);
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        vm.deal(address(deviceWallet), 1 ether);

        vm.prank(retiredAdmin);
        vm.expectRevert(Errors.OnlyDeviceWalletOrESIMWalletAdmin.selector);
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 1));

        vm.prank(user3);
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 1));

        (, uint256 price) = eSIMWallet1.transactionHistory(0);
        assertEq(price, 1, "The purchase made by the rotated admin must be recorded");
    }

    MockDeviceWallet deviceWallet;
    MockDeviceWallet deviceWallet2;
    MockESIMWallet eSIMWallet1;     // has access to ETH, has eSIM identifier set        
    MockESIMWallet eSIMWallet2;     // no access to ETH, no eSIM identifier set

    function deployWallets() public {
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
        vm.expectRevert(abi.encodeWithSelector(Errors.ESIMIdentifierAlreadySet.selector, eSIMWallet1.eSIMUniqueIdentifier()));
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
    
    /// @notice A history long enough to need more than one batch arrives whole and in order
    /// @dev The registry copies pre-deployment history in batches now, so a second call has to
    ///      append after the first rather than refuse or overwrite it.
    function test_populateHistory_appendsTheSecondBatchAfterTheFirst() public {
        deployWallets();

        DataBundleDetails[] memory secondBatch = new DataBundleDetails[](2);
        secondBatch[0] = DataBundleDetails("DB_ID_6", 61);
        secondBatch[1] = DataBundleDetails("DB_ID_7", 71);

        vm.startPrank(address(registry));
        eSIMWallet1.populateHistory(customDataBundleDetails[0]);
        eSIMWallet1.populateHistory(secondBatch);
        vm.stopPrank();

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 7, "Both batches should have landed");

        for (uint256 i = 0; i < customDataBundleDetails[0].length; ++i) {
            assertEq(history[i].dataBundleID, customDataBundleDetails[0][i].dataBundleID);
            assertEq(history[i].dataBundlePrice, customDataBundleDetails[0][i].dataBundlePrice);
        }
        assertEq(history[5].dataBundleID, "DB_ID_6", "The second batch must start where the first ended");
        assertEq(history[5].dataBundlePrice, 61);
        assertEq(history[6].dataBundleID, "DB_ID_7");
        assertEq(history[6].dataBundlePrice, 71);
    }

    /// @notice The event carries the running total, which is how an indexer spots the final batch
    function test_populateHistory_reportsTheRunningTotal() public {
        deployWallets();

        DataBundleDetails[] memory secondBatch = new DataBundleDetails[](1);
        secondBatch[0] = DataBundleDetails("DB_ID_6", 61);

        vm.prank(address(registry));
        eSIMWallet1.populateHistory(customDataBundleDetails[0]);

        vm.expectEmit(false, false, false, true, address(eSIMWallet1));
        emit ESIMWallet.TransactionHistoryPopulated(secondBatch, 6);

        vm.prank(address(registry));
        eSIMWallet1.populateHistory(secondBatch);
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
        vm.expectRevert(abi.encodeWithSelector(Errors.NotADeviceWallet.selector, user1));
        eSIMWallet1.requestTransferOwnership(user1);
        vm.stopPrank();
    }

    function test_requestTransferOwnership() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[1];
        listOfKeys[0] = listOfOwnerKeys[1];
        salts[0] = 919;
        deposits[0] = 0;

        // Deploy new device wallet
        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        )[0];
        vm.stopPrank();

        deviceWallet2 = MockDeviceWallet(payable(wallet.deviceWallet));

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");
        assertEq(address(eSIMWallet1).balance, 1 ether, "eSIM wallet balance should have been 1 ETH");
        assertEq(currentOwner.balance, 10 ether, "device wallet balance should have been 10 ETH");

        vm.startPrank(currentOwner);
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();
        assertEq(address(eSIMWallet1).balance, 0 ether, "eSIM wallet balance should have been 0 ETH");
        assertEq(currentOwner.balance, 11 ether, "device wallet balance should have been 11 ETH");

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
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedOwner.selector, eSIMWallet1.newRequestedOwner()));
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();
    }

    function test_acceptOwnershipTransfer_currentOwner() public {
        test_requestTransferOwnership();

        address currentOwner = eSIMWallet1.owner();
        vm.startPrank(currentOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedOwner.selector, eSIMWallet1.newRequestedOwner()));
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
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedOwner.selector, eSIMWallet1.newRequestedOwner()));
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address owner = eSIMWallet1.owner();
        assertEq(owner, address(deviceWallet), "Owner should not have updated");
    }

    function test_transferOwnership() public {
        deployWallets();

        vm.startPrank(user1);
        vm.expectRevert(Errors.UseAcceptOwnershipTransfer.selector);
        eSIMWallet1.transferOwnership(user1);
        vm.stopPrank();
    }

    /// @dev It is important to remove eSIM wallet from the device wallet before transferring ownership
    /// If not done, the eSIM wallet will still be able to pull ETH from the device wallet it previously belonged to
    function test_acceptOwnershipTransfer_addESIMWallet() public {
        // Current owner requests transfer of ownership to the new owner & removes eSIM wallet in same step
        // also sets it to standby and mark owner as address(0)
        test_requestTransferOwnership();

        // Should revert as eSIM wallet has already been removed in previous step
        vm.startPrank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownESIMWallet.selector, address(eSIMWallet1)));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "ESIMWallet1 should have been on standBy");

        // New owner accepts transfer of ownership to themselves
        address requestedOwner = eSIMWallet1.newRequestedOwner();
        vm.startPrank(requestedOwner);
        eSIMWallet1.acceptOwnershipTransfer();
        vm.stopPrank();

        address newOwner = address(deviceWallet2);
        assertEq(newOwner, requestedOwner, "newOwner should have accepted the ownership");
        assertEq(address(eSIMWallet1.deviceWallet()), newOwner, "Device wallet should have updated along with the owner");

        requestedOwner = eSIMWallet1.newRequestedOwner();
        assertEq(requestedOwner, address(0), "newRequestedOwner should have reset to address(0)");

        // New owner adds eSIM wallet to their device wallet, and removes eSIM wallet from standBy
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0 ether, "eSIM wallet balance should have decreased to 0 ETH");
        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet1)), true, "eSIM wallet added should have been set to valid");
        assertEq(deviceWallet2.canPullETH(address(eSIMWallet1)), true, "eSIM wallet should have ability to pull ETH");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "ESIMWallet1 should not have been on standBy");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet2), "Registry should have updated the eSIM wallet to the new device wallet");
    }

    /// @notice A single ownership transfer emits exactly one OwnershipTransferred
    /// @dev Counts logs rather than using vm.expectEmit, which matches one occurrence and would
    ///      pass just as happily against a duplicate emission.
    function test_acceptOwnershipTransfer_emitsOwnershipTransferredOnce() public {
        test_requestTransferOwnership();

        address requestedOwner = eSIMWallet1.newRequestedOwner();

        vm.recordLogs();
        vm.prank(requestedOwner);
        eSIMWallet1.acceptOwnershipTransfer();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 ownershipTransferred = keccak256("OwnershipTransferred(address,address)");
        uint256 count;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(eSIMWallet1) &&
                logs[i].topics.length > 0 &&
                logs[i].topics[0] == ownershipTransferred
            ) {
                ++count;
            }
        }

        assertEq(count, 1, "Exactly one OwnershipTransferred should have been emitted");
        assertEq(eSIMWallet1.owner(), requestedOwner, "Ownership should have moved to the requested owner");
    }

    function test_buyDataBundle_noFundsFromESIMWallet() public {
        deployWallets();

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            100000000000000000      // 0.1 ETH
        );

        vm.startPrank(eSIMWalletAdmin);
        // The shortfall is pulled from the device wallet, which holds nothing
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 0, 0.1 ether));
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 0.9 ether, "Device wallet balance should have been 0.9 ETH");
        assertEq((deviceWallet.getVaultAddress()).balance, 0.1 ether, "Vault balance should have increased by 0.1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Transaction history's data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Transaction history's data bundle price should have been correct");
    }

    function test_buyDataBundle_partialFundsFromESIMWallet() public {
        deployWallets();

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            100000000000000000      // 0.1 ETH
        );

        vm.deal(address(eSIMWallet1), 0.03 ether);
        vm.startPrank(eSIMWalletAdmin);
        // The wallet covers 0.03 of the 0.1 and pulls the rest from an empty device wallet
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 0, 0.07 ether));
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 0.93 ether, "Device wallet balance should have been 0.93 ETH");
        assertEq(address(eSIMWallet1).balance, 0 ether, "ESIM wallet balance should have been 0 ETH");
        assertEq((deviceWallet.getVaultAddress()).balance, 0.1 ether, "Vault balance should have increased by 0.1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Transaction history's data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Transaction history's data bundle price should have been correct");
    }

    function test_buyDataBundle_partialFundsFromUserAndESIMWallet() public {
        deployWallets();

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            100000000000000000      // 0.1 ETH
        );
        
        vm.deal(eSIMWalletAdmin, 0.04 ether);       // 0.04 ETH to be supplied as msg.value
        vm.deal(address(eSIMWallet1), 0.03 ether);  // 0.03 ETH to be used from eSIM wallet

        vm.startPrank(eSIMWalletAdmin);
        // Revert from the device wallet, needed 0.03 ETH, found 0 ETH
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 0, 0.03 ether));
        eSIMWallet1.buyDataBundle{value: 0.04 ether}(_dataBundleDetail);
        vm.stopPrank();

        vm.deal(address(deviceWallet), 1 ether);    // needed 0.03 ETH from Device walelt, found 1 ETH
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle{value: 0.04 ether}(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 0.97 ether, "Device wallet balance should have been 0.97 ETH");
        assertEq(address(eSIMWallet1).balance, 0 ether, "ESIM wallet balance should have been 0 ETH");
        assertEq((deviceWallet.getVaultAddress()).balance, 0.1 ether, "Vault balance should have increased by 0.1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Transaction history's data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Transaction history's data bundle price should have been correct");
    }

    function test_buyDataBundle_allFundsFromUser() public {
        deployWallets();

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(deviceWallet), 2 ether);
        vm.deal(address(eSIMWallet1), 1 ether);
        vm.deal(eSIMWalletAdmin, 0.2 ether);        // remaining ETH should go to eSIM wallet
        
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle{value: 0.2 ether}(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 2 ether, "Device wallet balance should have been 2 ETH");
        assertEq(address(eSIMWallet1).balance, 1.1 ether, "ESIM wallet balance should have been 1 ETH");
        assertEq((deviceWallet.getVaultAddress()).balance, 0.1 ether, "Vault balance should have increased by 0.1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Transaction history's data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Transaction history's data bundle price should have been correct");
    }

    function test_sendETHToDeviceWallet_unauthorised() public {
        deployWallets();

        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyDeviceWallet()")));
        eSIMWallet1.sendETHToDeviceWallet(1 ether);
        vm.stopPrank();
    }

    function test_sendETHToDeviceWallet() public {
        deployWallets();

        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(address(deviceWallet));
        eSIMWallet1.sendETHToDeviceWallet(1 ether);
        vm.stopPrank();

        assertEq(address(eSIMWallet1).balance, 0 ether, "eSIM wallet balance should have gone down to 0 ETH");
        assertEq(address(deviceWallet).balance, 1 ether, "Device wallet balance should have increased to 1 ETH");
    }

    function test_sendETHToDeviceWallet_newDeviceWallet() public {
        test_acceptOwnershipTransfer_addESIMWallet();

        vm.deal(address(eSIMWallet1), 1 ether);

        address newDeviceWallet = eSIMWallet1.owner();

        vm.startPrank(newDeviceWallet);
        eSIMWallet1.sendETHToDeviceWallet(1 ether);
        vm.stopPrank();

        assertEq(address(eSIMWallet1).balance, 0 ether, "eSIM wallet balance should have gone down to 0 ETH");
        assertEq(address(newDeviceWallet).balance, 1 ether, "New device wallet balance should have increased to 1 ETH");
    }

    /// @notice buyDataBundle pulls whatever price it is given out of the device wallet and sends it
    /// to the vault, on the admin's say-so alone, which is the largest ETH exit in the protocol.
    function test_buyDataBundle_revertsWhilePaused() public {
        deployWallets();
        vm.deal(address(deviceWallet), 1 ether);

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.ProtocolPaused.selector);
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 0.1 ether));

        assertEq(vault.balance, 0, "The vault must receive nothing while paused");
        assertEq(address(deviceWallet).balance, 1 ether, "The device wallet must keep its ETH");

        vm.prank(registry.owner());
        registry.unpause();

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 0.1 ether));
        assertEq(vault.balance, 0.1 ether, "The release must restore the path");
    }

    /// @notice A wallet that sets its own ceiling is held to it, whatever the admin asks for.
    function test_buyDataBundle_revertsAboveTheWalletCap() public {
        deployWallets();
        vm.deal(address(deviceWallet), 5 ether);

        vm.prank(address(deviceWallet));
        eSIMWallet1.setDataBundlePriceCap(0.2 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, 0.3 ether, 0.2 ether));
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 0.3 ether));

        assertEq(vault.balance, 0, "The vault must receive nothing above the cap");
        assertEq(address(deviceWallet).balance, 5 ether, "The device wallet must keep its ETH");
    }

    /// @notice A wallet holding no ceiling of its own falls back to the registry's.
    /// @dev This is the case that matters for wallets already deployed. They read zero, so the
    ///      registry is the only place a limit can reach them from.
    function test_buyDataBundle_revertsAboveTheRegistryDefault() public {
        deployWallets();
        vm.deal(address(deviceWallet), 5 ether);

        vm.prank(registry.owner());
        registry.setDefaultDataBundlePriceCap(0.2 ether);

        assertEq(eSIMWallet1.dataBundlePriceCap(), 0, "The wallet must hold no ceiling of its own");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, 0.3 ether, 0.2 ether));
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 0.3 ether));

        assertEq(vault.balance, 0, "The vault must receive nothing above the default");
    }

    /// @notice A wallet's own ceiling wins over the registry default, in both directions.
    function test_buyDataBundle_theWalletCapOverridesTheRegistryDefault() public {
        deployWallets();
        vm.deal(address(deviceWallet), 5 ether);

        vm.prank(registry.owner());
        registry.setDefaultDataBundlePriceCap(0.1 ether);

        vm.prank(address(deviceWallet));
        eSIMWallet1.setDataBundlePriceCap(1 ether);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", 0.5 ether));
        assertEq(vault.balance, 0.5 ether, "A wallet raising its own ceiling must be able to spend to it");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, 2 ether, 1 ether));
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_2", 2 ether));
    }

    /// @notice A wallet with no ceiling of its own is still bound by the registry default set at
    /// deployment.
    /// @dev `Registry.initialize` and `setDefaultDataBundlePriceCap` both refuse zero, so a wallet
    /// that never sets its own cap is never actually uncapped, only deferring to whatever the
    /// registry was given at deploy time.
    function test_buyDataBundle_rejectsAPriceAboveTheRegistryDefault() public {
        deployWallets();
        vm.deal(address(deviceWallet), 5 ether);

        assertEq(eSIMWallet1.dataBundlePriceCap(), 0, "The wallet must hold no ceiling of its own");

        uint256 price = defaultDataBundlePriceCap + 1;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, defaultDataBundlePriceCap)
        );
        eSIMWallet1.buyDataBundle(DataBundleDetails("DB_ID_1", price));

        assertEq(vault.balance, 0, "The vault must receive nothing above the registry default");
    }

    /// @notice The admin names the price, so it must not also be able to raise the ceiling.
    function test_setDataBundlePriceCap_rejectsTheAdmin() public {
        deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        eSIMWallet1.setDataBundlePriceCap(100 ether);

        assertEq(eSIMWallet1.dataBundlePriceCap(), 0, "The admin must not be able to set a ceiling");
    }
}
