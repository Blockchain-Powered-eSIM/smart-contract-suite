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
        assertTrue(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), coldProposer));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), proposer));

        assertTrue(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), guardian));
        assertTrue(protocolAdmin.hasRole(protocolAdmin.EXECUTOR_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), guardian));
        assertFalse(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), guardian));
    }

    /// @dev The base grants every proposer the cancel power too, which is kept: a signer set that
    ///      can start an operation can stop one. What the separate list adds is accounts that can
    ///      only stop, so one key behind a multisig vetoes alone without scheduling alone.
    function test_construction_spreadsTheCancelPowerWiderThanTheProposerSet() public view {
        bytes32 cancellerRole = protocolAdmin.CANCELLER_ROLE();

        assertTrue(protocolAdmin.hasRole(cancellerRole, proposer));
        assertTrue(protocolAdmin.hasRole(cancellerRole, coldProposer));

        address[] memory cancellers = _cancellerSet();
        for(uint256 i = 0; i < cancellers.length; ++i) {
            assertTrue(protocolAdmin.hasRole(cancellerRole, cancellers[i]));
            assertFalse(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), cancellers[i]));
        }
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
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.DelayBelowFloor.selector, 30 minutes, 1 hours));
        new ProtocolAdmin(30 minutes, 1 hours, _proposerSet(), _cancellerSet(), _guardianSet());
    }

    /// @dev Without a guardian there is no way to release a pause quickly, and no way to break a
    ///      compromised canceller loose from cancelling its own eviction.
    function test_construction_rejectsAnEmptyGuardianSet() public {
        vm.expectRevert(ProtocolAdmin.NoGuardians.selector);
        new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), _cancellerSet(), new address[](0));
    }

    /// @dev The proposers already carry the cancel power, so naming no extra accounts is a weaker
    ///      configuration rather than a broken one.
    function test_construction_acceptsAnEmptyCancellerSet() public {
        ProtocolAdmin lean =
            new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), new address[](0), _guardianSet());

        assertTrue(lean.hasRole(lean.CANCELLER_ROLE(), proposer));
        assertFalse(lean.hasRole(lean.CANCELLER_ROLE(), canceller));
    }

    function test_construction_rejectsTheZeroAddressInEveryRoleList() public {
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.ZeroAddress.selector, "_proposers"));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, new address[](1), _cancellerSet(), _guardianSet());

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.ZeroAddress.selector, "_cancellers"));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), new address[](1), _guardianSet());

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.ZeroAddress.selector, "_guardians"));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), _cancellerSet(), new address[](1));
    }

    /// @dev The separation the whole recovery story rests on, refused at construction rather than
    ///      written down. A guardian holding the cancel power could strip every other canceller,
    ///      become the only one, and cancel its own eviction for as long as it liked.
    function test_construction_rejectsAGuardianThatCanAlsoCancel() public {
        address[] memory cancellers = new address[](1);
        cancellers[0] = guardian;

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.RolesMustNotOverlap.selector, guardian));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), cancellers, _guardianSet());
    }

    /// @dev The same overlap reached the other way. A proposer already holds the cancel power, so
    ///      naming one as a guardian is the same configuration under a different spelling.
    function test_construction_rejectsAGuardianThatIsAlsoAProposer() public {
        address[] memory guardians = new address[](1);
        guardians[0] = proposer;

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.RolesMustNotOverlap.selector, proposer));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), _cancellerSet(), guardians);
    }

    /// @dev The extra canceller list is for accounts that hold nothing else. A proposer named there
    ///      would already have the role, and the duplicate is a configuration someone got wrong.
    function test_construction_rejectsACancellerThatIsAlsoAProposer() public {
        address[] memory cancellers = new address[](1);
        cancellers[0] = coldProposer;

        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.RolesMustNotOverlap.selector, coldProposer));
        new ProtocolAdmin(DELAY, DELAY_FLOOR, _proposerSet(), cancellers, _guardianSet());
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
        assertEq(registry.defaultDataBundlePriceCap(), defaultDataBundlePriceCap);

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
    /// @dev A veto needs one account acting alone, whether that account can also schedule or not.
    ///      Requiring the proposer set to agree to stop something would make the delay useless in
    ///      exactly the case it exists for, which is that set having been compromised.
    function test_cancel_worksForAProposerAndForACancellerAlike() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));

        bytes32 first = _schedule(address(registry), data, bytes32(uint256(1)));
        vm.prank(proposer);
        protocolAdmin.cancel(first);
        assertFalse(protocolAdmin.isOperation(first));

        bytes32 second = _schedule(address(registry), data, bytes32(uint256(2)));
        vm.prank(canceller);
        protocolAdmin.cancel(second);
        assertFalse(protocolAdmin.isOperation(second));

        bytes32 third = _schedule(address(registry), data, bytes32(uint256(3)));
        vm.prank(coldProposer);
        protocolAdmin.cancel(third);
        assertFalse(protocolAdmin.isOperation(third));
    }

    /// @dev The guardian is not part of the veto. It can take the cancel power away from an
    ///      account and can never use it, which is what keeps it evictable.
    function test_cancel_rejectsTheGuardian() public {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (1 ether));
        bytes32 id = _schedule(address(registry), data, bytes32(0));
        bytes32 role = protocolAdmin.CANCELLER_ROLE();

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, role)
        );
        protocolAdmin.cancel(id);
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

        assertEq(
            registry.defaultDataBundlePriceCap(),
            defaultDataBundlePriceCap,
            "the first call must not have stuck"
        );
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
