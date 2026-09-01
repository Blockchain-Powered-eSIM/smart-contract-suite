// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Errors} from "contracts/Errors.sol";
import {PaymentAdapter, Asset} from "contracts/payments/PaymentAdapter.sol";

import "test/utils/DeployerBase.sol";

/// @notice Sweeps `quote` across every price the protocol can express and every currency it can
///         accept.
/// @dev Every price in the protocol passes through this one function, and it is the only place a
///      cent figure becomes a token amount, so there is no second figure anywhere to check its
///      answer against. The sweep is what stands in for that: the price range is the full `uint64`
///      the struct field carries, and the decimals range is every value the asset table will store.
///
///      No wallets are deployed here. Only the adapter is under test and nothing below moves ETH.
contract QuotePricingTest is DeployerBase {

    /// @dev Matches MIN_ASSET_DECIMALS and MAX_ASSET_DECIMALS in the adapter, which are private
    ///      there. Registering outside this range is refused, so nothing else can be quoted.
    uint8 private constant MIN_DECIMALS = 2;
    uint8 private constant MAX_DECIMALS = 36;

    bytes32 private constant FUZZED = bytes32("FUZZ");

    /// @notice Registers the fuzzed currency and returns the decimals it settled on
    function _registerFuzzed(uint8 _decimals, bool _allowed, bool _isDollarUnit)
        internal
        returns (uint8 decimals)
    {
        decimals = uint8(bound(uint256(_decimals), MIN_DECIMALS, MAX_DECIMALS));

        vm.prank(upgradeManager);
        paymentAdapter.registerAsset(FUZZED, Asset({
            allowed: _allowed,
            isDollarUnit: _isDollarUnit,
            decimals: decimals,
            token: settlementToken
        }));
    }

    // ---------------------------------------------------------------------------------------------
    // Currencies already in dollars
    // ---------------------------------------------------------------------------------------------

    /// @notice Any price in any registrable currency converts to cents times that currency's unit
    function testFuzz_quote_convertsAnyPriceInAnyCurrency(uint64 _priceUSDCents, uint8 _decimals) public {
        uint8 decimals = _registerFuzzed(_decimals, true, true);

        assertEq(
            paymentAdapter.quote(FUZZED, _priceUSDCents),
            (uint256(_priceUSDCents) * 10 ** decimals) / 100,
            "The quote must be the cent price scaled into the currency's own unit"
        );
    }

    /// @notice No price in any registrable currency overflows
    /// @dev This is what the decimals ceiling is for. Without it a currency could be registered
    ///      that no price could ever be quoted in, and every purchase in it would revert.
    function testFuzz_quote_neverRevertsForARegisteredCurrency(uint64 _priceUSDCents, uint8 _decimals) public {
        _registerFuzzed(_decimals, true, true);

        try paymentAdapter.quote(FUZZED, _priceUSDCents) returns (uint256) {}
        catch {
            fail();
        }
    }

    /// @notice Nothing is lost converting a cent price, whatever the currency
    /// @dev The decimals floor is what makes this hold. At two decimals or more the division by a
    ///      hundred is exact, so the user is charged the price the protocol recorded.
    function testFuzz_quote_losesNoCents(uint64 _priceUSDCents, uint8 _decimals) public {
        uint8 decimals = _registerFuzzed(_decimals, true, true);
        uint256 amountIn = paymentAdapter.quote(FUZZED, _priceUSDCents);

        assertEq(
            (amountIn * 100) / 10 ** decimals,
            uint256(_priceUSDCents),
            "Converting back must give the price the protocol recorded"
        );
    }

    /// @notice A higher price never quotes a smaller amount
    function testFuzz_quote_risesWithThePrice(uint64 _lowerPrice, uint64 _higherPrice, uint8 _decimals) public {
        vm.assume(_lowerPrice <= _higherPrice);
        _registerFuzzed(_decimals, true, true);

        assertLe(
            paymentAdapter.quote(FUZZED, _lowerPrice),
            paymentAdapter.quote(FUZZED, _higherPrice),
            "A higher price must never cost less"
        );
    }

    /// @notice Two currencies with the same decimals quote the same amount for the same price
    function testFuzz_quote_dependsOnlyOnTheDecimals(uint64 _priceUSDCents) public {
        vm.startPrank(upgradeManager);
        paymentAdapter.registerAsset(bytes32("USDT"), Asset({
            allowed: true, isDollarUnit: true, decimals: 6, token: address(0)
        }));
        vm.stopPrank();

        assertEq(
            paymentAdapter.quote(bytes32("USDT"), _priceUSDCents),
            paymentAdapter.quote(ASSET_USDC, _priceUSDCents),
            "Two six-decimal currencies must quote alike"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Currencies the adapter refuses to price
    // ---------------------------------------------------------------------------------------------

    /// @notice A currency that is not already in dollars needs a rate, at any price
    /// @dev There are no price feeds here, so refusing is the only honest answer. This is the case
    ///      the swap path in a later release fills in.
    function testFuzz_quote_refusesACurrencyThatNeedsARate(uint64 _priceUSDCents, uint8 _decimals) public {
        _registerFuzzed(_decimals, true, false);

        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNeedsSwap.selector, FUZZED));
        paymentAdapter.quote(FUZZED, _priceUSDCents);
    }

    /// @notice A withdrawn currency never quotes, at any price
    function testFuzz_quote_refusesAWithdrawnCurrency(uint64 _priceUSDCents, uint8 _decimals) public {
        _registerFuzzed(_decimals, false, true);

        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, FUZZED));
        paymentAdapter.quote(FUZZED, _priceUSDCents);
    }

    /// @notice Being withdrawn is checked before needing a rate, so the reason never flips
    function testFuzz_quote_refusesAWithdrawnCurrencyThatAlsoNeedsARate(uint64 _priceUSDCents) public {
        _registerFuzzed(18, false, false);

        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, FUZZED));
        paymentAdapter.quote(FUZZED, _priceUSDCents);
    }

    /// @notice A symbol nobody registered never quotes
    function testFuzz_quote_refusesAnUnknownSymbol(bytes32 _symbol, uint64 _priceUSDCents) public {
        vm.assume(_symbol != ASSET_USDC && _symbol != ASSET_USD && _symbol != ASSET_ETH);

        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, _symbol));
        paymentAdapter.quote(_symbol, _priceUSDCents);
    }

    /// @notice Withdrawing a currency stops it quoting from that call onwards
    /// @dev The sweep is over the price, so this says the withdrawal holds for every price rather
    ///      than for the one a unit test would pick.
    function testFuzz_quote_stopsAfterACurrencyIsWithdrawn(uint64 _priceUSDCents, uint8 _decimals) public {
        uint8 decimals = _registerFuzzed(_decimals, true, true);
        paymentAdapter.quote(FUZZED, _priceUSDCents);

        vm.prank(upgradeManager);
        paymentAdapter.updateAsset(FUZZED, Asset({
            allowed: false,
            isDollarUnit: true,
            decimals: decimals,
            token: settlementToken
        }));

        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotAllowed.selector, FUZZED));
        paymentAdapter.quote(FUZZED, _priceUSDCents);
    }

    // ---------------------------------------------------------------------------------------------
    // The decimals the table accepts
    // ---------------------------------------------------------------------------------------------

    /// @notice A currency that cannot carry a cent is refused
    function testFuzz_registerAsset_refusesDecimalsBelowTheFloor(uint8 _decimals) public {
        uint8 decimals = uint8(bound(uint256(_decimals), 0, MIN_DECIMALS - 1));

        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetDecimalsTooLow.selector, FUZZED, decimals));
        paymentAdapter.registerAsset(FUZZED, Asset({
            allowed: true, isDollarUnit: true, decimals: decimals, token: settlementToken
        }));
    }

    /// @notice A currency no price could be quoted in is refused
    function testFuzz_registerAsset_refusesDecimalsAboveTheCeiling(uint8 _decimals) public {
        uint8 decimals = uint8(bound(uint256(_decimals), MAX_DECIMALS + 1, type(uint8).max));

        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetDecimalsTooHigh.selector, FUZZED, decimals));
        paymentAdapter.registerAsset(FUZZED, Asset({
            allowed: true, isDollarUnit: true, decimals: decimals, token: settlementToken
        }));
    }

    /// @notice The same two bounds apply to changing a currency as to adding one
    function testFuzz_updateAsset_refusesDecimalsOutsideTheBounds(uint8 _decimals) public {
        _registerFuzzed(18, true, true);
        vm.assume(_decimals < MIN_DECIMALS || _decimals > MAX_DECIMALS);

        bytes4 expected = _decimals < MIN_DECIMALS
            ? Errors.AssetDecimalsTooLow.selector
            : Errors.AssetDecimalsTooHigh.selector;

        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(expected, FUZZED, _decimals));
        paymentAdapter.updateAsset(FUZZED, Asset({
            allowed: true, isDollarUnit: true, decimals: _decimals, token: settlementToken
        }));
    }
}
