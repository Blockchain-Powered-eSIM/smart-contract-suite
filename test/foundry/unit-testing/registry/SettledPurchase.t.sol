// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {Registry} from "contracts/Registry.sol";
import {PaymentAdapter, Asset} from "contracts/payments/PaymentAdapter.sol";

import "test/utils/DeployerBase.sol";

/// @notice Covers purchases the admin says were paid for outside the protocol.
/// @dev These are the records nothing onchain can witness, so what they are bounded by is the whole
///      subject: the price ceiling, a payment reference that can only be spent once, a settlement
///      the admin is not allowed to claim, and the ordering guard that keeps a new entry from
///      landing ahead of history still waiting to be copied in.
contract SettledPurchaseTest is DeployerBase {

    uint256 private constant FULL_BATCH = 20;

    DeviceWallet deviceWallet;
    MockESIMWallet eSIMWallet;

    /// @notice Deploys one device wallet with its first eSIM wallet, funded for purchases
    function _deployWallets() internal {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = 1;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets =
            deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        deviceWallet = DeviceWallet(payable(wallets[0].deviceWallet));
        eSIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        vm.deal(address(deviceWallet), 10 ether);
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet), true);
    }

    /// @notice Records a purchase the admin says was paid for offchain
    function _settle(bytes32 _id, uint64 _priceUSDCents, bytes32 _paymentReference) internal {
        vm.prank(eSIMWalletAdmin);
        registry.recordSettledPurchase(
            address(eSIMWallet),
            bundle(_id, _priceUSDCents),
            ASSET_USDC,
            1e6,
            _paymentReference
        );
    }

    /// @notice Stores history for the fixture devices and deploys the first one's wallets
    /// @dev The deployment sets identifiers only. History is copied in afterwards, which is the
    ///      window the ordering guard exists to cover.
    function _lazyDeployWithHistoryOutstanding() internal returns (MockESIMWallet lazyWallet) {
        vm.startPrank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(
            customDeviceUniqueIdentifiers,
            customESIMUniqueIdentifiers,
            customDataBundleDetails
        );
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            999,
            0,
            FULL_BATCH
        );
        vm.stopPrank();

        return MockESIMWallet(payable(lazyWalletRegistry.lazyDeployedESIMWallet(customESIMUniqueIdentifiers[0][0])));
    }

    // ---------------------------------------------------------------------------------------------
    // Recording a purchase
    // ---------------------------------------------------------------------------------------------

    /// @notice A settled purchase lands in the wallet's history and is announced by the registry
    function test_recordSettledPurchase_appendsToTheHistory() public {
        _deployWallets();
        bytes32 orderRef = paymentRef("moonpay-charge");

        vm.expectEmit(true, true, true, true);
        emit RegistryHelper.DataBundleSettled(
            address(eSIMWallet),
            "DB_SETTLED",
            TEST_PRICE_CENTS,
            Settlement.Fiat,
            ASSET_USDC,
            settlementToken,
            1e6,
            orderRef
        );
        _settle("DB_SETTLED", TEST_PRICE_CENTS, orderRef);

        (bytes32 id, uint64 priceUSDCents, Settlement settlement) = eSIMWallet.transactionHistory(0);
        assertEq(id, "DB_SETTLED", "The bundle id must be recorded");
        assertEq(priceUSDCents, TEST_PRICE_CENTS, "The price must be recorded in cents");
        assertTrue(settlement == Settlement.Fiat, "The settlement must be recorded as the admin stated it");
    }

    /// @notice A purchase paid from an external wallet records that settlement
    function test_recordSettledPurchase_recordsAnExternalWallet() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        registry.recordSettledPurchase(
            address(eSIMWallet),
            DataBundleDetails({
                id: "DB_EXTERNAL",
                priceUSDCents: TEST_PRICE_CENTS,
                settlement: Settlement.ExternalWallet
            }),
            ASSET_USDC,
            1e6,
            nextRef()
        );

        (,, Settlement settlement) = eSIMWallet.transactionHistory(0);
        assertTrue(settlement == Settlement.ExternalWallet, "The settlement must be recorded as stated");
    }

    /// @notice No money moves, so the vault balance must not change
    function test_recordSettledPurchase_movesNoETH() public {
        _deployWallets();
        uint256 vaultBalanceBefore = vault.balance;
        uint256 walletBalanceBefore = address(deviceWallet).balance;

        _settle("DB_NO_TRANSFER", TEST_PRICE_CENTS, nextRef());

        assertEq(vault.balance, vaultBalanceBefore, "The vault must not be paid");
        assertEq(address(deviceWallet).balance, walletBalanceBefore, "The device wallet must not be charged");
    }

    /// @notice Only the admin records a settled purchase
    function test_recordSettledPurchase_rejectsAnyoneButTheAdmin() public {
        _deployWallets();

        vm.prank(user1);
        vm.expectRevert(Errors.OnlyAdmin.selector);
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice A paused protocol records nothing
    function test_recordSettledPurchase_rejectsWhilePaused() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        registry.pause();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.ProtocolPaused.selector);
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice A wallet this registry never recorded gets no history
    function test_recordSettledPurchase_rejectsAnUnknownWallet() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAProtocolESIMWallet.selector, user1));
        registry.recordSettledPurchase(user1, bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef());
    }

    /// @notice A purchase needs a bundle id
    function test_recordSettledPurchase_rejectsAnEmptyBundleID() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyDataBundleID.selector);
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle(bytes32(0), TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice A purchase needs a price
    function test_recordSettledPurchase_rejectsAZeroPrice() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.ZeroDataBundlePrice.selector);
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", 0), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice The admin cannot claim a payment the protocol would have witnessed
    /// @dev `Settlement.DeviceWallet` means the ETH reached the vault through `buyDataBundle`.
    ///      Nothing here saw that, so nothing here may say it happened.
    function test_recordSettledPurchase_rejectsAClaimOfAnOnchainPayment() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.SettlementNotAsserted.selector);
        registry.recordSettledPurchase(
            address(eSIMWallet),
            DataBundleDetails({
                id: "DB_CLAIMED",
                priceUSDCents: TEST_PRICE_CENTS,
                settlement: Settlement.DeviceWallet
            }),
            ASSET_USDC,
            1e6,
            nextRef()
        );
    }

    /// @notice A currency the protocol does not accept cannot be recorded against
    function test_recordSettledPurchase_rejectsAnUnknownCurrency() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, bytes32("TON")));
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", TEST_PRICE_CENTS), bytes32("TON"), 1e9, nextRef()
        );
    }

    /// @notice Withdrawing a currency stops it being recorded against straight away
    function test_recordSettledPurchase_rejectsAWithdrawnCurrency() public {
        _deployWallets();

        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: 6,
            token: settlementToken
        }));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, ASSET_USDC));
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice Nothing here witnessed the payment, so the ceiling is what bounds the price
    function test_recordSettledPurchase_rejectsAPriceAboveTheCeiling() public {
        _deployWallets();
        uint64 aboveTheCap = defaultPriceCapUSDCents + 1;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.DataBundlePriceAboveCap.selector, aboveTheCap, defaultPriceCapUSDCents
        ));
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", aboveTheCap), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice A wallet's own ceiling wins over the registry default here too
    function test_recordSettledPurchase_followsTheWalletsOwnCeiling() public {
        _deployWallets();
        uint64 walletCap = 500;   // $5.00

        vm.prank(address(deviceWallet));
        eSIMWallet.setPriceCapUSDCents(walletCap);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.DataBundlePriceAboveCap.selector, walletCap + 1, walletCap
        ));
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", walletCap + 1), ASSET_USDC, 1e6, nextRef()
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Payment references
    // ---------------------------------------------------------------------------------------------

    /// @notice Recording a purchase spends its reference
    function test_recordSettledPurchase_spendsTheReference() public {
        _deployWallets();
        bytes32 orderRef = paymentRef("stripe-intent");

        _settle("DB_ID", TEST_PRICE_CENTS, orderRef);

        assertTrue(paymentAdapter.usedReferences(orderRef), "The reference must be spent");
    }

    /// @notice A retried call cannot record the purchase twice
    /// @dev The backend retries the whole onchain step on any failure, so the second attempt of a
    ///      call that already landed is the case this is here for.
    function test_recordSettledPurchase_rejectsARetryOfAPurchaseThatLanded() public {
        _deployWallets();
        bytes32 orderRef = paymentRef("retried-charge");
        _settle("DB_ID", TEST_PRICE_CENTS, orderRef);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentReferenceAlreadyUsed.selector, orderRef));
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, orderRef
        );

        assertEq(eSIMWallet.getTransactionHistory().length, 1, "The purchase must be recorded once");
    }

    /// @notice A reference spent by a purchase cannot be spent again on the settled path
    function test_recordSettledPurchase_rejectsAReferenceSpentByAPurchase() public {
        _deployWallets();
        bytes32 orderRef = paymentRef("shared-order");

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(eSIMWallet), needed);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet.buyDataBundleWithToken(bundle("DB_BOUGHT", TEST_PRICE_CENTS), ASSET_USDC, needed, orderRef);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentReferenceAlreadyUsed.selector, orderRef));
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_SETTLED", TEST_PRICE_CENTS), ASSET_USDC, 1e6, orderRef
        );
    }

    /// @notice And the same reference cannot go the other way round either
    /// @dev Both paths spend through the one adapter, which is what makes this hold.
    function test_buyDataBundleWithToken_rejectsAReferenceSpentBySettlement() public {
        _deployWallets();
        bytes32 orderRef = paymentRef("shared-order-reversed");
        _settle("DB_SETTLED", TEST_PRICE_CENTS, orderRef);

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(eSIMWallet), needed);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentReferenceAlreadyUsed.selector, orderRef));
        eSIMWallet.buyDataBundleWithToken(bundle("DB_BOUGHT", TEST_PRICE_CENTS), ASSET_USDC, needed, orderRef);
    }

    /// @notice An empty reference ties the purchase to nothing
    function test_recordSettledPurchase_rejectsAnEmptyReference() public {
        _deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyPaymentReference.selector);
        registry.recordSettledPurchase(
            address(eSIMWallet), bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, bytes32(0)
        );
    }

    /// @notice Only an eSIM wallet the registry knows can spend a reference through it
    function test_consumePaymentReference_rejectsAnyoneButAnESIMWallet() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAProtocolESIMWallet.selector, eSIMWalletAdmin));
        registry.consumePaymentReference(paymentRef("forged-order"));
    }

    // ---------------------------------------------------------------------------------------------
    // The ordering guard
    // ---------------------------------------------------------------------------------------------

    /// @notice A new purchase cannot land ahead of history still waiting to be copied in
    /// @dev Otherwise the older entries append after the newer one and the wallet's history reads
    ///      out of order, which is the exact case a fiat user switching to crypto hits.
    function test_recordSettledPurchase_rejectsWhileHistoryIsOutstanding() public {
        MockESIMWallet lazyWallet = _lazyDeployWithHistoryOutstanding();
        string memory eSIMIdentifier = customESIMUniqueIdentifiers[0][0];
        uint256 outstanding = lazyWalletRegistry.outstandingHistoryEntries(eSIMIdentifier);
        assertGt(outstanding, 0, "The fixture must leave history uncopied");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.HistoryNotFullyCopied.selector, eSIMIdentifier, outstanding
        ));
        registry.recordSettledPurchase(
            address(lazyWallet), bundle("DB_ID", TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef()
        );
    }

    /// @notice Once the history is copied the purchase goes through and lands last
    function test_recordSettledPurchase_acceptsOnceHistoryIsCopied() public {
        MockESIMWallet lazyWallet = _lazyDeployWithHistoryOutstanding();
        string memory eSIMIdentifier = customESIMUniqueIdentifiers[0][0];

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.setHistoryForLazyWallet(eSIMIdentifier, FULL_BATCH);
        assertEq(
            lazyWalletRegistry.outstandingHistoryEntries(eSIMIdentifier),
            0,
            "The copy must have caught up"
        );

        uint256 copiedEntries = lazyWallet.getTransactionHistory().length;

        vm.prank(eSIMWalletAdmin);
        registry.recordSettledPurchase(
            address(lazyWallet), bundle("DB_LAST", TEST_PRICE_CENTS), ASSET_USDC, 1e6, nextRef()
        );

        assertEq(lazyWallet.getTransactionHistory().length, copiedEntries + 1, "The purchase must be appended");
        (bytes32 id,,) = lazyWallet.transactionHistory(copiedEntries);
        assertEq(id, "DB_LAST", "The new purchase must be the last entry");
    }

    /// @notice A wallet with no identifier has no lazy history to wait for
    /// @dev Every eagerly deployed wallet is in this state until the admin names its eSIM.
    function test_recordSettledPurchase_acceptsAWalletWithNoIdentifier() public {
        _deployWallets();
        assertEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "The fixture must have no identifier");

        _settle("DB_ID", TEST_PRICE_CENTS, nextRef());

        assertEq(eSIMWallet.getTransactionHistory().length, 1, "The purchase must be recorded");
    }

    // ---------------------------------------------------------------------------------------------
    // Pointing at the adapter
    // ---------------------------------------------------------------------------------------------

    /// @notice The owner points the registry at an adapter
    function test_setPaymentAdapter_storesTheAddress() public {
        address newAdapter = makeAddr("newAdapter");

        vm.expectEmit(true, true, true, true);
        emit RegistryHelper.PaymentAdapterUpdated(newAdapter);

        vm.prank(upgradeManager);
        registry.setPaymentAdapter(newAdapter);

        assertEq(registry.paymentAdapter(), newAdapter, "The adapter address must be stored");
    }

    /// @notice Only the owner points the registry at an adapter
    /// @dev The adapter holds the spent references. An admin that could swap it would get an empty
    ///      set back and record every purchase a second time.
    function test_setPaymentAdapter_rejectsTheAdmin() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin));
        registry.setPaymentAdapter(makeAddr("newAdapter"));
    }

    /// @notice A zero address would take every payment path down
    function test_setPaymentAdapter_rejectsTheZeroAddress() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_paymentAdapter"));
        registry.setPaymentAdapter(address(0));
    }

    /// @notice Setting the same address again is refused
    function test_setPaymentAdapter_rejectsTheAddressAlreadySet() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.PaymentAdapterUnchanged.selector, address(paymentAdapter)
        ));
        registry.setPaymentAdapter(address(paymentAdapter));
    }
}
