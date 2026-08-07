// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IOwnable2Step} from "../interfaces/IOwnable2Step.sol";
import {IPausable} from "../interfaces/IPausable.sol";

/// @notice Owner of the four upgradeable protocol contracts, with a delay on every change
/// @dev Replaces the single externally owned account that owns `Registry`, `LazyWalletRegistry`,
///      `DeviceWalletFactory` and `ESIMWalletFactory` today. Both wallet beacons sit under the two
///      factories, so owning the factories reaches every device wallet and every eSIM wallet.
///
///      Everything this contract can do to the protocol goes one way: a proposer schedules it, the
///      delay elapses, and anyone at all executes it. Execution is open on purpose. The
///      announcement is what the delay buys, and once the wait is served there is no reason to make
///      the protocol depend on one key still being available to press the button.
///
///      A guardian does not get a general fast path. It can say exactly two things, and both are
///      written here as their own functions rather than as payloads, so no third sentence is
///      expressible however the role is held:
///
///      1. Release a pause. An upgrade that waits is reviewable; an outage that waits is an outage.
///      2. Take `CANCELLER_ROLE` away from an account.
///
///      The second one exists because without it a compromised canceller is permanent. Evicting any
///      role holder means scheduling `revokeRole`, a scheduled operation can be cancelled by any
///      canceller, and so a compromised canceller cancels its own eviction forever. Nothing else can
///      break that loop, because the delay is what every other route waits on.
///
///      Two limits on that power carry the whole recovery argument, and both are enforced rather
///      than documented. A guardian may not hold `CANCELLER_ROLE` itself, or it could revoke every
///      other canceller, become the only one, and cancel its own eviction. And it may not touch
///      `PROPOSER_ROLE`, because reaching zero proposers is unrecoverable: re-granting any role
///      needs a scheduled operation, scheduling needs a proposer, and `Registry.unpause` is owner
///      only, so a bricked admin plus a pause is a pause nobody can ever release. Reaching zero
///      cancellers is fine by comparison. It costs the veto, and a proposer can schedule it back.
///
///      Not upgradeable, deliberately. An upgradeable owner of upgradeable contracts moves the
///      trust to whoever can upgrade it, and there is no delay left to protect that step.
contract ProtocolAdmin is TimelockController {

    /// @notice Releases a pause and strips a canceller, both without waiting for the delay
    /// @dev Also granted `EXECUTOR_ROLE` at construction, which keeps the role useful if open
    ///      execution is ever closed off. Deliberately not granted `CANCELLER_ROLE`; see the note on
    ///      the contract for why that pairing is what makes a guardian un-evictable.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Shortest delay this contract will ever accept, whatever `updateDelay` was given
    /// @dev `updateDelay` takes any value including zero, and it is reachable by scheduling a call
    ///      to this contract like any other. Without a floor, one scheduled operation turns the
    ///      timelock into a plain multisig and nothing after it ever waits again. Read through
    ///      `getMinDelay`, which is what `schedule` measures against.
    uint256 public immutable minDelayFloor;

    /// @notice A guardian released a pause
    event PauseReleased(address indexed target, address indexed guardian);

    /// @notice A guardian took the cancel power away from an account
    event CancellerRevoked(address indexed account, address indexed guardian);

    /// @notice Ownership of a protocol contract was accepted
    event OwnershipAccepted(address indexed target);

    /// @notice The initial delay was below the floor
    error DelayBelowFloor(uint256 delay, uint256 floor);

    /// @notice No guardian was named at construction
    error NoGuardians();

    /// @notice A zero address appeared in one of the constructor role lists
    error ZeroAddress(string parameter);

    /// @notice An account was named in two role lists that have to stay separate
    error RolesMustNotOverlap(address account);

    /// @notice The account named does not hold the cancel power
    error NotACanceller(address account);

    /// @notice The contract was not offered ownership of this target
    error OwnershipNotOffered(address target);

    /// @param _initialDelay Delay new operations wait before they can be executed
    /// @param _minDelayFloor Shortest delay `updateDelay` can ever bring the contract down to
    /// @param _proposers Accounts that may schedule operations, and that may also cancel them
    /// @param _cancellers Further accounts that may cancel, holding no other role
    /// @param _guardians Accounts that may release a pause and strip a canceller
    /// @dev No admin account. The zero passed to `TimelockController` leaves this contract holding
    ///      its own `DEFAULT_ADMIN_ROLE`, so granting or revoking any role is itself an operation
    ///      that has to be scheduled and waited out. Rotating a signer set is a role change here and
    ///      never touches the protocol contracts, whose owner stays this address.
    ///
    ///      The base constructor gives every proposer `CANCELLER_ROLE` as well, which is kept.
    ///      `_cancellers` is for the accounts that cancel and do nothing else, typically the
    ///      individual keys behind a proposer multisig, so that one key can veto on its own without
    ///      being able to schedule anything on its own.
    ///
    ///      `EXECUTOR_ROLE` goes to the zero address, which `onlyRoleOrOpenRole` reads as open to
    ///      everyone. See the note on the contract for why.
    ///
    ///      An empty `_cancellers` is allowed, since the proposers already carry the role. An empty
    ///      `_guardians` is not: there would be no way to add one without the delay it exists to
    ///      skip, and no way at all to break a compromised canceller loose.
    constructor(
        uint256 _initialDelay,
        uint256 _minDelayFloor,
        address[] memory _proposers,
        address[] memory _cancellers,
        address[] memory _guardians
    ) TimelockController(_initialDelay, _proposers, new address[](0), address(0)) {
        if(_initialDelay < _minDelayFloor) revert DelayBelowFloor(_initialDelay, _minDelayFloor);
        if(_guardians.length == 0) revert NoGuardians();

        for(uint256 i = 0; i < _proposers.length; ++i) {
            if(_proposers[i] == address(0)) revert ZeroAddress("_proposers");
        }

        for(uint256 i = 0; i < _cancellers.length; ++i) {
            address canceller = _cancellers[i];
            if(canceller == address(0)) revert ZeroAddress("_cancellers");
            if(hasRole(PROPOSER_ROLE, canceller)) revert RolesMustNotOverlap(canceller);

            _grantRole(CANCELLER_ROLE, canceller);
        }

        for(uint256 i = 0; i < _guardians.length; ++i) {
            address guardian = _guardians[i];
            if(guardian == address(0)) revert ZeroAddress("_guardians");
            if(hasRole(CANCELLER_ROLE, guardian)) revert RolesMustNotOverlap(guardian);

            _grantRole(GUARDIAN_ROLE, guardian);
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

    /// @notice Releases a pause on a protocol contract immediately
    /// @dev The selector is fixed in the interface rather than passed in, so this cannot be pointed
    ///      at anything else on the target. Whatever a guardian does here, the worst outcome
    ///      reachable is that something is unpaused which someone wanted paused, and the key that
    ///      applies a pause is not this one and can simply apply it again.
    /// @param target Contract to unpause
    function unpauseInstantly(address target) external onlyRole(GUARDIAN_ROLE) {
        emit PauseReleased(target, _msgSender());

        IPausable(target).unpause();
    }

    /// @notice Takes the cancel power away from accounts immediately
    /// @dev Only `CANCELLER_ROLE`, never anything else, and adding it back is an ordinary scheduled
    ///      operation. A batch because the account being evicted is usually one signer set holding
    ///      the role several times over, and doing that in one transaction rather than several is
    ///      the difference between the eviction landing and the operation it is racing landing
    ///      first.
    ///
    ///      All or nothing, and an account that does not hold the role reverts rather than passing
    ///      quietly. A guardian doing this is acting on a named list during an incident, and a
    ///      silent no-op would leave it believing a veto is gone while the veto is still there.
    /// @param accounts Accounts to strip
    function revokeCancellersInstantly(address[] calldata accounts) external onlyRole(GUARDIAN_ROLE) {
        for(uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];

            if(!_revokeRole(CANCELLER_ROLE, account)) revert NotACanceller(account);

            emit CancellerRevoked(account, _msgSender());
        }
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
}
