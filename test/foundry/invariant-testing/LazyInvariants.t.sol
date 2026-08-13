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

    /// @notice The deploy cursor never runs past the list it walks
    /// @dev The cursor is where the next batch starts reading, so a cursor beyond the list length
    ///      would underflow the outstanding count and take the continuation down permanently for
    ///      that device, leaving eSIMs that can never get a wallet.
    function invariant_deployedNeverExceedsTheESIMList() public view {
        uint256 devices = state.lazyDeviceIdentifierCount();
        for (uint256 i = 0; i < devices; ++i) {
            string memory device = state.lazyDeviceIdentifiers(i);

            assertLe(
                lazyWalletRegistry.eSIMWalletsDeployed(device),
                lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(device).length,
                "More eSIM wallets have been deployed than the device lists"
            );
        }
    }

    /// @notice A device with a deploy cursor has a device wallet, and one without has neither
    /// @dev The cursor is what the continuation reads to tell the lazy route from the ordinary one.
    ///      A cursor standing without a wallet behind it would let the continuation bind eSIM
    ///      wallets to address zero; a wallet this contract deployed with no cursor would be
    ///      unreachable, since the continuation refuses a cursor of zero.
    function invariant_deployCursorMovesOnlyWithADeviceWallet() public view {
        uint256 devices = state.lazyDeviceIdentifierCount();
        for (uint256 i = 0; i < devices; ++i) {
            string memory device = state.lazyDeviceIdentifiers(i);
            if (lazyWalletRegistry.eSIMWalletsDeployed(device) == 0) continue;

            assertTrue(
                registry.uniqueIdentifierToDeviceWallet(device) != address(0),
                "A device has a deploy cursor but no device wallet"
            );
        }
    }

    /// @notice Exactly the eSIMs below the cursor have wallets, and each carries its own identifier
    /// @dev The list positions and the wallet record are written on the same path but read on
    ///      different ones, so this is what proves the cursor names the same set the record does. An
    ///      eSIM above the cursor holding a wallet means a batch skipped a position and the next one
    ///      will deploy onto a salt already used; one below the cursor without a wallet means an eSIM
    ///      that can never be deployed, since nothing ever revisits a position behind the cursor.
    ///
    ///      Nothing is claimed here about which device wallet holds the eSIM wallet. That binding is
    ///      free to move once the wallet exists, through a removal or an ownership transfer, and the
    ///      record deliberately follows the wallet rather than the device. What has to hold is that
    ///      the wallet at a position still answers for the identifier that position names.
    function invariant_walletsExistExactlyBelowTheDeployCursor() public view {
        uint256 devices = state.lazyDeviceIdentifierCount();
        for (uint256 i = 0; i < devices; ++i) {
            string memory device = state.lazyDeviceIdentifiers(i);
            uint256 deployed = lazyWalletRegistry.eSIMWalletsDeployed(device);

            string[] memory associated =
                lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(device);

            for (uint256 j = 0; j < associated.length; ++j) {
                address wallet = lazyWalletRegistry.lazyDeployedESIMWallet(associated[j]);

                if (j < deployed) {
                    assertTrue(wallet != address(0), "An eSIM below the deploy cursor has no wallet");
                    assertTrue(
                        _sameString(MockESIMWallet(payable(wallet)).eSIMUniqueIdentifier(), associated[j]),
                        "An eSIM's wallet carries a different identifier"
                    );
                } else {
                    assertEq(wallet, address(0), "An eSIM above the deploy cursor already has a wallet");
                }
            }
        }
    }

    /// @notice A device identifier a fiat user is waiting on is only ever deployed by the lazy route
    /// @dev The collision case as a property. A wallet under a reserved identifier without this
    ///      registry's cursor behind it came from the ordinary route, and that state strands every
    ///      eSIM bound to it for good.
    ///
    ///      Both routes draw device identifiers from a shared pool, so this is reached rather than
    ///      assumed away.
    function invariant_aDeviceIdentifierIsOwnedByOneRouteOnly() public view {
        uint256 devices = state.lazyDeviceIdentifierCount();
        for (uint256 i = 0; i < devices; ++i) {
            string memory device = state.lazyDeviceIdentifiers(i);
            if (lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(device).length == 0) {
                continue;
            }
            if (registry.uniqueIdentifierToDeviceWallet(device) == address(0)) continue;

            assertTrue(
                lazyWalletRegistry.eSIMWalletsDeployed(device) != 0,
                "A reserved device identifier was deployed through the ordinary route"
            );
        }
    }

    /// @notice Compares two identifiers
    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
