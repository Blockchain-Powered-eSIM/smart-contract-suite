// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Base64} from "solady/utils/Base64.sol";
import {FCL_ecdsa_utils} from "FreshCryptoLib/FCL_ecdsa_utils.sol";

import {WebAuthnSignature} from "contracts/CustomStructs.sol";

/// @notice Drives test/utils/ffi/webauthn-signer.js so a test can obtain a WebAuthn assertion over
///         a challenge it chooses.
/// @dev A captured assertion cannot be reused for a different challenge. The challenge is embedded
///      in the clientDataJSON that the P256 signature covers, so any test that changes how the
///      challenge is derived has to sign again rather than edit a fixture. This shells out through
///      `vm.ffi`, which is enabled in foundry.toml.
library WebAuthnSigner {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string private constant NODE = "node";
    string private constant SCRIPT = "test/utils/ffi/webauthn-signer.js";

    /// @notice The P256 public key the harness signs with, in the shape a wallet is deployed with.
    function publicKey() internal returns (bytes32[2] memory) {
        string[] memory args = new string[](3);
        args[0] = NODE;
        args[1] = SCRIPT;
        args[2] = "pubkey";

        (bytes32 x, bytes32 y) = abi.decode(vm.ffi(args), (bytes32, bytes32));
        return [x, y];
    }

    /// @notice An ABI encoded WebAuthnSignature over `challenge`, in the form the wallet expects as
    ///         the body of a version 1 signature.
    function sign(bytes memory challenge) internal returns (bytes memory) {
        string[] memory args = new string[](4);
        args[0] = NODE;
        args[1] = SCRIPT;
        args[2] = "sign";
        args[3] = vm.toString(challenge);

        return vm.ffi(args);
    }

    /// @dev Order of the P256 curve, for moving s into the lower half the verifier requires
    uint256 private constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    /// @notice The P256 public key for a private key, in the shape a wallet holds it
    /// @dev FreshCryptoLib rather than `vm.publicKeyP256`, because Medusa has no P256 cheatcodes and
    ///      the fuzz harness signs with this too.
    function publicKeyOf(uint256 privateKey) internal view returns (bytes32[2] memory) {
        (uint256 x, uint256 y) = FCL_ecdsa_utils.ecdsa_derivKpub(privateKey);
        return [bytes32(x), bytes32(y)];
    }

    /// @notice An ABI encoded WebAuthnSignature over `challenge`, signed with any private key
    /// @dev Built in Solidity on FreshCryptoLib, so fuzz, invariant and Medusa runs can all sign
    ///      without a node process or a cheatcode. The nonce is derived from the key and the
    ///      message, so the same inputs always give the same signature. The authenticator data
    ///      carries the user present and user verified flags.
    function signWith(uint256 privateKey, bytes memory challenge) internal view returns (bytes memory) {
        string memory clientDataJSON = string.concat(
            '{"type":"webauthn.get","challenge":"',
            Base64.encode(challenge, true, true),
            '","origin":"https://kokio.test","crossOrigin":false}'
        );
        bytes memory authenticatorData = abi.encodePacked(bytes32(0), bytes1(0x05), bytes4(0));
        bytes32 messageHash = sha256(abi.encodePacked(authenticatorData, sha256(bytes(clientDataJSON))));

        uint256 nonce = (uint256(keccak256(abi.encode(privateKey, messageHash))) % (P256_N - 1)) + 1;
        (uint256 r, uint256 s) = FCL_ecdsa_utils.ecdsa_sign(messageHash, nonce, privateKey);
        uint256 lowS = s > P256_N / 2 ? P256_N - s : s;

        return abi.encode(WebAuthnSignature({
            authenticatorData: authenticatorData,
            clientDataJSON: clientDataJSON,
            challengeIndex: 23,
            typeIndex: 1,
            r: r,
            s: lowS
        }));
    }
}
