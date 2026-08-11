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
        uint256 dataBundlePriceCap;
        address[] proposers;
        address[] cancellers;
        address[] guardians;
    }

    /// @notice A required environment variable resolved to the zero address
    error MissingAddress(string variable);

    /// @notice A required address list was empty
    error EmptyList(string variable);

    /// @notice The EntryPoint address carries no code on this chain
    error EntryPointNotDeployed(address entryPoint, uint256 chainId);

    /// @notice An account appears in two role lists the timelock requires to stay separate
    error RolesMustNotOverlap(address account);

    /// @notice Reads and checks every deployment parameter from the environment
    /// @dev Every failure here is one a deployment can recover from, so they all happen before
    ///      anything is broadcast. The role overlap checks duplicate what `ProtocolAdmin`'s
    ///      constructor enforces, deliberately: reverting inside a broadcast leaves the earlier
    ///      contracts of that run deployed and orphaned.
    /// @return config Resolved parameters for this run
    function load() internal view returns (Config memory config) {
        config.chainId = block.chainid;

        config.deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        config.deployer = vm.addr(config.deployerPrivateKey);

        config.eSIMWalletAdmin = vm.envAddress("ESIM_WALLET_ADMIN");
        if(config.eSIMWalletAdmin == address(0)) revert MissingAddress("ESIM_WALLET_ADMIN");

        config.vault = vm.envAddress("VAULT");
        if(config.vault == address(0)) revert MissingAddress("VAULT");

        // Zero is a valid answer and means no ceiling, which is what the protocol does when the
        // registry default is unset. Stated as a default rather than required, so a deployment
        // that has not decided yet is explicit about running without one.
        config.dataBundlePriceCap = vm.envOr("DATA_BUNDLE_PRICE_CAP", uint256(0));

        config.entryPoint = IEntryPoint(ENTRY_POINT_V08);
        if(ENTRY_POINT_V08.code.length == 0) {
            revert EntryPointNotDeployed(ENTRY_POINT_V08, block.chainid);
        }

        config.proposers = vm.envAddress("TIMELOCK_PROPOSERS", ",");
        if(config.proposers.length == 0) revert EmptyList("TIMELOCK_PROPOSERS");

        // Empty is allowed. The base constructor already gives every proposer the cancel power,
        // so this list is for accounts that cancel and do nothing else.
        config.cancellers = vm.envOr("TIMELOCK_CANCELLERS", ",", new address[](0));

        config.guardians = vm.envAddress("TIMELOCK_GUARDIANS", ",");
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

    /// @notice Name this chain is recorded under in `deployments/address.json`
    /// @dev Keyed by chain id rather than by forge's `--chain` string, so the same record is
    ///      written whichever way the script is invoked. Unknown chains fall back to the id, which
    ///      keeps a local or forked run from overwriting a real network's entry.
    /// @return name Key for this chain in the deployment record
    function networkName() internal view returns (string memory name) {
        uint256 id = block.chainid;

        if(id == 11155111) return "sepolia";
        if(id == 11155420) return "optimism-sepolia";
        if(id == 84532) return "base-sepolia";
        if(id == 1) return "mainnet";
        if(id == 10) return "optimism";
        if(id == 8453) return "base";
        if(id == 31337) return "anvil";

        return string.concat("chain-", vm.toString(id));
    }
}
