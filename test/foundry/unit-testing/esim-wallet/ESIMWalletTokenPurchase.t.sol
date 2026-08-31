// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {Asset} from "contracts/payments/PaymentAdapter.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";
import {MockFeeOnTransferERC20} from "test/utils/mocks/tokens/MockFeeOnTransferERC20.sol";
import {MockReenteringERC20} from "test/utils/mocks/tokens/MockReenteringERC20.sol";

/// @notice Buying a data bundle with USDC (or any other acceptable stablecoin/ERC20), and getting a token balance back out again.
contract ESIMWalletTokenPurchaseTest is DeviceWalletFixture {

    uint64 constant PRICE_CENTS = 1_250;   // $12.50
    uint256 constant DEVICE_BALANCE = 1_000e6;

    event DataBundleBoughtWithToken(
        bytes32 _dataBundleID,
        uint64 _priceUSDCents,
        bytes32 indexed _asset,
        address indexed _token,
        uint256 _amountSpent,
        bytes32 indexed _paymentReference
    );

    event TokenSentToDeviceWallet(address indexed _token, address indexed _deviceWallet, uint256 _amount);

    function setUp() public override {
        super.setUp();
        deployWallets();
        fundSettlementToken(address(deviceWallet), DEVICE_BALANCE);
    }

    // ---------------------------------------------------------------------------------------------
    // The bought path
    // ---------------------------------------------------------------------------------------------

    function test_buyDataBundleWithToken_pullsTheWholePriceFromTheDeviceWallet() public {
        uint256 needed = settlementAmount(PRICE_CENTS);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, nextRef());

        assertEq(settlementERC20.balanceOf(vault), needed, "The vault should hold the price");
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), DEVICE_BALANCE - needed, "The device wallet pays for it");
        assertEq(settlementERC20.balanceOf(address(eSIMWallet1)), 0, "Nothing should be left in the eSIM wallet");
    }

    /// @notice The eSIM wallet is the funding pot, so a balance it already holds is spent first
    function test_buyDataBundleWithToken_spendsItsOwnBalanceBeforePulling() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(eSIMWallet1), needed);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, nextRef());

        assertEq(settlementERC20.balanceOf(vault), needed, "The vault should hold the price");
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), DEVICE_BALANCE, "The device wallet should be untouched");
    }

    function test_buyDataBundleWithToken_pullsOnlyTheShortfall() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        uint256 held = needed / 4;
        fundSettlementToken(address(eSIMWallet1), held);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, nextRef());

        assertEq(settlementERC20.balanceOf(address(deviceWallet)), DEVICE_BALANCE - (needed - held), "Only the shortfall should have been pulled");
        assertEq(settlementERC20.balanceOf(vault), needed, "The vault still gets the whole price");
    }

    function test_buyDataBundleWithToken_recordsThePurchaseAsWitnessed() public {
        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());

        (bytes32 id, uint64 price, Settlement settlement) = eSIMWallet1.transactionHistory(0);
        assertEq(id, bytes32("DB_TOKEN"), "The bundle id should have been recorded");
        assertEq(price, PRICE_CENTS, "The price should have been recorded in cents");
        assertEq(uint8(settlement), uint8(Settlement.DeviceWallet), "The protocol saw this money move");
    }

    /// @notice The settlement is set here, not taken from the caller
    function test_buyDataBundleWithToken_overwritesTheSettlementItWasHanded() public {
        DataBundleDetails memory detail = bundle("DB_TOKEN", PRICE_CENTS);
        detail.settlement = Settlement.Fiat;

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(detail, ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());

        (,, Settlement settlement) = eSIMWallet1.transactionHistory(0);
        assertEq(uint8(settlement), uint8(Settlement.DeviceWallet), "A caller cannot name the settlement here");
    }

    function test_buyDataBundleWithToken_emitsDataBundleBoughtWithToken() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        bytes32 spentRef = nextRef();

        vm.expectEmit(true, true, true, true, address(eSIMWallet1));
        emit DataBundleBoughtWithToken(bytes32("DB_TOKEN"), PRICE_CENTS, ASSET_USDC, settlementToken, needed, spentRef);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, spentRef);
    }

    /// @notice The owner can buy without the admin, through the device wallet
    function test_buyDataBundleWithToken_acceptsTheOwningDeviceWallet() public {
        vm.prank(address(deviceWallet));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());

        assertEq(eSIMWallet1.getTransactionHistory().length, 1, "The purchase should have been recorded");
    }

    /// @notice A ceiling above the price does not get in the way
    function test_buyDataBundleWithToken_acceptsACeilingAboveTheQuote() public {
        uint256 needed = settlementAmount(PRICE_CENTS);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed * 2, nextRef());

        assertEq(settlementERC20.balanceOf(vault), needed, "Only the quoted amount should be spent");
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), DEVICE_BALANCE - needed, "The ceiling is not what gets pulled");
    }

    // ---------------------------------------------------------------------------------------------
    // What the purchase refuses
    // ---------------------------------------------------------------------------------------------

    function test_buyDataBundleWithToken_revertsForAnUnauthorisedCaller() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyDeviceWalletOrESIMWalletAdmin.selector);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    function test_buyDataBundleWithToken_revertsOnAnEmptyBundleID() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyDataBundleID.selector);
        eSIMWallet1.buyDataBundleWithToken(bundle(bytes32(0), PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    function test_buyDataBundleWithToken_revertsOnAZeroPrice() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.ZeroDataBundlePrice.selector);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", 0), ASSET_USDC, 1, nextRef());
    }

    function test_buyDataBundleWithToken_revertsAboveTheRegistryCeiling() public {
        uint64 tooMuch = defaultPriceCapUSDCents + 1;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, tooMuch, defaultPriceCapUSDCents));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", tooMuch), ASSET_USDC, settlementAmount(tooMuch), nextRef());
    }

    /// @notice The admin names the price, so it must not be able to charge past the owner's own limit
    function test_buyDataBundleWithToken_revertsAboveTheWalletsOwnCeiling() public {
        vm.prank(address(deviceWallet));
        eSIMWallet1.setPriceCapUSDCents(500);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DataBundlePriceAboveCap.selector, PRICE_CENTS, uint64(500)));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    function test_buyDataBundleWithToken_revertsWhileTheProtocolIsPaused() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.ProtocolPaused.selector);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    function test_buyDataBundleWithToken_revertsWhenTheCeilingIsBelowTheQuote() public {
        uint256 needed = settlementAmount(PRICE_CENTS);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementAboveMax.selector, needed, needed - 1));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed - 1, nextRef());
    }

    /// @notice Fiat has no token address, so there is nothing to transfer
    function test_buyDataBundleWithToken_revertsForFiat() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotTransferable.selector, ASSET_USD));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USD, 1_000e6, nextRef());
    }

    function test_buyDataBundleWithToken_revertsForAWithdrawnAsset() public {
        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: SETTLEMENT_DECIMALS,
            token: settlementToken
        }));

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, ASSET_USDC));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    /// @notice A wallet whose access the owner revoked cannot reach the device wallet's tokens
    function test_buyDataBundleWithToken_revertsWhenAccessToTheDeviceWalletIsRevoked() public {
        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), false);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.FundsAccessRevoked.selector, address(eSIMWallet1)));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    /// @notice A revoked wallet can still spend what it already holds, since it pulls nothing
    function test_buyDataBundleWithToken_stillWorksWithoutAccessWhenFullyFunded() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(eSIMWallet1), needed);

        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), false);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, nextRef());

        assertEq(settlementERC20.balanceOf(vault), needed, "The wallet's own balance should have paid for it");
    }

    /// @notice The wallet reads the adapter through the registry, so it checks what it got back
    function test_buyDataBundleWithToken_revertsWhenTheAdapterIsUnset() public {
        vm.mockCall(
            address(registry),
            abi.encodeWithSignature("paymentAdapter()"),
            abi.encode(address(0))
        );

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.PaymentAdapterNotSet.selector);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), nextRef());
    }

    // ---------------------------------------------------------------------------------------------
    // Payment references
    // ---------------------------------------------------------------------------------------------

    function test_buyDataBundleWithToken_revertsOnAReferenceAlreadySpent() public {
        bytes32 spentRef = nextRef();
        uint256 needed = settlementAmount(PRICE_CENTS);

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, spentRef);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.PaymentReferenceAlreadyUsed.selector, spentRef));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, spentRef);
    }

    /// @notice A second, unrelated wallet can use the same raw reference: the record is scoped per
    ///         wallet, so this is not the same spend
    /// @dev A reference already used by one wallet used to block every other wallet from ever using
    ///      the identical raw value, which let anyone burn a reference an admin's pending
    ///      settlement for a completely different wallet was about to spend. Scoping by wallet
    ///      closes that off: the two are independent records.
    function test_buyDataBundleWithToken_aDifferentWalletCanUseTheSameRawReference() public {
        bytes32 sharedRef = nextRef();

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), sharedRef);

        fundSettlementToken(address(deviceWallet2), DEVICE_BALANCE);
        vm.prank(eSIMWalletAdmin);
        eSIMWallet3.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, settlementAmount(PRICE_CENTS), sharedRef);

        assertEq(eSIMWallet3.getTransactionHistory().length, 1, "The second wallet's purchase must have landed");
    }

    // ---------------------------------------------------------------------------------------------
    // What the ceiling and the standby flag do not bound
    // ---------------------------------------------------------------------------------------------

    /// @notice The ceiling bounds one charge, not the total the admin can charge
    /// @dev Each call spends up to the ceiling against a payment reference the caller picks, and
    ///      nothing counts the calls, so the whole device wallet balance is reachable one capped
    ///      charge at a time. Granting a wallet funds access is an open allowance, not a capped one.
    function test_buyDataBundleWithToken_theCeilingDoesNotBoundRepeatedCharges() public {
        uint64 cap = 10_000;   // $100 per purchase
        vm.prank(address(deviceWallet));
        eSIMWallet1.setPriceCapUSDCents(cap);

        uint256 perPurchase = settlementAmount(cap);
        uint256 purchases = DEVICE_BALANCE / perPurchase;

        for (uint256 i = 0; i < purchases; ++i) {
            vm.prank(eSIMWalletAdmin);
            eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", cap), ASSET_USDC, perPurchase, nextRef());
        }

        assertEq(settlementERC20.balanceOf(address(deviceWallet)), 0, "The whole balance is reachable through capped charges");
        assertEq(settlementERC20.balanceOf(vault), DEVICE_BALANCE, "Every charge should have landed in the vault");
    }

    /// @notice A wallet marked on standby can still be charged
    /// @dev The flag says a release is outstanding and gates nothing. `removeESIMWallet` raises it
    ///      whether or not a transfer follows and only a later bind lowers it, so refusing spend
    ///      here would leave a plainly removed wallet unable to spend its own balance for good.
    function test_buyDataBundleWithToken_isNotHeldByTheStandbyFlag() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(eSIMWallet1), needed);

        vm.prank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), false);
        assertTrue(registry.isESIMWalletOnStandby(address(eSIMWallet1)), "The release should be outstanding");

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), ASSET_USDC, needed, nextRef());

        assertEq(settlementERC20.balanceOf(vault), needed, "Standby should not have stopped the purchase");
    }

    // ---------------------------------------------------------------------------------------------
    // Fee-on-transfer assets
    // ---------------------------------------------------------------------------------------------

    /// @notice A fee-on-transfer asset fails at settle's own funding check, not on an opaque
    ///         transfer revert inside this wallet
    /// @dev Before this, the wallet forwarded the nominal price regardless of what the pull actually
    ///      delivered, so the plain `token.safeTransfer` a few lines below reverted with a bare
    ///      ERC-20 balance error for every purchase in a mistakenly registered fee-on-transfer
    ///      asset. Forwarding the real balance instead means the wallet's own device wallet balance
    ///      is never touched (the whole call still reverts atomically either way), and the failure
    ///      now surfaces through settle()'s existing, tested funding check.
    function test_buyDataBundleWithToken_revertsCleanlyOnAFeeOnTransferAsset() public {
        uint256 feeBps = 100; // 1%
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20("Fee Token", "FEE", 6, feeBps);
        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(bytes32("FEE"), Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: 6,
            token: address(feeToken)
        }));

        uint256 amountIn = settlementAmount(PRICE_CENTS);
        feeToken.mint(address(deviceWallet), amountIn * 10);

        // The fee bites once pulling from the device wallet and again forwarding to the adapter.
        uint256 afterPull = amountIn - (amountIn * feeBps) / 10_000;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementAboveMax.selector, amountIn, afterPull));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_FEE", PRICE_CENTS), bytes32("FEE"), amountIn, nextRef());
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------------------------------------

    /// @notice A token calling back mid-purchase arrives as itself, which no gate on this path
    /// accepts, so the purchase still lands exactly once
    function test_buyDataBundleWithToken_refusesAReentrantCallFromTheToken() public {
        MockReenteringERC20 token = new MockReenteringERC20("Callback Token", "CB", 6);
        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(bytes32("CB"), Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: 6,
            token: address(token)
        }));

        uint256 needed = settlementAmount(PRICE_CENTS);
        token.mint(address(eSIMWallet1), needed);
        token.setReentry(
            address(eSIMWallet1),
            abi.encodeCall(
                eSIMWallet1.buyDataBundleWithToken,
                (bundle("DB_REENTER", PRICE_CENTS), bytes32("CB"), needed, paymentRef("reentrant"))
            )
        );

        vm.prank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_TOKEN", PRICE_CENTS), bytes32("CB"), needed, nextRef());

        assertTrue(token.reentered(), "The token should have tried to call back");
        assertTrue(token.reentryReverted(), "The call back should have been refused");
        assertEq(eSIMWallet1.getTransactionHistory().length, 1, "Exactly one purchase should have been recorded");
        assertEq(token.balanceOf(vault), needed, "The vault should have been paid once");
    }

    // ---------------------------------------------------------------------------------------------
    // Getting a token balance back out
    // ---------------------------------------------------------------------------------------------

    function test_sendTokenToDeviceWallet_returnsTheBalance() public {
        fundSettlementToken(address(eSIMWallet1), 100e6);

        vm.prank(address(deviceWallet));
        eSIMWallet1.sendTokenToDeviceWallet(settlementToken, 100e6);

        assertEq(settlementERC20.balanceOf(address(eSIMWallet1)), 0, "The eSIM wallet should be empty");
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), DEVICE_BALANCE + 100e6, "The device wallet should have it back");
    }

    function test_sendTokenToDeviceWallet_emitsTokenSentToDeviceWallet() public {
        fundSettlementToken(address(eSIMWallet1), 100e6);

        vm.expectEmit(true, true, false, true, address(eSIMWallet1));
        emit TokenSentToDeviceWallet(settlementToken, address(deviceWallet), 100e6);

        vm.prank(address(deviceWallet));
        eSIMWallet1.sendTokenToDeviceWallet(settlementToken, 100e6);
    }

    function test_sendTokenToDeviceWallet_revertsForAnyoneElse() public {
        fundSettlementToken(address(eSIMWallet1), 100e6);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        eSIMWallet1.sendTokenToDeviceWallet(settlementToken, 100e6);
    }

    function test_sendTokenToDeviceWallet_revertsOnZeroAmount() public {
        vm.prank(address(deviceWallet));
        vm.expectRevert(Errors.ZeroAmount.selector);
        eSIMWallet1.sendTokenToDeviceWallet(settlementToken, 0);
    }

    function test_sendTokenToDeviceWallet_revertsOnTheZeroTokenAddress() public {
        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_token"));
        eSIMWallet1.sendTokenToDeviceWallet(address(0), 1);
    }

    /// @notice Any token can come back out, not only the ones the adapter knows about
    function test_sendTokenToDeviceWallet_returnsATokenTheProtocolNeverPricedIn() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(eSIMWallet1), 5 ether);

        vm.prank(address(deviceWallet));
        eSIMWallet1.sendTokenToDeviceWallet(address(other), 5 ether);

        assertEq(other.balanceOf(address(deviceWallet)), 5 ether, "The device wallet should have it");
    }
}
