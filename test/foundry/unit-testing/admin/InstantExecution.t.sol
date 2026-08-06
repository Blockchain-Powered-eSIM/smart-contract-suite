// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Reenters the admin contract with whatever it was handed.
/// @dev Stands in for a compromised or hostile upgrade target. The point is that an operation
///      released from the delay is not left in a state a callback can run a second time.
contract Reenterer {

    ProtocolAdmin private immutable admin;

    bytes private payload;

    constructor(ProtocolAdmin _admin) {
        admin = _admin;
    }

    function arm(bytes calldata _payload) external {
        payload = _payload;
    }

    /// @dev Not payable. The operation it is reached through carries no value, and a payable
    ///      fallback with no receive function is a compiler warning this repo does not carry.
    fallback() external {
        bytes memory armed = payload;
        if(armed.length == 0) return;

        delete payload;
        (bool success, bytes memory returndata) = address(admin).call(armed);
        if(!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

/// @notice The guardian's path around the delay: who may take it, what it leaves behind, and what
///         it must never allow twice.
contract InstantExecutionTest is AdminBase {

    /// @dev The reason the role exists. The admin key trips the pause and the owner clears it, so
    ///      without a way around the delay a release would be a two day outage.
    function test_instant_releasesAPauseWithoutWaiting() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused());

        uint256 before = block.timestamp;
        _runInstantly(address(registry), abi.encodeCall(registry.unpause, ()), bytes32(0));

        assertFalse(registry.paused());
        assertEq(block.timestamp, before, "no time may have passed");
    }

    function test_instant_runsAnOperationThatWasNeverScheduled() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = protocolAdmin.hashOperation(address(registry), 0, data, bytes32(0), bytes32(0));

        assertFalse(protocolAdmin.isOperation(id), "nothing scheduled beforehand");

        _runInstantly(address(registry), data, bytes32(0));

        assertEq(registry.defaultDataBundlePriceCap(), 4 ether);
    }

    /// @dev Fast forwarding something already announced, rather than starting from nothing.
    function test_instant_runsAnOperationStillInsideItsDelay() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        assertTrue(protocolAdmin.isOperationPending(id));
        assertFalse(protocolAdmin.isOperationReady(id));

        _runInstantly(address(registry), data, bytes32(0));

        assertEq(registry.defaultDataBundlePriceCap(), 4 ether);
        assertTrue(protocolAdmin.isOperationDone(id));
    }

    function test_instant_rejectsAnAccountWithoutTheGuardianRole() public {
        bytes memory data = abi.encodeCall(registry.unpause, ());
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        protocolAdmin.executeInstantly(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev The proposer holds the other half of the split and must not be able to take both.
    function test_instant_rejectsTheProposer() public {
        bytes memory data = abi.encodeCall(registry.unpause, ());
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, proposer, role)
        );
        protocolAdmin.executeInstantly(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    function test_instant_rejectsAnAccountWithoutTheGuardianRoleOnTheBatchForm() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _single(address(registry), abi.encodeCall(registry.unpause, ()));
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        protocolAdmin.executeBatchInstantly(targets, values, payloads, bytes32(0), bytes32(0));
    }

    /// @dev The whole point of clearing the release inside the same transaction. If the flag
    ///      survived, the payload is public and open execution would let anyone replay it.
    function test_instant_leavesNothingAnyoneElseCanReplay() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = protocolAdmin.hashOperation(address(registry), 0, data, bytes32(0), bytes32(0));

        _runInstantly(address(registry), data, bytes32(0));

        assertFalse(protocolAdmin.isReleased(id), "the release must not outlive the transaction");
        assertTrue(protocolAdmin.isOperationDone(id));

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(uint256(1 << uint8(TimelockController.OperationState.Ready))))
        );
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    function test_instant_cannotRunTheSameOperationTwice() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = protocolAdmin.hashOperation(address(registry), 0, data, bytes32(0), bytes32(0));

        _runInstantly(address(registry), data, bytes32(0));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.OperationAlreadyExecuted.selector, id));
        protocolAdmin.executeInstantly(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev An operation that already served its delay and ran is closed to the fast path too.
    function test_instant_cannotRerunAnOperationThatAlreadyWentThroughTheDelay() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = protocolAdmin.hashOperation(address(registry), 0, data, bytes32(0), bytes32(0));

        _runThroughTheDelay(address(registry), data, bytes32(0));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.OperationAlreadyExecuted.selector, id));
        protocolAdmin.executeInstantly(address(registry), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev The same payload under a different salt is a different operation, which is how a
    ///      setting gets changed twice rather than being burned by its first use.
    function test_instant_allowsTheSamePayloadUnderADifferentSalt() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));

        _runInstantly(address(registry), data, bytes32(uint256(1)));
        _runInstantly(address(registry), data, bytes32(uint256(2)));

        assertEq(registry.defaultDataBundlePriceCap(), 4 ether);
    }

    /// @dev A reverting call takes the release back with it, so nothing is left half open for the
    ///      next transaction to pick up.
    function test_instant_leavesNoReleaseBehindWhenTheCallReverts() public {
        bytes memory data = abi.encodeCall(registry.addOrUpdateLazyWalletRegistryAddress, (address(0)));
        bytes32 id = protocolAdmin.hashOperation(address(registry), 0, data, bytes32(0), bytes32(0));

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.executeInstantly(address(registry), 0, data, bytes32(0), bytes32(0));

        assertFalse(protocolAdmin.isReleased(id));
        assertFalse(protocolAdmin.isOperation(id));
    }

    /// @dev The batch form is what an upgrade uses, so partial application is the failure that
    ///      matters most here.
    function test_instant_revertsTheWholeBatchWhenOneCallFails() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);

        targets[0] = address(registry);
        payloads[0] = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        targets[1] = address(registry);
        payloads[1] = abi.encodeCall(registry.addOrUpdateLazyWalletRegistryAddress, (address(0)));

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.executeBatchInstantly(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(registry.defaultDataBundlePriceCap(), 0);
    }

    function test_instant_rejectsMismatchedArrayLengthsOnTheBatchForm() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](2);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 2, 1)
        );
        protocolAdmin.executeBatchInstantly(targets, values, payloads, bytes32(0), bytes32(0));
    }

    /// @dev A predecessor is still a predecessor. Skipping the wait does not skip the ordering the
    ///      proposer asked for.
    function test_instant_stillHonoursAnUnexecutedPredecessor() public {
        bytes memory first = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        bytes32 firstId = _schedule(address(registry), first, bytes32(0));

        bytes memory second = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (2 ether));

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, firstId)
        );
        protocolAdmin.executeInstantly(address(registry), 0, second, firstId, bytes32(0));
    }

    /// @dev Cancelling clears the schedule but does not blacklist the payload, so the guardian can
    ///      still act on it. Anything else would let one cancellation lock out an emergency.
    function test_instant_stillWorksAfterTheOperationWasCancelled() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        vm.prank(proposer);
        protocolAdmin.cancel(id);

        _runInstantly(address(registry), data, bytes32(0));
        assertEq(registry.defaultDataBundlePriceCap(), 4 ether);
    }

    function test_instant_forwardsValueToTheTarget() public {
        vm.deal(guardian, 1 ether);

        vm.prank(guardian);
        protocolAdmin.executeInstantly{value: 1 ether}(user5, 1 ether, "", bytes32(0), bytes32(0));

        assertEq(user5.balance, 1 ether);
        assertEq(address(protocolAdmin).balance, 0);
    }

    /// @dev The released operation is marked done before control returns, so a callback trying to
    ///      run it a second time takes the whole transaction down with it.
    function test_instant_rejectsATargetThatReentersWithTheSameOperation() public {
        Reenterer target = new Reenterer(protocolAdmin);

        bytes memory payload = hex"1234";
        target.arm(
            abi.encodeCall(
                protocolAdmin.execute,
                (address(target), 0, payload, bytes32(0), bytes32(0))
            )
        );

        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.executeInstantly(address(target), 0, payload, bytes32(0), bytes32(0));
    }

    /// @dev Revoking open execution does not take the fast path with it, because guardians hold
    ///      the executor role in their own right.
    function test_instant_survivesOpenExecutionBeingClosedOff() public {
        bytes32 executorRole = protocolAdmin.EXECUTOR_ROLE();

        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.revokeRole, (executorRole, address(0))),
            bytes32(0)
        );

        assertFalse(protocolAdmin.hasRole(executorRole, address(0)));

        _runInstantly(
            address(registry),
            abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether)),
            bytes32(0)
        );

        assertEq(registry.defaultDataBundlePriceCap(), 4 ether);
    }

    /// @dev With open execution closed, an ordinary execution needs the role again.
    function test_execute_closesToOutsidersOnceOpenExecutionIsRevoked() public {
        bytes32 executorRole = protocolAdmin.EXECUTOR_ROLE();

        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.revokeRole, (executorRole, address(0))),
            bytes32(uint256(1))
        );

        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        _schedule(address(registry), data, bytes32(uint256(2)));
        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, executorRole
            )
        );
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(uint256(2)));
    }

    function test_isReleased_readsFalseOutsideAGuardianTransaction() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));

        assertFalse(protocolAdmin.isReleased(id));
        assertFalse(protocolAdmin.isOperationReady(id), "a pending operation must not read ready");
    }
}
