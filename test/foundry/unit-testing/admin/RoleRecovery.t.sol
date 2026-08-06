// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Getting a compromised key out, and the states that must stay unreachable while doing it.
/// @dev Every other file here tests what the contract does. This one tests what happens after
///      something has already gone wrong, which is the only condition under which the role split
///      earns anything.
///
///      The shape all of these share: a role holder turns hostile, the honest side evicts it, and
///      the eviction has to land even though the hostile account is trying to stop it. Two of them
///      only work because of a specific decision, and both are called out where they appear.
contract RoleRecoveryTest is AdminBase {

    /// @dev The deadlock the guardian's second power exists to break. Evicting any role holder is a
    ///      scheduled operation, a scheduled operation can be cancelled by any canceller, so
    ///      without an instant revocation a compromised canceller cancels its own eviction for as
    ///      long as it cares to and nothing else in the contract can reach it.
    function test_recovery_aCompromisedCancellerCannotBlockItsOwnEviction() public {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();
        bytes memory eviction = abi.encodeCall(protocolAdmin.revokeRole, (cancellerRole, canceller));

        // Without the instant path this is where it ends. The hostile key cancels every attempt.
        bytes32 blocked = _schedule(address(protocolAdmin), eviction, bytes32(uint256(1)));
        vm.prank(canceller);
        protocolAdmin.cancel(blocked);
        assertFalse(protocolAdmin.isOperation(blocked), "the hostile key stopped its own eviction");

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));

        // Now the same operation cannot be stopped, because the account has nothing left to stop it
        bytes32 id = _schedule(address(protocolAdmin), eviction, bytes32(uint256(2)));

        vm.prank(canceller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, canceller, cancellerRole
            )
        );
        protocolAdmin.cancel(id);

        assertTrue(protocolAdmin.isOperationPending(id));
    }

    /// @dev A compromised proposer multisig holds the cancel power through the multisig itself and
    ///      through each key behind it. All of it goes in one transaction, and the eviction that
    ///      follows is then unstoppable.
    function test_recovery_aCompromisedProposerIsEvictedByTheBackupProposer() public {
        address[] memory hostile = new address[](4);
        hostile[0] = proposer;
        hostile[1] = canceller;
        hostile[2] = secondCanceller;
        hostile[3] = thirdCanceller;

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(hostile);

        bytes32 proposerRole = protocolAdmin.PROPOSER_ROLE();
        bytes memory eviction = abi.encodeCall(protocolAdmin.revokeRole, (proposerRole, proposer));

        uint256 delay = protocolAdmin.getMinDelay();
        vm.prank(coldProposer);
        protocolAdmin.schedule(address(protocolAdmin), 0, eviction, bytes32(0), bytes32(0), delay);

        // Read ahead of the pranks. A view call in an argument list is what the prank lands on.
        bytes32 id =
            protocolAdmin.hashOperation(address(protocolAdmin), 0, eviction, bytes32(0), bytes32(0));

        // Nobody hostile can stop it now
        for(uint256 i = 0; i < hostile.length; ++i) {
            vm.prank(hostile[i]);
            vm.expectRevert();
            protocolAdmin.cancel(id);
        }

        vm.warp(block.timestamp + delay);

        vm.prank(outsider);
        protocolAdmin.execute(address(protocolAdmin), 0, eviction, bytes32(0), bytes32(0));

        assertFalse(protocolAdmin.hasRole(proposerRole, proposer), "the compromised multisig is out");
        assertTrue(protocolAdmin.hasRole(proposerRole, coldProposer), "the backup still holds its role");
    }

    /// @dev The cold key is the whole reason the step above works. With one proposer, a compromised
    ///      one would be the only account able to schedule its own eviction, and governance would
    ///      end there with nothing anyone could do about it.
    function test_recovery_hasNoRouteAtAllWithASingleProposer() public {
        address[] memory one = new address[](1);
        one[0] = proposer;

        ProtocolAdmin lean = new ProtocolAdmin(DELAY, DELAY_FLOOR, one, _cancellerSet(), _guardianSet());

        bytes32 proposerRole = lean.PROPOSER_ROLE();
        bytes memory eviction = abi.encodeCall(lean.revokeRole, (proposerRole, proposer));

        // Every account that is not the compromised one, and none of them can start the eviction
        address[4] memory others = [coldProposer, canceller, guardian, outsider];
        for(uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], proposerRole
                )
            );
            lean.schedule(address(lean), 0, eviction, bytes32(0), bytes32(0), DELAY);
        }
    }

    /// @dev A guardian gone hostile is a nuisance rather than a takeover, and it stays evictable.
    ///      It can strip every canceller and it still cannot cancel, so the operation removing it
    ///      runs the moment its delay is served.
    function test_recovery_aHostileGuardianIsStillEvictable() public {
        address[] memory everyone = new address[](5);
        everyone[0] = proposer;
        everyone[1] = coldProposer;
        everyone[2] = canceller;
        everyone[3] = secondCanceller;
        everyone[4] = thirdCanceller;

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(everyone);

        bytes32 guardianRole = protocolAdmin.GUARDIAN_ROLE();
        bytes memory eviction = abi.encodeCall(protocolAdmin.revokeRole, (guardianRole, guardian));

        _runThroughTheDelay(address(protocolAdmin), eviction, bytes32(0));

        assertFalse(protocolAdmin.hasRole(guardianRole, guardian));

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, guardianRole
            )
        );
        protocolAdmin.unpauseInstantly(address(registry));
    }

    /// @dev What a keyholder does before telling anyone. Renouncing is instant, self only, and
    ///      nobody can block it, which makes it the fastest thing available to someone who thinks
    ///      their key is gone.
    function test_recovery_aKeyholderCanStepDownWithoutWaitingForAnyone() public {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();
        bytes32 proposerRole = protocolAdmin.PROPOSER_ROLE();

        vm.prank(canceller);
        protocolAdmin.renounceRole(cancellerRole, canceller);

        assertFalse(protocolAdmin.hasRole(cancellerRole, canceller));

        vm.prank(proposer);
        protocolAdmin.renounceRole(proposerRole, proposer);

        assertFalse(protocolAdmin.hasRole(proposerRole, proposer));
        assertTrue(protocolAdmin.hasRole(proposerRole, coldProposer));
    }

    /// @dev Nobody can renounce on someone else's behalf, so this is not a route to stripping a
    ///      role the delay would otherwise protect.
    function test_recovery_nobodyCanStepDownOnAnotherAccountsBehalf() public {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();

        vm.prank(guardian);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        protocolAdmin.renounceRole(cancellerRole, canceller);

        assertTrue(protocolAdmin.hasRole(cancellerRole, canceller));
    }

    /// @dev Putting a key back is the slow direction, and deliberately so. Every grant widens the
    ///      trusted set, and there is no emergency that needs one to land without warning.
    function test_recovery_addingTheCancelPowerBackTakesTheFullDelay() public {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));

        bytes memory restore = abi.encodeCall(protocolAdmin.grantRole, (cancellerRole, canceller));
        bytes32 id = _schedule(address(protocolAdmin), restore, bytes32(0));

        vm.warp(block.timestamp + DELAY - 1);

        vm.prank(outsider);
        vm.expectRevert();
        protocolAdmin.execute(address(protocolAdmin), 0, restore, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1);

        vm.prank(outsider);
        protocolAdmin.execute(address(protocolAdmin), 0, restore, bytes32(0), bytes32(0));

        assertTrue(protocolAdmin.hasRole(cancellerRole, canceller));
        assertTrue(protocolAdmin.isOperationDone(id));
    }

    /// @dev A grant is delayed, a revocation is instant, so the honest side wins any race between
    ///      the two. This is what stops a compromised proposer from restoring its own veto faster
    ///      than the guardian can take it away.
    function test_recovery_anInstantRevocationBeatsAScheduledGrant() public {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));

        bytes memory restore = abi.encodeCall(protocolAdmin.grantRole, (cancellerRole, canceller));
        _runThroughTheDelay(address(protocolAdmin), restore, bytes32(0));
        assertTrue(protocolAdmin.hasRole(cancellerRole, canceller));

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));

        assertFalse(protocolAdmin.hasRole(cancellerRole, canceller), "the instant path takes it straight back");
    }

    /// @dev Rotating a signer set touches nothing outside this contract. The four protocol
    ///      contracts keep the same owner throughout, so no proxy moves and no wallet notices.
    function test_recovery_leavesTheProtocolContractsUntouched() public {
        address[] memory targets = _ownedContracts();

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));

        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.revokeRole, (protocolAdmin.PROPOSER_ROLE(), proposer)),
            bytes32(0)
        );

        for(uint256 i = 0; i < targets.length; ++i) {
            assertEq(Ownable2StepUpgradeable(targets[i]).owner(), address(protocolAdmin));
            assertEq(Ownable2StepUpgradeable(targets[i]).pendingOwner(), address(0));
        }
    }
}
