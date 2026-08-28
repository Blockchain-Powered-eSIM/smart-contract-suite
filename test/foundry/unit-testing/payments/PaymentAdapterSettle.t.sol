// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Errors} from "contracts/Errors.sol";
import {Asset} from "contracts/payments/PaymentAdapter.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";
import {MockFeeOnTransferERC20} from "test/utils/mocks/tokens/MockFeeOnTransferERC20.sol";
import {MockNoReturnERC20} from "test/utils/mocks/tokens/MockNoReturnERC20.sol";
import {MockReenteringERC20} from "test/utils/mocks/tokens/MockReenteringERC20.sol";

/// @notice `settle`, the only place in the protocol that moves a token to the vault.
/// @dev The caller has to be an eSIM wallet the registry knows, so these prank as one from the
///      shared fixture rather than deploying a stand-in.
contract PaymentAdapterSettleTest is DeviceWalletFixture {

    bytes32 constant ASSET_WETH = bytes32("WETH");
    bytes32 constant ASSET_NRT = bytes32("NRT");
    uint64 constant PRICE_CENTS = 1_250;   // $12.50

    event PaymentSettled(
        bytes32 indexed _symbol,
        address indexed _eSIMWallet,
        address indexed _vault,
        uint64 _priceUSDCents,
        uint256 _spent,
        uint256 _refunded
    );

    function setUp() public override {
        super.setUp();
        deployWallets();
    }

    // ---------------------------------------------------------------------------------------------
    // The settled path
    // ---------------------------------------------------------------------------------------------

    function test_settle_paysTheVaultTheQuotedAmount() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(paymentAdapter), needed);

        vm.prank(address(eSIMWallet1));
        (uint256 spent, uint256 refunded) =
            paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, needed, address(eSIMWallet1));

        assertEq(spent, needed, "The whole amount should have been spent");
        assertEq(refunded, 0, "An exactly funded settlement refunds nothing");
        assertEq(settlementERC20.balanceOf(vault), needed, "The vault should hold the price");
        assertEq(settlementERC20.balanceOf(address(paymentAdapter)), 0, "Nothing should rest in the adapter");
    }

    function test_settle_refundsWhatThePriceDidNotNeed() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        uint256 funded = needed + 40e6;
        fundSettlementToken(address(paymentAdapter), funded);

        vm.prank(address(eSIMWallet1));
        (uint256 spent, uint256 refunded) =
            paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, funded, address(eSIMWallet1));

        assertEq(spent, needed, "Only the price should reach the vault");
        assertEq(refunded, funded - needed, "The rest should come back");
        assertEq(settlementERC20.balanceOf(vault), needed, "The vault gets the price and no more");
        assertEq(settlementERC20.balanceOf(address(eSIMWallet1)), funded - needed, "The refund goes where it was asked to");
    }

    function test_settle_emitsPaymentSettled() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(paymentAdapter), needed);

        vm.expectEmit(true, true, true, true, address(paymentAdapter));
        emit PaymentSettled(ASSET_USDC, address(eSIMWallet1), vault, PRICE_CENTS, needed, 0);

        vm.prank(address(eSIMWallet1));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, needed, address(eSIMWallet1));
    }

    /// @notice The vault is read on every call, so a rotation reaches the next payment
    function test_settle_paysTheVaultCurrentlySet() public {
        address newVault = makeAddr("newVault");
        vm.prank(registry.owner());
        registry.updateVaultAddress(newVault);

        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(paymentAdapter), needed);

        vm.prank(address(eSIMWallet1));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, needed, address(eSIMWallet1));

        assertEq(settlementERC20.balanceOf(newVault), needed, "The new vault should have been paid");
        assertEq(settlementERC20.balanceOf(vault), 0, "The old vault should get nothing");
    }

    /// @notice A cent price on a two decimal currency is one unit, the smallest a settlement can be
    function test_settle_handlesTheSmallestPrice() public {
        MockERC20 cents = new MockERC20("Cent Token", "CENT", 2);
        _register(bytes32("CENT"), true, 2, address(cents));
        cents.mint(address(paymentAdapter), 1);

        vm.prank(address(eSIMWallet1));
        (uint256 spent,) = paymentAdapter.settle(bytes32("CENT"), 1, 1, address(eSIMWallet1));

        assertEq(spent, 1, "One cent must settle as one unit");
    }

    /// @notice USDT returns nothing from `transfer`, which only SafeERC20 accepts
    function test_settle_movesATokenThatReturnsNothing() public {
        MockNoReturnERC20 token = new MockNoReturnERC20();
        _register(ASSET_NRT, true, 6, address(token));

        uint256 needed = settlementAmount(PRICE_CENTS);
        token.mint(address(paymentAdapter), needed);

        vm.prank(address(eSIMWallet1));
        paymentAdapter.settle(ASSET_NRT, PRICE_CENTS, needed, address(eSIMWallet1));

        assertEq(token.balanceOf(vault), needed, "The vault should have been paid");
    }

    // ---------------------------------------------------------------------------------------------
    // What settle refuses
    // ---------------------------------------------------------------------------------------------

    function test_settle_revertsForACallerTheRegistryDoesNotKnow() public {
        fundSettlementToken(address(paymentAdapter), settlementAmount(PRICE_CENTS));

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAProtocolESIMWallet.selector, user1));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, settlementAmount(PRICE_CENTS), user1);
    }

    /// @notice A device wallet is not an eSIM wallet, so it cannot settle on one's behalf
    function test_settle_revertsForADeviceWallet() public {
        fundSettlementToken(address(paymentAdapter), settlementAmount(PRICE_CENTS));

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAProtocolESIMWallet.selector, address(deviceWallet)));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, settlementAmount(PRICE_CENTS), address(deviceWallet));
    }

    function test_settle_revertsForAnUnregisteredSymbol() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotTransferable.selector, bytes32("NOPE")));
        paymentAdapter.settle(bytes32("NOPE"), PRICE_CENTS, 1, address(eSIMWallet1));
    }

    function test_settle_revertsForAWithdrawnAsset() public {
        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(ASSET_USDC, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: SETTLEMENT_DECIMALS,
            token: settlementToken
        }));

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, ASSET_USDC));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, 1, address(eSIMWallet1));
    }

    /// @notice A currency that is not already in dollars needs a rate, and there are no feeds here
    function test_settle_revertsForAnAssetThatNeedsASwap() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        _register(ASSET_WETH, false, 18, address(weth));

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNeedsSwap.selector, ASSET_WETH));
        paymentAdapter.settle(ASSET_WETH, PRICE_CENTS, 1 ether, address(eSIMWallet1));
    }

    /// @notice Fiat is recorded, never transferred, so it has no token address to move
    function test_settle_revertsForFiat() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotTransferable.selector, ASSET_USD));
        paymentAdapter.settle(ASSET_USD, PRICE_CENTS, 1, address(eSIMWallet1));
    }

    function test_settle_revertsOnAZeroPrice() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.ZeroDataBundlePrice.selector);
        paymentAdapter.settle(ASSET_USDC, 0, 1, address(eSIMWallet1));
    }

    function test_settle_revertsOnAZeroRefundAddress() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_refundTo"));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, 1, address(0));
    }

    function test_settle_revertsWhenThePriceIsAboveWhatTheCallerWillSpend() public {
        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(paymentAdapter), needed);

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementAboveMax.selector, needed, needed - 1));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, needed - 1, address(eSIMWallet1));
    }

    function test_settle_revertsWhenTheCallerHasNotFundedIt() public {
        uint256 needed = settlementAmount(PRICE_CENTS);

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementNotFunded.selector, needed, 0));
        paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, needed, address(eSIMWallet1));
    }

    /// @notice A fee-on-transfer token delivers less than was sent, so it can never fund a settlement
    function test_settle_revertsForAFeeOnTransferToken() public {
        MockFeeOnTransferERC20 token = new MockFeeOnTransferERC20("Fee Token", "FEE", 6, 100);
        _register(bytes32("FEE"), true, 6, address(token));

        uint256 needed = settlementAmount(PRICE_CENTS);
        token.mint(address(eSIMWallet1), needed);

        vm.prank(address(eSIMWallet1));
        token.transfer(address(paymentAdapter), needed);

        uint256 arrived = token.balanceOf(address(paymentAdapter));
        assertLt(arrived, needed, "The fee should have eaten part of the transfer");

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementNotFunded.selector, needed, arrived));
        paymentAdapter.settle(bytes32("FEE"), PRICE_CENTS, needed, address(eSIMWallet1));
    }

    // ---------------------------------------------------------------------------------------------
    // What settle leaves alone
    // ---------------------------------------------------------------------------------------------

    /// @notice A caller naming more than it funded takes the difference, so nothing may name more
    /// @dev Records what the contract does rather than what it should. `_amountIn` is checked
    ///      against the balance and nothing else, so the guard is the caller: `buyDataBundleWithToken`
    ///      is the one path in and it always passes `quote`. An eSIM wallet with a way to call
    ///      `settle` with a figure of its own would make this reachable.
    function test_settle_aCallerNamingMoreThanItSentTakesTheDifference() public {
        uint256 donation = 500e6;
        fundSettlementToken(address(paymentAdapter), donation);

        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(paymentAdapter), needed);

        vm.prank(address(eSIMWallet1));
        (uint256 spent, uint256 refunded) =
            paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, donation + needed, address(eSIMWallet1));

        assertEq(spent, needed, "Only the price reaches the vault either way");
        assertEq(refunded, donation, "The declared surplus came back as a refund");
        assertEq(settlementERC20.balanceOf(address(eSIMWallet1)), donation, "The caller took what it never sent");
    }

    /// @notice A token sent here by mistake belongs to nobody, and a purchase must not carry it off
    function test_settle_leavesATokenSentHereByMistake() public {
        uint256 donation = 500e6;
        fundSettlementToken(address(paymentAdapter), donation);

        uint256 needed = settlementAmount(PRICE_CENTS);
        fundSettlementToken(address(paymentAdapter), needed);

        vm.prank(address(eSIMWallet1));
        (uint256 spent, uint256 refunded) =
            paymentAdapter.settle(ASSET_USDC, PRICE_CENTS, needed, address(eSIMWallet1));

        assertEq(spent, needed, "Only the price should move to the vault");
        assertEq(refunded, 0, "The donation is not a refund");
        assertEq(settlementERC20.balanceOf(address(paymentAdapter)), donation, "The donation must still be here");
    }

    /// @notice A token calling back mid-transfer arrives as itself, and the registry has no record
    /// of it, so the caller gate refuses it before the reentrancy guard has to
    function test_settle_refusesAReentrantCallFromTheToken() public {
        MockReenteringERC20 token = new MockReenteringERC20("Callback Token", "CB", 6);
        _register(bytes32("CB"), true, 6, address(token));

        uint256 needed = settlementAmount(PRICE_CENTS);
        token.mint(address(paymentAdapter), needed);
        token.setReentry(
            address(paymentAdapter),
            abi.encodeCall(paymentAdapter.settle, (bytes32("CB"), PRICE_CENTS, needed, address(eSIMWallet1)))
        );

        vm.prank(address(eSIMWallet1));
        paymentAdapter.settle(bytes32("CB"), PRICE_CENTS, needed, address(eSIMWallet1));

        assertTrue(token.reentered(), "The token should have tried to call back");
        assertTrue(token.reentryReverted(), "The call back should have been refused");
        assertEq(token.balanceOf(vault), needed, "The vault should have been paid once");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _register(bytes32 _symbol, bool _isDollarUnit, uint8 _decimals, address _token) private {
        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(_symbol, Asset({
            allowed: true,
            isDollarUnit: _isDollarUnit,
            decimals: _decimals,
            token: _token
        }));
    }
}
