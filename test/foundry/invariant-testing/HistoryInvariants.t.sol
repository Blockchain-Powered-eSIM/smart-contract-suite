// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

/// @notice What has to stay true about an eSIM wallet's record of what it bought.
/// @dev Its own file because the prover does not reach it. The ESIMWallet rules cover ownership,
///      the identifier and the price ceiling, but the storage analysis fails on this contract, so
///      no rule can read the array's length and this property has nowhere else to be stated. It is
///      worth stating: purchase history is what a billing dispute is settled from, and an entry
///      that goes missing cannot be reconstructed from anything else onchain.
///
///      Two writers, `buyDataBundle` on the wallet and `populateHistory` from the registry, and
///      both only append. Everything below is about the calls that are not either of them.
///
///      The comparison itself happens in the handlers, once per call, because a foundry invariant
///      function runs without committing its state and so cannot carry a mark from one call to the
///      next. What is left here is reading the flags and one sweep of every wallet at the end.
contract HistoryInvariantsTest is CampaignBase {

    /// @notice No eSIM wallet ever holds fewer purchase entries than it held before
    /// @dev The campaign swaps the eSIM wallet beacon while wallets are live, which is the one call
    ///      in the protocol that can change what every wallet's storage means at once. It also
    ///      transfers wallets between device wallets, and a transfer that took the history with it
    ///      would leave the wallet reading empty to the party that has to answer for the charges.
    function invariant_purchaseHistoryNeverShrinks() public view {
        assertFalse(state.ghost_historyShrank(), "An eSIM wallet lost purchase entries");

        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            assertGe(
                MockESIMWallet(payable(wallet)).getTransactionHistory().length,
                state.ghost_historyEntries(wallet),
                "An eSIM wallet holds fewer purchase entries than it did"
            );
        }
    }

    /// @notice An entry already written is never written over
    /// @dev The count staying put is not enough on its own. Writing through an index rather than
    ///      appending leaves the length alone and replaces what was there, which is the shape the
    ///      lazy history path had before it was changed to push each entry whole, and it is the
    ///      reason this is checked by digest rather than by length.
    function invariant_purchaseHistoryIsNeverRewritten() public view {
        assertFalse(state.ghost_historyRewritten(), "A recorded purchase entry was written over");
    }
}
