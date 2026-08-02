// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";

import {HandlerBase, HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";

/// @notice Everything anyone at all can do, done by someone holding no role.
/// @dev Three entry points against the seven in each of the other two handlers, and that costs
///      them nothing. The runner picks uniformly across every function on every target rather than
///      picking a target first, so a handler holding fewer entry points does not win a larger
///      share of the sequence for each of them. Measured at 256 runs and depth 500: every one of
///      the seventeen entry points landed between 7361 and 7661 calls.
contract AttackerHandler is HandlerBase {

    constructor(HandlerConfig memory config) HandlerBase(config) {}

    /// @notice An unprivileged caller deploys a device wallet through the permissionless path
    /// @dev `createAccount` writes no registry state, so the wallet it returns is bound to nothing
    ///      until the admin follows up. Letting the attacker reuse an identifier the admin has
    ///      already deployed against is the point: that is the front-run.
    /// @param seed Drives the identifier and owner key
    /// @param salt CREATE2 salt, kept in a small range so collisions actually happen
    /// @param reuseIdentifier Whether to claim an identifier the campaign has already used
    function createAccountPermissionless(uint256 seed, uint256 salt, bool reuseIdentifier)
        external
        counted
    {
        salt = bound(salt, 0, 1000);

        uint256 used = state.usedIdentifierCount();
        string memory identifier = reuseIdentifier && used > 0
            ? state.usedIdentifiers(seed % used)
            : _identifier(seed);
        bytes32[2] memory ownerKey = _ownerKey(seed);

        uint256 value = bound(seed, 0, _spendable(attacker, 1 ether));

        vm.prank(attacker);
        try deviceWalletFactory.createAccount{value: value}(identifier, ownerKey, salt) returns (
            DeviceWallet wallet
        ) {
            state.addPending(address(wallet), identifier, ownerKey);
            state.recordCall("createAccountPermissionless");
        } catch {
            state.recordRevert("createAccountPermissionless");
        }
    }

    /// @notice The attacker forces ETH into a wallet that never asked for it
    /// @dev Only the wallets are reachable this way. None of the four singletons declares a
    ///      `receive`, so a plain send to one reverts, which is what the singleton invariant
    ///      states and what the entry point below keeps testing.
    /// @param target Picks which wallet to hit
    /// @param amount How much to force in
    function donateETH(uint256 target, uint256 amount) external counted {
        amount = bound(amount, 1, _spendable(attacker, 1 ether));

        address recipient = _donationTarget(target);
        if (recipient == address(0) || amount == 0) {
            state.recordRevert("donateETH");
            return;
        }

        vm.prank(attacker);
        (bool sent,) = recipient.call{value: amount}("");

        if (sent) {
            state.addDonation(amount);
            state.recordCall("donateETH");
        } else {
            state.recordRevert("donateETH");
        }
    }

    /// @notice The attacker tries to strand ETH in a contract that has no way to move it out
    /// @dev None of the four accepts a plain send today. If one ever does, the ETH is stuck for
    ///      good, so the attempt is made every run rather than assumed to fail.
    /// @param target Picks which singleton to hit
    /// @param amount How much to try to force in
    function donateToSingleton(uint256 target, uint256 amount) external counted {
        amount = bound(amount, 1, _spendable(attacker, 1 ether));

        address recipient = _singletonTarget(target);

        vm.prank(attacker);
        (bool sent,) = recipient.call{value: amount}("");

        if (sent) {
            state.markSingletonAcceptedETH();
        }

        state.recordCall("donateToSingleton");
    }

    /// @notice Picks a wallet to force ETH into, or zero when none exists yet
    function _donationTarget(uint256 seed) internal view returns (address) {
        uint256 devices = state.deviceWalletCount();
        uint256 eSIMs = state.eSIMWalletCount();

        if (seed % 2 == 0 && devices > 0) {
            return state.deviceWallets(seed % devices);
        }
        if (eSIMs > 0) {
            return state.eSIMWallets(seed % eSIMs);
        }
        if (devices > 0) {
            return state.deviceWallets(seed % devices);
        }
        return address(0);
    }

    /// @notice Picks one of the four contracts that hold no balance by design
    function _singletonTarget(uint256 seed) internal view returns (address) {
        uint256 choice = seed % 4;
        if (choice == 0) return address(deviceWalletFactory);
        if (choice == 1) return address(eSIMWalletFactory);
        if (choice == 2) return address(registry);
        return address(lazyWalletRegistry);
    }
}
