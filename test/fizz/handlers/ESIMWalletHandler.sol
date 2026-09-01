// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with ESIMWallet
/// @dev Every entry point here is gated on the caller being the owning device wallet, the admin, or
///      the nominated new owner, so each handler resolves that address out of live state rather than
///      taking one from the fuzzer. A handler pranking the wallet that used to own an eSIM wallet is
///      refused on every call, which is why `_pickOwnedPair` re-reads ownership on each use.
///
///      `populateHistory`, `recordSettledPurchase` and `setESIMUniqueIdentifier` have no handler.
///      All three are `onlyRegistry` with no guard of their own, so pranking the registry to call
///      them directly would reach the same code while skipping the registry-side bookkeeping the
///      properties check against. They are exercised through their real callers instead.
abstract contract ESIMWalletHandler is Properties {

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice A purchase priced under the ceiling, paid in the one currency that can move
    function eSIMWallet_buyDataBundleWithToken_clamped(
        uint256 walletSeed,
        uint256 bundleSeed,
        uint64 priceUSDCents,
        uint256 refSeed,
        bool asAdminCaller
    ) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, _effectiveCap(eSIMWallet)));

        uint256 amountIn = _settlementAmount(priceUSDCents);
        _fundForPurchase(eSIMWallet, deviceWallet, amountIn);

        eSIMWallet_buyDataBundleWithToken(
            asAdminCaller ? registry.eSIMWalletAdmin() : deviceWallet,
            eSIMWallet,
            _bundle(bundleSeed, priceUSDCents),
            ASSET_USDC,
            amountIn,
            _paymentReference(refSeed)
        );
    }

    /// @notice The smallest price the ceiling allows
    /// @dev `_quote` divides by 100 to turn cents into whole dollars before scaling, so a price
    ///      small enough relative to the asset's decimals truncates to zero units. At six decimals
    ///      one cent is still 10,000 units, but the two-decimal currency registered alongside it
    ///      makes the boundary reachable, and a decimals change would move it here first.
    function eSIMWallet_buyDataBundleWithToken_dustPrice(uint256 walletSeed, uint256 refSeed) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        _fundForPurchase(eSIMWallet, deviceWallet, _settlementAmount(1));

        eSIMWallet_buyDataBundleWithToken(
            deviceWallet, eSIMWallet, _bundle(refSeed, 1), ASSET_USDC, type(uint256).max, _paymentReference(refSeed)
        );
    }

    /// @notice A purchase priced exactly at the ceiling, which must be accepted
    /// @dev The guard is `>`, so the ceiling itself is legal. A run that only ever priced below it
    ///      would never tell the two apart.
    function eSIMWallet_buyDataBundleWithToken_atCap(uint256 walletSeed, uint256 refSeed) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        uint64 cap = uint64(_effectiveCap(eSIMWallet));
        uint256 amountIn = _settlementAmount(cap);
        _fundForPurchase(eSIMWallet, deviceWallet, amountIn);

        eSIMWallet_buyDataBundleWithToken(
            deviceWallet, eSIMWallet, _bundle(refSeed, cap), ASSET_USDC, amountIn, _paymentReference(refSeed)
        );
    }

    /// @notice A purchase the wallet cannot cover, so the shortfall has to come from the device wallet
    /// @dev The pull is where a wallet without `canPullFunds` is refused and where a fee-on-transfer
    ///      asset under-delivers, and neither is reachable while the wallet already holds enough.
    function eSIMWallet_buyDataBundleWithToken_needsPull(
        uint256 walletSeed,
        uint64 priceUSDCents,
        uint256 refSeed
    ) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, _effectiveCap(eSIMWallet)));

        // Strip the wallet so the pull is the only way the purchase can be funded
        uint256 held = settlementERC20.balanceOf(eSIMWallet);
        if (held > 0) {
            vm.prank(eSIMWallet);
            settlementERC20.transfer(address(this), held);
        }
        settlementERC20.mint(deviceWallet, _settlementAmount(priceUSDCents));

        eSIMWallet_buyDataBundleWithToken(
            deviceWallet,
            eSIMWallet,
            _bundle(refSeed, priceUSDCents),
            ASSET_USDC,
            type(uint256).max,
            _paymentReference(refSeed)
        );
    }

    /// @notice A currency that is registered but cannot settle
    /// @dev USD has no token address and ETH is not a dollar unit, so these are the two refusals
    ///      `resolveAsset` and `quote` are written for. The fuzzer would rarely guess a registered
    ///      symbol on its own.
    function eSIMWallet_buyDataBundleWithToken_unsettleableAsset(
        uint256 walletSeed,
        uint256 refSeed,
        bool useETH
    ) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        eSIMWallet_buyDataBundleWithToken(
            deviceWallet,
            eSIMWallet,
            _bundle(refSeed, 100),
            useETH ? ASSET_ETH : ASSET_USD,
            type(uint256).max,
            _paymentReference(refSeed)
        );
    }

    /// @notice Nominates another device wallet to take an eSIM wallet over
    function eSIMWallet_requestTransferOwnership_clamped(uint256 walletSeed, uint256 targetSeed) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        address target = _pickDeviceWallet(targetSeed);
        if (target == address(0)) return;

        eSIMWallet_requestTransferOwnership(deviceWallet, eSIMWallet, target);
    }

    /// @notice Completes a handover, called by whichever address the wallet currently names
    /// @dev The nominee is read off the wallet rather than guessed. There is one address that can
    ///      make this call at any moment and the fuzzer would never land on it.
    function eSIMWallet_acceptOwnershipTransfer_clamped(uint256 walletSeed) public {
        uint256 count = eSIMWallets.length;
        if (count == 0) return;

        for (uint256 i; i < count; ++i) {
            address candidate = eSIMWallets[(walletSeed + i) % count];
            address nominee = MockESIMWallet(payable(candidate)).newRequestedOwner();
            if (nominee == address(0)) continue;

            eSIMWallet_acceptOwnershipTransfer(nominee, candidate);
            return;
        }
    }

    function eSIMWallet_sendETHToDeviceWallet_clamped(uint256 walletSeed, uint256 amount) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0) || eSIMWallet.balance == 0) return;

        amount = clampBetween(amount, 1, eSIMWallet.balance);
        eSIMWallet_sendETHToDeviceWallet(deviceWallet, eSIMWallet, amount);
    }

    function eSIMWallet_sendTokenToDeviceWallet_clamped(uint256 walletSeed, uint256 amount) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        uint256 held = settlementERC20.balanceOf(eSIMWallet);
        if (held == 0) return;

        amount = clampBetween(amount, 1, held);
        eSIMWallet_sendTokenToDeviceWallet(deviceWallet, eSIMWallet, settlementToken, amount);
    }

    /// @notice ETH arriving at an eSIM wallet from outside any protocol path
    function eSIMWallet_donateETH(uint256 walletSeed, uint256 amount) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0) || actor.balance == 0) return;

        amount = clampBetween(amount, 1, actor.balance);
        Actor(payable(actor)).forceSendETH(eSIMWallet, amount);
    }

    /// @notice Settlement token arriving at an eSIM wallet from outside any protocol path
    function eSIMWallet_donateERC20(uint256 walletSeed, uint256 amount) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        uint256 balance = settlementERC20.balanceOf(actor);
        if (balance == 0) return;

        amount = clampBetween(amount, 1, balance);
        vm.prank(actor);
        settlementERC20.transfer(eSIMWallet, amount);
    }

    function eSIMWallet_secondary(uint8 selector, uint256 walletSeed, uint256 arg) public {
        selector = uint8(selector % 2);
        if (selector == 0) _eSIMWallet_setPriceCapUSDCents(walletSeed, arg);
        else _eSIMWallet_donateETHToAdapter(arg);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function eSIMWallet_buyDataBundleWithToken(
        address caller,
        address eSIMWallet,
        DataBundleDetails memory _dataBundleDetail,
        bytes32 _asset,
        uint256 _maxAmountIn,
        bytes32 _paymentRef
    ) public {
        address owningDeviceWallet = _safeESIMOwner(eSIMWallet);
        _snapshotPair(owningDeviceWallet, eSIMWallet);
        snapshotBefore();

        bool wasPaused = registry.paused();
        uint256 capAtCallTime = _effectiveCap(eSIMWallet);

        vm.prank(caller);
        MockESIMWallet(payable(eSIMWallet)).buyDataBundleWithToken(
            _dataBundleDetail, _asset, _maxAmountIn, _paymentRef
        );

        // Everything below runs only when the call went through
        if (wasPaused) ghosts.pausedCallSucceeded = true;
        if (_dataBundleDetail.priceUSDCents > capAtCallTime) ghosts.purchaseAboveCap = true;

        snapshotAfter();
        ghosts.witnessedPurchases[eSIMWallet] += 1;
        _recordSpentReference(eSIMWallet, _paymentRef);

        // Only the settleable currency actually moves tokens, so the conservation check is scoped
        // to it. The other two registered symbols never reach a transfer.
        if (_asset == ASSET_USDC) _prop_purchaseConservesValue();
    }

    function eSIMWallet_requestTransferOwnership(address caller, address eSIMWallet, address _newOwner) public {
        vm.prank(caller);
        MockESIMWallet(payable(eSIMWallet)).requestTransferOwnership(_newOwner);
    }

    function eSIMWallet_acceptOwnershipTransfer(address caller, address eSIMWallet) public {
        address associationBefore = registry.isESIMWalletValid(eSIMWallet);

        vm.prank(caller);
        MockESIMWallet(payable(eSIMWallet)).acceptOwnershipTransfer();

        _prop_handoverClearsThePriceCap(eSIMWallet);
        _prop_handoverLeavesTheAssociation(eSIMWallet, associationBefore);
    }

    function eSIMWallet_sendETHToDeviceWallet(address caller, address eSIMWallet, uint256 _amount) public {
        vm.prank(caller);
        MockESIMWallet(payable(eSIMWallet)).sendETHToDeviceWallet(_amount);
    }

    function eSIMWallet_sendTokenToDeviceWallet(
        address caller,
        address eSIMWallet,
        address _token,
        uint256 _amount
    ) public {
        vm.prank(caller);
        MockESIMWallet(payable(eSIMWallet)).sendTokenToDeviceWallet(_token, _amount);
    }

    function _eSIMWallet_setPriceCapUSDCents(uint256 walletSeed, uint256 cap) internal {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        vm.prank(deviceWallet);
        MockESIMWallet(payable(eSIMWallet)).setPriceCapUSDCents(uint64(clampBetween(cap, 0, type(uint64).max)));
    }

    /// @notice Leaves settlement token sitting on the adapter with no purchase behind it
    /// @dev The adapter is meant to hold nothing between calls. A residual balance is what would
    ///      let one purchase settle against another's funding.
    function _eSIMWallet_donateETHToAdapter(uint256 amount) internal {
        uint256 balance = settlementERC20.balanceOf(actor);
        if (balance == 0) return;

        amount = clampBetween(amount, 1, balance);
        address adapter = address(_activeAdapter());

        vm.prank(actor);
        settlementERC20.transfer(adapter, amount);
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @notice Puts enough settlement token where the purchase path will look for it
    function _fundForPurchase(address eSIMWallet, address deviceWallet, uint256 amountIn) internal {
        if (settlementERC20.balanceOf(eSIMWallet) < amountIn) {
            settlementERC20.mint(deviceWallet, amountIn);
        }
    }
}
