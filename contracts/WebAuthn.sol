// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FCL_ecdsa} from "FreshCryptoLib/FCL_ecdsa.sol";
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";
import {Base64 as SoladyBase64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./CustomStructs.sol";

/// @title WebAuthn: https://github.com/base-org/webauthn-sol/blob/main/src/WebAuthn.sol
///
/// @notice A library for verifying WebAuthn Authentication Assertions, built off the work
///         of Daimo.
///
/// @dev Attempts to use the RIP-7212 precompile for signature verification.
///      If precompile verification fails, it falls back to FreshCryptoLib.
///
/// @author Coinbase (https://github.com/base-org/webauthn-sol)
/// @author Daimo (https://github.com/daimo-eth/p256-verifier/blob/master/src/WebAuthn.sol)
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/utils/WebAuthn.sol),
///         for `tryDecodeSignature`
library WebAuthn {
    using LibString for string;

    /// @dev Bit 0 of the authenticator data struct, corresponding to the "User Present" bit.
    ///      See https://www.w3.org/TR/webauthn-2/#flags.
    bytes1 private constant _AUTH_DATA_FLAGS_UP = 0x01;

    /// @dev Bit 2 of the authenticator data struct, corresponding to the "User Verified" bit.
    ///      See https://www.w3.org/TR/webauthn-2/#flags.
    bytes1 private constant _AUTH_DATA_FLAGS_UV = 0x04;

    /// @dev Half the secp256r1 curve order. Rejecting s above it stops (r, n - s) being a second
    ///      valid signature.
    uint256 private constant _P256_N_DIV_2 = FCL_Elliptic_ZZ.n / 2;

    /// @dev The precompiled contract address to use for signature verification in the “secp256r1” elliptic curve.
    ///      See https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7212.md.
    address private constant _VERIFIER = address(0x100);

    /// @dev The expected type (hash) in the client data JSON when verifying assertion signatures.
    ///      See https://www.w3.org/TR/webauthn-2/#dom-collectedclientdata-type
    bytes32 private constant _EXPECTED_TYPE_HASH = keccak256('"type":"webauthn.get"');

    /// @dev bytes('"type":"webauthn.get"').length
    uint256 private constant _TYPE_FIELD_LENGTH = 21;

    /// @dev The expected key and separator immediately preceding the challenge value in the client
    ///      data JSON. See https://www.w3.org/TR/webauthn-2/#dom-collectedclientdata-challenge
    bytes32 private constant _EXPECTED_CHALLENGE_KEY_HASH = keccak256('"challenge":"');

    /// @dev bytes('"challenge":"').length
    uint256 private constant _CHALLENGE_KEY_LENGTH = 13;

    /// @dev Offset of the flags byte in the authenticator data, after the 32 byte rpIdHash.
    ///      See https://www.w3.org/TR/webauthn-2/#sctn-authenticator-data.
    uint256 private constant _AUTH_DATA_FLAGS_OFFSET = 32;

    /// @dev Smallest encoding that can hold the struct head: six words, one per member.
    uint256 private constant _MIN_ENCODED_LENGTH = 0xc0;

    ///
    /// @notice Decodes an encoded `WebAuthnSignature` without reverting on a malformed encoding.
    ///
    /// @dev `abi.decode` reverts on bad input. Inside ERC-4337 validation that fails the whole
    ///      bundle, and behind `isValidSignature` it reaches the caller as an error, not a rejection.
    ///
    ///      On a failed bound `decoded` stays as solc allocated it, both dynamic members empty, and
    ///      `verifySignature` returns false since an empty `clientDataJSON` holds no valid index.
    ///
    ///      Inherited from solady: the length checks wrap, so a crafted length can run out of gas.
    ///      That reverts, it never accepts a signature.
    ///
    ///      Copied from solady's `WebAuthn.tryDecodeAuth` (identical struct layout) rather than
    ///      rewriting an ABI bounds check by hand. Memory-safe: every read is inside
    ///      `encodedSignature`, and the only writes are to the six words solc reserved for `decoded`.
    ///
    /// @param encodedSignature `abi.encode` of a `WebAuthnSignature`, as supplied by the caller.
    ///
    /// @return decoded The signature, or a zeroed struct when the encoding is malformed.
    function tryDecodeSignature(bytes memory encodedSignature)
        internal
        pure
        returns (WebAuthnSignature memory decoded)
    {
        /// @solidity memory-safe-assembly
        assembly {
            for { let n := mload(encodedSignature) } iszero(lt(n, _MIN_ENCODED_LENGTH)) {} {
                let o := add(encodedSignature, 0x20) // Start of the encoded bytes.
                let e := add(o, n) // End of the encoded bytes.
                let p := add(mload(o), o) // Start of the struct, from the outer offset.
                if or(gt(add(p, _MIN_ENCODED_LENGTH), e), lt(p, o)) { break }
                let authenticatorData := add(mload(p), p)
                let clientDataJSON := add(mload(add(p, 0x20)), p)
                if or(
                    or(gt(authenticatorData, e), lt(authenticatorData, p)),
                    or(gt(clientDataJSON, e), lt(clientDataJSON, p))
                ) { break }
                if or(
                    gt(add(add(authenticatorData, 0x20), mload(authenticatorData)), e),
                    gt(add(add(clientDataJSON, 0x20), mload(clientDataJSON)), e)
                ) { break }
                mstore(decoded, authenticatorData)
                mstore(add(decoded, 0x20), clientDataJSON)
                mstore(add(decoded, 0x40), mload(add(p, 0x40))) // challengeIndex
                mstore(add(decoded, 0x60), mload(add(p, 0x60))) // typeIndex
                mstore(add(decoded, 0x80), mload(add(p, 0x80))) // r
                mstore(add(decoded, 0xa0), mload(add(p, 0xa0))) // s
                break
            }
        }
    }

    ///
    /// @notice Verifies a Webauthn Authentication Assertion as described
    /// in https://www.w3.org/TR/webauthn-2/#sctn-verifying-assertion.
    ///
    /// @dev Only the spec steps relevant here are checked. Read this list before using it.
    ///
    ///      Verified:
    ///         - authenticatorData has the user present bit set, and the user verified bit too when
    ///           `requireUV` is set (require it only if options.userVerification was "required").
    ///         - The client JSON has type "webauthn.get".
    ///         - The client JSON carries the requested challenge.
    ///         - (r, s) is a valid signature by (x, y) over authenticatorData and the client JSON.
    ///
    ///      NOT verified:
    ///         - `clientDataJSON.origin`: trusted to the authenticator's own cross-origin policy.
    ///         - `clientDataJSON.topOrigin`: assumed absent, i.e. no cross-origin/iframe usage.
    ///         - `authenticatorData.rpIdHash`: trusted to the authenticator. Sign messages with an
    ///           expiry to limit exposure if a linked RP ID is later removed.
    ///         - Credential backup state: assumed unused in Relying Party policy.
    ///         - Client extension outputs: assumed unused.
    ///         - The signature counter: assumed unused for risk scoring.
    ///         - The attestation object: assumed absent from the response.
    ///
    /// @param challenge    The challenge that was provided by the relying party.
    /// @param requireUV    A boolean indicating whether user verification is required.
    /// @param webAuthnSignature The `WebAuthnSignature` struct.
    /// @param x            The x coordinate of the public key.
    /// @param y            The y coordinate of the public key.
    ///
    /// @return `true` if the authentication assertion passed validation, else `false`.
    function verifySignature(
        bytes memory challenge,
        bool requireUV,
        WebAuthnSignature memory webAuthnSignature,
        uint256 x,
        uint256 y
    )
        internal
        view
        returns (bool)
    {
        if (webAuthnSignature.s > _P256_N_DIV_2) {
            // guard against signature malleability
            return false;
        }

        // Caller-supplied indices are bounded before any arithmetic, which could otherwise overflow
        // and panic. This must return false, not revert: in ERC-4337 validation and behind
        // isValidSignature a revert is not a rejection.
        uint256 clientDataJSONLength = bytes(webAuthnSignature.clientDataJSON).length;
        if (
            webAuthnSignature.typeIndex >= clientDataJSONLength ||
            webAuthnSignature.challengeIndex >= clientDataJSONLength
        ) {
            return false;
        }

        // 11. Verify that the value of C.type is the string webauthn.get.
        string memory _type = webAuthnSignature.clientDataJSON.slice(
            webAuthnSignature.typeIndex,
            webAuthnSignature.typeIndex + _TYPE_FIELD_LENGTH
        );
        if (keccak256(bytes(_type)) != _EXPECTED_TYPE_HASH) {
            return false;
        }

        // 12. Verify that the value of C.challenge equals the base64url encoding of options.challenge.
        // `challenge` is raw bytes, and clientDataJSON holds "challenge":"<base64url, no padding>".

        // challengeIndex must point at the "challenge" key. Otherwise it could aim at another
        // quoted field, such as the origin, holding the expected value, and a signature over a
        // different challenge would pass.
        string memory challengeKey = webAuthnSignature.clientDataJSON.slice(
            webAuthnSignature.challengeIndex,
            webAuthnSignature.challengeIndex + _CHALLENGE_KEY_LENGTH
        );
        if (keccak256(bytes(challengeKey)) != _EXPECTED_CHALLENGE_KEY_HASH) {
            return false;
        }

        uint256 challengeValueStartIndexInJson = webAuthnSignature.challengeIndex + _CHALLENGE_KEY_LENGTH; // Start of the Base64URL string

        if (challengeValueStartIndexInJson >= bytes(webAuthnSignature.clientDataJSON).length) {
            return false;
        }

        // Find the closing quote for the challenge value
        uint256 challengeValueEndIndexInJson = 0;
        bytes memory clientDataBytes = bytes(webAuthnSignature.clientDataJSON);
        for (uint256 i = challengeValueStartIndexInJson; i < clientDataBytes.length; i++) {
            if (clientDataBytes[i] == '"') { // Found the closing quote
                challengeValueEndIndexInJson = i;
                break;
            }
        }

        if (challengeValueEndIndexInJson == 0 || challengeValueEndIndexInJson <= challengeValueStartIndexInJson) {
            return false;
        }

        string memory actualChallengeValue = webAuthnSignature.clientDataJSON.slice(
            challengeValueStartIndexInJson,
            challengeValueEndIndexInJson // Slice up to (but not including) the closing quote
        );

        // Base64url without padding, matching simple-webauthn's isoBase64URL.fromBuffer()
        string memory expectedChallengeValue = SoladyBase64.encode(challenge, true, true);
        if (keccak256(bytes(actualChallengeValue)) != keccak256(bytes(expectedChallengeValue))) {
            return false;
        }

        // Skip 13., 14., 15.

        // Indexing a shorter authenticatorData would panic instead of failing the signature
        if (webAuthnSignature.authenticatorData.length <= _AUTH_DATA_FLAGS_OFFSET) {
            return false;
        }
        bytes1 flags = webAuthnSignature.authenticatorData[_AUTH_DATA_FLAGS_OFFSET];

        // 16. Verify that the UP bit of the flags in authData is set.
        if (flags & _AUTH_DATA_FLAGS_UP != _AUTH_DATA_FLAGS_UP) {
            return false;
        }

        // 17. If user verification is required for this assertion, verify that the User Verified bit of the flags in
        //     authData is set.
        if (requireUV && (flags & _AUTH_DATA_FLAGS_UV) != _AUTH_DATA_FLAGS_UV) {
            return false;
        }

        // skip 18.

        // 19. Let hash be the result of computing a hash over the cData using SHA-256.
        bytes32 clientDataJSONHash = sha256(bytes(webAuthnSignature.clientDataJSON));

        // 20. Using credentialPublicKey, verify that sig is a valid signature over the binary concatenation of authData
        //     and hash.
        bytes32 messageHash = sha256(abi.encodePacked(webAuthnSignature.authenticatorData, clientDataJSONHash));
        bytes memory args = abi.encode(messageHash, webAuthnSignature.r, webAuthnSignature.s, x, y);
        // Try the RIP-7212 precompile. With no code there the call succeeds with empty output.
        (bool success, bytes memory ret) = _VERIFIER.staticcall(args);
        // The precompile also returns nothing for an invalid signature, so that case is checked
        // again by FCL. Simulating offchain first avoids paying for it.
        bool valid = ret.length > 0;
        if (success && valid) {
            return abi.decode(ret, (uint256)) == 1;
        }

        return FCL_ecdsa.ecdsa_verify(messageHash, webAuthnSignature.r, webAuthnSignature.s, x, y);
    }
}
