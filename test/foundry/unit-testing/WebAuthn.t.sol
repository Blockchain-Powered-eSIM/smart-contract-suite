// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Base64 as SoladyBase64} from "solady/utils/Base64.sol";

import "contracts/CustomStructs.sol";
import "contracts/P256Verifier.sol";

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
