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
///      The signer sets mirror the intended deployment rather than the smallest thing that would
///      compile, because most of what is worth testing here is which account can reach which call.
///      Two proposers, one standing in for a multisig and one for a cold key that exists so a
///      compromised multisig is not the end of governance. Three cancellers holding nothing else,
///      standing in for the individual keys behind that multisig, so one of them can veto alone
///      without being able to schedule alone. One guardian, holding neither.
///
///      The handover runs the way a real one would. The outgoing owner offers each contract, then
///      the admin takes all four in a single `acceptOwnershipBatch`, so nothing here depends on a
///      shortcut the deployment could not take.
abstract contract AdminBase is DeployerBase {

    uint256 internal constant DELAY = 2 days;
    uint256 internal constant DELAY_FLOOR = 1 hours;

    /// @dev Stands in for the multisig. Every test that schedules something signs as this address.
    address internal proposer;

    /// @dev The backup. Never used in routine work, and the only thing standing between a
    ///      compromised `proposer` and a protocol nobody can ever schedule anything for again.
    address internal coldProposer;

    /// @dev Cancel and nothing else, the three keys behind `proposer`. Held apart because a
    ///      canceller that could also schedule would make the veto meaningless as a separation.
    address internal canceller;
    address internal secondCanceller;
    address internal thirdCanceller;

    /// @dev Holds neither of the above, which the constructor enforces. A guardian that could
    ///      cancel would be able to strip every other canceller, become the only one, and then
    ///      cancel its own eviction forever.
    address internal guardian;

    /// @dev Holds no role at all. Used to prove open execution really is open, and that everything
    ///      else really is closed.
    address internal outsider;

    ProtocolAdmin internal protocolAdmin;

    function setUp() public virtual override {
        super.setUp();

        // The timelock adds a delay to the current time and Foundry starts the clock at 1, which
        // would put every scheduled operation in the first two days of the epoch.
        vm.warp(1_800_000_000);

        proposer = makeAddr("proposer");
        coldProposer = makeAddr("coldProposer");
        canceller = makeAddr("canceller");
        secondCanceller = makeAddr("secondCanceller");
        thirdCanceller = makeAddr("thirdCanceller");
        guardian = makeAddr("guardian");
        outsider = makeAddr("outsider");

        protocolAdmin = new ProtocolAdmin(
            DELAY,
            DELAY_FLOOR,
            _proposerSet(),
            _cancellerSet(),
            _guardianSet()
        );

        _handOverOwnership();
    }

    /// @notice The two accounts that may schedule, and that the base also gives the cancel power
    function _proposerSet() internal view returns (address[] memory proposers) {
        proposers = new address[](2);
        proposers[0] = proposer;
        proposers[1] = coldProposer;
    }

    /// @notice The three accounts that may only cancel
    function _cancellerSet() internal view returns (address[] memory cancellers) {
        cancellers = new address[](3);
        cancellers[0] = canceller;
        cancellers[1] = secondCanceller;
        cancellers[2] = thirdCanceller;
    }

    /// @notice The one account that may release a pause and strip a canceller
    function _guardianSet() internal view returns (address[] memory guardians) {
        guardians = new address[](1);
        guardians[0] = guardian;
    }

    /// @notice A second admin contract holding the same signer sets
    /// @dev What retiring this one looks like. The four contracts move to the replacement through
    ///      the ordinary two step handover, so the test is the migration rather than a shortcut.
    /// @param _delay Delay the replacement starts with
    function _deployReplacement(uint256 _delay) internal returns (ProtocolAdmin) {
        return new ProtocolAdmin(_delay, DELAY_FLOOR, _proposerSet(), _cancellerSet(), _guardianSet());
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

    /// @notice Wraps a single address into the array shape `revokeCancellersInstantly` takes
    function _one(address _account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = _account;
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
