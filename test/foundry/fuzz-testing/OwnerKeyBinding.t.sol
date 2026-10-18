// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {Account4337} from "contracts/aa-helper/Account4337.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";

/// @notice The registry's record of a wallet's owner key, over arbitrary keys.
/// @dev The registry keeps one key to one wallet, and the deploy paths rely on that. The record
///      must always be the key the wallet actually holds, whichever way a wallet tries to write it.
contract OwnerKeyBindingTest is FuzzBase {

    /// @dev Order of the P256 curve. Private keys are taken from [1, n - 1].
    uint256 private constant P256_N =
        0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    function setUp() public override {
        super.setUp();
        _deployFuzzWallets();
    }

    function _keyHash(bytes32[2] memory _key) internal pure returns (bytes32) {
        return keccak256(abi.encode(_key[0], _key[1]));
    }

    function _publicKey(uint256 _privateKey) internal pure returns (bytes32[2] memory key) {
        (uint256 x, uint256 y) = vm.publicKeyP256(bound(_privateKey, 1, P256_N - 1));
        key = [bytes32(x), bytes32(y)];
    }

    function _callFromWallet(address _target, bytes memory _data) internal {
        vm.prank(address(entryPoint));
        fuzzDeviceWallet.execute(Call({dest: _target, value: 0, data: _data}));
    }

    /// @notice A wallet naming any key other than its own is refused, and nothing is written
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_updateDeviceWalletOwnerKey_refusesAnyKeyTheWalletDoesNotHold(
        bytes32 _x,
        bytes32 _y
    ) public {
        vm.assume(_x != pubKey1[0] || _y != pubKey1[1]);
        bytes32[2] memory named = [_x, _y];

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyNotHeldByWallet.selector, address(fuzzDeviceWallet))
        );
        _callFromWallet(address(registry), abi.encodeCall(registry.updateDeviceWalletOwnerKey, (named)));

        assertEq(registry.registeredP256Keys(_keyHash(named)), address(0), "The named key must stay free");
        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(fuzzDeviceWallet),
            "The wallet must stay registered under its own key"
        );
    }

    /// @notice After a real rotation, the registry holds exactly the key the wallet holds
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferOwnership_registryMatchesTheWallet(uint256 _privateKey) public {
        bytes32[2] memory newKey = _publicKey(_privateKey);
        vm.assume(registry.registeredP256Keys(_keyHash(newKey)) == address(0) || newKey[0] == pubKey1[0]);

        _callFromWallet(address(fuzzDeviceWallet), abi.encodeCall(Account4337.transferOwnership, (newKey)));

        bytes32[2] memory recorded = registry.getDeviceWalletToOwner(address(fuzzDeviceWallet));
        assertEq(recorded[0], fuzzDeviceWallet.owner(0), "The registry must record the X the wallet holds");
        assertEq(recorded[1], fuzzDeviceWallet.owner(1), "The registry must record the Y the wallet holds");
        assertEq(
            registry.registeredP256Keys(_keyHash(newKey)),
            address(fuzzDeviceWallet),
            "The new key must resolve to the wallet"
        );
    }

    /// @notice Once a wallet has rotated away from a key, it cannot name that key again
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_updateDeviceWalletOwnerKey_refusesTheRetiredKey(uint256 _privateKey) public {
        bytes32[2] memory newKey = _publicKey(_privateKey);
        vm.assume(newKey[0] != pubKey1[0] && registry.registeredP256Keys(_keyHash(newKey)) == address(0));

        _callFromWallet(address(fuzzDeviceWallet), abi.encodeCall(Account4337.transferOwnership, (newKey)));

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyNotHeldByWallet.selector, address(fuzzDeviceWallet))
        );
        _callFromWallet(address(registry), abi.encodeCall(registry.updateDeviceWalletOwnerKey, (pubKey1)));

        assertEq(registry.registeredP256Keys(_keyHash(pubKey1)), address(0), "The retired key must stay free");
    }
}
