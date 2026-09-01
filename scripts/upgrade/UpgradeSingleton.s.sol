// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {console} from "forge-std/console.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Registry} from "../../contracts/Registry.sol";
import {LazyWalletRegistry} from "../../contracts/LazyWalletRegistry.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";
import {PaymentAdapter} from "../../contracts/payments/PaymentAdapter.sol";

// Config
import {DeploymentRecord} from "../deploy/config/DeploymentRecord.sol";
import {TimelockOperation} from "./TimelockOperation.sol";

/// @notice Upgrades one of the four UUPS singletons, through the timelock
/// @dev Two runs. `UPGRADE_ACTION=schedule` deploys the new implementation and schedules the
///      upgrade; `UPGRADE_ACTION=execute` performs it once the delay has elapsed. Which contract is
///      named by `UPGRADE_TARGET`, using the same key it carries in the deployment record.
///
///      **Check the storage layout before scheduling.** Nothing in this script can do it: the
///      layout of the new implementation is a property of the tree it was compiled from, not of
///      anything readable on chain. Run `python3 scripts/checks/storage-layouts.py` and diff the
///      result against the `storageLayoutHashes` recorded for this deployment. A moved slot behind
///      a live proxy is not recoverable by any admin path here.
///
///      The delay is the point of the two runs. Between them the operation is visible on chain and
///      any canceller can stop it, which is the whole protection the timelock buys.
contract UpgradeSingleton is TimelockOperation {

    /// @notice `UPGRADE_TARGET` does not name one of the five upgradeable singletons
    error UnknownTarget(string target);

    /// @notice `UPGRADE_ACTION` is neither `schedule` nor `execute`
    error UnknownAction(string action);

    /// @notice Schedules or executes a UUPS upgrade, depending on `UPGRADE_ACTION`
    function run() external {
        string memory target = vm.envString("UPGRADE_TARGET");
        string memory action = vm.envString("UPGRADE_ACTION");

        if(_is(action, "schedule")) {
            _scheduleUpgrade(target);
            return;
        }
        if(_is(action, "execute")) {
            _execute(target);
            return;
        }

        revert UnknownAction(action);
    }

    /// @notice Deploys the new implementation and schedules the proxy's move to it
    /// @dev The implementation is deployed by the proposer key rather than the timelock. A logic
    ///      contract holds no state and owns nothing until a proxy points at it, so deploying it
    ///      early costs nothing and lets the scheduled payload name a concrete address that
    ///      reviewers can read during the delay.
    function _scheduleUpgrade(string memory target) private {
        address proxy = DeploymentRecord.readAddress(target);

        vm.startBroadcast(vm.envUint("PROPOSER_PRIVATE_KEY"));
        address implementation = _deployImplementation(target);
        vm.stopBroadcast();

        console.log("Target proxy   ", proxy);
        console.log("New logic      ", implementation);
        console.log("");

        // No initializer call. A reinitializer belongs in its own scheduled operation, so that a
        // reviewer reading the pending payload sees the upgrade and the migration separately.
        _schedule(
            target,
            proxy,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, "")),
            implementation
        );
    }

    /// @notice Deploys the logic contract matching the named target
    /// @dev A branch per contract rather than a factory, because each is a distinct type and the
    ///      compiler is what should reject a name this deployment does not have.
    function _deployImplementation(string memory target) private returns (address implementation) {
        if(_is(target, "RegistryProxy")) return address(new Registry());
        if(_is(target, "LazyWalletRegistryProxy")) return address(new LazyWalletRegistry());
        if(_is(target, "DeviceWalletFactoryProxy")) return address(new DeviceWalletFactory());
        if(_is(target, "ESIMWalletFactoryProxy")) return address(new ESIMWalletFactory());
        if(_is(target, "PaymentAdapterProxy")) return address(new PaymentAdapter());

        revert UnknownTarget(target);
    }

    function _is(string memory left, string memory right) private pure returns (bool equal) {
        equal = keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
