// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {WebAuthn} from "contracts/WebAuthn.sol";
import "contracts/CustomStructs.sol";

/// @notice Holds WebAuthn.verifySignature to returning false on any input rather than reverting.
/// @dev The library states this itself, at the index bound check: "this function must return false
///      on a malformed signature rather than revert: it runs inside ERC-4337 validation and behind
///      isValidSignature, where a revert is not a rejection." Every field of the struct arrives
///      from the caller, so that promise covers arbitrary combinations of them, which is what this
///      file supplies.
///
///      Three fields are the ones with arithmetic behind them. typeIndex and challengeIndex are
///      offsets into a caller-supplied string that get added to before being sliced, so a value
///      past the end used to overflow and panic. s is compared against n/2 for malleability ahead
///      of any curve work.
///
///      Called as a library rather than through a wallet, on purpose: the wallet path reaches this
///      only after abi.decode, which refuses anything that is not already a well formed struct, so
///      going through it would put the malformed cases out of reach.
contract WebAuthnInputsTest is Test {

    /// @dev A point on the P256 curve, so the fuzz reaches the verification rather than stopping at
    ///      a key check. Taken from lib/p256-verifier/test-vectors/vectors_random_valid.jsonl.
    uint256 private constant VECTOR_X = 0x31a80482dadf89de6302b1988c82c29544c9c07bb910596158f6062517eb089a;
    uint256 private constant VECTOR_Y = 0x2f54c9a0f348752950094d3228d3b940258c75fe2a413cb70baa21dc2e352fc5;

    /// @dev What a real authenticator emits, and what the type field check expects to find at
    ///      typeIndex. Kept as the well formed starting point that the fuzz moves away from.
    string private constant REAL_CLIENT_DATA =
        '{"type":"webauthn.get","challenge":"K6NCsXHLc-ZKiEZ7s5aRkRIUe_8A9hvF7DQHod-hkqw","origin":"https://example.com"}';

    /// @notice Arbitrary indices into a real clientDataJSON never revert
    /// @dev The pair the bound check exists for. typeIndex + 21 and challengeIndex + 13 are both
    ///      computed before slicing, so an index near the end of the string is where an unguarded
    ///      version overflows.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_verifySignature_arbitraryIndicesReturnFalse(
        uint256 _typeIndex,
        uint256 _challengeIndex,
        uint256 _r,
        uint256 _s
    ) public view {
        WebAuthnSignature memory assertion = WebAuthnSignature({
            authenticatorData: hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630500000000",
            clientDataJSON: REAL_CLIENT_DATA,
            challengeIndex: _challengeIndex,
            typeIndex: _typeIndex,
            r: _r,
            s: _s
        });

        assertFalse(
            WebAuthn.verifySignature(abi.encodePacked(keccak256("challenge")), true, assertion, VECTOR_X, VECTOR_Y),
            "A forged assertion must not verify"
        );
    }

    /// @notice An arbitrary clientDataJSON of any length never reverts
    /// @dev Length is the part that matters: the indices are bounded against it, so a string
    ///      shorter than the field the slice wants is the case that has to be refused rather than
    ///      read past. The empty string is included deliberately.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_verifySignature_arbitraryClientDataReturnsFalse(
        string calldata _clientDataJSON,
        uint256 _typeIndex,
        uint256 _challengeIndex
    ) public view {
        WebAuthnSignature memory assertion = WebAuthnSignature({
            authenticatorData: hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630500000000",
            clientDataJSON: _clientDataJSON,
            challengeIndex: _challengeIndex,
            typeIndex: _typeIndex,
            r: 1,
            s: 1
        });

        assertFalse(
            WebAuthn.verifySignature(abi.encodePacked(keccak256("challenge")), true, assertion, VECTOR_X, VECTOR_Y),
            "A forged assertion must not verify"
        );
    }

    /// @notice An arbitrary authenticatorData never reverts, whatever its flags byte says
    /// @dev The flags are read at a fixed offset, so a shorter authenticatorData than the format
    ///      requires is the case worth reaching. The user present and user verified bits are read
    ///      out of byte 32, which an empty value does not have.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_verifySignature_arbitraryAuthenticatorDataReturnsFalse(
        bytes calldata _authenticatorData,
        bool _requireUserVerification
    ) public view {
        WebAuthnSignature memory assertion = WebAuthnSignature({
            authenticatorData: _authenticatorData,
            clientDataJSON: REAL_CLIENT_DATA,
            challengeIndex: 23,
            typeIndex: 1,
            r: 1,
            s: 1
        });

        assertFalse(
            WebAuthn.verifySignature(
                abi.encodePacked(keccak256("challenge")),
                _requireUserVerification,
                assertion,
                VECTOR_X,
                VECTOR_Y
            ),
            "A forged assertion must not verify"
        );
    }

    /// @notice Every field arbitrary at once, including the public key
    /// @dev The combinations the field-at-a-time tests above cannot reach. An unbounded x and y are
    ///      included because a point off the curve reaches the verifier rather than a bounds check.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_verifySignature_everythingArbitraryReturnsFalse(
        bytes calldata _challenge,
        bytes calldata _authenticatorData,
        string calldata _clientDataJSON,
        uint256 _challengeIndex,
        uint256 _typeIndex,
        uint256 _r,
        uint256 _s,
        uint256 _x,
        uint256 _y
    ) public view {
        WebAuthnSignature memory assertion = WebAuthnSignature({
            authenticatorData: _authenticatorData,
            clientDataJSON: _clientDataJSON,
            challengeIndex: _challengeIndex,
            typeIndex: _typeIndex,
            r: _r,
            s: _s
        });

        assertFalse(
            WebAuthn.verifySignature(_challenge, true, assertion, _x, _y),
            "A forged assertion must not verify"
        );
    }
}
