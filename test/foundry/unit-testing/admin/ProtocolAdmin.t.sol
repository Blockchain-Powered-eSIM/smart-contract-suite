// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Construction, roles, the delay, and the two ways an operation reaches a protocol
///         contract.
contract ProtocolAdminTest is AdminBase {

    function test_construction_grantsTheRolesItSaysItDoes() public view {
        assertTrue(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), proposer));
        assertTrue(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), proposer));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), proposer));

        assertTrue(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), guardian));
        assertTrue(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), guardian));
        assertTrue(protocolAdmin.hasRole(protocolAdmin.EXECUTOR_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), guardian));
    }

    /// @dev The zero address holding a role is how `onlyRoleOrOpenRole` spells "open to everyone".
    function test_construction_leavesExecutionOpenToEveryone() public view {
        assertTrue(protocolAdmin.hasRole(protocolAdmin.EXECUTOR_ROLE(), address(0)));
    }

    /// @dev No account outside the contract may hand out a role, so rotating the proposer set is
    ///      itself an operation that waits.
    function test_construction_keepsRoleAdministrationInsideTheContract() public view {
        assertTrue(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), address(protocolAdmin)));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), proposer));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), upgradeManager));
    }

    function test_construction_rejectsADelayUnderTheFloor() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.DelayBelowFloor.selector, 30 minutes, 1 hours));
        new ProtocolAdmin(30 minutes, 1 hours, proposers, guardians);
    }

    /// @dev Without a guardian there is no way to release a pause quickly, which is the one thing
    ///      the delay must not stand in front of.
    function test_construction_rejectsAnEmptyGuardianSet() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        vm.expectRevert(ProtocolAdmin.NoGuardians.selector);
        new ProtocolAdmin(DELAY, DELAY_FLOOR, proposers, new address[](0));
    }

    function test_construction_rejectsTheZeroAddressInEitherRoleList() public {
        address[] memory withZeroProposer = new address[](1);
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.ZeroAddress.selector, "_proposers"));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, withZeroProposer, guardians);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.ZeroAddress.selector, "_guardians"));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, proposers, new address[](1));
    }

    function test_ownership_reachesAllFourContracts() public view {
        assertEq(registry.owner(), address(protocolAdmin));
        assertEq(lazyWalletRegistry.owner(), address(protocolAdmin));
        assertEq(deviceWalletFactory.owner(), address(protocolAdmin));
        assertEq(eSIMWalletFactory.owner(), address(protocolAdmin));
    }

    /// @dev `upgradeManager()` is a view over `owner()`, so the address that authorises an upgrade
    ///      moved with the ownership rather than being a second thing to remember to update.
    function test_ownership_movesTheUpgradeAuthorityWithIt() public view {
        assertEq(registry.upgradeManager(), address(protocolAdmin));
        assertEq(lazyWalletRegistry.upgradeManager(), address(protocolAdmin));
    }

    function test_schedule_rejectsAnAccountWithoutTheProposerRole() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        bytes32 role = protocolAdmin.PROPOSER_ROLE();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
    }

    /// @dev A guardian skips the wait but cannot start one. Scheduling stays with the proposers.
    function test_schedule_rejectsTheGuardian() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        bytes32 role = protocolAdmin.PROPOSER_ROLE();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, role)
        );
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
    }

    function test_execute_rejectsAnOperationStillInsideItsDelay() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        vm.warp(block.timestamp + DELAY - 1);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(uint256(1 << uint8(TimelockController.OperationState.Ready)))
            )
        );
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev The point of open execution: once the wait is served the protocol does not depend on
    ///      any particular key still being available to press the button.
    function test_execute_allowsAnyoneOnceTheDelayHasPassed() public {
        assertEq(registry.defaultDataBundlePriceCap(), 0);

        _runThroughTheDelay(
            address(registry),
            abi.encodeCall(registry.setDefaultDataBundlePriceCap, (7 ether)),
            bytes32(0)
        );

        assertEq(registry.defaultDataBundlePriceCap(), 7 ether);
    }

    function test_execute_rejectsAnOperationThatWasNeverScheduled() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        vm.prank(outsider);
        vm.expectRevert();
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev Both roles can stop a scheduled operation. A guardian trusted to skip the wait is
    ///      trusted to call one off.
    function test_cancel_worksForBothTheProposerAndTheGuardian() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        bytes32 first = _schedule(address(registry), data, bytes32(uint256(1)));
        vm.prank(proposer);
        protocolAdmin.cancel(first);
        assertFalse(protocolAdmin.isOperation(first));

        bytes32 second = _schedule(address(registry), data, bytes32(uint256(2)));
        vm.prank(guardian);
        protocolAdmin.cancel(second);
        assertFalse(protocolAdmin.isOperation(second));
    }

    function test_cancel_rejectsAnAccountHoldingNeitherRole() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        bytes32 role = protocolAdmin.CANCELLER_ROLE();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        protocolAdmin.cancel(id);
    }

    /// @dev A cancelled operation goes back to unset, so the same payload can be proposed again
    ///      rather than being burned by one cancellation.
    function test_cancel_leavesThePayloadSchedulableAgain() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        vm.prank(proposer);
        protocolAdmin.cancel(id);

        _runThroughTheDelay(address(registry), data, bytes32(0));
        assertEq(registry.defaultDataBundlePriceCap(), 1 ether);
    }

    function test_getMinDelay_startsAtTheConstructorValue() public view {
        assertEq(protocolAdmin.getMinDelay(), DELAY);
        assertEq(protocolAdmin.minDelayFloor(), DELAY_FLOOR);
    }

    /// @dev `updateDelay` is reachable by scheduling a call to the admin contract itself, which is
    ///      the intended way to change it.
    function test_updateDelay_appliesOnceItHasBeenScheduledAndRun() public {
        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.updateDelay, (5 days)),
            bytes32(0)
        );

        assertEq(protocolAdmin.getMinDelay(), 5 days);
    }

    /// @dev The floor is what stops one scheduled operation from turning the contract into a plain
    ///      multisig. `updateDelay` still accepts the value, but nothing ever waits less than the
    ///      floor because `schedule` measures against `getMinDelay`.
    function test_updateDelay_cannotBringTheDelayBelowTheFloor() public {
        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.updateDelay, (0)),
            bytes32(0)
        );

        assertEq(protocolAdmin.getMinDelay(), DELAY_FLOOR);

        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 0, DELAY_FLOOR)
        );
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), 0);
    }

    function test_updateDelay_rejectsACallerThatIsNotTheContractItself() public {
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, proposer)
        );
        protocolAdmin.updateDelay(5 days);
    }

    /// @dev Rotating the signer set is a role change here. The protocol contracts keep the same
    ///      owner throughout, so nothing about them moves.
    function test_roles_rotateWithoutTouchingTheProtocolContracts() public {
        address replacement = address(0xBEEF);

        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.grantRole, (protocolAdmin.PROPOSER_ROLE(), replacement)),
            bytes32(uint256(1))
        );
        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.revokeRole, (protocolAdmin.PROPOSER_ROLE(), proposer)),
            bytes32(uint256(2))
        );

        assertTrue(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), replacement));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), proposer));
        assertEq(registry.owner(), address(protocolAdmin));
        assertEq(deviceWalletFactory.owner(), address(protocolAdmin));
    }

    function test_roles_cannotBeGrantedDirectlyByAnyone() public {
        bytes32 adminRole = protocolAdmin.DEFAULT_ADMIN_ROLE();
        bytes32 guardianRole = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, proposer, adminRole)
        );
        protocolAdmin.grantRole(guardianRole, outsider);
    }

    /// @dev Four proxies in one operation. Either every one moves or the transaction reverts and
    ///      none of them do, which is the whole reason the batch form exists.
    function test_executeBatch_appliesEveryCallOrNone() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _twoCallBatch();

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(registry.defaultDataBundlePriceCap(), 3 ether);
        assertEq(registry.lazyWalletRegistry(), address(lazyWalletRegistry));
    }

    /// @dev The second call in the batch is rejected by the registry, so the first has to come back
    ///      with it.
    function test_executeBatch_revertsTheWholeBatchWhenOneCallFails() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);

        targets[0] = address(registry);
        payloads[0] = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (3 ether));
        targets[1] = address(registry);
        payloads[1] = abi.encodeCall(registry.addOrUpdateLazyWalletRegistryAddress, (address(0)));

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        vm.expectRevert();
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(registry.defaultDataBundlePriceCap(), 0, "the first call must not have stuck");
    }

    function test_executeBatch_rejectsMismatchedArrayLengths() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](2);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 2, 1)
        );
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
    }

    /// @dev Split out because the array setup and the assertions together run the stack up.
    function _twoCallBatch()
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);

        targets[0] = address(registry);
        payloads[0] = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (3 ether));
        targets[1] = address(registry);
        payloads[1] = abi.encodeCall(registry.addOrUpdateLazyWalletRegistryAddress, (address(lazyWalletRegistry)));
    }
}
