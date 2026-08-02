// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {FuzzBase} from "test/foundry/fuzz-testing/base/FuzzBase.sol";

/// @notice The identifier lengths and array shapes the lazy registry accepts.
/// @dev Two guards sit on the same call and neither implies the other. Identifiers are bounded at
///      64 bytes because an unbounded one is written to storage and read back on every deploy, and
///      the parallel arrays must agree in length because they are indexed together in a loop.
///
///      The lengths are swept a little past the bound rather than into the kilobytes. The cap is
///      what makes the long case unreachable, so the interesting values sit either side of 64 and
///      nowhere near the calldata limits.
///
///      Nothing here reads a value the test itself wrote. Each assertion goes to the registry's own
///      view of what it stored, which is the copy a later deploy would act on.
contract IdentifiersAndArraysTest is FuzzBase {

    /// @dev Matches MAX_IDENTIFIER_LENGTH in LazyWalletRegistry, which is private there
    uint256 private constant MAX_IDENTIFIER_LENGTH = 64;

    /// @notice An identifier at or under the bound is accepted and stored intact
    /// @dev Boundary included: 64 is accepted, and the check is `>` rather than `>=`.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_populateHistory_acceptsIdentifiersInsideTheBound(
        uint256 _deviceLength,
        uint256 _eSIMLength
    ) public {
        uint256 deviceLength = bound(_deviceLength, 1, MAX_IDENTIFIER_LENGTH);
        uint256 eSIMLength = bound(_eSIMLength, 1, MAX_IDENTIFIER_LENGTH);

        string memory deviceIdentifier = _stringOfLength(deviceLength);
        string memory eSIMIdentifier = _stringOfLength(eSIMLength);

        _populateOne(deviceIdentifier, eSIMIdentifier, 1 ether);

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIMIdentifier),
            deviceIdentifier,
            "The registry must record the eSIM identifier against the device that claimed it"
        );

        string[] memory associated =
            lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(deviceIdentifier);
        assertEq(associated.length, 1, "The device must list exactly the one eSIM identifier");
        assertEq(associated[0], eSIMIdentifier, "The listed identifier must be the one supplied");
    }

    /// @notice A device identifier past the bound is refused, and nothing is written
    /// @dev The revert carries the identifier and the limit, so the caller can tell which of the
    ///      two it broke without guessing.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_populateHistory_refusesALongDeviceIdentifier(uint256 _length) public {
        uint256 length = bound(_length, MAX_IDENTIFIER_LENGTH + 1, MAX_FUZZED_IDENTIFIER_LENGTH);
        string memory deviceIdentifier = _stringOfLength(length);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.IdentifierTooLong.selector, deviceIdentifier, MAX_IDENTIFIER_LENGTH)
        );
        _populateOne(deviceIdentifier, "ESIM_FUZZ", 1 ether);

        assertEq(
            lazyWalletRegistry.getESIMIdentifiersAssociatedWithDeviceIdentifier(deviceIdentifier).length,
            0,
            "A refused call must leave the device identifier with no associations"
        );
    }

    /// @notice An eSIM identifier past the bound is refused by the same check
    /// @dev Worth its own case because the two identifiers reach the bound through different
    ///      arguments, and only one of them is checked before the loop starts.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_populateHistory_refusesALongESIMIdentifier(uint256 _length) public {
        uint256 length = bound(_length, MAX_IDENTIFIER_LENGTH + 1, MAX_FUZZED_IDENTIFIER_LENGTH);
        string memory eSIMIdentifier = _stringOfLength(length);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.IdentifierTooLong.selector, eSIMIdentifier, MAX_IDENTIFIER_LENGTH)
        );
        _populateOne("DEVICE_FUZZ", eSIMIdentifier, 1 ether);

        assertEq(
            lazyWalletRegistry.eSIMIdentifierToDeviceIdentifier(eSIMIdentifier),
            "",
            "A refused call must leave the eSIM identifier unbound"
        );
    }

    /// @notice An empty identifier is refused on both sides
    /// @dev Zero length is not the same case as too long. An empty device identifier would key
    ///      every unbound eSIM identifier to the same entry.
    function test_populateHistory_refusesEmptyIdentifiers() public {
        vm.expectRevert("Device identifier 0");
        _populateOne("", "ESIM_FUZZ", 1 ether);

        vm.expectRevert("eSIM identifier 0");
        _populateOne("DEVICE_FUZZ", "", 1 ether);
    }

    /// @notice The three top-level arrays must agree in length
    /// @dev They are indexed together in one loop, so a shorter one either reverts on the index or
    ///      silently pairs a device with another device's history, depending which is short.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_batchPopulateHistory_refusesUnequalArrays(
        uint256 _deviceCount,
        uint256 _eSIMCount,
        uint256 _detailCount
    ) public {
        uint256 deviceCount = bound(_deviceCount, 0, 5);
        uint256 eSIMCount = bound(_eSIMCount, 0, 5);
        uint256 detailCount = bound(_detailCount, 0, 5);
        vm.assume(deviceCount != eSIMCount || deviceCount != detailCount);

        string[] memory devices = new string[](deviceCount);
        for (uint256 i = 0; i < deviceCount; ++i) {
            devices[i] = _stringOfLength(i + 1);
        }

        string[][] memory eSIMs = new string[][](eSIMCount);
        for (uint256 i = 0; i < eSIMCount; ++i) {
            eSIMs[i] = new string[](1);
            eSIMs[i][0] = _stringOfLength(i + 2);
        }

        DataBundleDetails[][] memory details = new DataBundleDetails[][](detailCount);
        for (uint256 i = 0; i < detailCount; ++i) {
            details[i] = new DataBundleDetails[](1);
            details[i][0] = DataBundleDetails("DB_FUZZ", 1 ether);
        }

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert("Unequal array provided");
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, details);
    }

    /// @notice The inner arrays must agree too, per device
    /// @dev The outer lengths matching says nothing about the inner ones, and the inner pair is
    ///      what the purchase loop indexes.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_batchPopulateHistory_refusesUnequalInnerArrays(
        uint256 _eSIMCount,
        uint256 _detailCount
    ) public {
        uint256 eSIMCount = bound(_eSIMCount, 0, 5);
        uint256 detailCount = bound(_detailCount, 0, 5);
        vm.assume(eSIMCount != detailCount);

        string[] memory devices = new string[](1);
        devices[0] = "DEVICE_FUZZ";

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](eSIMCount);
        for (uint256 i = 0; i < eSIMCount; ++i) {
            eSIMs[0][i] = _stringOfLength(i + 2);
        }

        DataBundleDetails[][] memory details = new DataBundleDetails[][](1);
        details[0] = new DataBundleDetails[](detailCount);
        for (uint256 i = 0; i < detailCount; ++i) {
            details[0][i] = DataBundleDetails("DB_FUZZ", 1 ether);
        }

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert("Unequal array provided");
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, details);
    }

    /// @notice An empty batch is accepted and changes nothing
    /// @dev The loop runs zero times rather than the call being rejected. Worth pinning because a
    ///      guard added against empty input would break a batch job that legitimately has nothing
    ///      to send this round.
    function test_batchPopulateHistory_acceptsAnEmptyBatch() public {
        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(
            new string[](0),
            new string[][](0),
            new DataBundleDetails[][](0)
        );
    }

    /// @notice Sends one device, one eSIM identifier and one purchase through the batch entry point
    function _populateOne(
        string memory _deviceIdentifier,
        string memory _eSIMIdentifier,
        uint256 _price
    ) private {
        string[] memory devices = new string[](1);
        devices[0] = _deviceIdentifier;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](1);
        eSIMs[0][0] = _eSIMIdentifier;

        DataBundleDetails[][] memory details = new DataBundleDetails[][](1);
        details[0] = new DataBundleDetails[](1);
        details[0][0] = DataBundleDetails("DB_FUZZ", _price);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, details);
    }
}
