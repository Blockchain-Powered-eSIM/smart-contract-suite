// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";

import "contracts/CustomStructs.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";
import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";
import {Registry} from "contracts/Registry.sol";
import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";

/// @notice The only contract an invariant campaign calls directly.
/// @dev Pointed at the protocol itself, the runner spends every call being refused by an access
///      control modifier. Each entry point here impersonates the actor that is allowed to make the
///      call it wraps, bounds its own arguments, and records what happened in ghost state the
///      invariants read back.
///
///      All ETH in the campaign originates here. The handler is funded once and every actor it
///      impersonates is part of the accounted set, so the sum over that set has to stay equal to
///      what was funded. Nothing else may hold a balance.
contract Handler is Test {

    /// @notice Every wei the campaign will ever have
    uint256 public constant TOTAL_ETH = 1_000 ether;

    address internal immutable admin;
    address internal immutable upgradeManager;
    address internal immutable vault;
    address internal immutable attacker;

    DeviceWalletFactory internal immutable deviceWalletFactory;
    ESIMWalletFactory internal immutable eSIMWalletFactory;
    Registry internal immutable registry;
    LazyWalletRegistry internal immutable lazyWalletRegistry;
    address internal immutable entryPoint;

    // ----------------------------------------------------------------------------------------
    // Ghost state
    // ----------------------------------------------------------------------------------------

    /// @notice Every device wallet the protocol has recorded, in deployment order
    /// @dev The protocol stores associations in mappings and exposes no enumeration, so without
    ///      this list the global invariants have nothing to iterate over.
    address[] public deviceWallets;

    /// @notice Every eSIM wallet reached through a device wallet, in deployment order
    address[] public eSIMWallets;

    /// @notice Device wallets deployed through `createAccount` that no one has registered yet
    /// @dev `createAccount` is permissionless and writes no registry state. A wallet sits here
    ///      until `postCreateAccount` binds it, which is the window a front-runner works in.
    address[] public unregisteredDeviceWallets;

    /// @notice Device identifier of each unregistered wallet, at the same index
    string[] public unregisteredIdentifiers;

    /// @notice Owner key of each unregistered wallet, at the same index
    bytes32[2][] public unregisteredOwnerKeys;

    /// @notice Every device identifier the handler has ever passed to a deploy path
    string[] public usedIdentifiers;

    /// @notice The device wallet the handler believes owns each identifier
    mapping(string identifier => address deviceWallet) public ghost_identifierToDevice;

    /// @notice Every owner key hash the handler has ever passed to a deploy path
    bytes32[] public usedKeyHashes;

    /// @notice The device wallet the handler believes owns each key hash
    mapping(bytes32 keyHash => address deviceWallet) public ghost_keyHashToDevice;

    mapping(address wallet => bool known) public isKnownDeviceWallet;
    mapping(address wallet => bool known) public isKnownESIMWallet;

    /// @notice Every address the campaign has caused to exist, each appearing once
    /// @dev The three lists above overlap. A wallet the permissionless path deployed can be the
    ///      same wallet a batch already produced, and it stays in the pending list until someone
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

    /// @notice Successful executions per entry point, keyed by function name
    mapping(bytes32 entryPoint => uint256 count) public calls;

    /// @notice Calls that reverted, keyed by function name
    mapping(bytes32 entryPoint => uint256 count) public reverts;

    /// @notice Every entry point invocation in this sequence, whether it got through or not
    /// @dev Lets the distribution check tell a full sequence from the one-call replay the shrinker
    ///      produces, which no distribution assertion could ever pass.
    uint256 public totalInvocations;

    constructor(
        DeviceWalletFactory _deviceWalletFactory,
        ESIMWalletFactory _eSIMWalletFactory,
        Registry _registry,
        LazyWalletRegistry _lazyWalletRegistry,
        address _entryPoint,
        address _admin,
        address _upgradeManager,
        address _vault,
        address _attacker
    ) payable {
        deviceWalletFactory = _deviceWalletFactory;
        eSIMWalletFactory = _eSIMWalletFactory;
        registry = _registry;
        lazyWalletRegistry = _lazyWalletRegistry;
        entryPoint = _entryPoint;
        admin = _admin;
        upgradeManager = _upgradeManager;
        vault = _vault;
        attacker = _attacker;
    }

    // ----------------------------------------------------------------------------------------
    // Entry points
    // ----------------------------------------------------------------------------------------

    /// @notice Counts an invocation before the body decides whether it can go through
    modifier counted() {
        ++totalInvocations;
        _;
    }

    /// @notice The admin deploys a batch of device wallets, each with one eSIM wallet
    /// @param count How many wallets the batch asks for
    /// @param seed Drives the identifiers, owner keys and salts
    /// @param deposit Total ETH offered for the batch, which may be less than the deposits ask for
    function deployDeviceWalletBatch(uint256 count, uint256 seed, uint256 deposit) external counted {
        count = bound(count, 1, 3);
        deposit = bound(deposit, 0, _spendable(admin, 10 ether));

        string[] memory identifiers = new string[](count);
        bytes32[2][] memory ownerKeys = new bytes32[2][](count);
        uint256[] memory salts = new uint256[](count);
        uint256[] memory deposits = new uint256[](count);

        uint256 perWallet = deposit / count;
        for (uint256 i = 0; i < count; ++i) {
            identifiers[i] = _identifier(seed + i);
            ownerKeys[i] = _ownerKey(seed + i);
            salts[i] = bound(uint256(keccak256(abi.encode(seed, i))), 0, 1000);
            deposits[i] = perWallet;
        }

        vm.prank(admin);
        try deviceWalletFactory.deployDeviceWalletForUsers{value: deposit}(
            identifiers, ownerKeys, salts, deposits
        ) returns (Wallets[] memory deployed) {
            for (uint256 i = 0; i < deployed.length; ++i) {
                _recordDeviceWallet(deployed[i].deviceWallet, identifiers[i], ownerKeys[i]);
                _recordESIMWallet(deployed[i].eSIMWallet);
            }
            calls["deployDeviceWalletBatch"]++;
        } catch {
            reverts["deployDeviceWalletBatch"]++;
        }
    }

    /// @notice An unprivileged caller deploys a device wallet through the permissionless path
    /// @dev `createAccount` writes no registry state, so the wallet it returns is bound to nothing
    ///      until the admin follows up. Letting the attacker reuse an identifier the admin has
    ///      already deployed against is the point: that is the front-run.
    /// @param seed Drives the identifier and owner key
    /// @param salt CREATE2 salt, kept in a small range so collisions actually happen
    /// @param reuseIdentifier Whether to claim an identifier the handler has already used
    function createAccountPermissionless(uint256 seed, uint256 salt, bool reuseIdentifier) external counted {
        salt = bound(salt, 0, 1000);

        string memory identifier;
        bytes32[2] memory ownerKey;
        if (reuseIdentifier && usedIdentifiers.length > 0) {
            identifier = usedIdentifiers[seed % usedIdentifiers.length];
            ownerKey = _ownerKey(seed);
        } else {
            identifier = _identifier(seed);
            ownerKey = _ownerKey(seed);
        }

        uint256 value = bound(seed, 0, _spendable(attacker, 1 ether));

        vm.prank(attacker);
        try deviceWalletFactory.createAccount{value: value}(identifier, ownerKey, salt) returns (
            DeviceWallet wallet
        ) {
            _account(address(wallet));
            unregisteredDeviceWallets.push(address(wallet));
            unregisteredIdentifiers.push(identifier);
            unregisteredOwnerKeys.push(ownerKey);
            calls["createAccountPermissionless"]++;
        } catch {
            reverts["createAccountPermissionless"]++;
        }
    }

    /// @notice The admin binds a wallet the permissionless path left unregistered
    /// @param index Which pending wallet to bind
    function postCreateAccount(uint256 index) external counted {
        if (unregisteredDeviceWallets.length == 0) {
            reverts["postCreateAccount"]++;
            return;
        }
        index = bound(index, 0, unregisteredDeviceWallets.length - 1);

        address wallet = unregisteredDeviceWallets[index];
        string memory identifier = unregisteredIdentifiers[index];
        bytes32[2] memory ownerKey = unregisteredOwnerKeys[index];

        vm.prank(admin);
        try deviceWalletFactory.postCreateAccount(wallet, identifier, ownerKey) {
            _recordDeviceWallet(wallet, identifier, ownerKey);
            _removePending(index);
            calls["postCreateAccount"]++;
        } catch {
            reverts["postCreateAccount"]++;
        }
    }

    /// @notice The attacker forces ETH into a wallet that never asked for it
    /// @dev Only the wallets are reachable this way. None of the four singletons declares a
    ///      `receive`, so a plain send to one reverts, which is what
    ///      `invariant_singletonsHoldNoETH` states.
    /// @param target Picks which wallet to hit
    /// @param amount How much to force in
    function donateETH(uint256 target, uint256 amount) external counted {
        amount = bound(amount, 1, _spendable(attacker, 1 ether));

        address recipient = _donationTarget(target);
        if (recipient == address(0) || amount == 0) {
            reverts["donateETH"]++;
            return;
        }

        vm.prank(attacker);
        (bool sent,) = recipient.call{value: amount}("");

        if (sent) {
            ghost_donated += amount;
            calls["donateETH"]++;
        } else {
            reverts["donateETH"]++;
        }
    }

    /// @notice The attacker tries to strand ETH in a contract that has no way to move it out
    /// @dev None of the four accepts a plain send today. If one ever does, the ETH is stuck for
    ///      good, so the attempt is made every run rather than assumed to fail.
    /// @param target Picks which singleton to hit
    /// @param amount How much to try to force in
    function donateToSingleton(uint256 target, uint256 amount) external counted {
        amount = bound(amount, 1, _spendable(attacker, 1 ether));

        address recipient = _singletonTarget(target);

        vm.prank(attacker);
        (bool sent,) = recipient.call{value: amount}("");

        if (sent) {
            ghost_singletonAcceptedETH = true;
        }

        calls["donateToSingleton"]++;
    }

    // ----------------------------------------------------------------------------------------
    // Views the invariants read
    // ----------------------------------------------------------------------------------------

    /// @notice How many device wallets the campaign has deployed
    /// @return Length of the device wallet list
    function deviceWalletCount() external view returns (uint256) {
        return deviceWallets.length;
    }

    /// @notice How many eSIM wallets the campaign has deployed
    /// @return Length of the eSIM wallet list
    function eSIMWalletCount() external view returns (uint256) {
        return eSIMWallets.length;
    }

    /// @notice How many distinct device identifiers have reached a deploy path
    /// @return Length of the used identifier list
    function usedIdentifierCount() external view returns (uint256) {
        return usedIdentifiers.length;
    }

    /// @notice How many distinct owner key hashes have reached a deploy path
    /// @return Length of the used key hash list
    function usedKeyHashCount() external view returns (uint256) {
        return usedKeyHashes.length;
    }

    /// @notice How many wallets are deployed but not yet bound in the registry
    /// @return Length of the pending wallet list
    function unregisteredCount() external view returns (uint256) {
        return unregisteredDeviceWallets.length;
    }

    /// @notice How many distinct addresses the campaign has caused to exist
    /// @return Length of the accounted address list
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

    /// @notice Caps a bound at what the actor making the call can actually pay
    /// @dev The value on a pranked call comes out of the pranked account, not out of the handler,
    ///      so a ceiling taken from the handler's own balance would run every call out of funds.
    /// @param actor Account the call will be attributed to
    /// @param ceiling Most the entry point would ever offer
    /// @return Whichever of the two is smaller
    function _spendable(address actor, uint256 ceiling) internal view returns (uint256) {
        uint256 balance = actor.balance;
        return balance < ceiling ? balance : ceiling;
    }

    /// @notice A device identifier derived from a seed, short enough to pass the length bound
    function _identifier(uint256 seed) internal pure returns (string memory) {
        return string.concat("D", vm.toString(seed % 1_000_000));
    }

    /// @notice A P256 public key that is genuinely on the curve
    /// @dev The deploy paths reject an off-curve key, so a random pair would spend the whole run
    ///      being refused before reaching any state. Walking x upward until the curve equation has
    ///      a square root finds one in two tries on average.
    function _ownerKey(uint256 seed) internal view returns (bytes32[2] memory key) {
        uint256 x = uint256(keccak256(abi.encode("ownerKey", seed)));
        for (uint256 i = 0; i < 16; ++i) {
            uint256 y = FCL_Elliptic_ZZ.ec_Decompress(x, seed & 1);
            if (FCL_Elliptic_ZZ.ecAff_isOnCurve(x, y)) {
                return [bytes32(x), bytes32(y)];
            }
            unchecked {
                ++x;
            }
        }
        revert("no on-curve key found");
    }

    /// @notice Picks a wallet to force ETH into, or zero when none exists yet
    function _donationTarget(uint256 seed) internal view returns (address) {
        if (seed % 2 == 0 && deviceWallets.length > 0) {
            return deviceWallets[seed % deviceWallets.length];
        }
        if (eSIMWallets.length > 0) {
            return eSIMWallets[seed % eSIMWallets.length];
        }
        if (deviceWallets.length > 0) {
            return deviceWallets[seed % deviceWallets.length];
        }
        return address(0);
    }

    /// @notice Picks one of the four contracts that hold no balance by design
    function _singletonTarget(uint256 seed) internal view returns (address) {
        uint256 choice = seed % 4;
        if (choice == 0) return address(deviceWalletFactory);
        if (choice == 1) return address(eSIMWalletFactory);
        if (choice == 2) return address(registry);
        return address(lazyWalletRegistry);
    }

    /// @notice Adds an address to the balance sum once, however many lists it also lands in
    function _account(address account) internal {
        if (account != address(0) && !isAccounted[account]) {
            isAccounted[account] = true;
            accountedAddresses.push(account);
        }
    }

    function _recordDeviceWallet(
        address wallet,
        string memory identifier,
        bytes32[2] memory ownerKey
    ) internal {
        _account(wallet);
        if (!isKnownDeviceWallet[wallet]) {
            isKnownDeviceWallet[wallet] = true;
            deviceWallets.push(wallet);
        }

        if (ghost_identifierToDevice[identifier] == address(0)) {
            usedIdentifiers.push(identifier);
        }
        ghost_identifierToDevice[identifier] = wallet;

        bytes32 keyHash = keccak256(abi.encode(ownerKey[0], ownerKey[1]));
        if (ghost_keyHashToDevice[keyHash] == address(0)) {
            usedKeyHashes.push(keyHash);
        }
        ghost_keyHashToDevice[keyHash] = wallet;
    }

    function _recordESIMWallet(address wallet) internal {
        _account(wallet);
        if (wallet != address(0) && !isKnownESIMWallet[wallet]) {
            isKnownESIMWallet[wallet] = true;
            eSIMWallets.push(wallet);
        }
    }

    /// @dev Order does not matter, so the last entry fills the hole
    function _removePending(uint256 index) internal {
        uint256 last = unregisteredDeviceWallets.length - 1;
        unregisteredDeviceWallets[index] = unregisteredDeviceWallets[last];
        unregisteredIdentifiers[index] = unregisteredIdentifiers[last];
        unregisteredOwnerKeys[index] = unregisteredOwnerKeys[last];
        unregisteredDeviceWallets.pop();
        unregisteredIdentifiers.pop();
        unregisteredOwnerKeys.pop();
    }

    receive() external payable {}
}
