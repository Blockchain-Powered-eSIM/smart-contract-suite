// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {Account4337} from "contracts/aa-helper/Account4337.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

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

    function _privateKey(uint256 _seed) internal pure returns (uint256) {
        return bound(_seed, 1, P256_N - 1);
    }

    /// @notice Rotates the fuzz wallet onto the key for a private key, with a real proof by it
    function _rotateTo(uint256 _key) internal returns (bytes32[2] memory newKey) {
        newKey = WebAuthnSigner.publicKeyOf(_key);
        bytes memory proof = WebAuthnSigner.signWith(_key, fuzzDeviceWallet.rotationChallenge(newKey));
        _callFromWallet(address(fuzzDeviceWallet), abi.encodeCall(Account4337.transferOwnership, (newKey, proof)));
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
    function testFuzz_transferOwnership_registryMatchesTheWallet(uint256 _seed) public {
        uint256 key = _privateKey(_seed);
        bytes32[2] memory newKey = WebAuthnSigner.publicKeyOf(key);
        vm.assume(registry.registeredP256Keys(_keyHash(newKey)) == address(0) || newKey[0] == pubKey1[0]);

        _rotateTo(key);

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
    function testFuzz_updateDeviceWalletOwnerKey_refusesTheRetiredKey(uint256 _seed) public {
        uint256 key = _privateKey(_seed);
        bytes32[2] memory newKey = WebAuthnSigner.publicKeyOf(key);
        vm.assume(newKey[0] != pubKey1[0] && registry.registeredP256Keys(_keyHash(newKey)) == address(0));

        _rotateTo(key);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyNotHeldByWallet.selector, address(fuzzDeviceWallet))
        );
        _callFromWallet(address(registry), abi.encodeCall(registry.updateDeviceWalletOwnerKey, (pubKey1)));

        assertEq(registry.registeredP256Keys(_keyHash(pubKey1)), address(0), "The retired key must stay free");
    }

    /// @notice A rotation is refused unless the new key itself signed the challenge
    /// @dev The signer is any key but the one being rotated onto, which is the stranger's-key case.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferOwnership_refusesAProofByAnyOtherKey(uint256 _targetSeed, uint256 _signerSeed) public {
        uint256 target = _privateKey(_targetSeed);
        uint256 signer = _privateKey(_signerSeed);
        vm.assume(target != signer);

        bytes32[2] memory newKey = WebAuthnSigner.publicKeyOf(target);
        vm.assume(registry.registeredP256Keys(_keyHash(newKey)) == address(0));
        bytes memory proof = WebAuthnSigner.signWith(signer, fuzzDeviceWallet.rotationChallenge(newKey));

        vm.expectRevert(Errors.NewOwnerKeyCannotSign.selector);
        _callFromWallet(address(fuzzDeviceWallet), abi.encodeCall(Account4337.transferOwnership, (newKey, proof)));

        assertEq(fuzzDeviceWallet.owner(0), pubKey1[0], "The wallet must keep its key");
        assertEq(registry.registeredP256Keys(_keyHash(newKey)), address(0), "The named key must stay free");
    }

    /// @notice A proof made for one wallet is refused by another, even by the right key
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferOwnership_refusesAProofMadeForAnotherWallet(uint256 _seed, address _otherWallet) public {
        vm.assume(_otherWallet != address(fuzzDeviceWallet));
        uint256 key = _privateKey(_seed);
        bytes32[2] memory newKey = WebAuthnSigner.publicKeyOf(key);

        // The challenge the other wallet would issue, computed the same way the contract does
        bytes memory foreignChallenge = abi.encodePacked(keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n", "116", block.chainid, _otherWallet, newKey[0], newKey[1]
        )));
        bytes memory proof = WebAuthnSigner.signWith(key, foreignChallenge);

        vm.expectRevert(Errors.NewOwnerKeyCannotSign.selector);
        _callFromWallet(address(fuzzDeviceWallet), abi.encodeCall(Account4337.transferOwnership, (newKey, proof)));
    }
}
