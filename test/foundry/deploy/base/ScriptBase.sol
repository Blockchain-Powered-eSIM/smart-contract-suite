// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Test} from "forge-std/Test.sol";
import {MockEntryPoint} from "test/utils/mocks/MockEntryPoint.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";

// Config
import {DeployConfig} from "scripts/deploy/config/DeployConfig.sol";

/// @notice Shared setup for the tests that run the deployment scripts
/// @dev The scripts read every parameter from the environment and their record from a file, so a
///      test standing one up has to provide both. `rehearse.sh` covers the same scripts against a
///      fork and is the better check of the happy path; what these tests reach that it cannot is
///      the failure and resume branches, which need a broken environment on purpose.
///
///      The environment is process wide, and so is the scratch record path built on top of it.
///      Each test contract therefore writes to a file named after itself, and `setUp` re-seeds it
///      so one test never reads what the previous one left.
abstract contract ScriptBase is Test {

    /// @notice Anvil's first account, the key `rehearse.sh` deploys with
    /// @dev Published in Foundry's own documentation, so it controls nothing anywhere. A test must
    ///      never be able to reach for a key that does.
    uint256 internal constant DEPLOYER_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    /// @notice Ceiling on one data bundle, in USD cents
    uint64 internal constant PRICE_CAP_CENTS = 100_000;

    /// @notice Decimals the stand-in settlement token reports
    /// @dev Six, matching USDC. `Configure` reads this off the token rather than assuming it, so a
    ///      token answering something else is what that path has to survive.
    uint8 internal constant SETTLEMENT_DECIMALS = 6;

    address internal deployer;
    address internal eSIMWalletAdmin;
    address internal vault;
    address internal proposer;
    address internal canceller;
    address internal guardian;

    /// @notice Stand-in for USDC, deployed so `Configure` has a real `decimals()` to read
    MockERC20 internal settlementToken;

    /// @notice Record this contract's tests read and write
    string internal scratchRecord;

    /// @notice Puts a complete, valid environment in place and seeds an empty record
    /// @dev Call from `setUp` before anything runs a script. The name has to be unique per test
    ///      contract, since forge runs contracts in parallel against one filesystem.
    /// @param _name Short name for this contract's scratch record
    function _setUpScriptEnvironment(string memory _name) internal {
        deployer = vm.addr(DEPLOYER_KEY);
        eSIMWalletAdmin = makeAddr("eSIMWalletAdmin");
        vault = makeAddr("vault");

        // The three timelock lists have to stay disjoint. `ProtocolAdmin`'s constructor rejects an
        // overlap and `DeployConfig` checks the same thing before anything is broadcast.
        proposer = makeAddr("proposer");
        canceller = makeAddr("canceller");
        guardian = makeAddr("guardian");

        settlementToken = new MockERC20("USD Coin", "USDC", SETTLEMENT_DECIMALS);

        // The scripts refuse a chain the EntryPoint is not on, which is every chain a test runs on
        // until something is put there.
        vm.etch(DeployConfig.ENTRY_POINT_V08, address(new MockEntryPoint()).code);

        _setEnvironment();
        _resetRecord(_name);
    }

    /// @notice Writes every variable `DeployConfig.load` reads
    function _setEnvironment() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("ESIM_WALLET_ADMIN", vm.toString(eSIMWalletAdmin));
        vm.setEnv("VAULT", vm.toString(vault));
        vm.setEnv("PRICE_CAP_USD_CENTS", vm.toString(uint256(PRICE_CAP_CENTS)));
        vm.setEnv("SETTLEMENT_TOKEN", vm.toString(address(settlementToken)));
        vm.setEnv("TIMELOCK_PROPOSERS", vm.toString(proposer));
        vm.setEnv("TIMELOCK_CANCELLERS", vm.toString(canceller));
        vm.setEnv("TIMELOCK_GUARDIANS", vm.toString(guardian));
    }

    /// @notice Points the scripts at an empty record of this contract's own
    /// @dev `fs_permissions` grants write access to `deployments` and nowhere else, so the scratch
    ///      file lives beside the real record rather than in a temporary directory. The leading dot
    ///      and the `test-` prefix are what `.gitignore` matches on.
    /// @param _name Short name for this contract's scratch record
    function _resetRecord(string memory _name) internal {
        scratchRecord = string.concat("deployments/.test-", _name, ".json");

        vm.writeFile(scratchRecord, "{}");
        vm.setEnv("DEPLOYMENT_RECORD_PATH", scratchRecord);
    }

    /// @notice The key this chain's entry lives under, which is `anvil-31337-entrypoint-v8` in tests
    function _recordKey() internal view returns (string memory key) {
        key = DeployConfig.recordKey();
    }

    /// @notice Reads a value out of the scratch record
    /// @param _path Dotted path below the network key
    function _recorded(string memory _path) internal view returns (string memory value) {
        value = vm.readFile(scratchRecord);
        value = vm.parseJsonString(value, string.concat(".", _recordKey(), ".", _path));
    }

    /// @notice True when the scratch record holds something at this path
    /// @param _path Dotted path below the network key
    function _recordHas(string memory _path) internal view returns (bool present) {
        present = vm.keyExistsJson(
            vm.readFile(scratchRecord),
            string.concat(".", _recordKey(), ".", _path)
        );
    }
}
