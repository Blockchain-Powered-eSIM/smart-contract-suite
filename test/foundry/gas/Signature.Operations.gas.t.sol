// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Base64 as SoladyBase64} from "solady/utils/Base64.sol";
import {FCL_ecdsa} from "FreshCryptoLib/FCL_ecdsa.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import "contracts/CustomStructs.sol";

import {GasBase} from "test/foundry/gas/base/GasBase.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";

/// @notice Gas for signature verification and for the validation an ERC-4337 bundler pays.
/// @dev `WebAuthn.verifySignature` asks the RIP-7212 precompile first and falls back to
///      FreshCryptoLib without saying which one answered, so the same signature costs one thing on a
///      chain that carries the precompile and something else entirely on one that does not. That
///      spread is what `verificationGasLimit` has to cover, and a budget sized for the precompile
///      strands every operation on a chain without it.
///
///      Both isolated figures are measured against the same known-good vector so they are directly
///      comparable. Foundry's own EVM carries the precompile at `evm_version = "osaka"`, so the
///      precompile figure here is the local EVM's, not any particular chain's.
contract SignatureOperationsGasTest is GasBase {

    string internal NAMESPACE = "Signature.Operations";

    /// @dev RIP-7212 precompile, the address `WebAuthn.sol:220` staticcalls.
    address private constant VERIFIER = address(0x100);

    /// @dev First entry of `lib/p256-verifier/test-vectors/vectors_random_valid.jsonl`.
    bytes32 private constant VECTOR_HASH = 0x3fec5769b5cf4e310a7d150508e82fb8e3eda1c2c94c61492d3bd8aea99e06c9;
    uint256 private constant VECTOR_R = 0xe22466e928fdccef0de49e3503d2657d00494a00e764fd437bdafa05f5922b1f;
    uint256 private constant VECTOR_S = 0xbbb77c6817ccf50748419477e843d5bac67e6a70e97dde5a57e0c983b777e1ad;
    uint256 private constant VECTOR_X = 0x31a80482dadf89de6302b1988c82c29544c9c07bb910596158f6062517eb089a;
    uint256 private constant VECTOR_Y = 0x2f54c9a0f348752950094d3228d3b940258c75fe2a413cb70baa21dc2e352fc5;

    /// @dev Order of the P256 curve. The vector's own `s` sits above n/2, which the malleability
    ///      guard at `WebAuthn.sol:114` rejects before either verifier is reached, so the fallback
    ///      measurement uses its twin below the halfway point instead.
    uint256 private constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    uint256 private constant LOW_S = P256_N - VECTOR_S;

    /// @dev A fixed challenge, so the clientDataJSON the fallback measurement verifies against never
    ///      changes between runs.
    bytes private constant FIXED_CHALLENGE =
        hex"2ba342b171cb73e64a88467bb396919112147bff00f61bc5ec3407a1dfa192ac";

    /// @notice Each verifier on its own, against the same vector
    /// @dev The precompile is a call, so it is measured as one. FreshCryptoLib is an internal
    ///      library call that gets inlined, so it needs an explicit span instead.
    function test_p256Verify_bothPaths() public {
        bytes memory args = abi.encode(VECTOR_HASH, VECTOR_R, VECTOR_S, VECTOR_X, VECTOR_Y);

        (bool success,) = VERIFIER.staticcall(args);
        vm.snapshotGasLastCall(NAMESPACE, "p256 verify: RIP-7212 precompile alone");
        require(success, "the precompile must answer for this figure to mean anything");

        vm.startSnapshotGas(NAMESPACE, "p256 verify: FreshCryptoLib alone");
        FCL_ecdsa.ecdsa_verify(VECTOR_HASH, VECTOR_R, VECTOR_S, VECTOR_X, VECTOR_Y);
        vm.stopSnapshotGas();
    }

    /// @notice The whole library, on the branch the precompile answers
    function test_verifySignature_precompileBranch() public {
        bytes memory challenge = abi.encodePacked(keccak256("gas: precompile branch"));

        bytes32[2] memory key = WebAuthnSigner.publicKey();
        WebAuthnSignature memory assertion = abi.decode(WebAuthnSigner.sign(challenge), (WebAuthnSignature));

        p256Verifier.verifySignature(challenge, false, assertion, uint256(key[0]), uint256(key[1]));
        vm.snapshotGasLastCall(NAMESPACE, "verifySignature: real assertion, precompile answers");
    }

    /// @notice The whole library, on the branch FreshCryptoLib answers
    /// @dev The signature is well formed and inside the field but does not match, so every
    ///      clientData check passes, the precompile is reached and returns empty, and empty is what
    ///      `WebAuthn.sol:226` reads as "did not answer". The call then runs the full fallback,
    ///      which is the same path a chain without RIP-7212 takes for a signature that is valid.
    ///
    ///      Every input here is fixed rather than signed offchain. FreshCryptoLib's cost moves with
    ///      the scalar, so asking the harness for a fresh assertion made this figure drift by around
    ///      a thousand gas per run and turned the whole file into a flapping baseline.
    function test_verifySignature_fallbackBranch() public {
        string memory encodedChallenge = SoladyBase64.encode(FIXED_CHALLENGE, true, true);
        bytes memory authenticatorData = new bytes(37);
        authenticatorData[32] = 0x05;

        WebAuthnSignature memory assertion = WebAuthnSignature({
            authenticatorData: authenticatorData,
            clientDataJSON: string.concat(
                '{"type":"webauthn.get","challenge":"',
                encodedChallenge,
                '","origin":"https://kokio.example"}'
            ),
            challengeIndex: 23,
            typeIndex: 1,
            r: VECTOR_R,
            s: LOW_S
        });

        p256Verifier.verifySignature(FIXED_CHALLENGE, false, assertion, VECTOR_X, VECTOR_Y);
        vm.snapshotGasLastCall(NAMESPACE, "verifySignature: falls through to FreshCryptoLib");
    }

    /// @notice What a bundler pays to validate one operation
    /// @dev Measured from the entry point directly rather than through `handleOps`, so this is the
    ///      wallet's own validation cost with none of the entry point's accounting on top. It is the
    ///      figure `verificationGasLimit` is sized against.
    function test_validateUserOp() public {
        MockDeviceWallet wallet = _deployWalletOwnedByTheSigner();

        PackedUserOperation memory op;
        op.sender = address(wallet);
        op.nonce = 1;

        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        op.signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(_userOpChallenge(validUntil, userOpHash))
        );

        vm.prank(address(entryPoint));
        wallet.validateUserOp(op, userOpHash, 0);
        vm.snapshotGasLastCall(NAMESPACE, "validateUserOp: valid assertion");
    }

    /// @notice Deploys a wallet owned by the offchain signing harness
    function _deployWalletOwnedByTheSigner() internal returns (MockDeviceWallet) {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = "Device_Gas_UserOp";
        keys[0] = WebAuthnSigner.publicKey();
        salts[0] = 8700;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        );

        return MockDeviceWallet(payable(wallets[0].deviceWallet));
    }

    /// @notice The challenge a wallet expects for a user operation
    /// @dev No chain id and no wallet address, because the operation hash already carries both.
    function _userOpChallenge(uint48 _validUntil, bytes32 _userOpHash) internal pure returns (bytes memory) {
        return abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n39",
                    uint8(1),
                    _validUntil,
                    _userOpHash
                )
            )
        );
    }
}
