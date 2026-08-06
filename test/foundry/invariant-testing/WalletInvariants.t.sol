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

    /// @notice A registration, once made, is never withdrawn
    /// @dev Zero is how the registry spells an address it has never heard of, so an eSIM wallet the
    ///      protocol deployed must never read it. This is the property that lets every other reader
    ///      answer "is this one of ours" from one mapping instead of two.
    function invariant_everyESIMWalletStaysRegistered() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);

            assertTrue(
                registry.isESIMWalletValid(wallet) != address(0),
                "An eSIM wallet the protocol deployed lost its registration"
            );
        }
    }

    /// @notice While a device wallet is holding an eSIM wallet, all three contracts agree
    /// @dev The registry's mapping, the device wallet's own list, and the eSIM wallet's owner. The
    ///      device wallet's claim is the condition rather than the registry's, because the registry
    ///      keeps naming the last holder after a release and there is nothing to agree with then.
    function invariant_associationsAgree() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            address device = registry.isESIMWalletValid(wallet);
            if (device == address(0)) continue;
            if (!MockDeviceWallet(payable(device)).isValidESIMWallet(wallet)) continue;

            assertEq(
                ESIMWallet(payable(wallet)).owner(),
                device,
                "Registry and the eSIM wallet disagree about the owner"
            );
            assertFalse(
                registry.isESIMWalletOnStandby(wallet),
                "An eSIM wallet reads as in transit while its device wallet still claims it"
            );
        }
    }

    /// @notice The transient marker is only ever up while nobody is holding the wallet
    /// @dev The marker and the device wallet's claim move in opposite directions in the same call,
    ///      one on release and one on bind, and nothing else writes either. A sequence that gets
    ///      them both up has found a path that raised the marker without the release running.
    function invariant_standbyMeansTheNamedDeviceHasLetGo() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            if (!registry.isESIMWalletOnStandby(wallet)) continue;

            address device = registry.isESIMWalletValid(wallet);
            assertFalse(
                MockDeviceWallet(payable(device)).isValidESIMWallet(wallet),
                "An eSIM wallet is in transit while its device wallet still claims it"
            );
        }
    }

    /// @notice Nothing may pull ETH from a device wallet that the device wallet does not hold
    /// @dev The pair is set together on the way in and cleared together on the way out, so the
    ///      only way to separate them is a path that clears one and not the other. A detached
    ///      wallet that kept its right to pull would be reaching into someone else's balance.
    function invariant_onlyHeldWalletsCanPullETH() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            address device = state.ghost_lastDevice(wallet);
            if (device == address(0)) continue;

            if (MockDeviceWallet(payable(device)).canPullETH(wallet)) {
                assertTrue(
                    MockDeviceWallet(payable(device)).isValidESIMWallet(wallet),
                    "An eSIM wallet may pull ETH from a device wallet that does not hold it"
                );
            }
        }
    }

    /// @notice A device wallet only claims eSIM wallets that name it as their owner
    /// @dev The opposite direction to the association check above, which starts from the registry.
    ///      A device wallet holding a claim the eSIM wallet does not recognise is what a transfer
    ///      that moved one side without the other would leave behind.
    function invariant_claimedWalletsNameTheirClaimant() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address wallet = state.eSIMWallets(i);
            address device = state.ghost_lastDevice(wallet);
            if (device == address(0)) continue;
            if (!MockDeviceWallet(payable(device)).isValidESIMWallet(wallet)) continue;

            assertEq(
                ESIMWallet(payable(wallet)).owner(),
                device,
                "A device wallet claims an eSIM wallet that names a different owner"
            );
        }
    }

    /// @notice An outstanding transfer offer always names a real device wallet, and never the
    ///         one that already owns it
    /// @dev The second half is what stops a wallet sitting with an offer nobody can act on. The
    ///      setter returns early on a self-offer rather than reverting, so the guard is a branch
    ///      and not a check, which is the kind that goes missing in a refactor.
    function invariant_transferOffersNameAnotherDeviceWallet() public view {
        uint256 count = state.eSIMWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            ESIMWallet wallet = ESIMWallet(payable(state.eSIMWallets(i)));
            address requested = wallet.newRequestedOwner();
            if (requested == address(0)) continue;

            assertTrue(
                registry.isDeviceWalletValid(requested),
                "An eSIM wallet is offered to an address the registry does not know as a device wallet"
            );
            assertTrue(
                requested != wallet.owner(),
                "An eSIM wallet is offered to the device wallet that already owns it"
            );
        }
    }

    /// @notice An eSIM wallet never ends up ownerless
    /// @dev Ownership cannot be renounced and cannot be transferred in one step, so there is no
    ///      sequence that should leave one with no owner. An ownerless wallet holds whatever ETH
    ///      it had with nobody able to move it.
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
