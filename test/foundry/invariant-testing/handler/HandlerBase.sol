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
        upgradeManager = config.upgradeManager;
        vault = config.vault;
        attacker = config.attacker;
    }

    /// @notice Counts an invocation before the body decides whether it can go through
    modifier counted() {
        state.recordInvocation();
        _;
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

    /// @notice Picks an eSIM wallet the campaign has deployed, or zero when none exists yet
    function _pickESIMWallet(uint256 seed) internal view returns (address) {
        uint256 count = state.eSIMWalletCount();
        if (count == 0) return address(0);
        return state.eSIMWallets(bound(seed, 0, count - 1));
    }

    receive() external payable {}
}
