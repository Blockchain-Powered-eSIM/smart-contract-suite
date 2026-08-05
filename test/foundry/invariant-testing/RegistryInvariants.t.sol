// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {CampaignBase} from "test/foundry/invariant-testing/base/CampaignBase.sol";

/// @notice What the registry's two one-to-one mappings have to keep promising.
/// @dev Both bind a device wallet to something the outside world names it by, an identifier and a
///      P256 key. Neither can point at two wallets at once without one of them becoming
///      unreachable, so these are the invariants a takeover shows up in.
contract RegistryInvariantsTest is CampaignBase {

    /// @notice A device identifier keeps resolving to the wallet it was deployed for
    /// @dev Read in this direction on purpose. Asking the registry what an identifier resolves to
    ///      and comparing it against the same lookup a handler stored would agree even if a second
    ///      wallet had taken the identifier over, because a handler records whatever the deploy
    ///      returned. Starting from the wallet is what makes a takeover visible: the displaced
    ///      wallet still names the identifier, and the identifier no longer names it.
    function invariant_deviceIdentifiersStayWithTheirWallet() public view {
        uint256 count = state.deviceWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address device = state.deviceWallets(i);
            assertEq(
                registry.uniqueIdentifierToDeviceWallet(state.ghost_deviceToIdentifier(device)),
                device,
                "A device identifier stopped resolving to the wallet it was deployed for"
            );
        }
    }

    /// @notice Each device wallet holds exactly the key the registry has reserved for it
    /// @dev Three things have to line up, and a rotation is what pulls them apart. The registry's
    ///      record of the wallet's key has to match what the campaign last set, the hash of that
    ///      key has to be reserved, and the reservation has to name this wallet and no other. A
    ///      rotation that took a hash another wallet was already registered under breaks the third.
    function invariant_ownerKeysStayWithTheirWallet() public view {
        uint256 count = state.deviceWalletCount();
        for (uint256 i = 0; i < count; ++i) {
            address device = state.deviceWallets(i);
            bytes32[2] memory key = registry.getDeviceWalletToOwner(device);
            bytes32 keyHash = keccak256(abi.encode(key[0], key[1]));

            assertEq(
                keyHash,
                state.ghost_currentKeyHash(device),
                "The registry holds a different owner key than the wallet was last given"
            );
            assertEq(
                registry.registeredP256Keys(keyHash),
                device,
                "An owner key reservation names a wallet that is not the one holding the key"
            );
        }
    }

    /// @notice A retired owner key never keeps its reservation
    /// @dev The rotation deletes the old hash before writing the new one. If it stopped doing
    ///      that, the retired key would stay reserved and the wallet that once held it could never
    ///      rotate back onto it, while no wallet would answer to it either.
    function invariant_retiredOwnerKeysHoldNoReservation() public view {
        uint256 count = state.usedKeyHashCount();
        for (uint256 i = 0; i < count; ++i) {
            bytes32 keyHash = state.usedKeyHashes(i);
            address reserved = registry.registeredP256Keys(keyHash);
            if (reserved == address(0)) continue;

            assertEq(
                state.ghost_currentKeyHash(reserved),
                keyHash,
                "A key a wallet has rotated away from is still reserved to it"
            );
        }
    }
}
