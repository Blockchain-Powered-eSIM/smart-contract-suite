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

        handler = new ProtocolAdminHandler(
            protocolAdmin,
            Registry(payable(address(registry))),
            proposer,
            guardian,
            eSIMWalletAdmin,
            _cancellerSet()
        );

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

    /// @notice The guardian never picks up the power it is allowed to take away
    /// @dev The single property the recovery story rests on. A guardian holding the cancel power
    ///      could strip every other canceller, become the only one, and then cancel its own
    ///      eviction for as long as it liked. There would be nothing left to break that loose.
    function invariant_theGuardianNeverHoldsTheCancelPower() public view {
        assertFalse(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), guardian));
    }

    /// @notice Both proposers keep the ability to schedule, whatever the guardian did
    /// @dev Reaching zero proposers is the one unrecoverable state in the contract: re-granting a
    ///      role needs a scheduled operation, scheduling needs a proposer, and `Registry.unpause`
    ///      is owner only, so a bricked admin plus a pause is a pause nobody can ever release.
    ///      The campaign lets the guardian strip cancel powers freely; this says none of that ever
    ///      reaches the other role.
    function invariant_theProposersCanAlwaysStillPropose() public view {
        bytes32 proposerRole = protocolAdmin.PROPOSER_ROLE();

        assertTrue(protocolAdmin.hasRole(proposerRole, proposer), "the proposer lost its role");
        assertTrue(protocolAdmin.hasRole(proposerRole, coldProposer), "the backup lost its role");
    }

    /// @notice The cancel power only ever leaves an account, never arrives at one
    /// @dev Adding it back is an ordinary scheduled operation and the campaign never runs one, so
    ///      any account holding it here that the handler did not start with came from somewhere
    ///      the design does not have a route for.
    function invariant_theCancelPowerIsOnlyEverGivenUp() public view {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();
        address[] memory started = _cancellerSet();
        uint256 holders;

        for(uint256 i = 0; i < started.length; ++i) {
            if(protocolAdmin.hasRole(cancellerRole, started[i])) ++holders;
        }

        assertEq(holders, handler.cancellerCount(), "the cancel power moved somewhere untracked");
        assertEq(
            started.length - holders,
            handler.cancellersRevoked(),
            "an account lost the cancel power without a guardian taking it"
        );
    }

    /// @notice An operation reads ready only because its own timestamp says so
    /// @dev Nothing in this contract can make an operation executable ahead of its time. The
    ///      guardian's two powers do not touch the schedule at all, and this is what says so from
    ///      the reader's side rather than from the entry points.
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
            handler.executed(),
            "the number of finished operations does not match the number that ran"
        );
    }

    /// @notice The registry only ever holds a value some completed operation put there
    /// @dev The end to end statement. Every other invariant is about the admin contract's own
    ///      bookkeeping; this one says the bookkeeping actually governs the protocol.
    function invariant_theRegistryOnlyReflectsCompletedOperations() public view {
        assertEq(
            registry.defaultPriceCapUSDCents(),
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

    /// @notice The privileged sets stay exactly who they were at construction
    function invariant_thePrivilegedSetsDoNotGrow() public view {
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), proposer));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), canceller));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), outsider));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), canceller));
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

        handler.scheduleCap(3 ether, bytes32(uint256(3)));
        handler.cancelAnnounced(handler.operationCount() - 1);
        assertEq(handler.cancelled(), 1, "the proposer could not call an operation off");

        handler.scheduleCap(4 ether, bytes32(uint256(4)));
        handler.cancelAsACanceller(handler.operationCount() - 1, 0);
        assertEq(handler.cancelled(), 2, "an account holding only the cancel power could not use it");

        _assertTheGuardianPathsFire();
        _assertEveryRejectionPathFires();
    }

    /// @dev Split out because the calls and their assertions are cumulative on the stack.
    function _assertTheGuardianPathsFire() private {
        handler.pauseProtocol();
        assertTrue(registry.paused(), "the hot key could not trip the pause");

        handler.unpauseInstantly();
        assertEq(handler.unpaused(), 1, "the guardian could not release the pause");
        assertFalse(registry.paused());

        uint256 before = handler.cancellerCount();
        handler.revokeCanceller(0);
        assertEq(handler.cancellersRevoked(), 1, "the guardian could not strip a canceller");
        assertEq(handler.cancellerCount(), before - 1);
    }

    /// @dev Same reason. Every call an actor is not allowed to make, proved to be turned away.
    function _assertEveryRejectionPathFires() private {
        handler.rejectsAnUnauthorisedSchedule(outsider, 1 ether);
        handler.rejectsAnUnauthorisedUnpause(outsider);
        handler.rejectsAnUnauthorisedCancellerRevocation(outsider, 0);
        handler.rejectsAGuardianReachingAnotherRole(0);
        handler.rejectsADirectCallToTheRegistry(outsider, 1 ether);
        handler.rejectsADirectRoleGrant(outsider, outsider);

        assertEq(handler.rejections(), 6, "an unauthorised call was not turned away");
    }
}
