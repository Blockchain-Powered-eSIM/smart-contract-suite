// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with PaymentAdapter
/// @dev `settle` is written not to trust its caller: it re-derives the amount from the price
///      through the same helper `quote` uses, and checks its own balance rather than believing the
///      funding claim. Both of those are called here directly, funded and unfunded, so the two
///      guards are exercised without a whole purchase having to line up first. In production only
///      `buyDataBundleWithToken` reaches this, since an eSIM wallet has no way to be made to call
///      anything else.
abstract contract PaymentAdapterHandler is Properties {

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice A settlement funded exactly to the price, which is what a real purchase does
    function paymentAdapter_settle_funded(uint256 walletSeed, uint64 priceUSDCents) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, registry.defaultPriceCapUSDCents()));
        uint256 amountIn = _settlementAmount(priceUSDCents);

        PaymentAdapter adapter = _activeAdapter();
        settlementERC20.mint(address(adapter), amountIn);

        paymentAdapter_settle(eSIMWallet, ASSET_USDC, priceUSDCents, amountIn, eSIMWallet);
    }

    /// @notice A settlement claiming funding that never arrived
    /// @dev The adapter holds nothing between calls, so this is the check standing between a
    ///      caller's word and the vault.
    function paymentAdapter_settle_unfunded(uint256 walletSeed, uint64 priceUSDCents) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, registry.defaultPriceCapUSDCents()));

        paymentAdapter_settle(
            eSIMWallet, ASSET_USDC, priceUSDCents, _settlementAmount(priceUSDCents), eSIMWallet
        );
    }

    /// @notice A settlement funded past the price, which is the branch that would refund
    /// @dev The one caller in production passes `quote`'s own output, so the refund never fires
    ///      there. Funding it over is the only way to reach the branch at all.
    function paymentAdapter_settle_overFunded(uint256 walletSeed, uint64 priceUSDCents, uint256 excess) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, registry.defaultPriceCapUSDCents()));
        uint256 amountIn = _settlementAmount(priceUSDCents) + clampBetween(excess, 1, 1e9);

        PaymentAdapter adapter = _activeAdapter();
        settlementERC20.mint(address(adapter), amountIn);

        paymentAdapter_settle(eSIMWallet, ASSET_USDC, priceUSDCents, amountIn, eSIMWallet);
    }

    /// @notice The conversion on its own, checked against a formula written here
    /// @dev Nothing else in the harness calls `quote` directly: the funding amounts are worked out
    ///      from `_settlementAmount`, and `settle` recomputes its own. So without this the public
    ///      entry point to the protocol's only arithmetic goes untouched by the campaign.
    function paymentAdapter_quote(uint256 symbolSeed, uint64 priceUSDCents) public {
        bytes32 symbol = symbolSeed % 2 == 0 ? ASSET_USDC : ASSET_USD;
        PaymentAdapter adapter = _activeAdapter();

        // Read through the plain getter: `resolveAsset` reverts on a withdrawn currency, and the
        // config handlers withdraw them, so the guard has to come before the read that would revert.
        (bool allowed, bool isDollarUnit, uint8 decimals,) = adapter.assets(symbol);
        if (!allowed || !isDollarUnit) return;

        _prop_quoteIsExact(priceUSDCents, decimals, adapter.quote(symbol, priceUSDCents));
    }

    /// @notice A higher price must never quote lower
    function paymentAdapter_quote_monotonic(uint256 symbolSeed, uint64 lowPrice, uint64 highPrice) public {
        bytes32 symbol = symbolSeed % 2 == 0 ? ASSET_USDC : ASSET_USD;
        PaymentAdapter adapter = _activeAdapter();

        (bool allowed, bool isDollarUnit,,) = adapter.assets(symbol);
        if (!allowed || !isDollarUnit) return;

        if (lowPrice > highPrice) (lowPrice, highPrice) = (highPrice, lowPrice);

        _prop_quoteIsMonotonic(
            adapter.quote(symbol, lowPrice), adapter.quote(symbol, highPrice), highPrice > lowPrice
        );
    }

    /// @notice A settlement funded from what `quote` itself returned
    /// @dev The two share one helper, so they cannot disagree today. That is the point: this is the
    ///      tripwire for a change that gives `settle` its own arithmetic.
    function paymentAdapter_settle_atQuotedAmount(uint256 walletSeed, uint64 priceUSDCents) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, registry.defaultPriceCapUSDCents()));

        PaymentAdapter adapter = _activeAdapter();
        uint256 quoted = adapter.quote(ASSET_USDC, priceUSDCents);
        settlementERC20.mint(address(adapter), quoted);

        vm.prank(eSIMWallet);
        (uint256 spent,) = adapter.settle(ASSET_USDC, priceUSDCents, quoted, eSIMWallet);

        eq(spent, quoted, "SP-03 settle disagreed with quote for the same inputs");
        _prop_settlementMatchesReference(priceUSDCents, spent);
    }

    /// @notice Settlement token left on the adapter with no purchase behind it
    function paymentAdapter_donateERC20(uint256 amount) public {
        uint256 balance = settlementERC20.balanceOf(actor);
        if (balance == 0) return;

        amount = clampBetween(amount, 1, balance);
        address adapter = address(_activeAdapter());

        vm.prank(actor);
        settlementERC20.transfer(adapter, amount);
    }

    function paymentAdapter_secondary(uint8 selector, uint256 arg, uint8 decimals) public {
        selector = uint8(selector % 3);
        if (selector == 0) _paymentAdapter_registerAsset(arg, decimals);
        else if (selector == 1) _paymentAdapter_updateAsset(arg, decimals);
        else _paymentAdapter_consumePaymentReference(arg);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function paymentAdapter_settle(
        address caller,
        bytes32 _symbol,
        uint64 _priceUSDCents,
        uint256 _amountIn,
        address _refundTo
    ) public {
        // Resolved before the prank, not inside the call: reading it is itself an external call,
        // and a prank only survives to the next one.
        PaymentAdapter adapter = _activeAdapter();

        vm.prank(caller);
        adapter.settle(_symbol, _priceUSDCents, _amountIn, _refundTo);
    }

    /// @notice Adds a currency under a symbol nothing has claimed
    /// @dev Decimals are drawn across the whole byte range rather than the legal window, so the
    ///      two bounds either side of it are reached rather than assumed.
    function _paymentAdapter_registerAsset(uint256 symbolSeed, uint8 decimals) internal asOwner {
        _activeAdapter().registerAsset(
            _symbol(symbolSeed),
            Asset({
                allowed: true,
                isDollarUnit: symbolSeed % 2 == 0,
                decimals: decimals,
                token: symbolSeed % 3 == 0 ? settlementToken : address(0)
            })
        );
    }

    /// @notice Rewrites a currency already registered
    /// @dev The settlement currency keeps its decimals. Everything that funds a purchase works the
    ///      amount out from six, so moving them under the harness would make it fund the wrong
    ///      number and report the mismatch as a protocol defect. Its `allowed` flag still moves,
    ///      which is the part that changes what the protocol does. The scratch symbols take the
    ///      fuzzed decimals, so the bound either side of the legal window is still reached.
    function _paymentAdapter_updateAsset(uint256 symbolSeed, uint8 decimals) internal asOwner {
        if (symbolSeed % 4 == 0) {
            _activeAdapter().updateAsset(
                ASSET_USDC,
                Asset({
                    allowed: symbolSeed % 5 != 0,
                    isDollarUnit: true,
                    decimals: SETTLEMENT_DECIMALS,
                    token: settlementToken
                })
            );
            return;
        }

        _activeAdapter().updateAsset(
            _symbol(symbolSeed),
            Asset({
                allowed: symbolSeed % 5 != 0,
                isDollarUnit: true,
                decimals: decimals,
                token: settlementToken
            })
        );
    }

    /// @notice The adapter's own retired reference store
    /// @dev No live purchase path reads it any more; the registry holds the one that counts. Called
    ///      so a property can show the two are genuinely independent rather than assumed to be.
    function _paymentAdapter_consumePaymentReference(uint256 refSeed) internal {
        PaymentAdapter adapter = _activeAdapter();

        vm.prank(address(registry));
        adapter.consumePaymentReference(_paymentReference(refSeed));
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @dev A small symbol space, so `registerAsset` and `updateAsset` contend over the same entries
    ///      instead of each call inventing a symbol neither guard has an opinion about.
    function _symbol(uint256 seed) internal pure returns (bytes32) {
        return bytes32(uint256(seed % 6) + 1);
    }
}
