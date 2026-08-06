// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

import "test/utils/DeployerBase.sol";

/// @notice Deploys `ProtocolAdmin` and hands it the four upgradeable contracts.
/// @dev This is the state the protocol is meant to be in once the single owning account is
///      retired: one contract owns `Registry`, `LazyWalletRegistry`, `DeviceWalletFactory` and
///      `ESIMWalletFactory`, and the two wallet beacons follow from the factories.
///
///      The handover runs the way a real one would. The outgoing owner offers each contract, then
///      the admin takes all four in a single `acceptOwnershipBatch`, so nothing here depends on a
///      shortcut the deployment could not take.
abstract contract AdminBase is DeployerBase {

    uint256 internal constant DELAY = 2 days;
    uint256 internal constant DELAY_FLOOR = 1 hours;

    /// @dev Stands in for the multisig. Every test that schedules something signs as this address.
    address internal proposer = address(0x50505Ea1b0f47F9B1A54f2D2F0e0EA3aA0E63c5f);

    /// @dev Held separately from the proposer on purpose. A guardian skips the delay entirely, so
    ///      a test that passes only because one address holds both roles proves nothing.
    address internal guardian = address(0x6d0A11a0F47f9B1a54f2d2F0E0EA3AA0E63C5f01);

    /// @dev Holds no role at all. Used to prove open execution really is open, and that everything
    ///      else really is closed.
    address internal outsider = address(0x0175106E1b0F47F9b1A54f2d2F0E0ea3aA0e63C5);

    ProtocolAdmin internal protocolAdmin;

    function setUp() public virtual override {
        super.setUp();

        // The timelock adds a delay to the current time and Foundry starts the clock at 1, which
        // would put every scheduled operation in the first two days of the epoch.
        vm.warp(1_800_000_000);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory guardians = new address[](1);
        guardians[0] = guardian;

        protocolAdmin = new ProtocolAdmin(DELAY, DELAY_FLOOR, proposers, guardians);

        _handOverOwnership();
    }

    /// @notice Moves all four contracts from the deploying account to the admin contract
    function _handOverOwnership() internal {
        address[] memory targets = _ownedContracts();

        vm.startPrank(upgradeManager);
        for(uint256 i = 0; i < targets.length; ++i) {
            Ownable2StepUpgradeable(targets[i]).transferOwnership(address(protocolAdmin));
        }
        vm.stopPrank();

        protocolAdmin.acceptOwnershipBatch(targets);
    }

    /// @notice The four contracts whose owner the admin contract holds
    function _ownedContracts() internal view returns (address[] memory) {
        address[] memory targets = new address[](4);
        targets[0] = address(registry);
        targets[1] = address(lazyWalletRegistry);
        targets[2] = address(deviceWalletFactory);
        targets[3] = address(eSIMWalletFactory);

        return targets;
    }

    /// @notice Schedules one call at the current minimum delay
    /// @dev The delay is read before the prank rather than inside the call. Arguments are
    ///      evaluated first, so a view call in the argument list is what `vm.prank` would apply to.
    /// @return id The operation identifier
    function _schedule(
        address _target,
        bytes memory _data,
        bytes32 _salt
    ) internal returns (bytes32 id) {
        uint256 delay = protocolAdmin.getMinDelay();

        vm.prank(proposer);
        protocolAdmin.schedule(_target, 0, _data, bytes32(0), _salt, delay);

        return protocolAdmin.hashOperation(_target, 0, _data, bytes32(0), _salt);
    }

    /// @notice Schedules one call, waits it out, and executes it as an account holding no role
    /// @dev Executed by `outsider` rather than the proposer, so every use of this helper is also a
    ///      check that execution stayed open once the delay was served.
    function _runThroughTheDelay(address _target, bytes memory _data, bytes32 _salt) internal {
        _schedule(_target, _data, _salt);

        vm.warp(block.timestamp + protocolAdmin.getMinDelay());

        vm.prank(outsider);
        protocolAdmin.execute(_target, 0, _data, bytes32(0), _salt);
    }

    /// @notice Runs one call immediately as the guardian
    function _runInstantly(address _target, bytes memory _data, bytes32 _salt) internal {
        vm.prank(guardian);
        protocolAdmin.executeInstantly(_target, 0, _data, bytes32(0), _salt);
    }

    /// @notice Wraps a single call into the array shape the batch entry points take
    function _single(
        address _target,
        bytes memory _data
    ) internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads) {
        targets = new address[](1);
        values = new uint256[](1);
        payloads = new bytes[](1);

        targets[0] = _target;
        values[0] = 0;
        payloads[0] = _data;
    }
}
