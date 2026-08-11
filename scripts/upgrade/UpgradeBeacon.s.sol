// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Interfaces
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

// Contracts
import {console} from "forge-std/console.sol";
import {P256Verifier} from "../../contracts/P256Verifier.sol";
import {DeviceWallet} from "../../contracts/device-wallet/DeviceWallet.sol";
import {DeviceWalletFactory} from "../../contracts/device-wallet/DeviceWalletFactory.sol";
import {ESIMWallet} from "../../contracts/esim-wallet/ESIMWallet.sol";
import {ESIMWalletFactory} from "../../contracts/esim-wallet/ESIMWalletFactory.sol";

// Config
import {DeploymentRecord} from "../deploy/config/DeploymentRecord.sol";
import {TimelockOperation} from "./TimelockOperation.sol";

/// @notice Moves the device wallet or eSIM wallet beacon to a new implementation, through the
///         timelock
/// @dev **A beacon upgrade reaches every wallet at once and no wallet can opt out.** There is one
///      beacon per wallet type and every wallet is a proxy reading its implementation from it, so
///      this is a protocol wide change however few wallets it was tested against. Treat it as such:
///      the delay between the two runs is the only window anybody has to object.
///
///      Two runs, same shape as `UpgradeSingleton.s.sol`. `UPGRADE_TARGET` is `DeviceWallet` or
///      `ESIMWallet`, and `UPGRADE_ACTION` is `schedule` or `execute`.
///
///      Neither beacon is upgraded directly. Both are owned by their factory, which is owned by the
///      timelock, so the scheduled call goes to the factory and the factory moves the beacon.
///
///      The device wallet implementation takes the EntryPoint and the verifier as constructor
///      arguments and holds them as immutables. Both are read back out of the deployment record
///      rather than the environment, so an upgrade cannot quietly rebind every wallet in the
///      protocol to a different EntryPoint.
contract UpgradeBeacon is TimelockOperation {

    /// @notice `UPGRADE_TARGET` names neither wallet type
    error UnknownTarget(string target);

    /// @notice `UPGRADE_ACTION` is neither `schedule` nor `execute`
    error UnknownAction(string action);

    /// @notice Schedules or executes a beacon implementation change
    function run() external {
        string memory target = vm.envString("UPGRADE_TARGET");
        string memory action = vm.envString("UPGRADE_ACTION");

        if(_is(action, "schedule")) {
            _scheduleUpgrade(target);
            return;
        }
        if(_is(action, "execute")) {
            _execute(string.concat(target, "Beacon"));
            return;
        }

        revert UnknownAction(action);
    }

    /// @notice Deploys the new wallet implementation and schedules the factory call that installs it
    function _scheduleUpgrade(string memory target) private {
        if(_is(target, "DeviceWallet")) {
            _scheduleDeviceWallet();
            return;
        }
        if(_is(target, "ESIMWallet")) {
            _scheduleESIMWallet();
            return;
        }

        revert UnknownTarget(target);
    }

    /// @notice Every device wallet in the protocol moves to a freshly deployed implementation
    /// @dev The EntryPoint and the verifier come from the record. Passing them from the environment
    ///      would make a typo in a shell variable enough to point every wallet at a different
    ///      EntryPoint, which no signature the SDK has already produced would validate against.
    function _scheduleDeviceWallet() private {
        address factory = DeploymentRecord.readAddress("DeviceWalletFactoryProxy");
        address entryPoint = DeploymentRecord.readRaw("external.entryPoint");
        address verifier = DeploymentRecord.readAddress("P256Verifier");

        vm.startBroadcast(vm.envUint("PROPOSER_PRIVATE_KEY"));
        address implementation = address(
            new DeviceWallet(IEntryPoint(entryPoint), P256Verifier(verifier))
        );
        vm.stopBroadcast();

        _logPlan(factory, implementation, entryPoint);

        _schedule(
            "DeviceWalletBeacon",
            factory,
            abi.encodeCall(DeviceWalletFactory.updateDeviceWalletImplementation, (implementation)),
            implementation
        );
    }

    /// @notice Every eSIM wallet in the protocol moves to a freshly deployed implementation
    function _scheduleESIMWallet() private {
        address factory = DeploymentRecord.readAddress("ESIMWalletFactoryProxy");

        vm.startBroadcast(vm.envUint("PROPOSER_PRIVATE_KEY"));
        address implementation = address(new ESIMWallet());
        vm.stopBroadcast();

        _logPlan(factory, implementation, address(0));

        _schedule(
            "ESIMWalletBeacon",
            factory,
            abi.encodeCall(ESIMWalletFactory.updateESIMWalletImplementation, (implementation)),
            implementation
        );
    }

    function _logPlan(address factory, address implementation, address entryPoint) private pure {
        console.log("Factory        ", factory);
        console.log("New logic      ", implementation);
        if(entryPoint != address(0)) console.log("EntryPoint     ", entryPoint);
        console.log("");
        console.log("This moves every wallet of this type. There is no per wallet opt out.");
        console.log("");
    }

    function _is(string memory left, string memory right) private pure returns (bool equal) {
        equal = keccak256(bytes(left)) == keccak256(bytes(right));
    }
}
