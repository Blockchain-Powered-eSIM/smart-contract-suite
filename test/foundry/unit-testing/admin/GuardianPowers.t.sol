// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Stands in for a pausable contract added after this deployment.
/// @dev The guardian's unpause takes a target rather than being pinned to the registry, so a
///      contract that does not exist yet is reachable without a new admin contract. This is the
///      contract that does not exist yet.
contract MockPausable {

    bool public paused = true;

    function unpause() external {
        paused = false;
    }
}

/// @notice Everything a guardian can do, and the much longer list of what it cannot.
/// @dev The role holds two powers and no general fast path. Half of this file is the second half of
///      that sentence: a guardian that could schedule, cancel, or run an arbitrary payload would
///      make every other guarantee in the contract advisory.
contract GuardianPowersTest is AdminBase {

    /// @dev The reason the role exists. The admin key trips the pause and the owner clears it, so
    ///      without a way around the delay a release would be a two day outage.
    function test_unpauseInstantly_releasesAPauseWithoutWaiting() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();
        assertTrue(registry.paused());

        uint256 before = block.timestamp;

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(registry));

        assertFalse(registry.paused());
        assertEq(block.timestamp, before, "no time may have passed");
    }

    function test_unpauseInstantly_emitsTheRelease() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();

        vm.expectEmit(true, true, false, true, address(protocolAdmin));
        emit ProtocolAdmin.PauseReleased(address(registry), guardian);

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(registry));
    }

    /// @dev The target is a parameter, so a pausable contract this deployment has never heard of is
    ///      still reachable. The selector is not a parameter, which is what keeps that safe.
    function test_unpauseInstantly_reachesAContractAddedLater() public {
        MockPausable later = new MockPausable();

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(later));

        assertFalse(later.paused());
    }

    /// @dev Releasing a pause that is not there changes nothing and is not worth a revert. The
    ///      guardian acting on stale information is the normal case during an incident.
    function test_unpauseInstantly_isHarmlessWhenNothingIsPaused() public {
        assertFalse(registry.paused());

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(registry));

        assertFalse(registry.paused());
    }

    function test_unpauseInstantly_revertsOnATargetWithNoCode() public {
        vm.prank(guardian);
        vm.expectRevert();
        protocolAdmin.unpauseInstantly(outsider);
    }

    function test_unpauseInstantly_rejectsAnAccountWithoutTheGuardianRole() public {
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        protocolAdmin.unpauseInstantly(address(registry));
    }

    /// @dev The proposer holds the other half of the split and must not be able to take both.
    function test_unpauseInstantly_rejectsTheProposer() public {
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, proposer, role)
        );
        protocolAdmin.unpauseInstantly(address(registry));
    }

    function test_unpauseInstantly_rejectsACanceller() public {
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(canceller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, canceller, role)
        );
        protocolAdmin.unpauseInstantly(address(registry));
    }

    /// @dev The power that breaks a compromised canceller loose. Without it, evicting one means a
    ///      scheduled operation, and the account being evicted can cancel that operation forever.
    function test_revokeCancellersInstantly_takesTheVetoAway() public {
        bytes32 id = _schedule(address(registry), abi.encodeCall(registry.unpause, ()), bytes32(0));

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(canceller));

        assertFalse(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), canceller));

        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();

        vm.prank(canceller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, canceller, cancellerRole
            )
        );
        protocolAdmin.cancel(id);
    }

    function test_revokeCancellersInstantly_emitsOnePerAccount() public {
        address[] memory accounts = new address[](2);
        accounts[0] = canceller;
        accounts[1] = secondCanceller;

        vm.expectEmit(true, true, false, true, address(protocolAdmin));
        emit ProtocolAdmin.CancellerRevoked(canceller, guardian);
        vm.expectEmit(true, true, false, true, address(protocolAdmin));
        emit ProtocolAdmin.CancellerRevoked(secondCanceller, guardian);

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(accounts);
    }

    /// @dev The recovery sequence in one test. A compromised signer set holds the role through the
    ///      multisig and through each key behind it, and all of them go in one transaction because
    ///      the eviction that follows is racing whatever the attacker scheduled.
    function test_revokeCancellersInstantly_stripsAWholeSignerSetAtOnce() public {
        address[] memory accounts = new address[](4);
        accounts[0] = proposer;
        accounts[1] = canceller;
        accounts[2] = secondCanceller;
        accounts[3] = thirdCanceller;

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(accounts);

        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();
        for(uint256 i = 0; i < accounts.length; ++i) {
            assertFalse(protocolAdmin.hasRole(cancellerRole, accounts[i]));
        }
    }

    /// @dev Stripping the veto must not strip the ability to schedule. A proposer that lost both
    ///      would be one revocation away from a protocol nobody can ever schedule anything for.
    function test_revokeCancellersInstantly_leavesTheProposerRoleAlone() public {
        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(proposer));

        assertFalse(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), proposer));
        assertTrue(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), proposer));

        _schedule(address(registry), abi.encodeCall(registry.unpause, ()), bytes32(0));
    }

    /// @dev Zero cancellers is a legal state. It costs the veto and a proposer can schedule the
    ///      role back, which is exactly why this revocation is safe to make instant and revoking a
    ///      proposer would not be.
    function test_revokeCancellersInstantly_mayLeaveNoCancellersAtAll() public {
        address[] memory accounts = new address[](5);
        accounts[0] = proposer;
        accounts[1] = coldProposer;
        accounts[2] = canceller;
        accounts[3] = secondCanceller;
        accounts[4] = thirdCanceller;

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(accounts);

        bytes32 id = _schedule(address(registry), abi.encodeCall(registry.unpause, ()), bytes32(0));
        assertTrue(protocolAdmin.isOperationPending(id), "a proposer can still schedule");
    }

    function test_revokeCancellersInstantly_rejectsAnAccountThatNeverHeldTheRole() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.NotACanceller.selector, outsider));
        protocolAdmin.revokeCancellersInstantly(_one(outsider));
    }

    /// @dev All or nothing. A guardian working from a named list during an incident must not be
    ///      told the batch succeeded when one of the accounts on it still holds the veto.
    function test_revokeCancellersInstantly_revertsTheWholeBatchOnOneBadAccount() public {
        address[] memory accounts = new address[](2);
        accounts[0] = canceller;
        accounts[1] = outsider;

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.NotACanceller.selector, outsider));
        protocolAdmin.revokeCancellersInstantly(accounts);

        assertTrue(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), canceller));
    }

    /// @dev Naming the same account twice is the second entry failing, not a silent pass.
    function test_revokeCancellersInstantly_rejectsARepeatedAccount() public {
        address[] memory accounts = new address[](2);
        accounts[0] = canceller;
        accounts[1] = canceller;

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.NotACanceller.selector, canceller));
        protocolAdmin.revokeCancellersInstantly(accounts);
    }

    function test_revokeCancellersInstantly_rejectsAnAccountWithoutTheGuardianRole() public {
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, role)
        );
        protocolAdmin.revokeCancellersInstantly(_one(canceller));
    }

    /// @dev A canceller stripping the other cancellers would be the same un-evictable position the
    ///      guardian is kept out of, reached from the other side.
    function test_revokeCancellersInstantly_rejectsACanceller() public {
        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(canceller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, canceller, role)
        );
        protocolAdmin.revokeCancellersInstantly(_one(secondCanceller));
    }

    /// @dev The separation the constructor enforces, read back from the deployed state. A guardian
    ///      holding the cancel power could revoke every other canceller, become the only one, and
    ///      then cancel its own eviction for as long as it liked.
    function test_guardian_holdsNeitherOfTheRolesItActsAgainst() public view {
        assertFalse(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), guardian));
    }

    function test_guardian_cannotSchedule() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        uint256 delay = protocolAdmin.getMinDelay();
        bytes32 role = protocolAdmin.PROPOSER_ROLE();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, role)
        );
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), delay);
    }

    function test_guardian_cannotCancel() public {
        bytes32 id = _schedule(address(registry), abi.encodeCall(registry.unpause, ()), bytes32(0));
        bytes32 role = protocolAdmin.CANCELLER_ROLE();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, role)
        );
        protocolAdmin.cancel(id);
    }

    function test_guardian_cannotGrantItselfAnythingDirectly() public {
        bytes32 role = protocolAdmin.PROPOSER_ROLE();
        bytes32 adminRole = protocolAdmin.DEFAULT_ADMIN_ROLE();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, adminRole
            )
        );
        protocolAdmin.grantRole(role, guardian);
    }

    /// @dev The guardian holds the executor role in its own right, so closing open execution does
    ///      not also close the route it would use during an incident.
    function test_guardian_canStillExecuteOnceOpenExecutionIsClosed() public {
        bytes32 executorRole = protocolAdmin.EXECUTOR_ROLE();

        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.revokeRole, (executorRole, address(0))),
            bytes32(uint256(1))
        );

        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (4 ether));
        _schedule(address(registry), data, bytes32(uint256(2)));
        vm.warp(block.timestamp + DELAY);

        vm.prank(guardian);
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(uint256(2)));

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
}
