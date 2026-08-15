// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {SIG_VALIDATION_FAILED} from "@account-abstraction/contracts/core/Helpers.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import "contracts/CustomStructs.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";

/// @notice What the two signature entry points do with bytes that are not a signature.
/// @dev Both read a one byte version and six validUntil bytes off the front, check the version, and
///      hand the rest to abi.decode. A caller controls every one of those bytes, so this sweeps
///      lengths across the guard boundary and versions across the whole byte.
///
///      The two entry points answer in different alphabets and the difference is deliberate.
///      isValidSignature returns a bytes4 an integrator compares against the magic value.
///      validateUserOp returns packed validationData whose low 160 bits the EntryPoint reads as an
///      authorizer address, so 0xffffffff there would name an aggregator that does not exist and
///      revert the whole bundle rather than failing one operation.
///
///      A body that gets past the version check reaches the decoder, which bounds-checks the
///      encoding and hands back a zeroed struct rather than reverting when any bound fails. So
///      every assertion below is strict: neither entry point ever accepts, and neither ever
///      answers by reverting.
contract SignatureShapeTest is FuzzBase {

    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 private constant ERC1271_REJECTED = 0xffffffff;

    function setUp() public override {
        super.setUp();
        _deployFuzzWallets();
    }

    /// @notice Any signature at or inside the guard length is refused without being decoded
    /// @dev The boundary is `length <= 39`. Nothing here reaches abi.decode, so the assertion can
    ///      be strict: the answer is always a clean rejection.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_isValidSignature_shortSignaturesAreRefused(
        bytes32 _messageHash,
        bytes calldata _noise,
        uint256 _length
    ) public view {
        uint256 length = bound(_length, 0, SHORTEST_DECODED_SIGNATURE - 1);
        vm.assume(_noise.length >= length);

        assertEq(
            fuzzDeviceWallet.isValidSignature(_messageHash, _noise[:length]),
            ERC1271_REJECTED,
            "A signature inside the guard must be refused"
        );
    }

    /// @notice Random bytes past the guard are never accepted as a signature
    /// @dev Accepting would mean random input forged an assertion against the owner key, which is
    ///      the only outcome that matters here. Answering at all is the second thing this asserts:
    ///      a body too malformed to decode comes back as a rejection, so the assertion is strict
    ///      rather than tolerating a revert.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_isValidSignature_neverAcceptsRandomBytes(
        bytes32 _messageHash,
        bytes calldata _body
    ) public view {
        vm.assume(_body.length >= 33);
        bytes memory signature = abi.encodePacked(uint8(1), uint48(type(uint48).max), _body);

        assertEq(
            fuzzDeviceWallet.isValidSignature(_messageHash, signature),
            ERC1271_REJECTED,
            "Random bytes must never be accepted as a signature"
        );
    }

    /// @notice Only version 1 is defined, and every other version is refused rather than decoded
    /// @dev The version check sits ahead of the decode, so an undefined version never reaches it
    ///      and the assertion can be strict. This is what stops an undefined version reading a
    ///      length prefix out of bytes that were never laid out that way.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_isValidSignature_unknownVersionsAreRefused(
        bytes32 _messageHash,
        uint8 _version,
        uint48 _validUntil,
        bytes calldata _body
    ) public view {
        vm.assume(_version != 1);
        vm.assume(_body.length >= 33);

        assertEq(
            fuzzDeviceWallet.isValidSignature(_messageHash, abi.encodePacked(_version, _validUntil, _body)),
            ERC1271_REJECTED,
            "A signature carrying an undefined version must be refused"
        );
    }

    /// @notice An expired signature is refused whatever its body holds
    /// @dev validUntil is read from the header and checked against the clock ahead of the decode,
    ///      so this holds strictly without the body being well formed.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_isValidSignature_expiredSignaturesAreRefused(
        bytes32 _messageHash,
        uint48 _validUntil,
        bytes calldata _body
    ) public view {
        uint48 validUntil = uint48(bound(_validUntil, 0, block.timestamp - 1));
        vm.assume(_body.length >= 33);

        assertEq(
            fuzzDeviceWallet.isValidSignature(_messageHash, abi.encodePacked(uint8(1), validUntil, _body)),
            ERC1271_REJECTED,
            "A signature past its expiry must be refused"
        );
    }

    /// @notice The userOp path answers with SIG_VALIDATION_FAILED and never with a bytes4
    /// @dev The value matters as much as the rejection. Anything whose low 160 bits are neither 0
    ///      nor 1 names an aggregator contract to the EntryPoint, and a bundle carrying one reverts
    ///      whole instead of dropping the operation that failed.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_validateUserOp_shortSignaturesFailTheOperationOnly(
        bytes32 _userOpHash,
        bytes calldata _noise,
        uint256 _length
    ) public {
        uint256 length = bound(_length, 0, SHORTEST_DECODED_SIGNATURE - 1);
        vm.assume(_noise.length >= length);

        PackedUserOperation memory userOp;
        userOp.sender = address(fuzzDeviceWallet);
        userOp.signature = _noise[:length];

        vm.prank(address(entryPoint));
        uint256 validationData = fuzzDeviceWallet.validateUserOp(userOp, _userOpHash, 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "A short signature must fail the operation");
        assertEq(
            validationData >> 160,
            0,
            "A failure must carry no validity window, or the EntryPoint reads a time range"
        );
    }

    /// @notice The userOp path refuses undefined versions the same way
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_validateUserOp_unknownVersionsFailTheOperation(
        bytes32 _userOpHash,
        uint8 _version,
        uint48 _validUntil,
        bytes calldata _body
    ) public {
        vm.assume(_version != 1);
        vm.assume(_body.length >= 33);

        PackedUserOperation memory userOp;
        userOp.sender = address(fuzzDeviceWallet);
        userOp.signature = abi.encodePacked(_version, _validUntil, _body);

        vm.prank(address(entryPoint));
        uint256 validationData = fuzzDeviceWallet.validateUserOp(userOp, _userOpHash, 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "An undefined version must fail the operation");
    }

    /// @notice Random bytes past the guard are never validated as a userOp signature
    /// @dev Same shape as the ERC-1271 case, and strict for the same reason, but the value it has
    ///      to come back with is different. Reverting here would take out the whole bundle.
    /// forge-config: default.fuzz.runs = 5000
    function testFuzz_validateUserOp_neverAcceptsRandomBytes(
        bytes32 _userOpHash,
        bytes calldata _body
    ) public {
        vm.assume(_body.length >= 33);

        PackedUserOperation memory userOp;
        userOp.sender = address(fuzzDeviceWallet);
        userOp.signature = abi.encodePacked(uint8(1), uint48(type(uint48).max), _body);

        vm.prank(address(entryPoint));
        uint256 validationData = fuzzDeviceWallet.validateUserOp(userOp, _userOpHash, 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "Random bytes must never validate a userOp");
    }

    /// @notice A body that is not an encoded WebAuthnSignature is rejected rather than reverted on
    /// @dev Forty bytes is the shortest signature the length guard lets through: one version byte,
    ///      six validUntil bytes and thirty three that reach the decoder. Thirty three bytes cannot
    ///      hold the six word struct head, so the decoder fails its first bound and hands back a
    ///      zeroed struct, which verifySignature rejects because an empty clientDataJSON cannot
    ///      contain the index it is handed.
    function test_isValidSignature_rejectsAMalformedBody() public view {
        bytes memory signature = abi.encodePacked(uint8(1), uint48(type(uint48).max), new bytes(33));
        assertEq(signature.length, SHORTEST_DECODED_SIGNATURE, "The guard must let this length through");

        assertEq(
            fuzzDeviceWallet.isValidSignature(keccak256("a message"), signature),
            ERC1271_REJECTED,
            "A malformed body must be refused rather than reverted on"
        );
    }

    /// @notice The same body fails one operation inside validateUserOp
    /// @dev Worth pinning apart from the ERC-1271 case because the consequence differs. A revert
    ///      here reaches the EntryPoint rather than an integrating contract, and the comment at the
    ///      length guard reasons specifically about not failing a whole bundle.
    function test_validateUserOp_rejectsAMalformedBody() public {
        PackedUserOperation memory userOp;
        userOp.sender = address(fuzzDeviceWallet);
        userOp.signature = abi.encodePacked(uint8(1), uint48(type(uint48).max), new bytes(33));

        vm.prank(address(entryPoint));
        uint256 validationData = fuzzDeviceWallet.validateUserOp(userOp, keccak256("a userOp"), 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "A malformed body must fail the operation only");
    }
}
