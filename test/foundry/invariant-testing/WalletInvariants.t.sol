// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";

/// @notice What has to stay true about who owns which eSIM wallet.
/// @dev The association is written in three places that no single call updates together, and the
///      three are only consistent because every path that changes one changes the others in the
///      same transaction. That is exactly the kind of agreement a long sequence breaks.
contract WalletInvariantsTest is CampaignBase {

    /// @notice All three contracts agree on which device wallet owns each eSIM wallet
    /// @dev The registry's mapping, the device wallet's own list, and the eSIM wallet's owner.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_associationsAgree() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            address device = registry.isESIMWalletValid(wallet);
            if (device == address(0)) continue;

            assertTrue(
                MockDeviceWallet(payable(device)).isValidESIMWallet(wallet),
                "Registry names a device wallet that does not claim the eSIM wallet"
            );
            assertEq(
                ESIMWallet(payable(wallet)).owner(),
                device,
                "Registry and the eSIM wallet disagree about the owner"
            );
        }
    }

    /// @notice An eSIM wallet is on standby exactly while no device wallet holds it
    /// @dev Two separate calls set these, so nothing in the code ties them together. The comment
    ///      at the standby toggle assumes the pairing rather than enforcing it, which makes this
    ///      the only thing checking it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_standbyMatchesDetachment() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            if (!registry.isESIMWalletOnStandby(wallet)) continue;

            assertEq(
                registry.isESIMWalletValid(wallet),
                address(0),
                "An eSIM wallet is on standby while a device wallet still holds it"
            );
        }
    }

    /// @notice An eSIM wallet never ends up ownerless
    /// @dev Ownership cannot be renounced and cannot be transferred in one step, so there is no
    ///      sequence that should leave one with no owner. An ownerless wallet holds whatever ETH
    ///      it had with nobody able to move it.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_eSIMWalletsKeepAnOwner() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            assertTrue(
                ESIMWallet(payable(state.eSIMWallets(i))).owner() != address(0),
                "An eSIM wallet has no owner"
            );
        }
    }
}
