// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Contracts
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Ownable2StepUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ProtocolAdmin} from "../../contracts/admin/ProtocolAdmin.sol";

// Config
import {DeployConfig} from "./config/DeployConfig.sol";
import {DeploymentRecord} from "./config/DeploymentRecord.sol";

/// @notice Hands the four upgradeable singletons to the timelock and closes the deployer's window
/// @dev The last of the three deployment scripts. Until this has run, one externally owned account
///      owns `Registry`, `LazyWalletRegistry` and both factories, and owning the factories reaches
///      every device wallet and every eSIM wallet through the two beacons. That is the state the
///      deployment is being moved off, so the gap between `Deploy.s.sol` and this script should be
///      minutes rather than days.
///
///      Two steps, because these contracts are `Ownable2Step`. The deployer offers ownership, then
///      the new owner accepts it. `ProtocolAdmin.acceptOwnershipBatch` is permissionless and takes
///      all four in one transaction, so the second step needs no key at all and cannot be the thing
///      that strands a handover halfway.
///
///      Nothing here is timelocked. Accepting an offer of ownership is not an operation the
///      timelock schedules; it is a function on the timelock contract itself. After this runs,
///      every owner gated call on all four contracts is.
contract TransferOwnership is Script {

    /// @notice Number of contracts handed over in one run
    uint256 private constant TARGET_COUNT = 4;

    /// @notice A contract did not end the run owned by the timelock
    error OwnershipNotMoved(address target, address owner);

    /// @notice The deployer does not own a contract it is supposed to hand over
    error NotOwner(address target, address owner, address deployer);

    /// @notice Offers all four singletons to the timelock and has it accept them
    /// @dev Broadcasts as the deployer for the offers. The acceptance is permissionless but is
    ///      broadcast from the same key, since somebody has to pay for it.
    function run() external {
        DeployConfig.Config memory config = DeployConfig.load();

        address protocolAdmin = DeploymentRecord.readRaw("admin.protocolAdmin");
        address[] memory targets = _targets();

        _requireDeployerOwnsAll(targets, config.deployer);

        vm.startBroadcast(config.deployerPrivateKey);

        for(uint256 i = 0; i < targets.length; ++i) {
            Ownable2StepUpgradeable(targets[i]).transferOwnership(protocolAdmin);
            console.log("Offered ownership of", targets[i]);
        }

        ProtocolAdmin(payable(protocolAdmin)).acceptOwnershipBatch(targets);

        vm.stopBroadcast();

        _verify(targets, protocolAdmin);
        DeploymentRecord.writeStatus("ownershipTransferred", true);

        console.log("");
        console.log("All four singletons are owned by", protocolAdmin);
        console.log("Every owner gated call now waits for the timelock delay.");
    }

    /// @notice The four contracts whose owner is the upgrade authority
    /// @dev Read from the record rather than taken as arguments. An address typed on a command line
    ///      is the one way to hand the wrong contract to the wrong owner permanently.
    function _targets() private view returns (address[] memory targets) {
        targets = new address[](TARGET_COUNT);
        targets[0] = DeploymentRecord.readAddress("RegistryProxy");
        targets[1] = DeploymentRecord.readAddress("LazyWalletRegistryProxy");
        targets[2] = DeploymentRecord.readAddress("DeviceWalletFactoryProxy");
        targets[3] = DeploymentRecord.readAddress("ESIMWalletFactoryProxy");
    }

    /// @notice Refuses to start unless the deployer still owns every target
    /// @dev Checked before broadcasting rather than per call, so a run that would hand over three
    ///      of four and revert on the fourth never sends the first transaction.
    function _requireDeployerOwnsAll(address[] memory targets, address deployer) private view {
        for(uint256 i = 0; i < targets.length; ++i) {
            address owner = Ownable2StepUpgradeable(targets[i]).owner();
            if(owner != deployer) revert NotOwner(targets[i], owner, deployer);
        }
    }

    /// @notice Reads the owner back off every target
    function _verify(address[] memory targets, address protocolAdmin) private view {
        for(uint256 i = 0; i < targets.length; ++i) {
            address owner = Ownable2StepUpgradeable(targets[i]).owner();
            if(owner != protocolAdmin) revert OwnershipNotMoved(targets[i], owner);
        }
    }
}
