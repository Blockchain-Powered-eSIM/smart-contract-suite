// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Minimal view of the two-step ownership handover the protocol contracts use
interface IOwnable2Step {
    /// @notice Completes a handover the current owner already offered to the caller
    function acceptOwnership() external;

    /// @notice Address the current owner has offered ownership to, or zero
    /// @return The nominated address
    function pendingOwner() external view returns (address);
}

/// @notice Owner of the four upgradeable protocol contracts, with a delay on every change
/// @dev Replaces the single externally owned account that owns `Registry`, `LazyWalletRegistry`,
///      `DeviceWalletFactory` and `ESIMWalletFactory` today. Both wallet beacons sit under the two
///      factories, so owning the factories reaches every device wallet and every eSIM wallet.
///
///      Two ways to get an operation executed, and nothing else:
///
///      1. A proposer schedules it, the delay elapses, and anyone at all executes it. Execution is
///         open on purpose: the announcement is what the delay buys, and once the wait is served
///         there is no reason to make the protocol depend on one key still being available to
///         press the button.
///      2. A guardian executes it immediately. No wait, but the payload is still announced in the
///         same transaction, so the record of what happened is identical.
///
///      A guardian therefore bypasses the delay completely. That is the point of the role, and it
///      is also the whole risk in it: whoever holds it can do anything a proposer could do, with no
///      warning window. Hold it on a separate signer set from the proposers.
///
///      Not upgradeable, deliberately. An upgradeable owner of upgradeable contracts moves the
///      trust to whoever can upgrade it, and there is no delay left to protect that step.
contract ProtocolAdmin is TimelockController {

    /// @notice Executes an operation without waiting for the delay
    /// @dev Also granted `CANCELLER_ROLE` and `EXECUTOR_ROLE` at construction. Anyone trusted to
    ///      skip the wait is trusted to stop a scheduled operation, and holding the executor role
    ///      explicitly keeps the fast path working even if open execution is later closed off.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Shortest delay this contract will ever accept, whatever `updateDelay` was given
    /// @dev `updateDelay` takes any value including zero, and it is reachable by scheduling a call
    ///      to this contract like any other. Without a floor, one scheduled operation turns the
    ///      timelock into a plain multisig and nothing after it ever waits again. Read through
    ///      `getMinDelay`, which is what `schedule` measures against.
    uint256 public immutable minDelayFloor;

    /// @dev Operations a guardian has released for immediate execution. Set and cleared inside the
    ///      one transaction that executes them, so a value is never observable between calls.
    mapping(bytes32 id => bool released) private _releasedByGuardian;

    /// @notice A guardian released an operation from the delay
    event OperationReleased(bytes32 indexed id, address indexed guardian);

    /// @notice Ownership of a protocol contract was accepted
    event OwnershipAccepted(address indexed target);

    /// @notice The initial delay was below the floor
    error DelayBelowFloor(uint256 delay, uint256 floor);

    /// @notice No guardian was named at construction
    error NoGuardians();

    /// @notice A zero address appeared in one of the constructor role lists
    error ZeroAddress(string parameter);

    /// @notice The operation has already run
    error OperationAlreadyExecuted(bytes32 id);

    /// @notice The contract was not offered ownership of this target
    error OwnershipNotOffered(address target);

    /// @param _minDelay Delay new operations wait before they can be executed
    /// @param _minDelayFloor Shortest delay `updateDelay` can ever bring the contract down to
    /// @param _proposers Accounts that may schedule and cancel operations
    /// @param _guardians Accounts that may execute an operation immediately
    /// @dev No admin account. The zero passed to `TimelockController` leaves this contract holding
    ///      its own `DEFAULT_ADMIN_ROLE`, so granting or revoking any role is itself an operation
    ///      that has to be scheduled and waited out. Rotating the proposer set is a role change
    ///      here and never touches the protocol contracts, whose owner stays this address.
    ///
    ///      `EXECUTOR_ROLE` goes to the zero address, which `onlyRoleOrOpenRole` reads as open to
    ///      everyone. See the note on the contract for why.
    constructor(
        uint256 _minDelay,
        uint256 _minDelayFloor,
        address[] memory _proposers,
        address[] memory _guardians
    ) TimelockController(_minDelay, _proposers, new address[](0), address(0)) {
        if(_minDelay < _minDelayFloor) revert DelayBelowFloor(_minDelay, _minDelayFloor);
        if(_guardians.length == 0) revert NoGuardians();

        for(uint256 i = 0; i < _proposers.length; ++i) {
            if(_proposers[i] == address(0)) revert ZeroAddress("_proposers");
        }

        for(uint256 i = 0; i < _guardians.length; ++i) {
            address guardian = _guardians[i];
            if(guardian == address(0)) revert ZeroAddress("_guardians");

            _grantRole(GUARDIAN_ROLE, guardian);
            _grantRole(CANCELLER_ROLE, guardian);
            _grantRole(EXECUTOR_ROLE, guardian);
        }

        minDelayFloor = _minDelayFloor;
        _grantRole(EXECUTOR_ROLE, address(0));
    }

    /// @inheritdoc TimelockController
    /// @dev Held at the floor whatever `updateDelay` last wrote. `schedule` reads this rather than
    ///      the stored value, so the floor binds every new operation without needing to intercept
    ///      the setter.
    function getMinDelay() public view virtual override returns (uint256) {
        uint256 delay = super.getMinDelay();

        return delay < minDelayFloor ? minDelayFloor : delay;
    }

    /// @inheritdoc TimelockController
    /// @dev A released operation reads as ready no matter how long it has left, which is what lets
    ///      the inherited `execute` run it. An operation that already ran is never reopened: `Done`
    ///      is returned untouched, so a release cannot replay one.
    ///
    ///      `getTimestamp` is left alone and keeps returning the real value, so an operation
    ///      released and executed in one transaction still reads zero there beforehand. Nothing in
    ///      this contract or its base reads that timestamp for a decision; every guard goes through
    ///      this function.
    function getOperationState(bytes32 id) public view virtual override returns (OperationState) {
        OperationState state = super.getOperationState(id);

        if(state != OperationState.Done && _releasedByGuardian[id]) {
            return OperationState.Ready;
        }

        return state;
    }

    /// @notice Runs a single operation immediately, whether or not it was ever scheduled
    /// @param target Contract to call
    /// @param value Wei to send with the call
    /// @param payload Calldata for the call
    /// @param predecessor Operation that must be done first, or zero
    /// @param salt Disambiguates two otherwise identical operations
    function executeInstantly(
        address target,
        uint256 value,
        bytes calldata payload,
        bytes32 predecessor,
        bytes32 salt
    ) external payable onlyRole(GUARDIAN_ROLE) {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);

        _release(id);
        emit CallScheduled(id, 0, target, value, payload, predecessor, 0);

        execute(target, value, payload, predecessor, salt);

        delete _releasedByGuardian[id];
    }

    /// @notice Runs a batch immediately, whether or not it was ever scheduled
    /// @dev The batch form is the one that matters for an upgrade. Four proxies and both beacons
    ///      move in one transaction or none of them do, so the two chains cannot be left half
    ///      upgraded by a transaction that stopped landing partway through.
    /// @param targets Contracts to call, in order
    /// @param values Wei to send with each call
    /// @param payloads Calldata for each call
    /// @param predecessor Operation that must be done first, or zero
    /// @param salt Disambiguates two otherwise identical operations
    function executeBatchInstantly(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable onlyRole(GUARDIAN_ROLE) {
        if(targets.length != values.length || targets.length != payloads.length) {
            revert TimelockInvalidOperationLength(targets.length, payloads.length, values.length);
        }

        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);

        _release(id);
        for(uint256 i = 0; i < targets.length; ++i) {
            emit CallScheduled(id, i, targets[i], values[i], payloads[i], predecessor, 0);
        }

        executeBatch(targets, values, payloads, predecessor, salt);

        delete _releasedByGuardian[id];
    }

    /// @notice Completes the handover of every contract that has offered this one its ownership
    /// @dev Permissionless, and safe to be: it only takes ownership that the current owner already
    ///      offered, and the offer is the decision. Scheduling it instead would mean waiting out
    ///      the delay before this contract could own anything, including during the deployment it
    ///      is being installed by.
    ///
    ///      Each event is emitted ahead of the call it describes, so a target that emits its own
    ///      events on handover cannot interleave them out of order. A failing handover takes the
    ///      whole batch down with it, so no event here can outlive the call it announced.
    /// @param targets Contracts whose `pendingOwner` is this address
    function acceptOwnershipBatch(address[] calldata targets) external {
        for(uint256 i = 0; i < targets.length; ++i) {
            address target = targets[i];

            if(IOwnable2Step(target).pendingOwner() != address(this)) {
                revert OwnershipNotOffered(target);
            }

            emit OwnershipAccepted(target);
            IOwnable2Step(target).acceptOwnership();
        }
    }

    /// @notice Returns whether an operation is currently released from the delay
    /// @dev Only ever true partway through a guardian's own transaction, so this reads false to
    ///      every observer outside one. Present for tracing, not for callers to act on.
    function isReleased(bytes32 id) external view returns (bool) {
        return _releasedByGuardian[id];
    }

    /// @notice Marks an operation ready regardless of its delay
    function _release(bytes32 id) private {
        if(super.getOperationState(id) == OperationState.Done) {
            revert OperationAlreadyExecuted(id);
        }

        _releasedByGuardian[id] = true;
        emit OperationReleased(id, _msgSender());
    }
}
