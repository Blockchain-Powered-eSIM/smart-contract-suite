// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

/// @notice Where the protocol's ETH is allowed to be after any sequence of calls.
/// @dev Configuration is in the inline `forge-config` comments rather than `foundry.toml`, which
///      this repo keeps fixed for bytecode parity with hardhat.
contract ETHInvariantsTest is CampaignBase {

    /// @notice No wei enters or leaves the accounted set
    /// @dev The campaign is funded once and nothing mints more. Every address that can end up
    ///      holding protocol ETH is summed, so a shortfall means wei reached somewhere the sum
    ///      does not name and a surplus means it was created.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
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
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
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
}
