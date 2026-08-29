// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {ScriptBase} from "./base/ScriptBase.sol";

// Config
import {DeployConfig} from "scripts/deploy/config/DeployConfig.sol";

/// @notice Calls the two library functions from outside, so a revert can be caught
/// @dev Both are internal, which a test calling them directly would inline, and `vm.expectRevert`
///      only sees a revert that crosses a call boundary.
contract ConfigLoader {
    function load() external view returns (DeployConfig.Config memory config) {
        config = DeployConfig.load();
    }

    function validate(DeployConfig.Config memory config) external view {
        DeployConfig.validate(config);
    }
}

/// @notice The environment a deployment reads, and every reason it refuses to start
/// @dev This is the one part of a deployment that costs nothing to get wrong: the checks run before
///      any broadcast, so everything they catch is recoverable. That is why it matters that they
///      work. A check that has never run is not known to run, and the first time these fire is
///      during a real deployment.
///
///      Nothing here rewrites an environment variable. Forge runs `setUp` once per contract and
///      environment variables belong to the process rather than to the EVM, so a test that set one
///      would change what every later test in this file reads, whichever order they run in. The
///      checks are reached with a configuration built by hand instead.
contract DeployConfigTest is ScriptBase {

    ConfigLoader private loader;

    function setUp() public {
        _setUpScriptEnvironment("deploy-config");
        loader = new ConfigLoader();
    }

    /// @notice A configuration that passes every check, for a test to break one field of
    function _validConfig() private view returns (DeployConfig.Config memory config) {
        config = loader.load();
    }

    function _list(address entry) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = entry;
    }

    // ---------------------------------------------------------------------------------------------
    // Reading the environment
    // ---------------------------------------------------------------------------------------------

    function test_load_resolvesEveryParameter() public view {
        DeployConfig.Config memory config = loader.load();

        assertEq(config.chainId, block.chainid, "chain id");
        assertEq(config.deployer, deployer, "deployer");
        assertEq(config.deployerPrivateKey, DEPLOYER_KEY, "deployer key");
        assertEq(address(config.entryPoint), DeployConfig.ENTRY_POINT_V08, "entry point");
        assertEq(config.eSIMWalletAdmin, eSIMWalletAdmin, "esim admin");
        assertEq(config.vault, vault, "vault");
        assertEq(config.priceCapUSDCents, PRICE_CAP_CENTS, "price cap");
        assertEq(config.settlementToken, address(settlementToken), "settlement token");
    }

    function test_load_resolvesTheThreeRoleLists() public view {
        DeployConfig.Config memory config = loader.load();

        assertEq(config.proposers.length, 1, "one proposer");
        assertEq(config.proposers[0], proposer, "proposer");
        assertEq(config.cancellers.length, 1, "one canceller");
        assertEq(config.cancellers[0], canceller, "canceller");
        assertEq(config.guardians.length, 1, "one guardian");
        assertEq(config.guardians[0], guardian, "guardian");
    }

    /// @dev The deployer is derived from the key rather than read as its own variable, so the two
    ///      cannot disagree about who is about to sign.
    function test_load_derivesTheDeployerFromTheKey() public view {
        assertEq(loader.load().deployer, vm.addr(DEPLOYER_KEY), "deployer from key");
    }

    // ---------------------------------------------------------------------------------------------
    // Addresses that have to be there
    // ---------------------------------------------------------------------------------------------

    function test_validate_revertsWhenTheAdminIsTheZeroAddress() public {
        DeployConfig.Config memory config = _validConfig();
        config.eSIMWalletAdmin = address(0);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.MissingAddress.selector, "ESIM_WALLET_ADMIN")
        );
        loader.validate(config);
    }

    function test_validate_revertsWhenTheVaultIsTheZeroAddress() public {
        DeployConfig.Config memory config = _validConfig();
        config.vault = address(0);

        vm.expectRevert(abi.encodeWithSelector(DeployConfig.MissingAddress.selector, "VAULT"));
        loader.validate(config);
    }

    function test_validate_revertsWhenTheSettlementTokenIsTheZeroAddress() public {
        DeployConfig.Config memory config = _validConfig();
        config.settlementToken = address(0);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.MissingAddress.selector, "SETTLEMENT_TOKEN")
        );
        loader.validate(config);
    }

    // ---------------------------------------------------------------------------------------------
    // The price ceiling
    // ---------------------------------------------------------------------------------------------

    /// @dev Zero is not a low ceiling, it is no ceiling. An eSIM wallet that never sets its own
    ///      falls back to this one, and `_requirePriceWithinCap` reads zero as "follow the
    ///      registry" the whole way down.
    function test_validate_revertsWhenThePriceCapIsZero() public {
        DeployConfig.Config memory config = _validConfig();
        config.priceCapUSDCents = 0;

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.MissingValue.selector, "PRICE_CAP_USD_CENTS")
        );
        loader.validate(config);
    }

    function test_validate_acceptsTheLargestCapThatFits() public view {
        DeployConfig.Config memory config = _validConfig();
        config.priceCapUSDCents = type(uint64).max;

        loader.validate(config);
    }

    // ---------------------------------------------------------------------------------------------
    // The EntryPoint
    // ---------------------------------------------------------------------------------------------

    /// @dev The address is the same on every chain, which is what makes it a constant, and is also
    ///      why a chain that does not carry it has to be caught here. The wallet implementations
    ///      take it as an immutable, so a wrong one is not reachable by any admin path afterwards.
    function test_validate_revertsWhenTheEntryPointIsNotOnThisChain() public {
        DeployConfig.Config memory config = _validConfig();
        vm.etch(DeployConfig.ENTRY_POINT_V08, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployConfig.EntryPointNotDeployed.selector,
                DeployConfig.ENTRY_POINT_V08,
                block.chainid
            )
        );
        loader.validate(config);
    }

    // ---------------------------------------------------------------------------------------------
    // Lists that cannot be empty
    // ---------------------------------------------------------------------------------------------

    /// @dev With no proposer nothing can ever be scheduled, so every owner gated call on all five
    ///      singletons is unreachable for good once the handover has run.
    function test_validate_revertsWithoutAProposer() public {
        DeployConfig.Config memory config = _validConfig();
        config.proposers = new address[](0);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.EmptyList.selector, "TIMELOCK_PROPOSERS")
        );
        loader.validate(config);
    }

    function test_validate_revertsWithoutAGuardian() public {
        DeployConfig.Config memory config = _validConfig();
        config.guardians = new address[](0);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.EmptyList.selector, "TIMELOCK_GUARDIANS")
        );
        loader.validate(config);
    }

    /// @dev Cancellers are the one list allowed to be empty. Every proposer can already cancel, so
    ///      this list is for accounts that cancel and do nothing else.
    function test_validate_acceptsAnEmptyCancellerList() public view {
        DeployConfig.Config memory config = _validConfig();
        config.cancellers = new address[](0);

        loader.validate(config);
    }

    // ---------------------------------------------------------------------------------------------
    // Roles that have to stay apart
    // ---------------------------------------------------------------------------------------------

    function test_validate_revertsWhenAProposerAlsoCancels() public {
        DeployConfig.Config memory config = _validConfig();
        config.cancellers = _list(proposer);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.RolesMustNotOverlap.selector, proposer)
        );
        loader.validate(config);
    }

    function test_validate_revertsWhenAProposerIsAlsoAGuardian() public {
        DeployConfig.Config memory config = _validConfig();
        config.guardians = _list(proposer);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.RolesMustNotOverlap.selector, proposer)
        );
        loader.validate(config);
    }

    function test_validate_revertsWhenACancellerIsAlsoAGuardian() public {
        DeployConfig.Config memory config = _validConfig();
        config.guardians = _list(canceller);

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfig.RolesMustNotOverlap.selector, canceller)
        );
        loader.validate(config);
    }

    /// @dev The overlap is found wherever it sits, not only when both lists start with it.
    function test_validate_findsAnOverlapPastTheFirstEntry() public {
        address shared = makeAddr("sharedAccount");

        DeployConfig.Config memory config = _validConfig();
        config.proposers = new address[](2);
        config.proposers[0] = proposer;
        config.proposers[1] = shared;
        config.guardians = new address[](2);
        config.guardians[0] = guardian;
        config.guardians[1] = shared;

        vm.expectRevert(abi.encodeWithSelector(DeployConfig.RolesMustNotOverlap.selector, shared));
        loader.validate(config);
    }

    // ---------------------------------------------------------------------------------------------
    // The record key
    // ---------------------------------------------------------------------------------------------

    /// @dev The chain id is in the key rather than only the name, because a name is a label somebody
    ///      chose and two chains sharing one is how a mainnet record overwrites a testnet one that
    ///      is still in use.
    function test_recordKey_namesTheChainTheIdAndTheEntryPoint() public {
        vm.chainId(84532);
        assertEq(DeployConfig.recordKey(), "base-sepolia-84532-entrypoint-v8", "base sepolia");

        vm.chainId(11155420);
        assertEq(DeployConfig.recordKey(), "optimism-sepolia-11155420-entrypoint-v8", "op sepolia");
    }

    function test_chainLabel_namesEveryChainTheProtocolTargets() public {
        vm.chainId(1);
        assertEq(DeployConfig.chainLabel(), "mainnet", "mainnet");

        vm.chainId(10);
        assertEq(DeployConfig.chainLabel(), "optimism", "optimism");

        vm.chainId(8453);
        assertEq(DeployConfig.chainLabel(), "base", "base");

        vm.chainId(11155111);
        assertEq(DeployConfig.chainLabel(), "sepolia", "sepolia");

        vm.chainId(31337);
        assertEq(DeployConfig.chainLabel(), "anvil", "anvil");
    }

    /// @dev An unrecognised chain still gets a key naming its id, so it cannot collide with a chain
    ///      the table does know.
    function test_recordKey_fallsBackToAKeyThatStillNamesTheChain() public {
        vm.chainId(4242);

        assertEq(DeployConfig.chainLabel(), "chain", "fallback label");
        assertEq(DeployConfig.recordKey(), "chain-4242-entrypoint-v8", "fallback key");
    }
}
