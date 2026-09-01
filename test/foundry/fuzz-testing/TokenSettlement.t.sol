// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Errors} from "contracts/Errors.sol";
import {Asset} from "contracts/payments/PaymentAdapter.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";

/// @notice Sweeps `settle` across every price and every currency the table will hold.
/// @dev `quote` is swept on its own elsewhere. What this adds is the transfer: the amount the
///      adapter worked out has to be the amount that reaches the vault, for every price and every
///      decimals, with nothing left behind.
contract TokenSettlementTest is FuzzBase {

    /// @dev Matches MIN_ASSET_DECIMALS and MAX_ASSET_DECIMALS in the adapter, which are private there.
    uint8 private constant MIN_DECIMALS = 2;
    uint8 private constant MAX_DECIMALS = 36;

    bytes32 private constant FUZZED = bytes32("FUZZ");

    MockERC20 private token;

    function setUp() public override {
        super.setUp();
        _deployFuzzWallets();
    }

    /// @notice Registers the fuzzed currency against a token with matching decimals
    function _register(uint8 _decimals) private returns (uint8 decimals) {
        decimals = uint8(bound(uint256(_decimals), MIN_DECIMALS, MAX_DECIMALS));
        token = new MockERC20("Fuzz Token", "FUZZ", decimals);

        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(FUZZED, Asset({
            allowed: true,
            isDollarUnit: true,
            decimals: decimals,
            token: address(token)
        }));
    }

    /// @notice The expected settlement for a price, worked out independently of the adapter
    function _expected(uint64 _priceUSDCents, uint8 _decimals) private pure returns (uint256) {
        return (uint256(_priceUSDCents) * 10 ** _decimals) / 100;
    }

    // ---------------------------------------------------------------------------------------------
    // What reaches the vault
    // ---------------------------------------------------------------------------------------------

    /// @notice Any price in any currency moves the quoted amount and nothing else
    function testFuzz_settle_movesTheQuotedAmount(uint64 _priceUSDCents, uint8 _decimals) public {
        vm.assume(_priceUSDCents != 0);
        uint8 decimals = _register(_decimals);
        uint256 needed = _expected(_priceUSDCents, decimals);

        token.mint(address(paymentAdapter), needed);

        vm.prank(address(fuzzESIMWallet));
        (uint256 spent, uint256 refunded) =
            paymentAdapter.settle(FUZZED, _priceUSDCents, needed, address(fuzzESIMWallet));

        assertEq(spent, needed, "The spend must equal the quote");
        assertEq(refunded, 0, "An exactly funded settlement refunds nothing");
        assertEq(token.balanceOf(vault), needed, "The vault must hold the quoted amount");
        assertEq(token.balanceOf(address(paymentAdapter)), 0, "The adapter must be left empty");
    }

    /// @notice What settle spends is always what quote said it would
    function testFuzz_settle_neverDisagreesWithQuote(uint64 _priceUSDCents, uint8 _decimals) public {
        vm.assume(_priceUSDCents != 0);
        uint8 decimals = _register(_decimals);
        uint256 quoted = paymentAdapter.quote(FUZZED, _priceUSDCents);

        token.mint(address(paymentAdapter), quoted);

        vm.prank(address(fuzzESIMWallet));
        (uint256 spent,) = paymentAdapter.settle(FUZZED, _priceUSDCents, quoted, address(fuzzESIMWallet));

        assertEq(spent, quoted, "settle and quote must agree on every price");
        assertEq(spent, _expected(_priceUSDCents, decimals), "Both must agree with the conversion");
    }

    /// @notice Funding above the price sends the excess back and pays the vault the same
    function testFuzz_settle_refundsTheExcess(uint64 _priceUSDCents, uint8 _decimals, uint128 _extra) public {
        vm.assume(_priceUSDCents != 0);
        uint8 decimals = _register(_decimals);
        uint256 needed = _expected(_priceUSDCents, decimals);
        uint256 funded = needed + _extra;

        token.mint(address(paymentAdapter), funded);

        vm.prank(address(fuzzESIMWallet));
        (uint256 spent, uint256 refunded) =
            paymentAdapter.settle(FUZZED, _priceUSDCents, funded, address(fuzzESIMWallet));

        assertEq(spent, needed, "The vault takes the price whatever was funded");
        assertEq(refunded, _extra, "Everything above the price comes back");
        assertEq(token.balanceOf(vault), needed, "The vault must hold the price");
        assertEq(token.balanceOf(address(fuzzESIMWallet)), _extra, "The refund must reach the caller");
    }

    // ---------------------------------------------------------------------------------------------
    // What never happens
    // ---------------------------------------------------------------------------------------------

    /// @notice A settlement one unit short of its funding is refused rather than part paid
    function testFuzz_settle_revertsWhenFundedShort(uint64 _priceUSDCents, uint8 _decimals) public {
        uint8 decimals = _register(_decimals);
        _priceUSDCents = uint64(bound(_priceUSDCents, 1, type(uint64).max));
        uint256 needed = _expected(_priceUSDCents, decimals);
        vm.assume(needed != 0);

        token.mint(address(paymentAdapter), needed - 1);

        vm.prank(address(fuzzESIMWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementNotFunded.selector, needed, needed - 1));
        paymentAdapter.settle(FUZZED, _priceUSDCents, needed, address(fuzzESIMWallet));

        assertEq(token.balanceOf(vault), 0, "A refused settlement pays nobody");
    }

    /// @notice A ceiling below the price is refused, whatever the currency
    function testFuzz_settle_revertsAboveTheCeiling(uint64 _priceUSDCents, uint8 _decimals) public {
        uint8 decimals = _register(_decimals);
        _priceUSDCents = uint64(bound(_priceUSDCents, 1, type(uint64).max));
        uint256 needed = _expected(_priceUSDCents, decimals);
        vm.assume(needed != 0);

        token.mint(address(paymentAdapter), needed);

        vm.prank(address(fuzzESIMWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.SettlementAboveMax.selector, needed, needed - 1));
        paymentAdapter.settle(FUZZED, _priceUSDCents, needed - 1, address(fuzzESIMWallet));
    }

    /// @notice A token sent to the adapter is never carried off by a later settlement
    function testFuzz_settle_leavesADonationBehind(uint64 _priceUSDCents, uint8 _decimals, uint128 _donation) public {
        vm.assume(_priceUSDCents != 0);
        uint8 decimals = _register(_decimals);
        uint256 needed = _expected(_priceUSDCents, decimals);

        token.mint(address(paymentAdapter), uint256(_donation) + needed);

        vm.prank(address(fuzzESIMWallet));
        paymentAdapter.settle(FUZZED, _priceUSDCents, needed, address(fuzzESIMWallet));

        assertEq(token.balanceOf(address(paymentAdapter)), _donation, "The donation must still be there");
        assertEq(token.balanceOf(vault), needed, "The vault takes the price and no more");
    }

    /// @notice Nobody outside the registry's eSIM wallets can settle, at any price
    function testFuzz_settle_revertsForAnyOtherCaller(address _caller, uint64 _priceUSDCents) public {
        vm.assume(_caller != address(fuzzESIMWallet));
        vm.assume(registry.isESIMWalletValid(_caller) == address(0));
        uint8 decimals = _register(6);
        uint256 needed = _expected(_priceUSDCents, decimals);

        token.mint(address(paymentAdapter), needed);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAProtocolESIMWallet.selector, _caller));
        paymentAdapter.settle(FUZZED, _priceUSDCents, needed, _caller);
    }

    // ---------------------------------------------------------------------------------------------
    // The wallet path on top of it
    // ---------------------------------------------------------------------------------------------

    /// @notice Any price under the ceiling leaves the vault paid and the wallet empty
    function testFuzz_buyDataBundleWithToken_paysTheVaultAndKeepsNothing(uint64 _priceUSDCents) public {
        _priceUSDCents = uint64(bound(_priceUSDCents, 1, defaultPriceCapUSDCents));
        uint256 needed = settlementAmount(_priceUSDCents);
        fundSettlementToken(address(fuzzDeviceWallet), needed);

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundleWithToken(bundle("DB_FUZZ", _priceUSDCents), ASSET_USDC, needed, nextRef());

        assertEq(settlementERC20.balanceOf(vault), needed, "The vault must hold the price");
        assertEq(settlementERC20.balanceOf(address(fuzzESIMWallet)), 0, "The eSIM wallet must keep nothing");
        assertEq(settlementERC20.balanceOf(address(fuzzDeviceWallet)), 0, "The whole amount came from the device wallet");
    }

    /// @notice A ceiling the price fits under never changes what gets spent
    function testFuzz_buyDataBundleWithToken_spendsTheQuoteNotTheCeiling(uint64 _priceUSDCents, uint128 _headroom) public {
        _priceUSDCents = uint64(bound(_priceUSDCents, 1, defaultPriceCapUSDCents));
        uint256 needed = settlementAmount(_priceUSDCents);
        fundSettlementToken(address(fuzzDeviceWallet), needed);

        vm.prank(eSIMWalletAdmin);
        fuzzESIMWallet.buyDataBundleWithToken(
            bundle("DB_FUZZ", _priceUSDCents),
            ASSET_USDC,
            needed + _headroom,
            nextRef()
        );

        assertEq(settlementERC20.balanceOf(vault), needed, "Only the quote reaches the vault");
        assertEq(settlementERC20.balanceOf(address(fuzzDeviceWallet)), 0, "Only the quote was pulled");
    }
}
