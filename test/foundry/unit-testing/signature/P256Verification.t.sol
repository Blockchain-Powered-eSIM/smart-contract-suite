// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {FCL_ecdsa} from "FreshCryptoLib/FCL_ecdsa.sol";

import {WebAuthn} from "contracts/WebAuthn.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";
import "contracts/CustomStructs.sol";

/// @notice Holds the two P256 verification paths to the same answer, and records what choosing the
///         wrong one costs.
/// @dev `WebAuthn.verifySignature` staticcalls the RIP-7212 precompile and falls back to
///      FreshCryptoLib without telling anyone which one answered. Two things follow. If the two
///      ever disagree, a signature the protocol accepts on one chain is refused on another. And
///      the fallback costs enough more that a `verificationGasLimit` sized for the precompile
///      cannot cover it, which strands every operation on a chain without RIP-7212.
///
///      These are deliberately not fork tests. Verification reads no chain state, and Foundry's own
///      EVM carries the precompile at `evm_version = "osaka"`, so a fork answers out of the local
///      EVM and would pass identically against a chain that has no RIP-7212 at all. Whether a
///      target chain really carries it has to be measured against the live RPC before deploying,
///      not asserted here.
contract P256VerificationTest is Test {

    /// @dev RIP-7212 precompile. A precompile holds no bytecode, so `cast code` on this address
    ///      returns empty whether or not it is there. Calling it with a known-good vector is the
    ///      only check that distinguishes the two.
    address private constant VERIFIER = address(0x100);

    /// @dev First entry of `lib/p256-verifier/test-vectors/vectors_random_valid.jsonl`. Its `s` sits
    ///      above n/2, which neither path here rejects: the malleability guard is in
    ///      `verifySignature` at `WebAuthn.sol:114`, above the branch under test.
    bytes32 private constant VECTOR_HASH = 0x3fec5769b5cf4e310a7d150508e82fb8e3eda1c2c94c61492d3bd8aea99e06c9;
    uint256 private constant VECTOR_R = 0xe22466e928fdccef0de49e3503d2657d00494a00e764fd437bdafa05f5922b1f;
    uint256 private constant VECTOR_S = 0xbbb77c6817ccf50748419477e843d5bac67e6a70e97dde5a57e0c983b777e1ad;
    uint256 private constant VECTOR_X = 0x31a80482dadf89de6302b1988c82c29544c9c07bb910596158f6062517eb089a;
    uint256 private constant VECTOR_Y = 0x2f54c9a0f348752950094d3228d3b940258c75fe2a413cb70baa21dc2e352fc5;

    /// @notice Asks the precompile the way `WebAuthn.sol:220` does.
    /// @param _r The r value to ask about
    /// @param _s The s value to ask about
    /// @return answered True when something at the address returned a word, false when the call
    ///         fell through an empty account
    /// @return verdict The verdict it returned, meaningful only when `answered`
    /// @return gasUsed Gas the call consumed
    function _askThePrecompile(uint256 _r, uint256 _s)
        internal
        view
        returns (bool answered, bool verdict, uint256 gasUsed)
    {
        bytes memory args = abi.encode(VECTOR_HASH, _r, _s, VECTOR_X, VECTOR_Y);

        uint256 gasBefore = gasleft();
        (bool success, bytes memory ret) = VERIFIER.staticcall(args);
        gasUsed = gasBefore - gasleft();

        answered = success && ret.length > 0;
        verdict = answered && abi.decode(ret, (uint256)) == 1;
    }

    /// @notice Asks FreshCryptoLib the same question, the way `WebAuthn.sol:231` does.
    /// @param _r The r value to ask about
    /// @param _s The s value to ask about
    /// @return verdict Whether the library accepts the signature
    /// @return gasUsed Gas the call consumed
    function _askTheFallback(uint256 _r, uint256 _s) internal view returns (bool verdict, uint256 gasUsed) {
        uint256 gasBefore = gasleft();
        verdict = FCL_ecdsa.ecdsa_verify(VECTOR_HASH, _r, _s, VECTOR_X, VECTOR_Y);
        gasUsed = gasBefore - gasleft();
    }

    /// @notice Both verifiers accept the same valid signature.
    function test_verify_bothPathsAcceptAValidSignature() public view {
        (bool answered, bool precompileVerdict,) = _askThePrecompile(VECTOR_R, VECTOR_S);
        (bool fallbackVerdict,) = _askTheFallback(VECTOR_R, VECTOR_S);

        assertTrue(answered, "The precompile must answer for the comparison to mean anything");
        assertTrue(precompileVerdict, "The precompile must accept a known-good vector");
        assertEq(precompileVerdict, fallbackVerdict, "Both paths must reach the same verdict");
    }

    /// @notice Both verifiers reject the same corrupted signature.
    /// @dev Flipping the low bit of r leaves it well formed and inside the field, so each verifier
    ///      reaches its own rejection rather than tripping an early bounds check and agreeing by
    ///      accident.
    function test_verify_bothPathsRejectACorruptedSignature() public view {
        uint256 corruptedR = VECTOR_R ^ 1;

        (bool answered, bool precompileVerdict,) = _askThePrecompile(corruptedR, VECTOR_S);
        (bool fallbackVerdict,) = _askTheFallback(corruptedR, VECTOR_S);

        assertFalse(precompileVerdict, "The precompile must reject a corrupted signature");
        assertFalse(fallbackVerdict, "The fallback must reject a corrupted signature");
        // A rejecting precompile returns empty rather than a zero word, which is the case
        // WebAuthn.sol:226 reads as "did not answer" and sends on to the fallback
        assertFalse(answered, "A rejected signature must fall through to the fallback");
    }

    /// @notice The fallback is the expensive branch, by enough that one gas budget cannot cover
    /// both.
    /// @dev This is the number `verificationGasLimit` has to respect. The bound is loose on
    ///      purpose: it exists to catch the two paths converging, which would mean the precompile
    ///      is not being reached at all, rather than to pin a figure that moves with the compiler.
    function test_verify_theFallbackCostsFarMoreThanThePrecompile() public view {
        (bool answered,, uint256 precompileGas) = _askThePrecompile(VECTOR_R, VECTOR_S);
        (, uint256 fallbackGas) = _askTheFallback(VECTOR_R, VECTOR_S);

        assertTrue(answered, "The precompile must answer for the comparison to mean anything");

        console.log("RIP-7212 precompile gas:", precompileGas);
        console.log("FreshCryptoLib fallback gas:", fallbackGas);

        assertGt(fallbackGas, precompileGas * 10, "The fallback must be the materially costlier path");
    }

    /// @notice A real WebAuthn assertion verifies through the full library, precompile branch
    /// included.
    /// @dev The two paths above are asked in isolation. This one goes through `verifySignature`,
    ///      so it covers the branch selection at `WebAuthn.sol:227-231` rather than the verifiers
    ///      underneath it.
    function test_verifySignature_acceptsARealAssertion() public {
        bytes memory challenge = abi.encodePacked(keccak256("p256 verification"));

        bytes32[2] memory key = WebAuthnSigner.publicKey();
        WebAuthnSignature memory assertion = abi.decode(WebAuthnSigner.sign(challenge), (WebAuthnSignature));

        assertTrue(
            WebAuthn.verifySignature(challenge, false, assertion, uint256(key[0]), uint256(key[1])),
            "A real assertion must verify"
        );
    }

    /// @notice The same assertion fails against a challenge it was not made for.
    /// @dev The challenge is inside the `clientDataJSON` the P256 signature covers, so this is what
    ///      says the library reads the challenge it was handed rather than the one in the payload.
    function test_verifySignature_rejectsAnAssertionMadeForAnotherChallenge() public {
        bytes memory challenge = abi.encodePacked(keccak256("p256 verification"));
        bytes memory otherChallenge = abi.encodePacked(keccak256("a different challenge"));

        bytes32[2] memory key = WebAuthnSigner.publicKey();
        WebAuthnSignature memory assertion = abi.decode(WebAuthnSigner.sign(challenge), (WebAuthnSignature));

        assertFalse(
            WebAuthn.verifySignature(otherChallenge, false, assertion, uint256(key[0]), uint256(key[1])),
            "An assertion must not verify against a challenge it does not carry"
        );
    }
}
