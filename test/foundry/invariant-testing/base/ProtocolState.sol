// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/// @notice The ghost state every handler writes and every invariant reads.
/// @dev Split out because the handlers are split by actor while this state is organised by entity.
///      A device wallet reaches the lists below from the admin's batch deploy, from the admin's
///      lazy deploy and from the attacker's permissionless deploy, and an eSIM wallet's owner is
///      moved by both the device wallet and the eSIM wallet itself. Keeping a copy per handler
///      would leave each one blind to two thirds of the protocol.
///
///      Nothing here is access controlled. It is never a target contract, so the runner has no way
///      to call it, and every caller is a handler in the same campaign.
contract ProtocolState {

    /// @notice Every wei the campaign will ever have
    uint256 public constant TOTAL_ETH = 1_000 ether;

    // ----------------------------------------------------------------------------------------
    // Wallets
    // ----------------------------------------------------------------------------------------

    /// @notice Every device wallet the protocol has recorded, in deployment order
    /// @dev The protocol stores associations in mappings and exposes no enumeration, so without
    ///      this list the global invariants have nothing to iterate over.
    address[] public deviceWallets;

    /// @notice Every eSIM wallet reached through a device wallet, in deployment order
    address[] public eSIMWallets;

    mapping(address wallet => bool known) public isKnownDeviceWallet;
    mapping(address wallet => bool known) public isKnownESIMWallet;

    /// @notice The device wallet the handler believes each eSIM wallet belongs to
    /// @dev Kept alongside the registry's own view so the two can be compared. Zero means the
    ///      wallet is detached, which is the state standby is supposed to mirror.
    mapping(address eSIMWallet => address deviceWallet) public ghost_esimToDevice;

    /// @notice The last device wallet that held each eSIM wallet, kept after a detachment
    /// @dev The mapping above goes back to zero when a wallet is removed, which loses the one
    ///      address worth checking afterwards. A removal that cleared the association but left the
    ///      right to pull ETH behind would leave the leftover on the wallet that just let go, and
    ///      finding it any other way means comparing every device wallet against every eSIM wallet.
    mapping(address eSIMWallet => address deviceWallet) public ghost_lastDevice;

    // ----------------------------------------------------------------------------------------
    // Wallets deployed but not yet bound
    // ----------------------------------------------------------------------------------------

    /// @notice Device wallets deployed through `createAccount` that no one has registered yet
    /// @dev `createAccount` is permissionless and writes no registry state. A wallet sits here
    ///      until `postCreateAccount` binds it, which is the window a front-runner works in.
    address[] public unregisteredDeviceWallets;

    /// @notice Device identifier of each unregistered wallet, at the same index
    string[] public unregisteredIdentifiers;

    /// @notice Owner key of each unregistered wallet, at the same index
    bytes32[2][] public unregisteredOwnerKeys;

    // ----------------------------------------------------------------------------------------
    // Identifiers and keys
    // ----------------------------------------------------------------------------------------

    /// @notice Every device identifier the handlers have ever passed to a deploy path
    string[] public usedIdentifiers;

    /// @notice The device wallet the handlers believe owns each identifier
    mapping(string identifier => address deviceWallet) public ghost_identifierToDevice;

    /// @notice The identifier each device wallet was deployed against
    /// @dev The reverse of the mapping above, and the direction that catches a takeover. Reading
    ///      the forward one back proves nothing, because a handler records whatever the deploy
    ///      returned, so a second wallet quietly claiming an identifier would update both the
    ///      registry and the ghost and the two would still agree.
    mapping(address deviceWallet => string identifier) public ghost_deviceToIdentifier;

    /// @notice Every owner key hash the handlers have ever passed to a deploy path
    bytes32[] public usedKeyHashes;

    /// @notice The device wallet the handlers believe owns each key hash
    mapping(bytes32 keyHash => address deviceWallet) public ghost_keyHashToDevice;

    /// @notice The key hash the handlers believe each device wallet currently answers to
    /// @dev Separate from the list above, which never forgets. A rotation retires a key without
    ///      removing it from history, so the two disagree for every wallet that has rotated, and
    ///      only this one says what the registry should still be naming.
    mapping(address deviceWallet => bytes32 keyHash) public ghost_currentKeyHash;

    // ----------------------------------------------------------------------------------------
    // The lazy path, which works in identifiers rather than addresses
    // ----------------------------------------------------------------------------------------

    /// @notice Every device identifier the lazy path has populated history against
    /// @dev Entries are never removed. A deployed identifier is still worth presenting, since
    ///      refusing a second deploy and refusing more history are both guards a run has to reach.
    string[] public lazyDeviceIdentifiers;

    /// @notice Every eSIM identifier the lazy path has bound to a device identifier
    string[] public lazyESIMIdentifiers;

    /// @notice The device identifier the handlers believe each eSIM identifier is bound to
    mapping(string eSIMIdentifier => string deviceIdentifier) public ghost_eSIMIdentifierToDeviceIdentifier;

    mapping(string identifier => bool known) public isKnownLazyDevice;
    mapping(string identifier => bool known) public isKnownLazyESIM;

    // ----------------------------------------------------------------------------------------
    // ETH
    // ----------------------------------------------------------------------------------------

    /// @notice Every address the campaign has caused to exist, each appearing once
    /// @dev The wallet lists overlap. A wallet the permissionless path deployed can be the same
    ///      wallet a batch already produced, and it stays in the pending list until someone
    ///      registers it, so summing the lists would count its balance twice.
    address[] public accountedAddresses;

    mapping(address account => bool accounted) public isAccounted;

    /// @notice Set if any of the four singletons ever accepted a plain ETH send
    bool public ghost_singletonAcceptedETH;

    /// @notice Wei the attacker has forced into wallets that never asked for it
    /// @dev Tracked rather than suppressed. A donation is a real thing anyone can do, so an
    ///      invariant that would break under one is stating something the protocol cannot promise.
    ///      It comes out of the attacker's own budget, so it moves ETH inside the accounted set
    ///      rather than creating any, and the conservation sum is untouched by it.
    uint256 public ghost_donated;

    // ----------------------------------------------------------------------------------------
    // Bookkeeping the distribution check reads
    // ----------------------------------------------------------------------------------------

    /// @notice Successful executions per entry point, keyed by function name
    mapping(bytes32 entryPoint => uint256 count) public calls;

    /// @notice Calls that reverted, keyed by function name
    mapping(bytes32 entryPoint => uint256 count) public reverts;

    /// @notice Every entry point invocation in this sequence, whether it got through or not
    /// @dev Lets the distribution check tell a full sequence from the one-call replay the shrinker
    ///      produces, which no distribution assertion could ever pass.
    uint256 public totalInvocations;

    // ----------------------------------------------------------------------------------------
    // Writes
    // ----------------------------------------------------------------------------------------

    /// @notice Records a device wallet, the identifier it answers to and the key that owns it
    /// @dev The bindings are written only the first time a wallet is seen. Every deploy entry point
    ///      returns an already-deployed wallet untouched when the counterfactual address it
    ///      computes is occupied, and the arguments that produced that address are the ones the
    ///      wallet was deployed with, so a later call carrying the same arguments must not restate
    ///      them. The wallet's own key may have moved since, through a rotation, and the caller of
    ///      a deploy has no say in that. Overwriting here would hand the invariants the deploy
    ///      arguments as truth and hide the rotation. Adoption is unaffected: a wallet the
    ///      permissionless path left behind is only ever pending, never known, until the call that
    ///      binds it.
    function recordDeviceWallet(
        address wallet,
        string memory identifier,
        bytes32[2] memory ownerKey
    ) external {
        account(wallet);
        if (isKnownDeviceWallet[wallet]) return;

        isKnownDeviceWallet[wallet] = true;
        deviceWallets.push(wallet);

        if (ghost_identifierToDevice[identifier] == address(0)) {
            usedIdentifiers.push(identifier);
        }
        ghost_identifierToDevice[identifier] = wallet;
        ghost_deviceToIdentifier[wallet] = identifier;

        _recordKey(wallet, ownerKey);
    }

    /// @notice Records an eSIM wallet and the device wallet holding it
    function recordESIMWallet(address wallet, address device) external {
        account(wallet);
        if (wallet != address(0) && !isKnownESIMWallet[wallet]) {
            isKnownESIMWallet[wallet] = true;
            eSIMWallets.push(wallet);
        }
        _setESIMOwner(wallet, device);
    }

    /// @notice Records which device wallet now holds an eSIM wallet, zero meaning detached
    function setESIMOwner(address wallet, address device) external {
        _setESIMOwner(wallet, device);
    }

    /// @notice Records the key a wallet now answers to, keeping the retired one in history
    function recordKey(address wallet, bytes32[2] memory ownerKey) external {
        _recordKey(wallet, ownerKey);
    }

    /// @notice Adds a wallet the permissionless path deployed and nobody has bound yet
    function addPending(
        address wallet,
        string memory identifier,
        bytes32[2] memory ownerKey
    ) external {
        account(wallet);
        unregisteredDeviceWallets.push(wallet);
        unregisteredIdentifiers.push(identifier);
        unregisteredOwnerKeys.push(ownerKey);
    }

    /// @notice Drops a pending wallet once it has been bound
    /// @dev Order does not matter, so the last entry fills the hole
    function removePending(uint256 index) external {
        uint256 last = unregisteredDeviceWallets.length - 1;
        unregisteredDeviceWallets[index] = unregisteredDeviceWallets[last];
        unregisteredIdentifiers[index] = unregisteredIdentifiers[last];
        unregisteredOwnerKeys[index] = unregisteredOwnerKeys[last];
        unregisteredDeviceWallets.pop();
        unregisteredIdentifiers.pop();
        unregisteredOwnerKeys.pop();
    }

    /// @notice Records a device identifier the lazy path now carries history for
    function recordLazyDevice(string memory identifier) external {
        if (!isKnownLazyDevice[identifier]) {
            isKnownLazyDevice[identifier] = true;
            lazyDeviceIdentifiers.push(identifier);
        }
    }

    /// @notice Records an eSIM identifier and the device identifier it is bound to
    function recordLazyESIM(string memory eSIMIdentifier, string memory deviceIdentifier) external {
        if (!isKnownLazyESIM[eSIMIdentifier]) {
            isKnownLazyESIM[eSIMIdentifier] = true;
            lazyESIMIdentifiers.push(eSIMIdentifier);
        }
        ghost_eSIMIdentifierToDeviceIdentifier[eSIMIdentifier] = deviceIdentifier;
    }

    /// @notice Adds an address to the balance sum once, however many lists it also lands in
    function account(address target) public {
        if (target != address(0) && !isAccounted[target]) {
            isAccounted[target] = true;
            accountedAddresses.push(target);
        }
    }

    /// @notice Records wei the attacker forced into a wallet
    function addDonation(uint256 amount) external {
        ghost_donated += amount;
    }

    /// @notice Records that a contract with no withdrawal path took a plain send
    function markSingletonAcceptedETH() external {
        ghost_singletonAcceptedETH = true;
    }

    /// @notice Counts an entry point that reached the protocol
    function recordCall(bytes32 name) external {
        calls[name]++;
    }

    /// @notice Counts an entry point that was refused
    function recordRevert(bytes32 name) external {
        reverts[name]++;
    }

    /// @notice Counts an invocation before its body decides whether it can go through
    function recordInvocation() external {
        ++totalInvocations;
    }

    // ----------------------------------------------------------------------------------------
    // Views the invariants read
    // ----------------------------------------------------------------------------------------

    /// @notice How many device wallets the campaign has deployed
    function deviceWalletCount() external view returns (uint256) {
        return deviceWallets.length;
    }

    /// @notice How many eSIM wallets the campaign has deployed
    function eSIMWalletCount() external view returns (uint256) {
        return eSIMWallets.length;
    }

    /// @notice How many distinct device identifiers have reached a deploy path
    function usedIdentifierCount() external view returns (uint256) {
        return usedIdentifiers.length;
    }

    /// @notice How many distinct owner key hashes have reached a deploy path
    function usedKeyHashCount() external view returns (uint256) {
        return usedKeyHashes.length;
    }

    /// @notice How many wallets are deployed but not yet bound in the registry
    function unregisteredCount() external view returns (uint256) {
        return unregisteredDeviceWallets.length;
    }

    /// @notice How many device identifiers carry lazy history
    function lazyDeviceIdentifierCount() external view returns (uint256) {
        return lazyDeviceIdentifiers.length;
    }

    /// @notice How many eSIM identifiers the lazy path has bound
    function lazyESIMIdentifierCount() external view returns (uint256) {
        return lazyESIMIdentifiers.length;
    }

    /// @notice How many distinct addresses the campaign has caused to exist
    function accountedAddressCount() external view returns (uint256) {
        return accountedAddresses.length;
    }

    /// @notice Every wei the campaign is allowed to account for
    /// @dev Fixed. The budget is minted once, before the first call, and nothing mints more, so
    ///      any deviation is ETH the protocol created or lost rather than moved.
    function accountedETH() external pure returns (uint256) {
        return TOTAL_ETH;
    }

    // ----------------------------------------------------------------------------------------
    // Internals
    // ----------------------------------------------------------------------------------------

    /// @notice Points an eSIM wallet at its holder, remembering the last non-zero one
    function _setESIMOwner(address wallet, address device) internal {
        ghost_esimToDevice[wallet] = device;
        if (device != address(0)) {
            ghost_lastDevice[wallet] = device;
        }
    }

    function _recordKey(address wallet, bytes32[2] memory ownerKey) internal {
        bytes32 keyHash = keccak256(abi.encode(ownerKey[0], ownerKey[1]));
        if (ghost_keyHashToDevice[keyHash] == address(0)) {
            usedKeyHashes.push(keyHash);
        }
        ghost_keyHashToDevice[keyHash] = wallet;
        ghost_currentKeyHash[wallet] = keyHash;
    }
}
