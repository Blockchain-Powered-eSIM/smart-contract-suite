// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {FCL_ecdsa} from "FreshCryptoLib/FCL_ecdsa.sol";

/// @notice Holds the RIP-7212 precompile and FreshCryptoLib to the same verdict over random input.
/// @dev WebAuthn.verifySignature tries the precompile first and falls back to the library without
///      recording which one answered. The protocol deploys to chains that differ on whether the
///      precompile exists, so the two paths disagreeing means a signature accepted on one chain is
///      refused on another, for the same wallet and the same owner key. There is no version of that
///      which is acceptable, which is why a single disagreement fails this file.
///
///      The two are asked directly rather than through verifySignature, because that function picks
///      one and returns a single answer. Asking both and comparing is the only way to see a split.
///
///      Not a fork test, for the reason recorded in the unit test alongside it: Foundry's own EVM
///      carries the precompile at evm_version = "osaka", so a fork answers out of the local EVM and
///      would pass identically against a chain with no RIP-7212 at all.
contract P256DifferentialTest is Test {

    /// @dev RIP-7212 precompile.
    address private constant VERIFIER = address(0x100);

    /// @dev Order of the P256 curve. r and s are only meaningful in [1, n-1], and both verifiers
    ///      are entitled to reject anything outside it, so the fuzz stays inside.
    uint256 private constant N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

    /// @dev A known-good vector, first entry of lib/p256-verifier/test-vectors/vectors_random_valid.jsonl
    bytes32 private constant VECTOR_HASH = 0x3fec5769b5cf4e310a7d150508e82fb8e3eda1c2c94c61492d3bd8aea99e06c9;
    uint256 private constant VECTOR_R = 0xe22466e928fdccef0de49e3503d2657d00494a00e764fd437bdafa05f5922b1f;
    uint256 private constant VECTOR_S = 0xbbb77c6817ccf50748419477e843d5bac67e6a70e97dde5a57e0c983b777e1ad;
    uint256 private constant VECTOR_X = 0x31a80482dadf89de6302b1988c82c29544c9c07bb910596158f6062517eb089a;
    uint256 private constant VECTOR_Y = 0x2f54c9a0f348752950094d3228d3b940258c75fe2a413cb70baa21dc2e352fc5;

    /// @notice Confirms something is actually at the precompile address before anything is compared
    /// @dev Without this the differential is vacuous: with no precompile every call returns empty,
    ///      which reads as "did not answer", and the file would pass while comparing nothing.
    function test_precompileIsPresent() public view {
        (bool answered, bool verdict) = _askThePrecompile(VECTOR_HASH, VECTOR_R, VECTOR_S, VECTOR_X, VECTOR_Y);

        assertTrue(answered, "Nothing answered at the precompile address");
        assertTrue(verdict, "The precompile must accept a known-good vector");
    }

    /// @notice Asks the precompile, the way WebAuthn.sol does
    /// @return answered True when something at the address returned a word. A rejecting precompile
    ///         returns empty rather than a zero word, so this is false for a rejection too
    /// @return verdict The verdict returned, meaningful only when answered
    function _askThePrecompile(
        bytes32 _hash,
        uint256 _r,
        uint256 _s,
        uint256 _x,
        uint256 _y
    ) internal view returns (bool answered, bool verdict) {
        (bool success, bytes memory ret) = VERIFIER.staticcall(abi.encode(_hash, _r, _s, _x, _y));

        answered = success && ret.length > 0;
        verdict = answered && abi.decode(ret, (uint256)) == 1;
    }

    /// @notice The two paths never disagree on random signatures against a real public key
    /// @dev Every one of these is a rejection, since forging a valid signature by fuzzing is not
    ///      possible. That is the case worth the runs: an accepting fallback where the precompile
    ///      rejects is the shape of the bug, and it can only come from a malformed input one path
    ///      handles and the other does not.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_bothPathsAgreeOnRandomSignatures(bytes32 _hash, uint256 _r, uint256 _s) public view {
        uint256 r = bound(_r, 1, N - 1);
        uint256 s = bound(_s, 1, N - 1);

        (bool answered, bool precompileVerdict) = _askThePrecompile(_hash, r, s, VECTOR_X, VECTOR_Y);
        bool fallbackVerdict = FCL_ecdsa.ecdsa_verify(_hash, r, s, VECTOR_X, VECTOR_Y);

        // An unanswered call is a rejection, which is what WebAuthn.sol reads it as
        assertEq(
            answered && precompileVerdict,
            fallbackVerdict,
            "The precompile and the fallback reached different verdicts"
        );
    }

    /// @notice The agreement survives a random public key as well as a random signature
    /// @dev A point off the curve is the input most likely to split them, since one may bounds check
    ///      where the other computes. Bounding x and y to the field would hide exactly that, so they
    ///      are left as the full word.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_bothPathsAgreeOnRandomPublicKeys(
        bytes32 _hash,
        uint256 _r,
        uint256 _s,
        uint256 _x,
        uint256 _y
    ) public view {
        uint256 r = bound(_r, 1, N - 1);
        uint256 s = bound(_s, 1, N - 1);

        (bool answered, bool precompileVerdict) = _askThePrecompile(_hash, r, s, _x, _y);
        bool fallbackVerdict = FCL_ecdsa.ecdsa_verify(_hash, r, s, _x, _y);

        assertEq(
            answered && precompileVerdict,
            fallbackVerdict,
            "The precompile and the fallback reached different verdicts on this public key"
        );
    }

    /// @notice Corrupting one component of a valid signature is rejected by both
    /// @dev Starts from a signature both accept and moves one field, so each verifier reaches its
    ///      own rejection rather than tripping a bounds check and agreeing by accident.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_bothPathsRejectACorruptedValidSignature(uint256 _delta) public view {
        uint256 delta = bound(_delta, 1, N - 1);
        uint256 corruptedR = addmod(VECTOR_R, delta, N);

        (bool answered, bool precompileVerdict) =
            _askThePrecompile(VECTOR_HASH, corruptedR, VECTOR_S, VECTOR_X, VECTOR_Y);
        bool fallbackVerdict = FCL_ecdsa.ecdsa_verify(VECTOR_HASH, corruptedR, VECTOR_S, VECTOR_X, VECTOR_Y);

        assertFalse(answered && precompileVerdict, "The precompile accepted a corrupted signature");
        assertFalse(fallbackVerdict, "The fallback accepted a corrupted signature");
    }
}
