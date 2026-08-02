// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Base64 as SoladyBase64} from "solady/utils/Base64.sol";
import {FCL_ecdsa} from "FreshCryptoLib/FCL_ecdsa.sol";
import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";

import "contracts/CustomStructs.sol";
import "contracts/P256Verifier.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

contract WebAuthnTest is Test {

    /// @dev A rejection that reaches the P256 verification costs far more than this. Any assertion
    ///      below the bound therefore stopped at one of the checks before it.
    uint256 constant BEFORE_P256_VERIFICATION_GAS = 50_000;

    P256Verifier verifier;

    bytes challenge = hex"2ba342b171cb73e64a88467bb396919112147bff00f61bc5ec3407a1dfa192ac";

    /// @dev Coordinates of a real device key. They only have to be non-zero here: every test in this
    ///      file asserts a rejection that happens before the signature is looked at.
    uint256 constant X = 0x827b60c4e33f9796284180b39a6e02d7442b2d5189eb3c7d21f384e787104655;
    uint256 constant Y = 0x0dbb6683c742e4d0a03c004e55a0c7c1c241ac30bf59711f7c8d2d51cf41f4df;

    function setUp() public {
        verifier = new P256Verifier();
    }

    /// @notice A challenge value read from a field other than "challenge" is refused
    /// @dev The JSON commits to a different challenge and carries the expected base64url value at
    ///      the end of its origin instead, with challengeIndex aimed 13 bytes before it. Without the
    ///      key check the value matches and verification runs on to the signature, which is what the
    ///      gas bound detects: a real WebAuthn assertion for another relying party can carry an
    ///      attacker-chosen string in its origin.
    function test_verifySignature_rejectsChallengeValueFromAnotherField() public view {
        string memory prefix = '{"type":"webauthn.get","challenge":"AAAA","origin":"https://kokio.example/';
        string memory encodedChallenge = SoladyBase64.encode(challenge, true, true);
        string memory clientDataJSON = string.concat(prefix, encodedChallenge, '"}');

        WebAuthnSignature memory signature = WebAuthnSignature({
            authenticatorData: _authenticatorData(),
            clientDataJSON: clientDataJSON,
            challengeIndex: bytes(prefix).length - 13,
            typeIndex: 1,
            r: 1,
            s: 1
        });

        uint256 gasBefore = gasleft();
        bool valid = verifier.verifySignature(challenge, false, signature, X, Y);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(valid, false, "A challenge taken from another field must not verify");
        assertLt(
            gasUsed,
            BEFORE_P256_VERIFICATION_GAS,
            "Rejection must happen before the signature is verified, not after"
        );
    }

    /// @notice An authenticatorData too short to hold the flags byte is refused, not panicked on
    function test_verifySignature_rejectsShortAuthenticatorData() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.authenticatorData = new bytes(32);

        assertEq(
            verifier.verifySignature(challenge, false, signature, X, Y),
            false,
            "An authenticatorData without a flags byte must be refused"
        );
    }

    /// @notice An empty authenticatorData is refused, not panicked on
    function test_verifySignature_rejectsEmptyAuthenticatorData() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.authenticatorData = "";

        assertEq(
            verifier.verifySignature(challenge, false, signature, X, Y),
            false,
            "An empty authenticatorData must be refused"
        );
    }

    /// @notice A challengeIndex past the end of the JSON is refused, not panicked on
    /// @dev The maximum value is the case that used to overflow the addition and panic.
    function test_verifySignature_rejectsChallengeIndexPastEnd() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.challengeIndex = type(uint256).max;

        assertEq(
            verifier.verifySignature(challenge, false, signature, X, Y),
            false,
            "A challengeIndex past the end of the JSON must be refused"
        );
    }

    /// @notice A typeIndex past the end of the JSON is refused, not panicked on
    function test_verifySignature_rejectsTypeIndexPastEnd() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.typeIndex = type(uint256).max;

        assertEq(
            verifier.verifySignature(challenge, false, signature, X, Y),
            false,
            "A typeIndex past the end of the JSON must be refused"
        );
    }

    /// @notice The second valid form of a real assertion's signature is refused
    /// @dev Every ECDSA signature has a twin: (r, n - s) verifies against the same message and key.
    ///      The test asserts FreshCryptoLib accepts the twin first, otherwise a rejection here would
    ///      prove only that the flipped value is malformed. Both forms verifying would give one
    ///      authorisation two distinct onchain representations.
    function test_verifySignature_rejectsTheMalleableTwinOfARealAssertion() public {
        bytes memory ownChallenge = abi.encodePacked(keccak256("webauthn malleability"));
        bytes32[2] memory key = WebAuthnSigner.publicKey();
        WebAuthnSignature memory assertion = abi.decode(WebAuthnSigner.sign(ownChallenge), (WebAuthnSignature));

        uint256 flippedS = FCL_Elliptic_ZZ.n - assertion.s;
        assertTrue(
            FCL_ecdsa.ecdsa_verify(_signedMessageHash(assertion), assertion.r, flippedS, uint256(key[0]), uint256(key[1])),
            "The flipped signature must be a valid curve signature, or the rejection proves nothing"
        );

        assertion.s = flippedS;
        assertEq(
            verifier.verifySignature(ownChallenge, false, assertion, uint256(key[0]), uint256(key[1])),
            false,
            "The second form of an accepted signature must not verify"
        );
    }

    /// @notice A registration ceremony response replayed as an authentication assertion is refused
    /// @dev The type field is the only thing separating the two ceremonies, and a credential
    ///      creation response is signed by the same key over an attacker-influenced challenge.
    function test_verifySignature_rejectsARegistrationCeremonyType() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.clientDataJSON = string.concat(
            '{"type":"webauthn.create","challenge":"',
            SoladyBase64.encode(challenge, true, true),
            '","origin":"https://kokio.example"}'
        );
        signature.challengeIndex = 26;

        _assertRefusedBeforeVerification(signature, false, "A webauthn.create assertion must be refused");
    }

    /// @notice A challenge key sitting at the very end of the JSON, with no value after it, is
    ///         refused rather than panicked on
    function test_verifySignature_rejectsChallengeValueStartingPastEnd() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.clientDataJSON = '{"type":"webauthn.get","challenge":"';

        _assertRefusedBeforeVerification(signature, false, "A challenge key with no value must be refused");
    }

    /// @notice A challenge value never closed by a quote is refused
    /// @dev The scan for the closing quote runs off the end of the JSON and leaves the end index at
    ///      zero, which would otherwise slice backwards.
    function test_verifySignature_rejectsUnterminatedChallengeValue() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.clientDataJSON = string.concat(
            '{"type":"webauthn.get","challenge":"',
            SoladyBase64.encode(challenge, true, true)
        );

        _assertRefusedBeforeVerification(signature, false, "An unterminated challenge value must be refused");
    }

    /// @notice An assertion the user was never present for is refused
    /// @dev Flags carry user verified but not user present, so the check under test is the only one
    ///      that can refuse it.
    function test_verifySignature_rejectsAbsentUserPresentFlag() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.authenticatorData[32] = 0x04;

        _assertRefusedBeforeVerification(signature, false, "An assertion without the user present flag must be refused");
    }

    /// @notice When user verification is required, an assertion that only proves presence is refused
    /// @dev The same signature is accepted at the flag check when requireUV is false, so this
    ///      pins the caller's choice rather than the authenticator's.
    function test_verifySignature_rejectsAbsentUserVerifiedFlagWhenRequired() public view {
        WebAuthnSignature memory signature = _validShapedSignature();
        signature.authenticatorData[32] = 0x01;

        _assertRefusedBeforeVerification(
            signature, true, "An unverified assertion must be refused when verification is required"
        );
    }

    /// @notice Asserts a signature is refused, and refused by a check that runs before the P256
    ///         verification rather than by the signature itself being nonsense
    /// @param _signature The signature to submit
    /// @param _requireUV Whether user verification is required
    /// @param _reason The assertion message
    function _assertRefusedBeforeVerification(
        WebAuthnSignature memory _signature,
        bool _requireUV,
        string memory _reason
    ) internal view {
        uint256 gasBefore = gasleft();
        bool valid = verifier.verifySignature(challenge, _requireUV, _signature, X, Y);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(valid, false, _reason);
        assertLt(
            gasUsed,
            BEFORE_P256_VERIFICATION_GAS,
            "Rejection must happen before the signature is verified, not after"
        );
    }

    /// @notice Recomputes the message the P256 signature in an assertion actually covers
    /// @param _signature The assertion to read
    /// @return The hash passed to the curve verifier
    function _signedMessageHash(WebAuthnSignature memory _signature) internal pure returns (bytes32) {
        bytes32 clientDataJSONHash = sha256(bytes(_signature.clientDataJSON));
        return sha256(abi.encodePacked(_signature.authenticatorData, clientDataJSONHash));
    }

    /// @notice Returns a signature whose JSON and indices are well formed, so that each test can
    ///         break exactly one thing and know which check refused it
    function _validShapedSignature() internal view returns (WebAuthnSignature memory) {
        string memory encodedChallenge = SoladyBase64.encode(challenge, true, true);
        string memory clientDataJSON = string.concat(
            '{"type":"webauthn.get","challenge":"',
            encodedChallenge,
            '","origin":"https://kokio.example"}'
        );

        return WebAuthnSignature({
            authenticatorData: _authenticatorData(),
            clientDataJSON: clientDataJSON,
            challengeIndex: 23,
            typeIndex: 1,
            r: 1,
            s: 1
        });
    }

    /// @notice Authenticator data with the user present and user verified flags set at offset 32
    function _authenticatorData() internal pure returns (bytes memory) {
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x05;
        return authenticatorData;
    }
}
