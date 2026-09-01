// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Base} from "./Base.sol";

/// @notice Used to take snapshots of the state before and after a function call
/// @dev Only the purchase path needs a before and after reading. Everything else a property checks
///      is either readable at any moment or carried in ghost state, and a snapshot field that no
///      property compares is a field that can go stale without anything noticing.
abstract contract Snapshots is Base {
    struct State {
        /// @dev The four addresses a purchase can move settlement token between. Summed rather than
        ///      kept apart because the property is about the total, and which leg moved how much is
        ///      the adapter's business rather than something to pin here.
        uint256 purchaseSideTotal;
        uint256 adapterBalance;
    }

    State internal stateBefore;
    State internal stateAfter;

    /// @dev The addresses the next snapshot pair is about, set by the handler before it calls.
    address internal snapshotDeviceWallet;
    address internal snapshotESIMWallet;

    function _takeSnapshot(State storage state) private {
        address adapter = registry.paymentAdapter();
        address vaultNow = registry.vault();

        state.adapterBalance = adapter == address(0) ? 0 : settlementERC20.balanceOf(adapter);
        state.purchaseSideTotal = state.adapterBalance + settlementERC20.balanceOf(vaultNow)
            + settlementERC20.balanceOf(snapshotDeviceWallet) + settlementERC20.balanceOf(snapshotESIMWallet);
    }

    /// @notice Names the pair the next before and after reading covers
    function _snapshotPair(address deviceWallet, address eSIMWallet) internal {
        snapshotDeviceWallet = deviceWallet;
        snapshotESIMWallet = eSIMWallet;
    }

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore);
    }

    function snapshotAfter() internal {
        _takeSnapshot(stateAfter);
    }
}
