// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "test/utils/AdminBase.sol";

/// @notice Pins every slot this contract and its bases occupy.
/// @dev The admin contract is not upgradeable, so nothing here is about surviving an upgrade. What
///      it is about is the claim that the contract adds no storage of its own at all. Its two
///      powers are both role checks, its floor is immutable, and its state is entirely the two
///      mappings and one word the timelock already keeps.
///
///      That claim is worth pinning because it is what makes the guardian's powers auditable by
///      reading three functions. A variable appearing here later would be state the guardian's
///      entry points could reach that nothing in the role model describes.
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

    /// @dev The first slot past everything the bases declare
    uint256 private constant FIRST_FREE_SLOT = 3;

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

    /// @dev The guardian role is an ordinary `AccessControl` entry rather than anything this
    ///      contract keeps for itself, which is why revoking it needs no bespoke bookkeeping.
    function test_layout_theGuardianRoleLivesInTheSameMappingAsTheRest() public {
        bytes32 guardianRole = protocolAdmin.GUARDIAN_ROLE();

        vm.store(address(protocolAdmin), _roleMember(guardianRole, guardian), bytes32(0));

        assertFalse(protocolAdmin.hasRole(guardianRole, guardian));

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.unpauseInstantly(address(registry));
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

    /// @dev The check the whole file exists for. Everything past the bases is untouched, so the
    ///      contract keeps no state a reader of its three functions would not know about.
    function test_layout_theContractAddsNoStorageOfItsOwn() public view {
        assertEq(vm.load(address(protocolAdmin), bytes32(MIN_DELAY_SLOT)), bytes32(DELAY));

        for(uint256 slot = FIRST_FREE_SLOT; slot < FIRST_FREE_SLOT + 4; ++slot) {
            assertEq(
                vm.load(address(protocolAdmin), bytes32(slot)),
                bytes32(0),
                "the admin contract wrote a slot past its bases"
            );
        }
    }

    /// @dev The floor is immutable, so it lives in the bytecode and occupies no slot at all. A
    ///      floor that could be written would be one a compromised key could write to zero.
    function test_layout_theDelayFloorIsNotInStorage() public {
        vm.store(address(protocolAdmin), bytes32(FIRST_FREE_SLOT), bytes32(uint256(99 days)));
        vm.store(address(protocolAdmin), bytes32(MIN_DELAY_SLOT), bytes32(0));

        assertEq(protocolAdmin.minDelayFloor(), DELAY_FLOOR);
        assertEq(protocolAdmin.getMinDelay(), DELAY_FLOOR, "the floor must still bind at zero delay");
    }

    /// @dev Nothing reads an operation as ready ahead of its own timestamp. With the release flag
    ///      gone there is no second source of readiness, and this is what says so.
    function test_layout_readinessComesOnlyFromTheTimestamp() public {
        vm.store(address(protocolAdmin), _entry(OPERATION, TIMESTAMPS_SLOT), bytes32(block.timestamp + 1));
        assertFalse(protocolAdmin.isOperationReady(OPERATION));

        vm.store(address(protocolAdmin), _entry(OPERATION, TIMESTAMPS_SLOT), bytes32(block.timestamp));
        assertTrue(protocolAdmin.isOperationReady(OPERATION));
    }

    /// @dev A done operation stays done. `_DONE_TIMESTAMP` is 1, and an operation carrying it must
    ///      never read ready however the clock has moved.
    function test_layout_aDoneOperationNeverReadsReady() public {
        vm.store(address(protocolAdmin), _entry(OPERATION, TIMESTAMPS_SLOT), bytes32(uint256(1)));

        assertTrue(protocolAdmin.isOperationDone(OPERATION));
        assertFalse(protocolAdmin.isOperationReady(OPERATION));
    }
}
