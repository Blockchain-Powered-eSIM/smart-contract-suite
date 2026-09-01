// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/AdminBase.sol";

/// @notice Sweeps the admin contract across arbitrary callers, delays, salts and batch shapes.
/// @dev The unit tests pin the paths that matter at fixed values. What is left for a sweep is the
///      boundary between them: exactly when a delay is long enough, which accounts the role checks
///      really turn away, and whether an operation identifier can be made to collide.
contract AdminOperationsFuzzTest is AdminBase {

    /// @dev Batches are capped well below anything gas would allow. The shape is what is being
    ///      fuzzed, not the size, and a long batch only makes each run slower.
    uint256 private constant MAX_FUZZED_BATCH = 8;

    /// @notice Only the proposer set may schedule, whoever else asks
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_schedule_turnsAwayEveryAccountOutsideTheProposerSet(address _caller) public {
        vm.assume(_caller != proposer && _caller != coldProposer);

        bytes memory data = abi.encodeCall(registry.setDefaultPriceCapUSDCents, (1 ether));
        bytes32 role = protocolAdmin.PROPOSER_ROLE();

        vm.prank(_caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, role)
        );
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
    }

    /// @notice Only a guardian may release a pause, whoever else asks
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_unpauseInstantly_turnsAwayEveryAccountOutsideTheGuardianSet(address _caller) public {
        vm.assume(_caller != guardian);

        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(_caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, role)
        );
        protocolAdmin.unpauseInstantly(address(registry));
    }

    /// @notice Only a guardian may strip a canceller, whoever else asks
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_revokeCancellers_turnsAwayEveryAccountOutsideTheGuardianSet(address _caller) public {
        vm.assume(_caller != guardian);

        bytes32 role = protocolAdmin.GUARDIAN_ROLE();

        vm.prank(_caller);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, role)
        );
        protocolAdmin.revokeCancellersInstantly(_one(canceller));
    }

    /// @notice Execution is open to every account once the wait is served
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_execute_acceptsAnyCallerOnceTheDelayHasPassed(address _caller, uint64 _cap) public {
        // A precompile or the cheatcode address as msg.sender is a test harness artefact
        vm.assume(uint160(_caller) > 0x0a);
        vm.assume(_caller != address(vm));

        uint64 cap = uint64(bound(_cap, 1, type(uint64).max));
        bytes memory data = abi.encodeCall(registry.setDefaultPriceCapUSDCents, (cap));
        _schedule(address(registry), data, bytes32(0));

        vm.warp(block.timestamp + DELAY);

        vm.prank(_caller);
        protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));

        assertEq(registry.defaultPriceCapUSDCents(), cap);
    }

    /// @notice An operation is executable at its ready time and not one second before
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_execute_holdsUntilExactlyTheReadyTime(uint256 _delay, uint256 _wait) public {
        uint256 delay = bound(_delay, protocolAdmin.getMinDelay(), 365 days);
        uint256 wait = bound(_wait, 0, delay + 1 days);

        bytes memory data = abi.encodeCall(registry.setDefaultPriceCapUSDCents, (1 ether));

        vm.prank(proposer);
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), delay);

        uint256 readyAt = block.timestamp + delay;
        vm.warp(block.timestamp + wait);

        if(block.timestamp < readyAt) {
            vm.prank(outsider);
            vm.expectRevert();
            protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));
        } else {
            vm.prank(outsider);
            protocolAdmin.execute(address(registry), 0, data, bytes32(0), bytes32(0));
            assertEq(registry.defaultPriceCapUSDCents(), 1 ether);
        }
    }

    /// @notice No delay under the floor is ever accepted, and every one at or above it is
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_schedule_acceptsExactlyTheDelaysAtOrAboveTheFloor(uint256 _delay) public {
        uint256 delay = bound(_delay, 0, 30 days);
        bytes memory data = abi.encodeCall(registry.setDefaultPriceCapUSDCents, (1 ether));
        uint256 floor = protocolAdmin.getMinDelay();

        vm.prank(proposer);
        if(delay < floor) {
            vm.expectRevert(
                abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, delay, floor)
            );
        }
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), delay);
    }

    /// @notice The floor holds whatever `updateDelay` was given
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_updateDelay_neverBringsTheEffectiveDelayBelowTheFloor(uint256 _newDelay) public {
        uint256 newDelay = bound(_newDelay, 0, 3650 days);

        _runThroughTheDelay(
            address(protocolAdmin),
            abi.encodeCall(protocolAdmin.updateDelay, (newDelay)),
            bytes32(0)
        );

        assertGe(protocolAdmin.getMinDelay(), DELAY_FLOOR);
        assertEq(protocolAdmin.getMinDelay(), newDelay < DELAY_FLOOR ? DELAY_FLOOR : newDelay);
    }

    /// @notice A salt separates two otherwise identical operations, and only a repeated one collides
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_salt_separatesOtherwiseIdenticalOperations(bytes32 _first, bytes32 _second) public {
        bytes memory data = abi.encodeCall(registry.setDefaultPriceCapUSDCents, (1 ether));

        _schedule(address(registry), data, _first);

        uint256 delay = protocolAdmin.getMinDelay();
        vm.prank(proposer);
        if(_second == _first) {
            vm.expectRevert();
        }
        protocolAdmin.schedule(address(registry), 0, data, bytes32(0), _second, delay);
    }

    /// @notice Whatever the batch looks like, it applies whole or not at all
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_executeBatch_appliesEveryCapInOrder(uint64[] calldata _caps) public {
        vm.assume(_caps.length > 0);
        uint256 count = _caps.length < MAX_FUZZED_BATCH ? _caps.length : MAX_FUZZED_BATCH;

        uint64[] memory caps = new uint64[](count);
        for(uint256 i = 0; i < count; ++i) {
            caps[i] = uint64(bound(_caps[i], 1, type(uint64).max));
        }

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _capBatch(caps, count);

        vm.prank(proposer);
        protocolAdmin.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY);

        vm.prank(outsider);
        protocolAdmin.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(registry.defaultPriceCapUSDCents(), caps[count - 1], "the last call must win");
    }

    /// @notice Nothing a guardian names loses anything but the cancel power
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_revokeCancellers_neverReachesAnotherRole(uint256 _seed) public {
        address[] memory candidates = _cancellerSet();
        address account = candidates[_seed % candidates.length];

        bool wasProposer = protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), account);
        bool wasGuardian = protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), account);

        vm.prank(guardian);
        protocolAdmin.revokeCancellersInstantly(_one(account));

        assertFalse(protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), account));
        assertEq(protocolAdmin.hasRole(protocolAdmin.PROPOSER_ROLE(), account), wasProposer);
        assertEq(protocolAdmin.hasRole(protocolAdmin.GUARDIAN_ROLE(), account), wasGuardian);
        assertTrue(protocolAdmin.hasRole(protocolAdmin.DEFAULT_ADMIN_ROLE(), address(protocolAdmin)));
    }

    /// @notice An account that never held the cancel power is refused rather than passed over
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_revokeCancellers_refusesAnyAccountWithoutTheRole(address _account) public {
        vm.assume(!protocolAdmin.hasRole(protocolAdmin.CANCELLER_ROLE(), _account));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(ProtocolAdmin.NotACanceller.selector, _account));
        protocolAdmin.revokeCancellersInstantly(_one(_account));
    }

    /// @notice The guardian's unpause can never reach a second selector on its target
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_unpauseInstantly_leavesEveryOtherRegistrySettingAlone(uint64 _cap) public {
        uint64 cap = uint64(bound(_cap, 1, type(uint64).max));

        _runThroughTheDelay(
            address(registry),
            abi.encodeCall(registry.setDefaultPriceCapUSDCents, (cap)),
            bytes32(0)
        );

        vm.prank(eSIMWalletAdmin);
        registry.pause();

        vm.prank(guardian);
        protocolAdmin.unpauseInstantly(address(registry));

        assertFalse(registry.paused());
        assertEq(registry.defaultPriceCapUSDCents(), cap, "only the pause may have moved");
        assertEq(registry.owner(), address(protocolAdmin));
    }

    /// @notice Ownership only ever moves to an address that was offered it
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_accept_refusesEveryTargetThatOfferedNothing(address _target) public {
        vm.assume(_target != address(0));

        address[] memory targets = new address[](1);
        targets[0] = _target;

        vm.expectRevert();
        protocolAdmin.acceptOwnershipBatch(targets);

        assertEq(registry.owner(), address(protocolAdmin));
    }

    /// @dev Split out because building the arrays and asserting on them together runs the stack up.
    function _capBatch(
        uint64[] memory _caps,
        uint256 _count
    ) private view returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        targets = new address[](_count);
        values = new uint256[](_count);
        payloads = new bytes[](_count);

        for(uint256 i = 0; i < _count; ++i) {
            targets[i] = address(registry);
            payloads[i] = abi.encodeCall(registry.setDefaultPriceCapUSDCents, (_caps[i]));
        }
    }
}
