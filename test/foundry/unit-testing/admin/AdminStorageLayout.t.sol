// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "test/utils/AdminBase.sol";

/// @notice Pins every slot this contract and its bases occupy.
/// @dev The admin contract is not upgradeable, so nothing here is about surviving an upgrade. It is
///      about the one variable this contract adds landing clear of the two the timelock already
///      keeps. A collision between the released flag and the operation timestamps would make an
///      operation read ready because an unrelated one was released, which no functional test would
///      notice while the layout happened to be right.
///
///      It also pins the base layout, so an OpenZeppelin bump that reorders `AccessControl` or
///      `TimelockController` shows up here rather than at deployment.
///
///      Each check writes a sentinel into a slot and reads it back through the getter compiled
///      against the current layout. Agreement means the variable still resolves where it was
///      written.
contract AdminStorageLayoutTest is AdminBase {

    uint256 private constant ROLES_SLOT = 0;
    uint256 private constant TIMESTAMPS_SLOT = 1;
    uint256 private constant MIN_DELAY_SLOT = 2;
    uint256 private constant RELEASED_SLOT = 3;

    bytes32 private constant OPERATION = keccak256("some operation");

    /// @notice Slot holding `_key`'s entry in the mapping declared at `_slot`
    function _entry(bytes32 _key, uint256 _slot) private pure returns (bytes32) {
        return keccak256(abi.encode(_key, _slot));
    }

    /// @dev `RoleData` puts its member mapping first, so the account entry hangs off the role entry.
    function _roleMember(bytes32 _role, address _account) private pure returns (bytes32) {
        return keccak256(abi.encode(_account, _entry(_role, ROLES_SLOT)));
    }

    function test_layout_accessControlRolesReadSlotZero() public {
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        assertFalse(protocolAdmin.hasRole(role, outsider));

        vm.store(address(protocolAdmin), _roleMember(role, outsider), bytes32(uint256(1)));

        assertTrue(protocolAdmin.hasRole(role, outsider), "AccessControl._roles must read slot 0");
    }

    function test_layout_operationTimestampsReadSlotOne() public {
        uint256 readyAt = block.timestamp + 1 days;

        vm.store(address(protocolAdmin), _entry(OPERATION, TIMESTAMPS_SLOT), bytes32(readyAt));

        assertEq(
            protocolAdmin.getTimestamp(OPERATION),
            readyAt,
            "TimelockController._timestamps must read slot 1"
        );
    }

    function test_layout_minDelayReadsSlotTwo() public {
        vm.store(address(protocolAdmin), bytes32(MIN_DELAY_SLOT), bytes32(uint256(9 days)));

        assertEq(protocolAdmin.getMinDelay(), 9 days, "TimelockController._minDelay must read slot 2");
    }

    function test_layout_releasedFlagReadsSlotThree() public {
        assertFalse(protocolAdmin.isReleased(OPERATION));

        vm.store(address(protocolAdmin), _entry(OPERATION, RELEASED_SLOT), bytes32(uint256(1)));

        assertTrue(protocolAdmin.isReleased(OPERATION), "the released flag must read slot 3");
    }

    /// @dev The check the whole file exists for. Both mappings are keyed by operation id, so if
    ///      they shared a slot every scheduled operation would also read as released.
    function test_layout_releasedFlagDoesNotCollideWithTheTimestamps() public {
        vm.store(address(protocolAdmin), _entry(OPERATION, TIMESTAMPS_SLOT), bytes32(uint256(block.timestamp + 1 days)));

        assertFalse(
            protocolAdmin.isReleased(OPERATION),
            "a scheduled operation must not read as released"
        );

        bytes32 other = keccak256("another operation");
        vm.store(address(protocolAdmin), _entry(other, RELEASED_SLOT), bytes32(uint256(1)));

        assertEq(protocolAdmin.getTimestamp(other), 0, "a released flag must not read as a timestamp");
    }

    /// @dev A released operation reads ready through `getOperationState` and keeps its real value
    ///      in `getTimestamp`. The two views disagree on purpose and this is what that looks like.
    function test_layout_aReleasedOperationReadsReadyWithoutATimestamp() public {
        vm.store(address(protocolAdmin), _entry(OPERATION, RELEASED_SLOT), bytes32(uint256(1)));

        assertTrue(protocolAdmin.isOperationReady(OPERATION));
        assertEq(protocolAdmin.getTimestamp(OPERATION), 0);
    }

    /// @dev A done operation stays done however the flag reads, which is what stops a release from
    ///      reopening something that already ran.
    function test_layout_aReleasedFlagCannotReopenADoneOperation() public {
        vm.store(address(protocolAdmin), _entry(OPERATION, TIMESTAMPS_SLOT), bytes32(uint256(1)));
        vm.store(address(protocolAdmin), _entry(OPERATION, RELEASED_SLOT), bytes32(uint256(1)));

        assertTrue(protocolAdmin.isOperationDone(OPERATION));
        assertFalse(protocolAdmin.isOperationReady(OPERATION));
    }

    /// @dev Nothing of the admin contract's own sits in the first three slots, so an OpenZeppelin
    ///      bump that appends to either base pushes the released flag rather than overwriting it.
    function test_layout_theContractAddsExactlyOneSlot() public view {
        assertEq(vm.load(address(protocolAdmin), bytes32(MIN_DELAY_SLOT)), bytes32(DELAY));
        assertEq(vm.load(address(protocolAdmin), bytes32(RELEASED_SLOT)), bytes32(0));
        assertEq(vm.load(address(protocolAdmin), bytes32(uint256(4))), bytes32(0));
    }

    /// @dev The floor is immutable, so it lives in the bytecode and occupies no slot at all. If it
    ///      ever moved into storage it would land on slot 3 and take the released flag with it.
    function test_layout_theDelayFloorIsNotInStorage() public {
        vm.store(address(protocolAdmin), bytes32(RELEASED_SLOT), bytes32(uint256(99 days)));

        assertEq(protocolAdmin.minDelayFloor(), DELAY_FLOOR);
    }
}
