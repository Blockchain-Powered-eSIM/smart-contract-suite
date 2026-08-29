// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";

/// @notice Where the protocol's ETH is allowed to be after any sequence of calls.
/// @dev Run settings come from `[profile.default.invariant]` in `foundry.toml`, and the long
///      campaign from `[profile.campaign.invariant]`. Inline `forge-config` comments are not used
///      here: they win over the active profile whatever it is named, so one left behind would pin
///      that invariant at the short settings and the campaign would silently not run it.
contract ETHInvariantsTest is CampaignBase {

    /// @notice No wei enters or leaves the accounted set
    /// @dev The campaign is funded once and nothing mints more. Every address that can end up
    ///      holding protocol ETH is summed, so a shortfall means wei reached somewhere the sum
    ///      does not name and a surplus means it was created.
    function invariant_ethIsConserved() public view {
        assertEq(_heldETH(), state.accountedETH(), "ETH left the accounted set");
    }

    /// @notice None of the four singletons ever holds ETH between transactions
    /// @dev Exactly zero, not merely small. None of them has a withdrawal path, so any balance is
    ///      stranded for good. The factory forwards or refunds everything it is sent, both
    ///      registries forward `msg.value` in full on the lazy deploy path, and none of the four
    ///      declares a `receive`, which is what stops a donation from creating a balance the
    ///      protocol can never move. The campaign attempts that donation on every run rather than
    ///      taking it on trust.
    function invariant_singletonsHoldNoETH() public view {
        assertFalse(
            state.ghost_singletonAcceptedETH(),
            "A contract with no withdrawal path accepted ETH"
        );
        assertEq(address(deviceWalletFactory).balance, 0, "Device wallet factory is holding ETH");
        assertEq(address(eSIMWalletFactory).balance, 0, "eSIM wallet factory is holding ETH");
        assertEq(address(registry).balance, 0, "Registry is holding ETH");
        assertEq(address(lazyWalletRegistry).balance, 0, "Lazy wallet registry is holding ETH");
    }

    /// @notice The right to spend a device wallet's money only ever comes from its owner
    /// @dev The flag covers only tokens now, so this is the whole spending right rather than part of
    ///      it. A pair holding it with no grant recorded is access the campaign got some other
    ///      way. Both the current device wallet and the last one are checked, since the two differ
    ///      while a transfer is outstanding.
    function invariant_fundsAccessOnlyEverCameFromTheOwner() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            _assertGranted(state.ghost_esimToDevice(wallet), wallet);
            _assertGranted(state.ghost_lastDevice(wallet), wallet);
        }
    }

    /// @notice Fails if a pair may spend without the owner having granted it
    function _assertGranted(address device, address wallet) private view {
        if (device == address(0)) return;
        if (!MockDeviceWallet(payable(device)).canPullFunds(wallet)) return;

        assertTrue(
            state.ghost_ethAccessGranted(device, wallet),
            "An eSIM wallet may spend a device wallet's money without the owner ever having granted it"
        );
    }
}
