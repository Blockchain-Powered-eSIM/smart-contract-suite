// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "contracts/CustomStructs.sol";

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice What has to stay true about purchase history recorded before any wallet exists.
/// @dev The lazy registry keeps the same association twice, once as a list per device identifier
///      and once as a single value per eSIM identifier, and moves both in the same call without
///      anything checking they still agree afterwards. A break is not visible from either side on
///      its own: the list would still deploy an eSIM wallet the other mapping says belongs
///      somewhere else, and the deploy is the point where that becomes real ETH and real history.
contract LazyInvariantsTest is CampaignBase {

    /// @notice The list and the reverse mapping name each other
    /// @dev Walked from the list side. An entry in a device identifier's list whose reverse points
    ///      elsewhere is an eSIM identifier two devices would both deploy.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_lazyListMatchesItsReverse() public view {
        uint256 devices = state.lazyDeviceIdentifierCount();
        for (uint256 i = 0; i < devices; ++i) {
            string memory device = state.lazyDeviceIdentifiers(i);
            string[] memory associated =
                lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(device);

            for (uint256 j = 0; j < associated.length; ++j) {
                assertTrue(
                    _sameString(
                        lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(associated[j]), device
                    ),
                    "A device identifier lists an eSIM identifier that points at another device"
                );
            }
        }
    }

    /// @notice Every eSIM identifier appears in the list of the device it points at
    /// @dev The other direction. An eSIM identifier pointing at a device whose list has never
    ///      heard of it is one that would be left behind by a deploy of that device.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_everyLazyESIMAppearsInItsList() public view {
        uint256 count = state.lazyESIMIdentifierCount();
        for (uint256 i = 0; i < count; ++i) {
            string memory eSIM = state.lazyESIMIdentifiers(i);
            string memory device = lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIM);
            if (bytes(device).length == 0) continue;

            string[] memory associated =
                lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(device);

            bool found;
            for (uint256 j = 0; j < associated.length; ++j) {
                if (_sameString(associated[j], eSIM)) {
                    found = true;
                    break;
                }
            }

            assertTrue(found, "An eSIM identifier points at a device whose list omits it");
        }
    }

    /// @notice A device identifier never lists the same eSIM identifier twice
    /// @dev A duplicate would deploy two eSIM wallets carrying one identifier's history, and the
    ///      purchases inside it would be replayed against both.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_lazyListsHoldNoDuplicates() public view {
        uint256 devices = state.lazyDeviceIdentifierCount();
        for (uint256 i = 0; i < devices; ++i) {
            string[] memory associated = lazyWalletRegistry
                .getESIMIdentifiersAssociatedWithDeviceIdentifier(state.lazyDeviceIdentifiers(i));

            for (uint256 j = 0; j < associated.length; ++j) {
                for (uint256 k = j + 1; k < associated.length; ++k) {
                    assertFalse(
                        _sameString(associated[j], associated[k]),
                        "A device identifier lists the same eSIM identifier twice"
                    );
                }
            }
        }
    }

    /// @notice The copy cursor never runs past what this registry actually holds
    /// @dev The cursor is what a batch reads to decide where to start, so a cursor beyond the
    ///      stored length would underflow the outstanding count on the next call and take the copy
    ///      path down permanently for that eSIM.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_copiedNeverExceedsStored() public view {
        uint256 count = state.lazyESIMIdentifierCount();
        for (uint256 i = 0; i < count; ++i) {
            string memory eSIM = state.lazyESIMIdentifiers(i);
            string memory device = lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIM);

            assertLe(
                lazyWalletRegistry.historyEntriesCopied(eSIM),
                lazyWalletRegistry.getDeviceIdentifierToESIMDetails(device, eSIM).length,
                "More history has been copied than this registry holds"
            );
        }
    }

    /// @notice The copied entries reach the wallet in order, once each
    /// @dev The wallet appends whatever batch it is handed, so a cursor that failed to advance or
    ///      advanced twice shows up here as entries missing or out of order.
    ///
    ///      Held as an in-order subsequence rather than a prefix, because a wallet can buy bundles
    ///      of its own through `buyDataBundle` while a copy is still running, and those land in the
    ///      middle of the array. That leaves the wallet's history out of chronological order, which
    ///      is a display problem with no accounting effect, and the copy is meant to finish before
    ///      the wallet is handed to anyone. What still has to hold either way is that every copied
    ///      entry arrives, in the order this registry recorded it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_copiedEntriesReachTheWalletInOrder() public view {
        uint256 count = state.lazyESIMIdentifierCount();
        for (uint256 i = 0; i < count; ++i) {
            string memory eSIM = state.lazyESIMIdentifiers(i);
            address wallet = lazyWalletRegistry.lazyDeployedESIMWallet(eSIM);
            if (wallet == address(0)) continue;

            uint256 copied = lazyWalletRegistry.historyEntriesCopied(eSIM);
            string memory device = lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIM);
            DataBundleDetails[] memory stored =
                lazyWalletRegistry.getDeviceIdentifierToESIMDetails(device, eSIM);
            DataBundleDetails[] memory inWallet = MockESIMWallet(payable(wallet)).getTransactionHistory();

            assertGe(inWallet.length, copied, "A wallet holds fewer entries than were copied into it");

            uint256 matched = 0;
            for (uint256 j = 0; j < inWallet.length && matched < copied; ++j) {
                if (
                    _sameString(inWallet[j].dataBundleID, stored[matched].dataBundleID)
                        && inWallet[j].dataBundlePrice == stored[matched].dataBundlePrice
                ) {
                    ++matched;
                }
            }

            assertEq(matched, copied, "A wallet is missing entries the cursor says were copied into it");
        }
    }

    /// @notice Nothing is copied for an eSIM that has no wallet yet
    /// @dev The cursor and the wallet record are written on different paths, so a cursor moving
    ///      without a deployment behind it would mean entries were sent somewhere unaccounted for
    ///      and would be skipped once the real wallet arrived.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_historyIsNeverCopiedBeforeDeployment() public view {
        uint256 count = state.lazyESIMIdentifierCount();
        for (uint256 i = 0; i < count; ++i) {
            string memory eSIM = state.lazyESIMIdentifiers(i);
            if (lazyWalletRegistry.lazyDeployedESIMWallet(eSIM) != address(0)) continue;

            assertEq(
                lazyWalletRegistry.historyEntriesCopied(eSIM),
                0,
                "History was copied for an eSIM that has no wallet"
            );
        }
    }

    /// @notice Every wallet the copy path can reach is one this registry deployed itself
    /// @dev Nothing makes an eSIM identifier unique across eSIM wallets, so this record is the only
    ///      thing keeping a wallet that claims a lazy user's identifier from receiving their
    ///      purchase history. The collision case as a property rather than a single case.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_historyOnlyReachesLazyDeployedWallets() public view {
        uint256 count = state.lazyESIMIdentifierCount();
        for (uint256 i = 0; i < count; ++i) {
            string memory eSIM = state.lazyESIMIdentifiers(i);
            address wallet = lazyWalletRegistry.lazyDeployedESIMWallet(eSIM);
            if (wallet == address(0)) continue;

            assertTrue(
                registry.isESIMWalletValid(wallet) != address(0)
                    || registry.isESIMWalletOnStandby(wallet),
                "The copy path names a wallet the protocol does not know"
            );
            assertTrue(
                _sameString(MockESIMWallet(payable(wallet)).eSIMUniqueIdentifier(), eSIM),
                "The copy path names a wallet carrying a different eSIM identifier"
            );
        }
    }

    /// @notice Compares two identifiers
    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
