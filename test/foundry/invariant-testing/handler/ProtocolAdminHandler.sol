// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Registry} from "contracts/Registry.sol";
import {ProtocolAdmin} from "contracts/admin/ProtocolAdmin.sol";

/// @notice Drives the admin contract the way its three actors would.
/// @dev Kept apart from the protocol campaign's handlers on purpose. Those run against a world
///      whose clock never moves, and a timelock is not worth testing without moving it. Everything
///      the campaign needs to check lives on this handler and the admin contract, so the two
///      campaigns share nothing.
///
///      Every call the actors are not allowed to make is here too, in the `rejects` entry points.
///      A campaign that only ever exercised the permitted paths would report an access control
///      failure as an unexplained state change rather than as the thing that went wrong.
contract ProtocolAdminHandler is Test {

    /// @dev What was scheduled, kept so the campaign can try to execute it later. Operations are
    ///      only ever appended, so an identifier that appeared once stays checkable for the rest of
    ///      the run.
    struct Operation {
        address target;
        bytes data;
        bytes32 salt;
        bytes32 id;
        uint256 cap;
    }

    ProtocolAdmin public immutable admin;
    Registry public immutable registry;

    address public immutable proposer;
    address public immutable guardian;

    Operation[] public operations;

    /// @notice What the registry's ceiling should read, given every operation that has completed
    /// @dev Written only where an execution succeeded, so a value reaching the registry any other
    ///      way pulls the two apart.
    uint256 public expectedCap;

    uint256 public scheduled;
    uint256 public executed;
    uint256 public executedInstantly;
    uint256 public cancelled;
    uint256 public rejections;

    constructor(ProtocolAdmin _admin, Registry _registry, address _proposer, address _guardian) {
        admin = _admin;
        registry = _registry;
        proposer = _proposer;
        guardian = _guardian;
    }

    /// @notice How many operations the campaign has announced or taken so far
    /// @return The tracked operation count
    function operationCount() external view returns (uint256) {
        return operations.length;
    }

    /// @notice A proposer announces a change to the registry's price ceiling
    function scheduleCap(uint96 _cap, bytes32 _salt) external {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (_cap));
        uint256 delay = admin.getMinDelay();

        vm.prank(proposer);
        try admin.schedule(address(registry), 0, data, bytes32(0), _salt, delay) {
            operations.push(
                Operation({
                    target: address(registry),
                    data: data,
                    salt: _salt,
                    id: admin.hashOperation(address(registry), 0, data, bytes32(0), _salt),
                    cap: _cap
                })
            );
            ++scheduled;
        } catch {}
    }

    /// @notice Someone holding no role at all executes an announced operation
    /// @dev The caller is derived rather than fuzzed so the campaign never signs as the proposer or
    ///      the guardian by accident, which would make an open execution look like a privileged one.
    function executeAnnounced(uint256 _index, uint256 _caller) external {
        if(operations.length == 0) return;

        Operation memory operation = operations[_index % operations.length];
        address caller = address(uint160(uint256(keccak256(abi.encode(_caller))) | 1));

        vm.prank(caller);
        try admin.execute(operation.target, 0, operation.data, bytes32(0), operation.salt) {
            expectedCap = operation.cap;
            ++executed;
        } catch {}
    }

    /// @notice A guardian takes an operation without waiting
    function executeInstantly(uint96 _cap, bytes32 _salt) external {
        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (_cap));
        bytes32 id = admin.hashOperation(address(registry), 0, data, bytes32(0), _salt);

        vm.prank(guardian);
        try admin.executeInstantly(address(registry), 0, data, bytes32(0), _salt) {
            operations.push(
                Operation({target: address(registry), data: data, salt: _salt, id: id, cap: _cap})
            );
            expectedCap = _cap;
            ++executedInstantly;
        } catch {}
    }

    /// @notice A proposer calls off something it announced
    function cancelAnnounced(uint256 _index) external {
        if(operations.length == 0) return;

        bytes32 id = operations[_index % operations.length].id;

        vm.prank(proposer);
        try admin.cancel(id) {
            ++cancelled;
        } catch {}
    }

    /// @notice The clock moves, which is the only reason a waiting operation ever becomes ready
    function passTime(uint32 _seconds) external {
        vm.warp(block.timestamp + (uint256(_seconds) % 7 days));
    }

    /// @notice Nobody outside the proposer set may announce anything
    function rejectsAnUnauthorisedSchedule(address _caller, uint96 _cap) external {
        if(_caller == proposer) return;

        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (_cap));

        vm.prank(_caller);
        try admin.schedule(address(registry), 0, data, bytes32(0), bytes32(0), admin.getMinDelay()) {
            revert("an account outside the proposer set announced an operation");
        } catch {
            ++rejections;
        }
    }

    /// @notice Nobody outside the guardian set may skip the delay
    function rejectsAnUnauthorisedInstantExecution(address _caller, uint96 _cap) external {
        if(_caller == guardian) return;

        bytes memory data = abi.encodeCall(registry.setDefaultDataBundlePriceCap, (_cap));

        vm.prank(_caller);
        try admin.executeInstantly(address(registry), 0, data, bytes32(0), bytes32(0)) {
            revert("an account outside the guardian set skipped the delay");
        } catch {
            ++rejections;
        }
    }

    /// @notice Nobody may reach the registry without going through the admin contract
    function rejectsADirectCallToTheRegistry(address _caller, uint96 _cap) external {
        if(_caller == address(admin)) return;

        vm.prank(_caller);
        try registry.setDefaultDataBundlePriceCap(_cap) {
            revert("an account reached the registry without going through the admin contract");
        } catch {
            ++rejections;
        }
    }

    /// @notice Nobody may hand out a role directly
    function rejectsADirectRoleGrant(address _caller, address _recipient) external {
        if(_caller == address(admin)) return;

        vm.prank(_caller);
        try admin.grantRole(admin.GUARDIAN_ROLE(), _recipient) {
            revert("an account granted itself a role without going through the delay");
        } catch {
            ++rejections;
        }
    }
}
