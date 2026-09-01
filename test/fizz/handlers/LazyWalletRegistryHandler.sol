// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with LazyWalletRegistry
/// @dev The fiat route, where purchase history is written before any wallet exists and copied in
///      afterwards. Two cursors run through it, `historyEntriesCopied` and `eSIMWalletsDeployed`,
///      and both are only safe because history freezes once a device has a wallet. Reaching that
///      freeze needs the calls in a particular order, which is what the clamped handlers arrange:
///      an all-random draw would almost never populate history before deploying against it.
abstract contract LazyWalletRegistryHandler is Properties {

    /// @dev Kept small so the same identifiers come up repeatedly and the cursors actually advance
    ///      across a sequence instead of every call starting a fresh, empty identifier.
    uint256 internal constant LAZY_DEVICES = 6;

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Pre-deployment purchase history for one device and one of its eSIMs
    function lazyWalletRegistry_batchPopulateHistory_clamped(
        uint256 deviceSeed,
        uint256 eSIMSeed,
        uint8 entryCount,
        uint64 priceUSDCents,
        bool contested
    ) public {
        string[] memory devices = new string[](1);
        string[][] memory eSIMs = new string[][](1);
        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);

        devices[0] = contested
            ? _contestedDeviceIdentifier(deviceSeed)
            : _lazyDeviceIdentifier(deviceSeed % LAZY_DEVICES);

        uint256 count = clampBetween(uint256(entryCount), 1, 6);
        priceUSDCents = uint64(clampBetween(uint256(priceUSDCents), 1, registry.defaultPriceCapUSDCents()));

        // The two inner arrays are read in step, one bundle per identifier, so an eSIM gets several
        // history entries by being named several times rather than by carrying a longer list.
        string memory eSIMIdentifier =
            contested ? _contestedESIMIdentifier(eSIMSeed) : _lazyESIMIdentifier(eSIMSeed % (LAZY_DEVICES * 2));

        eSIMs[0] = new string[](count);
        bundles[0] = new DataBundleDetails[](count);
        for (uint256 i; i < count; ++i) {
            eSIMs[0][i] = eSIMIdentifier;
            bundles[0][i] = _bundle(eSIMSeed + i, priceUSDCents);
        }

        lazyWalletRegistry_batchPopulateHistory(devices, eSIMs, bundles);
    }

    /// @notice Deploys the device wallet a lazy device has been accumulating history for
    /// @dev Moves the caller's ETH into the new wallet, which is why the pause check on this
    ///      function matters and why the handler is reachable while paused.
    function lazyWalletRegistry_deployLazyWalletAndSetESIMIdentifier_clamped(
        uint256 deviceSeed,
        uint256 keySeed,
        uint256 deposit,
        uint8 maxWallets,
        bool contested
    ) public {
        string memory identifier = contested
            ? _contestedDeviceIdentifier(deviceSeed)
            : _lazyDeviceIdentifier(deviceSeed % LAZY_DEVICES);

        // Topped up before the clamp, not after: a pranked call is debited from the pranked
        // account, so a ceiling read off an empty admin would pin every deposit at zero and the
        // ETH-moving branch this function exists to exercise would never run.
        address caller = registry.eSIMWalletAdmin();
        vm.deal(caller, caller.balance + 5 ether);
        deposit = clampBetween(deposit, 0, _spendable(caller, 5 ether));

        lazyWalletRegistry_deployLazyWalletAndSetESIMIdentifier(
            _ownerKey(keySeed),
            identifier,
            ++saltNonce,
            deposit,
            clampBetween(uint256(maxWallets), 1, 20)
        );
    }

    /// @notice Deploys the next batch of eSIM wallets for a device already deployed
    function lazyWalletRegistry_deployMoreESIMWalletsForLazyDevice_clamped(
        uint256 deviceSeed,
        uint8 maxWallets,
        bool contested
    ) public {
        string memory identifier = contested
            ? _contestedDeviceIdentifier(deviceSeed)
            : _lazyDeviceIdentifier(deviceSeed % LAZY_DEVICES);

        lazyWalletRegistry_deployMoreESIMWalletsForLazyDevice(identifier, clampBetween(uint256(maxWallets), 1, 20));
    }

    /// @notice Copies a slice of stored history into a deployed wallet
    /// @dev The cursor only ever advances here, and the whole ordering guarantee on the purchase
    ///      paths rests on it reaching the end. Small batches on purpose, so a run leaves history
    ///      partly copied often, which is the state `requireLazyHistoryCopied` exists to refuse.
    function lazyWalletRegistry_setHistoryForLazyWallet_clamped(
        uint256 eSIMSeed,
        uint8 maxEntries,
        bool contested
    ) public {
        string memory identifier =
            contested ? _contestedESIMIdentifier(eSIMSeed) : _lazyESIMIdentifier(eSIMSeed % (LAZY_DEVICES * 2));

        lazyWalletRegistry_setHistoryForLazyWallet(identifier, clampBetween(uint256(maxEntries), 1, 50));
    }

    /// @notice Moves an eSIM's reservation to a different device before either has a wallet
    /// @dev Frozen the moment either device has one, which is the guard the two cursors depend on.
    function lazyWalletRegistry_switchESIMIdentifierToNewDeviceIdentifier_clamped(
        uint256 eSIMSeed,
        uint256 fromSeed,
        uint256 toSeed
    ) public {
        lazyWalletRegistry_switchESIMIdentifierToNewDeviceIdentifier(
            _lazyESIMIdentifier(eSIMSeed % (LAZY_DEVICES * 2)),
            _lazyDeviceIdentifier(fromSeed % LAZY_DEVICES),
            _lazyDeviceIdentifier(toSeed % LAZY_DEVICES)
        );
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function lazyWalletRegistry_batchPopulateHistory(
        string[] memory _deviceUniqueIdentifiers,
        string[][] memory _eSIMUniqueIdentifiers,
        DataBundleDetails[][] memory _dataBundleDetails
    ) public asAdmin {
        lazyWalletRegistry.batchPopulateHistory(
            _deviceUniqueIdentifiers, _eSIMUniqueIdentifiers, _dataBundleDetails
        );
    }

    function lazyWalletRegistry_deployLazyWalletAndSetESIMIdentifier(
        bytes32[2] memory _deviceOwnerPublicKey,
        string memory _deviceUniqueIdentifier,
        uint256 _salt,
        uint256 _depositAmount,
        uint256 _maxWallets
    ) public asAdmin {
        // The one lazy entry point that moves ETH, and the one the pause reaches. Its two siblings
        // move none and are deliberately exempt, so neither is checked here.
        bool wasPaused = registry.paused();

        (address deviceWallet, address[] memory deployed,) = lazyWalletRegistry
            .deployLazyWalletAndSetESIMIdentifier{value: _depositAmount}(
            _deviceOwnerPublicKey, _deviceUniqueIdentifier, _salt, _depositAmount, _maxWallets
        );

        if (wasPaused) ghosts.pausedCallSucceeded = true;
        if (!_isKnownDeviceWallet(deviceWallet)) _trackDeviceWallet(deviceWallet);
        _trackDeployed(deployed);
    }

    function lazyWalletRegistry_deployMoreESIMWalletsForLazyDevice(
        string memory _deviceUniqueIdentifier,
        uint256 _maxWallets
    ) public asAdmin {
        (address[] memory deployed,) =
            lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(_deviceUniqueIdentifier, _maxWallets);
        _trackDeployed(deployed);
    }

    function lazyWalletRegistry_setHistoryForLazyWallet(string memory _eSIMIdentifier, uint256 _maxEntries)
        public
        asAdmin
    {
        lazyWalletRegistry.setHistoryForLazyWallet(_eSIMIdentifier, _maxEntries);
    }

    function lazyWalletRegistry_switchESIMIdentifierToNewDeviceIdentifier(
        string memory _eSIMIdentifier,
        string memory _oldDeviceIdentifier,
        string memory _newDeviceIdentifier
    ) public asAdmin {
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(
            _eSIMIdentifier, _oldDeviceIdentifier, _newDeviceIdentifier
        );
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    /// @notice Records whatever a lazy deployment produced, so later handlers can reach it
    function _trackDeployed(address[] memory deployed) internal {
        for (uint256 i; i < deployed.length; ++i) {
            _trackESIMWallet(deployed[i]);
        }
    }

    /// @dev A lazy device deploys one device wallet and many eSIM wallets across several calls, so
    ///      the same device wallet comes back in every batch after the first.
    function _isKnownDeviceWallet(address wallet) internal view returns (bool) {
        for (uint256 i; i < deviceWallets.length; ++i) {
            if (deviceWallets[i] == wallet) return true;
        }
        return false;
    }
}
