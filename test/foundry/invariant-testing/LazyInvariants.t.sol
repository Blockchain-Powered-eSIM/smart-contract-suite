// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

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

    /// @notice Compares two identifiers
    function _sameString(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
