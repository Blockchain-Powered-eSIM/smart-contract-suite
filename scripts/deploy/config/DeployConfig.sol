// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

// Contracts
import {Vm} from "forge-std/Vm.sol";

/// @notice Everything a deployment needs that is not derived from the code itself
/// @dev Split out of the scripts so the same values are read the same way by the deploy, the
///      configuration and the ownership handover, and so a missing variable fails before any
///      transaction is broadcast rather than halfway through one.
///
///      Addresses come from the environment rather than from constants here. The one exception is
///      the EntryPoint, which is a fixed address the protocol does not choose, and even that is
///      checked for code on the target chain before it is used. A wrong address written into an
///      immutable is not recoverable by any admin path in this protocol.
library DeployConfig {

    /// @notice ERC-4337 EntryPoint v0.8, the version `lib/account-abstraction` is pinned at
    /// @dev Deployed at the same address on every chain, so this is not a per-chain table.
    ///      Verified to carry code on OP Sepolia and Base Sepolia on 2026-08-11, and `load`
    ///      re-checks it at run time so a chain without it cannot be deployed to by accident.
    ///
    ///      This is not the v0.7 singleton the existing testnet deployment binds to. Every
    ///      signature the offchain SDK produces is scoped to one EntryPoint, because v0.8 moved
    ///      `userOpHash` to an EIP-712 domain separated form.
    address internal constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    /// @notice EntryPoint version this build binds to, as it appears in the record key
    /// @dev Part of the key rather than only a field inside the entry, for the same reason the
    ///      chain id is. One chain can carry a v0.7 deployment and a v0.8 deployment at once, and
    ///      they are different protocols to every offchain caller: a signature made for one is
    ///      rejected by the other. Sharing a key would mean the newer record overwrites a
    ///      deployment that is still being used, which is exactly what happened to `base-sepolia`
    ///      before the chain id was added.
    string internal constant ENTRY_POINT_TAG = "entrypoint-v8";

    /// @notice Delay every scheduled admin operation waits before it can be executed
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    /// @notice Shortest delay `updateDelay` can ever bring the timelock down to
    /// @dev Immutable in the deployed contract. Without it one scheduled operation turns the
    ///      timelock into a plain multisig and nothing after it ever waits again.
    uint256 internal constant TIMELOCK_DELAY_FLOOR = 1 hours;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Resolved deployment parameters for the chain the script is pointed at
    struct Config {
        uint256 chainId;
        address deployer;
        uint256 deployerPrivateKey;
        IEntryPoint entryPoint;
        address eSIMWalletAdmin;
        address vault;
        uint64 priceCapUSDCents;
        address settlementToken;
        address[] proposers;
        address[] cancellers;
        address[] guardians;
    }

    /// @notice A required environment variable resolved to the zero address
    error MissingAddress(string variable);

    /// @notice A required numeric environment variable resolved to zero
    error MissingValue(string variable);

    /// @notice A required address list was empty
    error EmptyList(string variable);

    /// @notice The EntryPoint address carries no code on this chain
    error EntryPointNotDeployed(address entryPoint, uint256 chainId);

    /// @notice An account appears in two role lists the timelock requires to stay separate
    error RolesMustNotOverlap(address account);

    /// @notice Reads every deployment parameter from the environment and checks it
    /// @dev Reading and checking are separate so the checks can be reached with a configuration
    ///      built by hand. Environment variables are process wide and forge does not restore them
    ///      between tests, so a test that reached these by rewriting the environment would change
    ///      what every later test in the same file reads.
    /// @return config Resolved parameters for this run
    function load() internal view returns (Config memory config) {
        config.chainId = block.chainid;

        config.deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        config.deployer = vm.addr(config.deployerPrivateKey);

        config.eSIMWalletAdmin = vm.envAddress("ESIM_WALLET_ADMIN");
        config.vault = vm.envAddress("VAULT");
        config.priceCapUSDCents = uint64(vm.envUint("PRICE_CAP_USD_CENTS"));
        config.settlementToken = vm.envAddress("SETTLEMENT_TOKEN");
        config.entryPoint = IEntryPoint(ENTRY_POINT_V08);

        config.proposers = vm.envAddress("TIMELOCK_PROPOSERS", ",");

        // Empty is allowed. The base constructor already gives every proposer the cancel power,
        // so this list is for accounts that cancel and do nothing else.
        config.cancellers = vm.envOr("TIMELOCK_CANCELLERS", ",", new address[](0));

        config.guardians = vm.envAddress("TIMELOCK_GUARDIANS", ",");

        validate(config);
    }

    /// @notice Refuses a configuration the deployment could not recover from
    /// @dev Every failure here is one a deployment can recover from, so they all happen before
    ///      anything is broadcast. The role overlap checks duplicate what `ProtocolAdmin`'s
    ///      constructor enforces, deliberately: reverting inside a broadcast leaves the earlier
    ///      contracts of that run deployed and orphaned.
    /// @param config Parameters to check
    function validate(Config memory config) internal view {
        if(config.eSIMWalletAdmin == address(0)) revert MissingAddress("ESIM_WALLET_ADMIN");
        if(config.vault == address(0)) revert MissingAddress("VAULT");

        // Never zero: `Registry.initialize` refuses a zero cap, since zero would read as "no
        // ceiling" for every wallet that never sets its own.
        if(config.priceCapUSDCents == 0) revert MissingValue("PRICE_CAP_USD_CENTS");

        // Nothing reads this until swaps exist, but the adapter takes it at initialisation so
        // adding them later needs no migration transaction.
        if(config.settlementToken == address(0)) revert MissingAddress("SETTLEMENT_TOKEN");

        if(address(config.entryPoint).code.length == 0) {
            revert EntryPointNotDeployed(address(config.entryPoint), block.chainid);
        }

        if(config.proposers.length == 0) revert EmptyList("TIMELOCK_PROPOSERS");
        if(config.guardians.length == 0) revert EmptyList("TIMELOCK_GUARDIANS");

        _requireDisjoint(config.proposers, config.cancellers);
        _requireDisjoint(config.proposers, config.guardians);
        _requireDisjoint(config.cancellers, config.guardians);
    }

    /// @notice Reverts if any account appears in both lists
    function _requireDisjoint(address[] memory left, address[] memory right) private pure {
        for(uint256 i = 0; i < left.length; ++i) {
            for(uint256 j = 0; j < right.length; ++j) {
                if(left[i] == right[j]) revert RolesMustNotOverlap(left[i]);
            }
        }
    }

    /// @notice Key this chain's entry lives under in `deployments/address.json`
    /// @dev The chain id is part of the key, not just a field inside the entry. A name on its own
    ///      is a label somebody chose, and two chains sharing one is how a mainnet deployment
    ///      overwrites a testnet one that is still being used. The id is what the chain answers
    ///      with, so the key cannot be wrong about which chain it describes.
    ///
    ///      Forge writes its own broadcast logs under `broadcast/<script>/<chainId>/` already, so
    ///      this puts the record on the same footing.
    ///
    ///      This does not tell a local fork apart from the chain it forked, because a fork keeps
    ///      the original chain id unless it is overridden. `Deploy.s.sol` refusing to write over an
    ///      existing entry is what covers that case; pass `--chain-id 31337` to anvil to be sure.
    ///
    ///      The EntryPoint tag comes last. It means the four records written before this build
    ///      exists are no longer reachable by any script here, which is correct: they bind to the
    ///      v0.7 singleton and nothing in this tree can talk to one.
    /// @return key Key for this chain in the deployment record, for example
    ///         `base-sepolia-84532-entrypoint-v8`
    function recordKey() internal view returns (string memory key) {
        key = string.concat(
            chainLabel(),
            "-",
            vm.toString(block.chainid),
            "-",
            ENTRY_POINT_TAG
        );
    }

    /// @notice Readable name for this chain, for logs and for the record's own `chain` section
    /// @dev Unknown chains fall back to `chain`, so an unrecognised id still produces a key that
    ///      names it rather than colliding with anything.
    /// @return name Human readable chain name
    function chainLabel() internal view returns (string memory name) {
        uint256 id = block.chainid;

        if(id == 11155111) return "sepolia";
        if(id == 11155420) return "optimism-sepolia";
        if(id == 84532) return "base-sepolia";
        if(id == 1) return "mainnet";
        if(id == 10) return "optimism";
        if(id == 8453) return "base";
        if(id == 31337) return "anvil";

        return "chain";
    }
}
