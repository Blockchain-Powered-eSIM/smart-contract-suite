// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {WebAuthn} from "contracts/WebAuthn.sol";
import "contracts/CustomStructs.sol";

/// @notice Holds the WebAuthn library to answering on any input rather than reverting.
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
///      Called as a library rather than through a wallet, on purpose. The wallet supplies the
///      struct by decoding caller bytes, so going through it would bound what the fields can be to
///      whatever a decoder will produce, and half of what is checked here is what happens outside
///      that range.
///
///      The second half of the file covers the decode itself, which is the step that turns those
///      bytes into the struct and the one place in this path that used to revert. Its promise is
///      narrower than "returns false": it returns a zeroed struct, which the rest of the library
///      then rejects on its own terms.
contract WebAuthnInputsTest is Test {

    /// @dev A point on the P256 curve, so the fuzz reaches the verification rather than stopping at
    ///      a key check. Taken from lib/p256-verifier/test-vectors/vectors_random_valid.jsonl.
    uint256 private constant VECTOR_X = 0x31a80482dadf89de6302b1988c82c29544c9c07bb910596158f6062517eb089a;
    uint256 private constant VECTOR_Y = 0x2f54c9a0f348752950094d3228d3b940258c75fe2a413cb70baa21dc2e352fc5;

    /// @dev What a real authenticator emits, and what the type field check expects to find at
    ///      typeIndex. Kept as the well formed starting point that the fuzz moves away from.
    string private constant REAL_CLIENT_DATA =
        '{"type":"webauthn.get","challenge":"K6NCsXHLc-ZKiEZ7s5aRkRIUe_8A9hvF7DQHod-hkqw","origin":"https://example.com"}';

    /// @dev What the decoder is measured against, defined at the bottom of this file.
    SolcDecodeProbe private probe;

    /// @notice Deploys the probe the decode tests measure against
    function setUp() public {
        probe = new SolcDecodeProbe();
    }

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

    /// @notice A well formed encoding comes back field for field
    /// @dev The direction that has to be exact. A decoder that rejected too much would pass every
    ///      test below this one and refuse every real signature.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_tryDecodeSignature_roundTripsAWellFormedEncoding(
        bytes calldata _authenticatorData,
        string calldata _clientDataJSON,
        uint256 _challengeIndex,
        uint256 _typeIndex,
        uint256 _r,
        uint256 _s
    ) public pure {
        WebAuthnSignature memory original = WebAuthnSignature({
            authenticatorData: _authenticatorData,
            clientDataJSON: _clientDataJSON,
            challengeIndex: _challengeIndex,
            typeIndex: _typeIndex,
            r: _r,
            s: _s
        });

        _assertSameSignature(WebAuthn.tryDecodeSignature(abi.encode(original)), original);
    }

    /// @notice Arbitrary bytes never revert, and agree with solc wherever solc reads them
    /// @dev Two assertions in one pass because the second needs the first to have held. Calling
    ///      tryDecodeSignature is itself the no-revert assertion, so reaching the probe at all
    ///      already proves it for this input.
    ///
    ///      Only the one direction is asserted. Where solc's decoder succeeds the fields must match
    ///      exactly, but where it reverts nothing is claimed, because these bounds are looser than
    ///      solc's: an offset that is not a multiple of 32 is refused there and accepted here. That
    ///      extra reach costs nothing, since a struct assembled from a strange offset still faces
    ///      the index bounds and the curve check further down.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_tryDecodeSignature_neverRevertsAndAgreesWithSolc(bytes calldata _encoded) public view {
        WebAuthnSignature memory decoded = WebAuthn.tryDecodeSignature(_encoded);

        try probe.decode(_encoded) returns (WebAuthnSignature memory expected) {
            _assertSameSignature(decoded, expected);
        } catch {
            // Nothing to compare against. The no-revert assertion already held above
        }
    }

    /// @notice One word of a real encoding overwritten still agrees with solc
    /// @dev The test above reaches solc's decoder and is turned away by it on nearly every run,
    ///      because random bytes almost never form a length prefix and two offsets that all point
    ///      somewhere plausible. Overwriting a single word of a valid encoding keeps the rest
    ///      readable, so the comparison runs instead of being skipped, and it lands on the words
    ///      that matter: either an offset, which is where a wrong bound shows up, or a field, which
    ///      is where a wrong copy does.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_tryDecodeSignature_agreesWithSolcOnAMutatedEncoding(
        bytes calldata _authenticatorData,
        string calldata _clientDataJSON,
        uint256 _wordIndex,
        bytes32 _replacement
    ) public view {
        bytes memory encoded = abi.encode(
            WebAuthnSignature({
                authenticatorData: _authenticatorData,
                clientDataJSON: _clientDataJSON,
                challengeIndex: 23,
                typeIndex: 1,
                r: 1,
                s: 1
            })
        );

        uint256 offset = bound(_wordIndex, 0, encoded.length / 32 - 1) * 32;
        for (uint256 i = 0; i < 32; ++i) {
            encoded[offset + i] = _replacement[i];
        }

        WebAuthnSignature memory decoded = WebAuthn.tryDecodeSignature(encoded);

        try probe.decode(encoded) returns (WebAuthnSignature memory expected) {
            _assertSameSignature(decoded, expected);
        } catch {
            // solc refused this mutation. Nothing is claimed about the looser bounds here
        }
    }

    /// @notice An encoding cut short of its own length never reverts
    /// @dev Random bytes almost never form a length prefix that points anywhere plausible, so the
    ///      test above rarely exercises the inner bounds. Truncating a real encoding lands on them
    ///      every run: the offsets still say where the members are and the bytes holding them are
    ///      gone.
    ///
    ///      The result is not asserted to be empty. Trailing padding is not covered by any declared
    ///      length, so cutting into it leaves an encoding these bounds still accept, and asserting
    ///      otherwise would pin behaviour that is neither promised nor needed.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_tryDecodeSignature_neverRevertsOnATruncatedEncoding(
        bytes calldata _authenticatorData,
        string calldata _clientDataJSON,
        uint256 _length
    ) public pure {
        bytes memory encoded = abi.encode(
            WebAuthnSignature({
                authenticatorData: _authenticatorData,
                clientDataJSON: _clientDataJSON,
                challengeIndex: 23,
                typeIndex: 1,
                r: 1,
                s: 1
            })
        );

        bytes memory truncated = new bytes(bound(_length, 0, encoded.length));
        for (uint256 i = 0; i < truncated.length; ++i) {
            truncated[i] = encoded[i];
        }

        WebAuthn.tryDecodeSignature(truncated);
    }

    /// @notice The shortest body the wallet's length guard lets through decodes to nothing
    /// @dev Thirty three bytes, which is what is left of a forty byte signature after the version
    ///      byte and the six validUntil bytes. It cannot hold the six word struct head, so it fails
    ///      the first bound. The empty clientDataJSON is what the rest of the library rejects on.
    function test_tryDecodeSignature_leavesAShortBodyEmpty() public pure {
        WebAuthnSignature memory decoded = WebAuthn.tryDecodeSignature(new bytes(33));

        assertEq(bytes(decoded.clientDataJSON).length, 0, "A body too short to decode must stay empty");
        assertEq(decoded.authenticatorData.length, 0, "A body too short to decode must stay empty");
        assertEq(decoded.r, 0, "A body too short to decode must stay empty");
        assertEq(decoded.s, 0, "A body too short to decode must stay empty");
    }

    /// @notice Compares two decoded signatures field for field
    /// @dev Held in a helper rather than inline. A run of six asserts in one test body is what the
    ///      Yul optimizer runs out of stack slots on.
    function _assertSameSignature(
        WebAuthnSignature memory _decoded,
        WebAuthnSignature memory _expected
    ) private pure {
        assertEq(_decoded.authenticatorData, _expected.authenticatorData, "authenticatorData differs");
        assertEq(_decoded.clientDataJSON, _expected.clientDataJSON, "clientDataJSON differs");
        assertEq(_decoded.challengeIndex, _expected.challengeIndex, "challengeIndex differs");
        assertEq(_decoded.typeIndex, _expected.typeIndex, "typeIndex differs");
        assertEq(_decoded.r, _expected.r, "r differs");
        assertEq(_decoded.s, _expected.s, "s differs");
    }
}

/// @notice Reaches solc's own decoder from somewhere a revert can be caught
/// @dev try/catch needs an external call, and abi.decode is not one. Kept beside the only file that
///      uses it rather than in the shared mocks, which hold contracts several suites share.
contract SolcDecodeProbe {

    /// @notice Decodes with solc's generated decoder, reverting on anything malformed
    function decode(bytes calldata _encoded) external pure returns (WebAuthnSignature memory) {
        return abi.decode(_encoded, (WebAuthnSignature));
    }
}
