// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with Registry
/// @dev This is the contract every other one reads its authority from, so the config handlers in
///      the secondary dispatcher are the highest-value calls in the campaign: each one changes what
///      every wallet is allowed to do, in the same block a purchase may be in flight. They swap
///      between valid targets rather than fuzzed addresses, because a registry pointing at nothing
///      would leave the rest of the run reverting instead of exploring.
abstract contract RegistryHandler is Properties {

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice The admin recording a purchase the protocol never saw the money for
    function registry_recordSettledPurchase_clamped(
        uint256 walletSeed,
        uint256 bundleSeed,
        uint64 priceUSDCents,
        uint256 tokenAmount,
        uint256 refSeed,
        bool fiat
    ) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, registry.defaultPriceCapUSDCents()));

        DataBundleDetails memory detail = _bundle(bundleSeed, priceUSDCents);
        detail.settlement = fiat ? Settlement.Fiat : Settlement.ExternalWallet;

        registry_recordSettledPurchase(
            eSIMWallet, detail, ASSET_USDC, clampBetween(tokenAmount, 0, 1e12), _paymentReference(refSeed)
        );
    }

    /// @notice A settlement the admin claims the protocol witnessed
    /// @dev Only `buyDataBundleWithToken` may make that claim. This is the call that must be
    ///      refused, and no random draw over a three-value enum reaches it often enough.
    function registry_recordSettledPurchase_assertsDeviceWallet(uint256 walletSeed, uint256 refSeed) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        DataBundleDetails memory detail = _bundle(refSeed, 100);
        detail.settlement = Settlement.DeviceWallet;

        registry_recordSettledPurchase(eSIMWallet, detail, ASSET_USDC, 0, _paymentReference(refSeed));
    }

    /// @notice A record priced above whichever ceiling applies to the wallet
    function registry_recordSettledPurchase_overCap(uint256 walletSeed, uint256 refSeed) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        uint256 cap = registry.defaultPriceCapUSDCents();
        if (cap >= type(uint64).max) return;

        registry_recordSettledPurchase(
            eSIMWallet, _bundle(refSeed, uint64(cap + 1)), ASSET_USDC, 0, _paymentReference(refSeed)
        );
    }

    /// @notice Names an eSIM wallet, drawing from the pool both routes contend over
    function registry_assignESIMIdentifier_clamped(uint256 walletSeed, uint256 idSeed, bool contested) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        registry_assignESIMIdentifier(
            eSIMWallet, contested ? _contestedESIMIdentifier(idSeed) : _ordinaryESIMIdentifier(idSeed)
        );
    }

    /// @notice A device wallet binding an eSIM wallet that already names it as owner
    function registry_bindESIMWallet_clamped(uint256 walletSeed) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        address owner = MockESIMWallet(payable(eSIMWallet)).owner();
        if (owner == address(0)) return;

        registry_bindESIMWallet(owner, eSIMWallet, owner);
    }

    /// @notice A device wallet binding an eSIM wallet it does not own
    /// @dev The authorization reads the eSIM wallet's live `owner()` rather than the registry's own
    ///      association, and this is the call that separates the two.
    function registry_bindESIMWallet_asStranger(uint256 walletSeed, uint256 strangerSeed) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        address stranger = _pickDeviceWallet(strangerSeed);
        if (eSIMWallet == address(0) || stranger == address(0)) return;
        if (MockESIMWallet(payable(eSIMWallet)).owner() == stranger) return;

        registry_bindESIMWallet(stranger, eSIMWallet, stranger);
    }

    function registry_toggleESIMWalletStandbyStatus_clamped(uint256 walletSeed, bool onStandby) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        address owner = MockESIMWallet(payable(eSIMWallet)).owner();
        if (owner == address(0)) return;

        registry_toggleESIMWalletStandbyStatus(owner, eSIMWallet, onStandby);
    }

    /// @notice An eSIM wallet spending a payment reference directly
    /// @dev Reachable from `buyDataBundleWithToken` in production. Called on its own here so the
    ///      one-way latch is exercised without a purchase having to succeed first.
    function registry_consumePaymentReference_clamped(uint256 walletSeed, uint256 refSeed) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        registry_consumePaymentReference(eSIMWallet, _paymentReference(refSeed));
    }

    /// @notice The config surface, sequenced against whatever else is in flight
    /// @dev Owner-key rotation is deliberately not here. `updateDeviceWalletOwnerKey` is one half of
    ///      a two-sided write: the real path is `DeviceWallet.transferOwnership`, which sets the
    ///      wallet's own key and then tells the registry in the same call. Reaching the registry
    ///      alone leaves the two copies naming different keys, which is a state no caller can
    ///      produce and which every key property would then report. The rotation is exercised
    ///      through `DeviceWalletHandler` instead.
    function registry_secondary(uint8 selector, uint256 arg) public {
        selector = uint8(selector % 10);

        if (selector == 0) _registry_pause();
        else if (selector == 1) _registry_unpause();
        else if (selector == 2) _registry_setDefaultPriceCapUSDCents(arg);
        else if (selector == 3) _registry_setPaymentAdapter(arg);
        else if (selector == 4) _registry_updateVaultAddress(arg);
        else if (selector == 5) _registry_disableAdmin();
        else if (selector == 6) _registry_enableAdmin();
        else if (selector == 7) _registry_requestAdminUpdate(arg);
        else if (selector == 8) _registry_acceptAdminUpdate();
        else _registry_addOrUpdateLazyWalletRegistryAddress(arg);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function registry_recordSettledPurchase(
        address _eSIMWallet,
        DataBundleDetails memory _dataBundleDetail,
        bytes32 _asset,
        uint256 _tokenAmount,
        bytes32 _paymentRef
    ) public asAdmin {
        bool wasPaused = registry.paused();
        uint256 capAtCallTime = _effectiveCap(_eSIMWallet);

        registry.recordSettledPurchase(_eSIMWallet, _dataBundleDetail, _asset, _tokenAmount, _paymentRef);

        if (wasPaused) ghosts.pausedCallSucceeded = true;
        if (_dataBundleDetail.priceUSDCents > capAtCallTime) ghosts.purchaseAboveCap = true;
        _recordSpentReference(_eSIMWallet, _paymentRef);
    }

    function registry_assignESIMIdentifier(address _eSIMWallet, string memory _eSIMUniqueIdentifier) public asAdmin {
        registry.assignESIMIdentifier(_eSIMWallet, _eSIMUniqueIdentifier);
    }

    /// @dev The authorization here reads the eSIM wallet's live owner, so the check that the call
    ///      should have been refused has to read it too, before the call moves it.
    function registry_bindESIMWallet(address caller, address _eSIMWallet, address _deviceWallet) public {
        address ownerBefore = _safeESIMOwner(_eSIMWallet);

        vm.prank(caller);
        registry.bindESIMWallet(_eSIMWallet, _deviceWallet);

        if (ownerBefore != caller || _deviceWallet != caller) ghosts.unauthorizedBind = true;
    }

    function registry_toggleESIMWalletStandbyStatus(address caller, address _eSIMWallet, bool _onStandby) public {
        address ownerBefore = _safeESIMOwner(_eSIMWallet);
        address registrationBefore = registry.isESIMWalletValid(_eSIMWallet);

        vm.prank(caller);
        registry.toggleESIMWalletStandbyStatus(_eSIMWallet, _onStandby);

        if (ownerBefore != caller) ghosts.unauthorizedStandby = true;
        _prop_standbyLeavesTheRegistration(_eSIMWallet, registrationBefore);
    }

    function registry_consumePaymentReference(address caller, bytes32 _paymentRef) public {
        vm.prank(caller);
        registry.consumePaymentReference(_paymentRef);

        _recordSpentReference(caller, _paymentRef);
    }

    function _registry_pause() internal asAdmin {
        registry.pause();
    }

    function _registry_unpause() internal asOwner {
        registry.unpause();
    }

    /// @dev Never zero: zero reads as "no ceiling" everywhere a cap is consumed, and both setters
    ///      refuse it. Clamped low often enough that existing wallet caps and the default disagree.
    function _registry_setDefaultPriceCapUSDCents(uint256 cap) internal asOwner {
        registry.setDefaultPriceCapUSDCents(uint64(clampBetween(cap, 1, 1_000_000)));
    }

    /// @dev The rotation the reference store was moved off the adapter to survive. A fresh adapter
    ///      starts with an empty table of its own, so if replay protection still lived there every
    ///      reference already spent would re-open here.
    function _registry_setPaymentAdapter(uint256 which) internal asOwner {
        registry.setPaymentAdapter(which % 2 == 0 ? address(paymentAdapter) : address(spareAdapter));
    }

    function _registry_updateVaultAddress(uint256 which) internal asOwner {
        registry.updateVaultAddress(which % 2 == 0 ? vault : spareVault);
    }

    function _registry_disableAdmin() internal asOwner {
        registry.disableAdmin();
    }

    function _registry_enableAdmin() internal asOwner {
        registry.enableAdmin();
    }

    function _registry_requestAdminUpdate(uint256 which) internal asOwner {
        registry.requestAdminUpdate(which % 2 == 0 ? adminSuccessor : admin);
    }

    /// @dev Called by whichever address the registry currently names, since no other caller passes.
    function _registry_acceptAdminUpdate() internal {
        address nominee = registry.newRequestedAdmin();
        if (nominee == address(0)) return;

        vm.prank(nominee);
        registry.acceptAdminUpdate();
    }

    function _registry_addOrUpdateLazyWalletRegistryAddress(uint256) internal asOwner {
        registry.addOrUpdateLazyWalletRegistryAddress(address(lazyWalletRegistry));
    }
}
