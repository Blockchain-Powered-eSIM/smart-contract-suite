// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IOwnable2Step} from "../interfaces/IOwnable2Step.sol";
import {IPausable} from "../interfaces/IPausable.sol";
import {IRegistryAdmin} from "../interfaces/IRegistryAdmin.sol";

// Contracts
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Owner of the five upgradeable protocol contracts, with a delay on every change
/// @dev Owns `Registry`, `LazyWalletRegistry`, `DeviceWalletFactory`, `ESIMWalletFactory` and
///      `PaymentAdapter` once `TransferOwnership.s.sol` has run, and through the factories both
///      wallet beacons.
///
///      Proposers schedule, the delay runs, then anyone may execute, so no single key has to stay
///      available. The delay is the safeguard.
///
///      A guardian has exactly four powers, each its own function so nothing else is expressible:
///      1. Raise a pause, which still works while the admin key is suspended.
///      2. Release a pause, since an outage should not wait out the delay.
///      3. Strip `CANCELLER_ROLE`. Without it a canceller can cancel its own eviction forever.
///      4. Suspend the admin key.
///      None grants anything, and restoring a canceller or admin waits, so taking power away wins.
///
///      A guardian may not hold `CANCELLER_ROLE`, or it could become the only canceller. It may not
///      touch `PROPOSER_ROLE`: with no proposers, nothing can ever be scheduled again.
///
///      Known limit: a rogue guardian plus a rogue proposer can strip every canceller. Keep their
///      Safes on disjoint signers and alert on `CancellerRevoked`.
///
///      Not upgradeable: an upgradeable owner would move the trust to whoever can upgrade it.
contract ProtocolAdmin is TimelockController {

    /// @notice Raises and releases a pause, strips a canceller and suspends the admin, all without
    ///         waiting for the delay
    /// @dev Always paired with `EXECUTOR_ROLE`, so it still works if open execution is closed.
    ///      Never paired with `CANCELLER_ROLE`, which would make a guardian impossible to evict.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Shortest delay this contract will ever accept, whatever `updateDelay` was given
    /// @dev `updateDelay` accepts zero, so without a floor one scheduled call would remove the
    ///      delay for good. Applied through `getMinDelay`, which `schedule` checks against.
    uint256 public immutable minDelayFloor;

    /// @notice A guardian raised a pause
    event PauseRaised(address indexed target, address indexed guardian);

    /// @notice A guardian released a pause
    event PauseReleased(address indexed target, address indexed guardian);

    /// @notice A guardian took the cancel power away from an account
    event CancellerRevoked(address indexed account, address indexed guardian);

    /// @notice A guardian suspended a protocol contract's admin key
    event AdminDisabled(address indexed target, address indexed guardian);

    /// @notice A scheduled operation suspended an admin key and nominated its replacement
    event AdminDisabledAndNominated(address indexed target, address indexed newAdmin);

    /// @notice Ownership of a protocol contract was accepted
    event OwnershipAccepted(address indexed target);

    /// @notice The initial delay was below the floor
    error DelayBelowFloor(uint256 delay, uint256 floor);

    /// @notice No guardian was named at construction
    error NoGuardians();

    /// @notice No proposer was named at construction
    error NoProposers();

    /// @notice A zero address appeared in one of the constructor role lists
    error ZeroAddress(string parameter);

    /// @notice An account was named in two role lists that have to stay separate
    error RolesMustNotOverlap(address account);

    /// @notice The account named does not hold the cancel power
    error NotACanceller(address account);

    /// @notice The contract was not offered ownership of this target
    error OwnershipNotOffered(address target);

    /// @notice A replacement nomination named the admin already on the books
    error NomineeIsTheIncumbent(address target, address admin);

    /// @notice Sets up the timelock's roles and delay bounds
    /// @param _initialDelay Delay new operations wait before they can be executed
    /// @param _minDelayFloor Shortest delay `updateDelay` can ever bring the contract down to
    /// @param _proposers Accounts that may schedule operations, and that may also cancel them
    /// @param _cancellers Further accounts that may cancel, holding no other role
    /// @param _guardians Accounts holding the four guardian powers
    /// @dev No admin account: this contract holds its own `DEFAULT_ADMIN_ROLE`, so every role
    ///      change is scheduled and waited out. Rotating signers never touches the protocol contracts.
    ///
    ///      Proposers also get `CANCELLER_ROLE` from the base. `_cancellers` is for veto-only keys,
    ///      typically the signers behind a proposer multisig, so one key can veto but not schedule.
    ///
    ///      `EXECUTOR_ROLE` on the zero address opens execution to everyone.
    ///
    ///      Empty `_cancellers` is fine, as proposers already cancel. Empty `_guardians` is not:
    ///      adding one would wait out the delay, and nothing could evict a compromised canceller.
    constructor(
        uint256 _initialDelay,
        uint256 _minDelayFloor,
        address[] memory _proposers,
        address[] memory _cancellers,
        address[] memory _guardians
    ) TimelockController(_initialDelay, _proposers, new address[](0), address(0)) {
        if(_initialDelay < _minDelayFloor) revert DelayBelowFloor(_initialDelay, _minDelayFloor);
        if(_guardians.length == 0) revert NoGuardians();
        if(_proposers.length == 0) revert NoProposers();

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

    // ---------------------------------------------------------------------------------------------
    // Delay floor
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc TimelockController
    /// @dev Never below the floor, whatever `updateDelay` stored. `schedule` reads this, so the
    ///      floor binds without intercepting the setter. Offchain readers should call this rather
    ///      than follow `MinDelayChange`, which reports the stored value.
    function getMinDelay() public view virtual override returns (uint256) {
        uint256 delay = super.getMinDelay();

        return delay < minDelayFloor ? minDelayFloor : delay;
    }

    // ---------------------------------------------------------------------------------------------
    // Role overlap
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc AccessControl
    /// @dev Enforces the constructor's guardian overlap rules on later grants, so one proposer
    ///      cannot schedule the pairing that makes a guardian impossible to evict.
    ///
    ///      Authority is checked first, as in the base, so an unauthorized caller still gets
    ///      `AccessControlUnauthorizedAccount` rather than an overlap error.
    ///
    ///      The canceller and proposer split is not enforced here. It only shapes the deployment,
    ///      and pairing those roles later is a fair call for a scheduled operation.
    ///
    ///      A new guardian gets `EXECUTOR_ROLE` too, as in the constructor. `revokeRole` cannot
    ///      tell that grant apart, so evicting a guardian means revoking both in one batch.
    function grantRole(bytes32 role, address account)
        public
        virtual
        override
        onlyRole(getRoleAdmin(role))
    {
        if(role == CANCELLER_ROLE || role == PROPOSER_ROLE) {
            if(hasRole(GUARDIAN_ROLE, account)) revert RolesMustNotOverlap(account);
        }
        else if(role == GUARDIAN_ROLE) {
            if(hasRole(CANCELLER_ROLE, account) || hasRole(PROPOSER_ROLE, account)) {
                revert RolesMustNotOverlap(account);
            }

            _grantRole(EXECUTOR_ROLE, account);
        }

        _grantRole(role, account);
    }

    // ---------------------------------------------------------------------------------------------
    // Guardian powers
    // ---------------------------------------------------------------------------------------------

    /// @notice Raises a pause on a protocol contract immediately
    /// @dev A rogue guardian can only stop the protocol, which the admin key could already do, and
    ///      it can be released at once.
    /// @param target Contract to pause
    function pauseInstantly(address target) external onlyRole(GUARDIAN_ROLE) {
        emit PauseRaised(target, _msgSender());

        IPausable(target).pause();
    }

    /// @notice Releases a pause on a protocol contract immediately
    /// @dev The selector is fixed, so this cannot call anything else on the target. The worst a
    ///      rogue guardian can do is unpause something, which can be paused again.
    /// @param target Contract to unpause
    function unpauseInstantly(address target) external onlyRole(GUARDIAN_ROLE) {
        emit PauseReleased(target, _msgSender());

        IPausable(target).unpause();
    }

    /// @notice Takes the cancel power away from accounts immediately
    /// @dev Only `CANCELLER_ROLE`, and restoring it is scheduled. A batch because one signer set
    ///      often holds the role on several keys, and one transaction beats the operation it races.
    ///
    ///      All or nothing. An account without the role reverts, so a guardian never wrongly
    ///      believes a veto is gone.
    /// @param accounts Accounts to strip
    function revokeCancellersInstantly(address[] calldata accounts) external onlyRole(GUARDIAN_ROLE) {
        for(uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];

            if(!_revokeRole(CANCELLER_ROLE, account)) revert NotACanceller(account);

            emit CancellerRevoked(account, _msgSender());
        }
    }

    /// @notice Suspends a protocol contract's admin key immediately
    /// @dev Against a compromised admin key, which holds `Registry.pause` and could re-pause after
    ///      every release for the whole delay. Suspending it makes `unpauseInstantly` stick.
    ///
    ///      Grants nothing. Only the owner, after the delay, can reinstate or replace the key, so
    ///      the worst a rogue guardian can cause is a stopped backend that the owner ends.
    /// @param target Contract whose admin is being suspended
    function disableAdminInstantly(address target) external onlyRole(GUARDIAN_ROLE) {
        emit AdminDisabled(target, _msgSender());

        IRegistryAdmin(target).disableAdmin();
    }

    // ---------------------------------------------------------------------------------------------
    // Admin handover
    // ---------------------------------------------------------------------------------------------

    /// @notice Suspends the current admin and nominates its replacement in one operation
    /// @dev Scheduled like anything else, not a fast path. A pending nomination already suspends
    ///      the incumbent, and naming that effect lets a reviewer read the intent off the operation.
    ///
    ///      The nominee must still accept, so the role cannot go to an address that cannot act.
    ///
    ///      The incumbent is refused: the registry would read it as a withdrawal and lift the
    ///      suspension.
    /// @param target Contract whose admin is being replaced
    /// @param newAdmin Address nominated to take the role
    function disableAndNominate(address target, address newAdmin) external {
        address sender = _msgSender();
        if(sender != address(this)) revert TimelockUnauthorizedCaller(sender);
        if(newAdmin == IRegistryAdmin(target).adminOfRecord()) revert NomineeIsTheIncumbent(target, newAdmin);

        emit AdminDisabledAndNominated(target, newAdmin);

        IRegistryAdmin(target).requestAdminUpdate(newAdmin);
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership handover
    // ---------------------------------------------------------------------------------------------

    /// @notice Completes the handover of every contract that has offered this one its ownership
    /// @dev Permissionless because the current owner's offer is the decision. Scheduling it would
    ///      make even the deployment wait out the delay.
    ///
    ///      Events go before each call so they keep order with the target's own, and a failed
    ///      handover reverts the batch, so no event outlives its call.
    ///
    ///      Any contract can fake `pendingOwner()` and `acceptOwnership()`, so `OwnershipAccepted`
    ///      is only a claim. Filter it against the expected targets. A fake costs nothing more: this
    ///      contract holds no funds, and a target cannot gain a role by being called.
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
