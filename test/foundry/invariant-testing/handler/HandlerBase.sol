// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {FCL_Elliptic_ZZ} from "FreshCryptoLib/FCL_elliptic.sol";

import "contracts/CustomStructs.sol";
import {DeviceWalletFactory} from "contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "contracts/esim-wallet/ESIMWalletFactory.sol";
import {Registry} from "contracts/Registry.sol";
import {LazyWalletRegistry} from "contracts/LazyWalletRegistry.sol";

import {ProtocolState} from "test/foundry/invariant-testing/base/ProtocolState.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Everything a handler needs to reach the protocol and record what it did.
/// @dev Bundled rather than passed as ten parameters, because every handler takes the same set and
///      each one would otherwise repeat the list twice, once to accept it and once to forward it.
struct HandlerConfig {
    ProtocolState state;
    DeviceWalletFactory deviceWalletFactory;
    ESIMWalletFactory eSIMWalletFactory;
    Registry registry;
    LazyWalletRegistry lazyWalletRegistry;
    address entryPoint;
    address admin;
    address adminSuccessor;
    address upgradeManager;
    address vault;
    address attacker;
}

/// @notice What every handler in the campaign shares.
/// @dev Handlers are split by actor rather than by contract. The split follows who is allowed to
///      make a call, which is what each entry point has to impersonate, and not which contract the
///      call happens to land on. An admin batch deploy touches the factory, the registry and both
///      wallet implementations in one transaction, so a split by contract would have put the same
///      entry point in three places.
///
///      Ghost state lives in `ProtocolState` rather than here, because it is organised by entity
///      and every actor contributes to the same lists.
abstract contract HandlerBase is Test {

    ProtocolState internal immutable state;

    address internal immutable admin;
    address internal immutable adminSuccessor;
    address internal immutable upgradeManager;
    address internal immutable vault;
    address internal immutable attacker;

    DeviceWalletFactory internal immutable deviceWalletFactory;
    ESIMWalletFactory internal immutable eSIMWalletFactory;
    Registry internal immutable registry;
    LazyWalletRegistry internal immutable lazyWalletRegistry;
    address internal immutable entryPoint;

    constructor(HandlerConfig memory config) {
        state = config.state;
        deviceWalletFactory = config.deviceWalletFactory;
        eSIMWalletFactory = config.eSIMWalletFactory;
        registry = config.registry;
        lazyWalletRegistry = config.lazyWalletRegistry;
        entryPoint = config.entryPoint;
        admin = config.admin;
        adminSuccessor = config.adminSuccessor;
        upgradeManager = config.upgradeManager;
        vault = config.vault;
        attacker = config.attacker;
    }

    /// @notice Counts an invocation before the body decides whether it can go through, and reads
    ///         the eSIM wallets' purchase history afterwards
    /// @dev The history check rides here rather than on the two entry points that write history,
    ///      because the thing worth catching is an entry lost to a call that had no business
    ///      touching history at all. A beacon swap is the clearest one: it moves every wallet onto
    ///      new logic in a single call.
    modifier counted() {
        state.recordInvocation();
        _;
        _readHistories();
    }

    /// @notice Whoever currently holds the admin role
    /// @dev Read out of the registry on every call rather than fixed at construction. Every admin
    ///      check in the protocol resolves through this one field, so a handler that kept its own
    ///      copy would go on impersonating an address the protocol has already demoted, and every
    ///      admin path would sit dead for the rest of the run once a rotation went through.
    function _currentAdmin() internal view returns (address) {
        return registry.eSIMWalletAdmin();
    }

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

    /// @notice A device identifier for the lazy path, in its own namespace
    /// @dev Kept apart from the identifiers the deploy paths use so a collision between the two is
    ///      something the run arranges deliberately rather than something it stumbles into.
    function _lazyIdentifier(uint256 seed) internal pure returns (string memory) {
        return string.concat("L", vm.toString(seed % 1_000_000));
    }

    /// @notice An eSIM identifier for the lazy path
    function _eSIMIdentifier(uint256 seed) internal pure returns (string memory) {
        return string.concat("E", vm.toString(seed % 1_000_000));
    }

    /// @notice An eSIM identifier for the ordinary path, in its own namespace
    function _ordinaryESIMIdentifier(uint256 seed) internal pure returns (string memory) {
        return string.concat("O", vm.toString(seed % 1_000_000));
    }

    /// @notice How many identifiers the two deployment routes are made to contend over
    /// @dev Small on purpose. The namespaces above never overlap, so a cross-route invariant would
    ///      otherwise hold over a state no sequence ever reaches. Eight is enough that a five
    ///      hundred call run has both routes reaching the same identifier repeatedly.
    uint256 internal constant CONTESTED_IDENTIFIERS = 8;

    /// @notice A device identifier both routes draw from
    function _contestedDeviceIdentifier(uint256 seed) internal pure returns (string memory) {
        return string.concat("CD", vm.toString(seed % CONTESTED_IDENTIFIERS));
    }

    /// @notice An eSIM identifier both routes draw from
    function _contestedESIMIdentifier(uint256 seed) internal pure returns (string memory) {
        return string.concat("CE", vm.toString(seed % CONTESTED_IDENTIFIERS));
    }

    /// @notice Finds an eSIM wallet with no identifier yet, and the device wallet holding it
    /// @dev Scans forward from the fuzzed position rather than taking whatever sits there, because
    ///      an identifier is set once per wallet and a plain pick would spend most of a run landing
    ///      on wallets that already have one.
    /// @param seed Where the scan starts
    /// @return wallet The eSIM wallet, or zero if every known one is already named
    /// @return device The device wallet that owns it
    function _pickUnnamedESIMWallet(uint256 seed) internal view returns (address wallet, address device) {
        uint256 count = state.eSIMWalletCount();
        if (count == 0) return (address(0), address(0));

        uint256 start = bound(seed, 0, count - 1);
        for (uint256 i = 0; i < count; ++i) {
            address candidate = state.eSIMWallets((start + i) % count);
            if (bytes(MockESIMWallet(payable(candidate)).eSIMUniqueIdentifier()).length != 0) continue;

            address owner = MockESIMWallet(payable(candidate)).owner();
            if (!registry.isDeviceWalletValid(owner)) continue;

            return (candidate, owner);
        }

        return (address(0), address(0));
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

    /// @notice Picks a device wallet the campaign has deployed, or zero when none exists yet
    function _pickDeviceWallet(uint256 seed) internal view returns (address) {
        uint256 count = state.deviceWalletCount();
        if (count == 0) return address(0);
        return state.deviceWallets(bound(seed, 0, count - 1));
    }

    /// @notice Reads purchase history off the eSIM wallets and hands it to the ghost state
    /// @dev Every wallet already known to hold an entry is read on every call, because that is the
    ///      only part of the list where a loss is visible and a wallet read only occasionally would
    ///      let one through: a rewrite is caught by comparing against the last reading, so a call
    ///      that writes and a call that rewrites both have to be seen. One further wallet is taken
    ///      in turn out of the full list, which is how a wallet reaches the short list in the first
    ///      place. Reading the full list every time would be several times the work for nothing.
    function _readHistories() internal {
        uint256 known = state.historyWalletCount();
        for (uint256 i = 0; i < known; ++i) {
            _readHistory(state.historyWallets(i));
        }

        uint256 count = state.eSIMWalletCount();
        if (count == 0) return;

        address next = state.eSIMWallets(state.totalInvocations() % count);
        if (!state.isHistoryWallet(next)) _readHistory(next);
    }

    /// @notice Digests one wallet's history and hands both the prefix and the whole of it over
    function _readHistory(address wallet) private {
        DataBundleDetails[] memory entries = MockESIMWallet(payable(wallet)).getTransactionHistory();

        uint256 recorded = state.ghost_historyEntries(wallet);
        bytes32 prefixDigest;
        bytes32 fullDigest;

        for (uint256 i = 0; i < entries.length; ++i) {
            fullDigest =
                keccak256(abi.encode(fullDigest, entries[i].id, entries[i].priceUSDCents));
            if (i + 1 == recorded) prefixDigest = fullDigest;
        }

        state.checkHistory(wallet, entries.length, prefixDigest, fullDigest);
    }

    /// @notice Picks an eSIM wallet the campaign has deployed, or zero when none exists yet
    function _pickESIMWallet(uint256 seed) internal view returns (address) {
        uint256 count = state.eSIMWalletCount();
        if (count == 0) return address(0);
        return state.eSIMWallets(bound(seed, 0, count - 1));
    }

    receive() external payable {}
}
