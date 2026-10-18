// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {Account4337} from "contracts/aa-helper/Account4337.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

/// @notice Rotating the P256 key a device wallet answers to.
/// @dev The registry is the only onchain record of which key owns which wallet, and the deploy
///      paths check it to keep one key to one wallet. A rotation has to move that record with it,
///      so every case here asserts the registry and the wallet together rather than either alone.
contract DeviceWalletOwnerKeyTest is DeviceWalletFixture {

    /// @notice Rotates a device wallet's owner key the only way it can be reached, through the
    /// wallet calling itself
    /// @dev The entry point address is read from the fixture rather than from the wallet, because
    ///      a call to the wallet here would absorb any vm.expectRevert set by the caller.
    function _rotateOwnerKey(MockDeviceWallet _wallet, bytes32[2] memory _newOwnerKey, bytes memory _signature) internal {
        vm.prank(address(entryPoint));
        _wallet.execute(Call({
            dest: address(_wallet),
            value: 0,
            data: abi.encodeCall(Account4337.transferOwnership, (_newOwnerKey, _signature))
        }));
    }

    /// @notice The new key's signature over the wallet's rotation challenge
    /// @dev The fixture's keys are k times the generator, so private key k signs for pubKey k.
    function _proof(MockDeviceWallet _wallet, uint256 _privateKey) internal view returns (bytes memory) {
        return WebAuthnSigner.signWith(_privateKey, _wallet.rotationChallenge(WebAuthnSigner.publicKeyOf(_privateKey)));
    }

    function _keyHash(bytes32[2] memory _ownerKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(_ownerKey[0], _ownerKey[1]));
    }

    /// @notice Both co-ordinates are non-zero and inside the field, and the pair still fails
    /// y^2 = x^3 - 3x + b
    function _offCurveKey() internal pure returns (bytes32[2] memory) {
        return [bytes32(uint256(1)), bytes32(uint256(1))];
    }

    /// @notice Asserts that a rejected rotation left the wallet and the registry on the old key
    function _assertStillOnDeploymentKey() internal view {
        bytes32[2] memory held = deviceWallet.getOwner();
        assertEq(held[0], pubKey1[0], "The wallet must still hold its deployment key");
        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(deviceWallet),
            "The registry must still resolve the deployment key to the wallet"
        );
    }

    /// @notice Rotating the owner key has to move the registry with it. The registry is the only
    /// onchain record of which key owns a wallet, and it is what the deploy paths check to keep one
    /// key to one wallet. Left behind, it names a key that can no longer authorise anything and
    /// leaves the key taking over free for a second wallet to claim.
    function test_transferOwnership_movesTheRegistryBindingToTheNewKey() public {
        deployWallets();

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(deviceWallet),
            "The wallet must start registered under its deployment key"
        );

        _rotateOwnerKey(deviceWallet, pubKey4, _proof(deviceWallet, 4));

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey4)),
            address(deviceWallet),
            "The key taking over must resolve to the wallet"
        );
        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(0),
            "The retired key must no longer resolve to anything"
        );

        bytes32[2] memory recorded = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(recorded[0], pubKey4[0], "The registry must record the new X co-ordinate");
        assertEq(recorded[1], pubKey4[1], "The registry must record the new Y co-ordinate");

        bytes32[2] memory held = deviceWallet.getOwner();
        assertEq(held[0], pubKey4[0], "The wallet must hold the new X co-ordinate");
        assertEq(held[1], pubKey4[1], "The wallet must hold the new Y co-ordinate");
    }

    /// @notice A key already registered to another wallet cannot be rotated onto. One key to one
    /// wallet is checked on every deploy path, and an unchecked rotation is a way around it that
    /// leaves the mapping able to name only one of the two wallets the key would then control.
    function test_transferOwnership_rejectsAKeyAnotherWalletHolds() public {
        deployWallets();

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey2)),
            address(deviceWallet2),
            "The second wallet must hold the key this test tries to take"
        );

        // A real proof by the key's holder, so the registry's own refusal is what is tested
        bytes memory proof = _proof(deviceWallet, 2);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyAlreadyRegistered.selector, _keyHash(pubKey2))
        );
        _rotateOwnerKey(deviceWallet, pubKey2, proof);

        bytes32[2] memory held = deviceWallet.getOwner();
        assertEq(held[0], pubKey1[0], "The rejected rotation must leave the wallet on its own key");
        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey2)),
            address(deviceWallet2),
            "The rejected rotation must leave the other wallet's registration alone"
        );
    }

    /// @notice The retired key becomes free again, so the same key can be brought back on a new
    /// wallet. Without the delete it stays reserved against a wallet that no longer answers to it,
    /// and nothing can ever register it again.
    function test_transferOwnership_freesTheRetiredKeyForANewWallet() public {
        deployWallets();
        _rotateOwnerKey(deviceWallet, pubKey4, _proof(deviceWallet, 4));

        deployCustomWallet("Device_Rotated", pubKey1[0], pubKey1[1], 4242);

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(userDeviceWallet),
            "The freed key must register against the wallet that claims it next"
        );
    }

    /// @notice Rotating onto the key already held is a no-op that must not revert. The retired
    /// registration is cleared before the new one is checked, so the wallet is not caught by its
    /// own reservation.
    function test_transferOwnership_acceptsARotationOntoTheSameKey() public {
        deployWallets();

        _rotateOwnerKey(deviceWallet, pubKey1, _proof(deviceWallet, 1));

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(deviceWallet),
            "The wallet must still be registered under the key it kept"
        );

        bytes32[2] memory recorded = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(recorded[0], pubKey1[0], "The registry must still record the X co-ordinate");
        assertEq(recorded[1], pubKey1[1], "The registry must still record the Y co-ordinate");
    }

    /// @notice The override must not widen who can rotate the key. Only the wallet calling itself
    /// can, which means the owner signed for it.
    function test_transferOwnership_rejectsACallerOtherThanTheWalletItself() public {
        deployWallets();

        bytes memory proof = _proof(deviceWallet, 4);
        vm.prank(user1);
        vm.expectRevert(Errors.OnlySelf.selector);
        deviceWallet.transferOwnership(pubKey4, proof);

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey1)),
            address(deviceWallet),
            "The rejected call must leave the registration where it was"
        );
    }

    /// @notice A key off the curve can never verify a signature, so rotating onto one takes the
    /// wallet beyond reach for good: this path is only callable through execute, which needs a
    /// signature, so there is no rotating back and no reaching the balance.
    function test_transferOwnership_rejectsAnOffCurveKey() public {
        deployWallets();

        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        _rotateOwnerKey(deviceWallet, _offCurveKey(), "");

        _assertStillOnDeploymentKey();
    }

    /// @notice A co-ordinate at or above the field prime is refused rather than reduced into the
    /// field, matching what the deploy paths do with the same key.
    function test_transferOwnership_rejectsAnOutOfFieldKey() public {
        deployWallets();

        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        _rotateOwnerKey(deviceWallet, [bytes32(type(uint256).max), pubKey1[1]], "");

        _assertStillOnDeploymentKey();
    }

    // ---------------------------------------------------------------------------------------------
    // The new key's proof
    // ---------------------------------------------------------------------------------------------

    /// @notice The attack the proof closes: rotating onto a stranger's public key without them
    /// @dev Without the proof the wallet would be lost and the stranger could never register their
    ///      own key. Here the stranger is pubKey4 and has not deployed anything yet.
    function test_transferOwnership_refusesAStrangersKeyWithoutTheirProof() public {
        deployWallets();

        vm.expectRevert(Errors.NewOwnerKeyCannotSign.selector);
        _rotateOwnerKey(deviceWallet, pubKey4, "");

        _assertStillOnDeploymentKey();
        deployCustomWallet("Device_Stranger", pubKey4[0], pubKey4[1], 4444);
        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey4)),
            address(userDeviceWallet),
            "The stranger must still be able to register their own key"
        );
    }

    function test_transferOwnership_refusesAProofByADifferentKey() public {
        deployWallets();
        bytes memory signedByFive = WebAuthnSigner.signWith(5, deviceWallet.rotationChallenge(pubKey4));

        vm.expectRevert(Errors.NewOwnerKeyCannotSign.selector);
        _rotateOwnerKey(deviceWallet, pubKey4, signedByFive);

        _assertStillOnDeploymentKey();
    }

    /// @notice A proof the key made for another wallet does not carry over
    function test_transferOwnership_refusesAProofMadeForAnotherWallet() public {
        deployWallets();
        bytes memory madeForWalletTwo = WebAuthnSigner.signWith(4, deviceWallet2.rotationChallenge(pubKey4));

        vm.expectRevert(Errors.NewOwnerKeyCannotSign.selector);
        _rotateOwnerKey(deviceWallet, pubKey4, madeForWalletTwo);

        _assertStillOnDeploymentKey();
    }

    /// @notice Wallets sit at the same address on every chain, so the chain id is in the challenge
    function test_transferOwnership_refusesAProofMadeOnAnotherChain() public {
        deployWallets();
        bytes memory otherChainChallenge = abi.encodePacked(keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n", "116", block.chainid + 1, address(deviceWallet), pubKey4[0], pubKey4[1]
        )));
        bytes memory homeChallenge = deviceWallet.rotationChallenge(pubKey4);
        assertTrue(keccak256(otherChainChallenge) != keccak256(homeChallenge), "the chain id must change the challenge");
        bytes memory madeElsewhere = WebAuthnSigner.signWith(4, otherChainChallenge);

        vm.expectRevert(Errors.NewOwnerKeyCannotSign.selector);
        _rotateOwnerKey(deviceWallet, pubKey4, madeElsewhere);

        _assertStillOnDeploymentKey();
    }

    /// @notice A rotation signed the way a browser signs, through the repo's WebAuthn harness
    /// @dev The other tests build assertions in Solidity. This one goes through the node signer the
    ///      user operation tests use, so a real clientDataJSON layout is covered too.
    function test_transferOwnership_acceptsAProofFromTheWebAuthnHarness() public {
        deployWallets();
        bytes32[2] memory harnessKey = WebAuthnSigner.publicKey();
        bytes memory proof = WebAuthnSigner.sign(deviceWallet.rotationChallenge(harnessKey));

        _rotateOwnerKey(deviceWallet, harnessKey, proof);

        bytes32[2] memory held = deviceWallet.getOwner();
        assertEq(held[0], harnessKey[0], "The wallet must hold the harness key");
        assertEq(registry.registeredP256Keys(_keyHash(harnessKey)), address(deviceWallet), "The registry must follow");
    }

    /// @notice Calls the registry from the wallet without rotating, which an owner can sign for
    function _registerKeyWithoutRotating(MockDeviceWallet _wallet, bytes32[2] memory _key) internal {
        vm.prank(address(entryPoint));
        _wallet.execute(Call({
            dest: address(registry),
            value: 0,
            data: abi.encodeCall(registry.updateDeviceWalletOwnerKey, (_key))
        }));
    }

    /// @notice A wallet cannot register a key it does not hold. Without this, any owner could
    /// claim a stranger's public key in the registry and that stranger could never be registered.
    function test_updateDeviceWalletOwnerKey_rejectsAKeyTheWalletDoesNotHold() public {
        deployWallets();

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyNotHeldByWallet.selector, address(deviceWallet))
        );
        _registerKeyWithoutRotating(deviceWallet, pubKey4);

        _assertStillOnDeploymentKey();
        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey4)),
            address(0),
            "The key the wallet named must stay unregistered"
        );
    }

    /// @notice The key the wallet tried to take is still free for its real holder
    function test_updateDeviceWalletOwnerKey_leavesTheNamedKeyFreeForItsHolder() public {
        deployWallets();

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyNotHeldByWallet.selector, address(deviceWallet))
        );
        _registerKeyWithoutRotating(deviceWallet, pubKey4);

        deployCustomWallet("Device_KeyHolder", pubKey4[0], pubKey4[1], 4343);

        assertEq(
            registry.registeredP256Keys(_keyHash(pubKey4)),
            address(userDeviceWallet),
            "The key's real holder must be able to register it"
        );
    }

    /// @notice Naming the key the wallet already holds is accepted and changes nothing
    function test_updateDeviceWalletOwnerKey_acceptsTheKeyTheWalletHolds() public {
        deployWallets();

        _registerKeyWithoutRotating(deviceWallet, pubKey1);

        _assertStillOnDeploymentKey();
        bytes32[2] memory recorded = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(recorded[0], pubKey1[0], "The registry must still record the X co-ordinate");
        assertEq(recorded[1], pubKey1[1], "The registry must still record the Y co-ordinate");
    }

    /// @notice Matching only one co-ordinate is not enough
    function test_updateDeviceWalletOwnerKey_rejectsAKeyMatchingOnlyX() public {
        deployWallets();

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OwnerKeyNotHeldByWallet.selector, address(deviceWallet))
        );
        _registerKeyWithoutRotating(deviceWallet, [pubKey1[0], pubKey4[1]]);

        _assertStillOnDeploymentKey();
    }

    /// @notice The zero key is the point at infinity, which the deploy paths already reject. It is
    /// worth its own case because it is what an empty calldata slot decodes to.
    function test_transferOwnership_rejectsTheZeroKey() public {
        deployWallets();

        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        _rotateOwnerKey(deviceWallet, [bytes32(0), bytes32(0)], "");

        _assertStillOnDeploymentKey();
    }
}
