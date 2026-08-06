// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";
import {ProtocolAdminHandler} from "test/foundry/invariant-testing/handler/ProtocolAdminHandler.sol";

/// @notice What has to stay true about the admin contract however its actors are sequenced.
/// @dev The unit tests take one path at a time. What they cannot reach is an order: an operation
///      cancelled after a guardian released it, a release landing in the same block as an ordinary
///      execution, the clock crossing a ready time between two calls in one transaction. Those are
///      the sequences a single compromised key would be looking for, and they are what the campaign
///      is here to walk.
///
///      This campaign moves the clock, which the protocol campaign deliberately does not. A
///      timelock with a static clock only ever tests the half of itself that rejects things.
contract AdminInvariantsTest is AdminBase {

    ProtocolAdminHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new ProtocolAdminHandler(protocolAdmin, Registry(payable(address(registry))), proposer, guardian);

        targetContract(address(handler));
    }

    /// @notice The admin contract never stops owning the four contracts it was given
    /// @dev Nothing the handler can call moves ownership, so this failing means a path exists that
    ///      reaches `transferOwnership` without going through a scheduled operation.
    function invariant_ownershipNeverLeavesTheAdminContract() public view {
        address[] memory targets = _ownedContracts();

        for(uint256 i = 0; i < targets.length; ++i) {
            assertEq(
                Ownable2StepUpgradeable(targets[i]).owner(),
                address(protocolAdmin),
                "the admin contract stopped owning one of the four"
            );
            assertEq(
                Ownable2StepUpgradeable(targets[i]).pendingOwner(),
                address(0),
                "an ownership offer appeared that nobody scheduled"
            );
        }
    }

    /// @notice No operation is ever observably released from its delay
    /// @dev The release exists only inside the transaction that uses it. If one is ever visible
    ///      between calls, the payload is public and open execution would let anyone replay it.
    ///      This is the single property the whole design rests on.
    function invariant_noOperationIsEverLeftReleased() public view {
        uint256 count = handler.operationCount();

        for(uint256 i = 0; i < count; ++i) {
            (,,, bytes32 id,) = handler.operations(i);
            assertFalse(protocolAdmin.isReleased(id), "an operation was left released");
        }
    }

    /// @notice An operation reads ready only because its own timestamp says so
    /// @dev The other half of the release check, from the reader's side. Between transactions the
    ///      two views of an operation have to agree, and the only thing that could pull them apart
    ///      is a release surviving.
    function invariant_readinessAlwaysMatchesTheTimestamp() public view {
        uint256 count = handler.operationCount();

        for(uint256 i = 0; i < count; ++i) {
            (,,, bytes32 id,) = handler.operations(i);
            if(!protocolAdmin.isOperationReady(id)) continue;

            uint256 readyAt = protocolAdmin.getTimestamp(id);
            assertTrue(readyAt > 1, "an operation reads ready with no timestamp behind it");
            assertLe(readyAt, block.timestamp, "an operation reads ready before its own time");
        }
    }

    /// @notice An operation that has run stays run
    /// @dev Executed operations are the ones a replay would target, and `Done` is the only thing
    ///      standing between a public payload and a second application of it.
    function invariant_executedOperationsStayDone() public view {
        uint256 count = handler.operationCount();
        uint256 done;

        for(uint256 i = 0; i < count; ++i) {
            (,,, bytes32 id,) = handler.operations(i);
            if(protocolAdmin.isOperationDone(id)) ++done;
        }

        assertEq(
            done,
            handler.executed() + handler.executedInstantly(),
            "the number of finished operations does not match the number that ran"
        );
    }

    /// @notice The registry only ever holds a value some completed operation put there
    /// @dev The end to end statement. Every other invariant is about the admin contract's own
    ///      bookkeeping; this one says the bookkeeping actually governs the protocol.
    function invariant_theRegistryOnlyReflectsCompletedOperations() public view {
        assertEq(
            registry.defaultDataBundlePriceCap(),
            handler.expectedCap(),
            "the registry holds a value no completed operation wrote"
        );
    }

    /// @notice The delay never drops below the floor
    function invariant_theDelayNeverFallsBelowTheFloor() public view {
        assertGe(protocolAdmin.getMinDelay(), protocolAdmin.minDelayFloor());
    }

    /// @notice Role administration stays inside the contract
    /// @dev If any account outside picks up `DEFAULT_ADMIN_ROLE`, every other guarantee here is
    ///      decoration: that account can grant itself the guardian role and skip every delay.
    function invariant_roleAdministrationStaysInsideTheContract() public view {
        assertTrue(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), address(protocolAdmin)));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), proposer));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), address(handler)));
    }

    /// @notice The two privileged sets stay exactly who they were at construction
    function invariant_thePrivilegedSetsDoNotGrow() public view {
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), proposer));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), outsider));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), address(handler)));
    }

    /// @notice The handler really reaches every path the invariants above assume it does
    /// @dev Not an invariant, because an invariant is also evaluated once before any call is made
    ///      and a coverage assertion would fail there by definition. Driven by hand instead, which
    ///      is the same reason `HandlerDistributionTest` is an ordinary test.
    ///
    ///      A campaign where every call reverted would satisfy all of the above and prove nothing,
    ///      so this is what stops the rest of the file from being decoration.
    function test_theHandlerReachesEveryPath() public {
        handler.scheduleCap(1 ether, bytes32(uint256(1)));
        assertEq(handler.scheduled(), 1, "the proposer could not announce an operation");

        handler.executeAnnounced(0, 1);
        assertEq(handler.executed(), 0, "an operation ran before its delay");

        handler.passTime(uint32(DELAY));
        handler.executeAnnounced(0, 1);
        assertEq(handler.executed(), 1, "an announced operation never became executable");

        handler.executeInstantly(2 ether, bytes32(uint256(2)));
        assertEq(handler.executedInstantly(), 1, "the guardian could not skip the delay");

        handler.scheduleCap(3 ether, bytes32(uint256(3)));
        handler.cancelAnnounced(handler.operationCount() - 1);
        assertEq(handler.cancelled(), 1, "the proposer could not call an operation off");

        _assertEveryRejectionPathFires();
    }

    /// @dev Split out because the four calls and their assertions are cumulative on the stack.
    function _assertEveryRejectionPathFires() private {
        handler.rejectsAnUnauthorisedSchedule(outsider, 1 ether);
        handler.rejectsAnUnauthorisedInstantExecution(outsider, 1 ether);
        handler.rejectsADirectCallToTheRegistry(outsider, 1 ether);
        handler.rejectsADirectRoleGrant(outsider, outsider);

        assertEq(handler.rejections(), 4, "an unauthorised call was not turned away");
    }
}
