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

    /// @dev Secp256r1 curve order / 2 used as guard to prevent signature malleability issue.
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
    /// @dev The decoder solc generates reverts when the bytes are not a well formed encoding, and a
    ///      revert is not a rejection anywhere this is reached from. Inside ERC-4337 validation it
    ///      fails the whole bundle rather than the one operation, and behind `isValidSignature` it
    ///      reaches an integrating contract as an error rather than as an invalid signature.
    ///      Everything below this point in this library was already written to return false instead
    ///      of reverting; the decode one level above it was not, so anything too malformed to decode
    ///      never reached the hardening.
    ///
    ///      An encoding failing any bound leaves `decoded` as solc allocated it, with both dynamic
    ///      members pointing at the zero slot. `verifySignature` then returns false, because an
    ///      empty `clientDataJSON` cannot contain the index it is handed.
    ///
    ///      Assembly, and a copy of solady's `WebAuthn.tryDecodeAuth` rather than a fresh
    ///      implementation: `WebAuthnAuth` and `WebAuthnSignature` have identical layouts, and
    ///      rewriting an audited ABI bounds check by hand only adds somewhere for a mistake to
    ///      live. Memory-safe: every read is inside `encodedSignature`, and the only writes are to
    ///      the six words solc already reserved for the return value.
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
    /// @dev We do not verify all the steps as described in the specification, only ones relevant to our context.
    ///      Please carefully read through this list before usage.
    ///
    ///      Specifically, we do verify the following:
    ///         - Verify that authenticatorData (which comes from the authenticator, such as iCloud Keychain) indicates
    ///           a well-formed assertion with the user present bit set. If `requireUV` is set, checks that the authenticator
    ///           enforced user verification. User verification should be required if, and only if, options.userVerification
    ///           is set to required in the request.
    ///         - Verifies that the client JSON is of type "webauthn.get", i.e. the client was responding to a request to
    ///           assert authentication.
    ///         - Verifies that the client JSON contains the requested challenge.
    ///         - Verifies that (r, s) constitute a valid signature over both the authenicatorData and client JSON, for public
    ///            key (x, y).
    ///
    ///      We make some assumptions about the particular use case of this verifier, so we do NOT verify the following:
    ///         - Does NOT verify that the origin in the `clientDataJSON` matches the Relying Party's origin: tt is considered
    ///           the authenticator's responsibility to ensure that the user is interacting with the correct RP. This is
    ///           enforced by most high quality authenticators properly, particularly the iCloud Keychain and Google Password
    ///           Manager were tested.
    ///         - Does NOT verify That `topOrigin` in `clientDataJSON` is well-formed: We assume it would never be present, i.e.
    ///           the credentials are never used in a cross-origin/iframe context. The website/app set up should disallow
    ///           cross-origin usage of the credentials. This is the default behaviour for created credentials in common settings.
    ///         - Does NOT verify that the `rpIdHash` in `authenticatorData` is the SHA-256 hash of the RP ID expected by the Relying
    ///           Party: this means that we rely on the authenticator to properly enforce credentials to be used only by the correct RP.
    ///           This is generally enforced with features like Apple App Site Association and Google Asset Links. To protect from
    ///           edge cases in which a previously-linked RP ID is removed from the authorised RP IDs, we recommend that messages
    ///           signed by the authenticator include some expiry mechanism.
    ///         - Does NOT verify the credential backup state: this assumes the credential backup state is NOT used as part of Relying
    ///           Party business logic or policy.
    ///         - Does NOT verify the values of the client extension outputs: this assumes that the Relying Party does not use client
    ///           extension outputs.
    ///         - Does NOT verify the signature counter: signature counters are intended to enable risk scoring for the Relying Party.
    ///           This assumes risk scoring is not used as part of Relying Party business logic or policy.
    ///         - Does NOT verify the attestation object: this assumes that response.attestationObject is NOT present in the response,
    ///           i.e. the RP does not intend to verify an attestation.
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

        // Both indices come from the caller, so bound them before any arithmetic on them. Past the
        // end of the JSON the addition below would overflow and panic, and this function must
        // return false on a malformed signature rather than revert: it runs inside ERC-4337
        // validation and behind isValidSignature, where a revert is not a rejection.
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
        // The `challenge` argument to this function is the raw bytes.
        // `webAuthnSignature.clientDataJSON` (after off-chain fix for Problem 1) contains:
        // "challenge":"<base64url_encoded_raw_hash_bytes_no_padding>"

        // challengeIndex must actually point at the challenge key. Without this the bytes are
        // skipped blindly, so an index aimed at any other quoted field is accepted, and a signature
        // made over a different challenge passes whenever that field happens to contain the
        // expected base64url value before its closing quote. The origin is the obvious carrier.
        string memory challengeKey = webAuthnSignature.clientDataJSON.slice(
            webAuthnSignature.challengeIndex,
            webAuthnSignature.challengeIndex + _CHALLENGE_KEY_LENGTH
        );
        if (keccak256(bytes(challengeKey)) != _EXPECTED_CHALLENGE_KEY_HASH) {
            return false;
        }

        // `challengeIndex` points to the opening quote of "challenge":
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

        // Encode the raw `challenge` bytes using Solady's Base64URL (fileSafe=true, noPadding=true)
        // This should match how simple-webauthn's isoBase64URL.fromBuffer() encodes.
        string memory expectedChallengeValue = SoladyBase64.encode(challenge, true, true);
        if (keccak256(bytes(actualChallengeValue)) != keccak256(bytes(expectedChallengeValue))) {
            return false;
        }

        // Skip 13., 14., 15.

        // The flags byte has to exist before it can be read. Indexing a shorter authenticatorData
        // panics, which reverts validation instead of failing the signature.
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
        // try the RIP-7212 precompile address
        (bool success, bytes memory ret) = _VERIFIER.staticcall(args);
        // staticcall will not revert if address has no code
        // check return length
        // note that even if precompile exists, ret.length is 0 when verification returns false
        // so an invalid signature will be checked twice: once by the precompile and once by FCL.
        // Ideally this signature failure is simulated offchain and no one actually pay this gas.
        bool valid = ret.length > 0;
        if (success && valid) {
            return abi.decode(ret, (uint256)) == 1;
        }

        return FCL_ecdsa.ecdsa_verify(messageHash, webAuthnSignature.r, webAuthnSignature.s, x, y);
    }
}
