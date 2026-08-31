// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {Asset} from "contracts/payments/PaymentAdapter.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import {MockReenteringERC20} from "test/utils/mocks/tokens/MockReenteringERC20.sol";

contract ESIMWalletTest is DeployerBase {

    // Redeclared so expectEmit can name it. This test contract does not inherit ESIMWallet.
    event PriceCapUSDCentsUpdated(uint64 _cap);

    /// @notice A rotated admin has to reach the purchase path, which the factory alone does not
    /// @dev This path spends out of the device wallet, so an admin address that changes only on the
    ///      factory leaves the retired key able to charge wallets and leaves the new key unable to
    ///      do its job.
    function test_buyDataBundleWithToken_followsTheRotatedAdmin() public {
        deployWallets();
        address retiredAdmin = registry.eSIMWalletAdmin();

        vm.prank(registry.owner());
        registry.requestAdminUpdate(user3);
        vm.prank(user3);
        registry.acceptAdminUpdate();

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(deviceWallet), needed);

        vm.prank(retiredAdmin);
        vm.expectRevert(Errors.OnlyDeviceWalletOrESIMWalletAdmin.selector);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_ID_1", TEST_PRICE_CENTS), ASSET_USDC, needed, nextRef());

        vm.prank(user3);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_ID_1", TEST_PRICE_CENTS), ASSET_USDC, needed, nextRef());

        (, uint64 price,) = eSIMWallet1.transactionHistory(0);
        assertEq(price, TEST_PRICE_CENTS, "The purchase made by the rotated admin must be recorded");
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
        registry.assignESIMIdentifier(address(eSIMWallet1), "ESIM_0_1");
        vm.stopPrank();

        // A bind never carries ETH access, so the owner grants it here
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), true);

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
        assertEq(deviceWallet.canPullFunds(address(eSIMWallet1)), true, "ESIMWallet1 should be able to pull ETH");
        assertEq(deviceWallet.canPullFunds(address(eSIMWallet2)), false, "ESIMWallet2 should not be able to pull ETH");

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

    /// @notice Deploys one more device wallet, for tests that need a third party to nominate
    function _anotherDeviceWallet(uint256 keyIndex, uint256 salt) internal returns (address) {
        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[keyIndex];
        listOfKeys[0] = listOfOwnerKeys[keyIndex];
        salts[0] = salt;
        deposits[0] = 0;

        vm.prank(deviceWalletFactory.eSIMWalletAdmin());
        return deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        )[0].deviceWallet;
    }

    function test_setESIMUniqueIdentifier_unauthorised() public {
        deployWallets();

        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlyRegistry.selector);
        eSIMWallet2.setESIMUniqueIdentifier("ESIM_0_2");
        vm.stopPrank();
    }

    /// @notice The owning device wallet is refused too, so the claim cannot be skipped
    function test_setESIMUniqueIdentifier_rejectsTheOwningDeviceWallet() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert(Errors.OnlyRegistry.selector);
        eSIMWallet2.setESIMUniqueIdentifier("ESIM_0_2");
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifier_callTwiceFail() public {
        deployWallets();

        vm.startPrank(address(registry));
        vm.expectRevert(abi.encodeWithSelector(Errors.ESIMIdentifierAlreadySet.selector, eSIMWallet1.eSIMUniqueIdentifier()));
        eSIMWallet1.setESIMUniqueIdentifier("ESIM_0_2");
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifier() public {
        deployWallets();

        vm.startPrank(address(registry));
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
        secondBatch[0] = bundle("DB_ID_6", 61);
        secondBatch[1] = bundle("DB_ID_7", 71);

        vm.startPrank(address(registry));
        eSIMWallet1.populateHistory(customDataBundleDetails[0]);
        eSIMWallet1.populateHistory(secondBatch);
        vm.stopPrank();

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 7, "Both batches should have landed");

        for (uint256 i = 0; i < customDataBundleDetails[0].length; ++i) {
            assertEq(history[i].id, customDataBundleDetails[0][i].id);
            assertEq(history[i].priceUSDCents, customDataBundleDetails[0][i].priceUSDCents);
        }
        assertEq(history[5].id, "DB_ID_6", "The second batch must start where the first ended");
        assertEq(history[5].priceUSDCents, 61);
        assertEq(history[6].id, "DB_ID_7");
        assertEq(history[6].priceUSDCents, 71);
    }

    /// @notice The event carries the running total, which is how an indexer spots the final batch
    function test_populateHistory_reportsTheRunningTotal() public {
        deployWallets();

        DataBundleDetails[] memory secondBatch = new DataBundleDetails[](1);
        secondBatch[0] = bundle("DB_ID_6", 61);

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

    /// @notice Cancelling a pending transfer re-binds the wallet to its device wallet
    /// @dev requestTransferOwnership's general branch removes the wallet from its device wallet
    ///      before the new owner has accepted anything. Self-cancelling used to clear the pending
    ///      request and stop there, leaving the wallet orphaned: still owned by the same device
    ///      wallet, but no longer in its isValidESIMWallet set and still marked on standby at the
    ///      registry. ETH access is deliberately not restored, since the flag it had before the
    ///      removal was never recorded anywhere.
    function test_requestTransferOwnership_selfCancelRestoresTheBinding() public {
        test_requestTransferOwnership();

        address currentOwner = eSIMWallet1.owner();
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "removed pending the transfer");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "on standby pending the transfer");

        vm.prank(currentOwner);
        eSIMWallet1.requestTransferOwnership(currentOwner);

        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "the pending request must be cleared");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), true, "the binding must be restored");
        assertEq(deviceWallet.canPullFunds(address(eSIMWallet1)), false, "ETH access is not restored");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "standby must be cleared");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), currentOwner, "the association is unchanged");
    }

    /// @notice An outstanding request can be pointed at a different device wallet in one call
    /// @dev The two writes the general branch makes have different idempotency: the nominee is
    ///      overwritable but the removal is not, so an unguarded removal made the second call
    ///      revert and the owner had to self-cancel first, which costs the wallet its ETH access.
    function test_requestTransferOwnership_retargetsAnOutstandingRequest() public {
        test_requestTransferOwnership();

        address currentOwner = eSIMWallet1.owner();
        address deviceWallet3 = _anotherDeviceWallet(2, 929);
        uint256 ownerBalance = currentOwner.balance;

        vm.prank(currentOwner);
        eSIMWallet1.requestTransferOwnership(deviceWallet3);

        assertEq(eSIMWallet1.newRequestedOwner(), deviceWallet3, "the nominee must have moved");
        assertEq(eSIMWallet1.owner(), currentOwner, "the owner does not change until acceptance");
        assertEq(currentOwner.balance, ownerBalance, "the ETH was already swept by the first request");

        // The removal happened on the first request and must not be attempted again
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "still off its device wallet");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "the release is still outstanding");
    }

    /// @notice The nominee that was replaced can no longer accept, and the new one can
    function test_requestTransferOwnership_retargetDropsTheOldNominee() public {
        test_requestTransferOwnership();

        address deviceWallet3 = _anotherDeviceWallet(2, 939);

        vm.prank(eSIMWallet1.owner());
        eSIMWallet1.requestTransferOwnership(deviceWallet3);

        vm.prank(address(deviceWallet2));
        vm.expectRevert(abi.encodeWithSelector(Errors.OnlyRequestedOwner.selector, deviceWallet3));
        eSIMWallet1.acceptOwnershipTransfer();

        vm.prank(deviceWallet3);
        eSIMWallet1.acceptOwnershipTransfer();

        assertEq(eSIMWallet1.owner(), deviceWallet3, "the wallet must land with the second nominee");
        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "the request must be cleared on acceptance");
    }

    /// @notice Re-issuing the same request is accepted rather than refused
    /// @dev What a dropped or replaced transaction gets resubmitted into. Nothing moves, which is
    ///      the point: the wallet is already off its device wallet and already on standby.
    function test_requestTransferOwnership_reissuingTheSameRequest() public {
        test_requestTransferOwnership();

        vm.prank(eSIMWallet1.owner());
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "the nominee must be unchanged");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "still off its device wallet");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), true, "the release is still outstanding");
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

        // New owner adds eSIM wallet to their device wallet, and removes eSIM wallet from standBy.
        // The bind carries no ETH access, so the new owner grants it separately.
        vm.startPrank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), false);
        deviceWallet2.toggleAccessToFunds(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0 ether, "eSIM wallet balance should have decreased to 0 ETH");
        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet1)), true, "eSIM wallet added should have been set to valid");
        assertEq(deviceWallet2.canPullFunds(address(eSIMWallet1)), true, "eSIM wallet should have ability to pull ETH");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "ESIMWallet1 should not have been on standBy");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet2), "Registry should have updated the eSIM wallet to the new device wallet");
    }

    /// @notice Between acceptance and the new owner binding, the registry association still names
    ///         the old device wallet, and that stale value hands it nothing
    /// @dev The association is a registration rather than a permission. Every gate that decides
    ///      anything about an eSIM wallet reads `ESIMWallet.owner()`, which moved with the
    ///      acceptance, so the association is free to lag behind it without opening a way back in
    ///      for the device wallet that let the wallet go.
    function test_acceptOwnershipTransfer_theStaleAssociationGrantsTheOldOwnerNothing() public {
        test_requestTransferOwnership();

        vm.prank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();

        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet), "The association still lags behind the owner");
        assertEq(eSIMWallet1.owner(), address(deviceWallet2), "The owner moved with the acceptance");

        // Re-binding reads owner(), so the old device wallet cannot take the wallet back
        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ESIMWalletNotOwnedByThisDeviceWallet.selector,
            address(eSIMWallet1),
            address(deviceWallet2)
        ));
        deviceWallet.addESIMWallet(address(eSIMWallet1), false);

        // The standby flag reads owner() too, so the old device wallet cannot clear the marker
        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.NotTheESIMWalletOwnerOrItsDeviceWallet.selector,
            address(eSIMWallet1)
        ));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet1), false);

        // And the wallet lost its route to the old device wallet's money on the release
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.OnlyAssociatedESIMWallets.selector);
        deviceWallet.pullToken(settlementToken, 1);
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

    /// @notice A wallet's own ceiling wins over the registry default, in both directions.
    function test_buyDataBundleWithToken_theWalletCapOverridesTheRegistryDefault() public {
        deployWallets();

        vm.prank(registry.owner());
        registry.setDefaultPriceCapUSDCents(10_000);   // $100

        vm.prank(address(deviceWallet));
        eSIMWallet1.setPriceCapUSDCents(100_000);   // $1000

        uint256 needed = settlementAmount(50_000);
        fundSettlementToken(address(deviceWallet), needed);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_ID_1", 50_000), ASSET_USDC, needed, nextRef());
        assertEq(
            settlementERC20.balanceOf(vault),
            needed,
            "A wallet raising its own ceiling must be able to spend to it"
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, 200_000, 100_000));
        eSIMWallet1.buyDataBundleWithToken(
            bundle("DB_ID_2", 200_000),
            ASSET_USDC,
            settlementAmount(200_000),
            nextRef()
        );
    }

    /// @notice The admin names the price, so it must not also be able to raise the ceiling.
    function test_setPriceCapUSDCents_rejectsTheAdmin() public {
        deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        eSIMWallet1.setPriceCapUSDCents(100_000);

        assertEq(eSIMWallet1.priceCapUSDCents(), 0, "The admin must not be able to set a ceiling");
    }

    /// @notice A handover clears the outgoing owner's ceiling and announces it.
    /// @dev Every other authority marker is re-decided by the incoming owner's addESIMWallet call.
    /// The ceiling has no such step, so a wallet handed over carrying a raised one would bind its
    /// new owner to a limit the last owner chose.
    function test_acceptOwnershipTransfer_clearsTheOutgoingOwnersPriceCeiling() public {
        test_requestTransferOwnership();

        // Still owned by the first device wallet until the request is accepted
        vm.prank(address(deviceWallet));
        eSIMWallet1.setPriceCapUSDCents(type(uint64).max);

        vm.expectEmit(false, false, false, true, address(eSIMWallet1));
        emit PriceCapUSDCentsUpdated(0);

        vm.prank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();

        assertEq(eSIMWallet1.owner(), address(deviceWallet2), "Ownership should have moved");
        assertEq(eSIMWallet1.priceCapUSDCents(), 0, "The new owner must start on the registry ceiling");
    }

    /// @notice A wallet that never set a ceiling emits nothing on handover.
    function test_acceptOwnershipTransfer_emitsNoCapUpdateWhenThereWasNoCeiling() public {
        test_requestTransferOwnership();
        assertEq(eSIMWallet1.priceCapUSDCents(), 0, "The wallet must hold no ceiling of its own");

        vm.recordLogs();
        vm.prank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 capUpdated = keccak256("PriceCapUSDCentsUpdated(uint64)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(eSIMWallet1) && logs[i].topics.length > 0) {
                assertNotEq(logs[i].topics[0], capUpdated, "An unchanged ceiling must announce nothing");
            }
        }
    }

    /// @notice The registry default applies again once a wallet changes hands.
    /// @dev The consequence of the clear: an inherited ceiling of type(uint64).max would leave the
    /// new owner with no effective limit on what the admin may charge it.
    function test_buyDataBundle_theNewOwnerIsNotBoundByTheOldOwnersCeiling() public {
        test_requestTransferOwnership();

        vm.prank(address(deviceWallet));
        eSIMWallet1.setPriceCapUSDCents(type(uint64).max);

        vm.prank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();
        vm.prank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), false);

        uint64 price = defaultPriceCapUSDCents + 1;
        fundSettlementToken(address(deviceWallet2), settlementAmount(price));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, price, defaultPriceCapUSDCents)
        );
        eSIMWallet1.buyDataBundleWithToken(
            bundle("DB_ID_1", price),
            ASSET_USDC,
            settlementAmount(price),
            nextRef()
        );

        assertEq(settlementERC20.balanceOf(vault), 0, "The registry default must bind the new owner");
    }

    /// @notice The purchase is already in history before any token moves
    /// @dev Read through a token that calls out mid-transfer. The first transfer is the pull from
    /// the device wallet, so a record written after it would show a history one entry short.
    function test_buyDataBundleWithToken_recordsTheHistoryBeforeAnythingMoves() public {
        deployWallets();

        HistoryReadingVault historyReader = new HistoryReadingVault(address(eSIMWallet1));

        MockReenteringERC20 callingToken = new MockReenteringERC20("Calling", "CALL", 6);

        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(bytes32("CALL"), Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: 6,
            token: address(callingToken)
        }));

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        callingToken.mint(address(deviceWallet), needed);

        // Armed after the mint, which is itself a transfer and would otherwise spend the one callback
        callingToken.setReentry(address(historyReader), abi.encodeWithSignature("record()"));

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_ID_1", TEST_PRICE_CENTS), bytes32("CALL"), needed, nextRef());

        assertEq(historyReader.historyLengthSeen(), 1, "The purchase must already be recorded before any transfer");
    }
}

/// @notice Reads back the paying wallet's transaction history length while a transfer is in flight
contract HistoryReadingVault {
    MockESIMWallet private immutable eSIMWallet;
    uint256 public historyLengthSeen;

    constructor(address _eSIMWallet) {
        eSIMWallet = MockESIMWallet(payable(_eSIMWallet));
    }

    function record() external {
        historyLengthSeen = eSIMWallet.getTransactionHistory().length;
    }
}
