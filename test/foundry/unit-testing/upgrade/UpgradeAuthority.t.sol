// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "test/utils/DeployerBase.sol";

/// @notice Stands in for a multisig: an owner that is a contract rather than a key.
/// @dev Deliberately minimal. The question is whether the protocol accepts a contract as its
///      upgrade authority at all, not whether any particular multisig works.
contract ContractOwner {
    function acceptOwnershipOf(address _target) external {
        Ownable2StepUpgradeable(_target).acceptOwnership();
    }

    function upgrade(address _proxy, address _newImplementation) external {
        UUPSUpgradeable(_proxy).upgradeToAndCall(_newImplementation, "");
    }
}

/// @notice Covers who the protocol reports as its upgrade authority, and who it accepts as one.
/// @dev `upgradeManager` used to be a stored copy written once in `initialize` with no setter, so
///      it kept naming the deploy-time address for the rest of the contract's life. Ownership can
///      move, and the moment it does a stored copy starts naming a key that can no longer upgrade
///      anything, which is what an operator reads before preparing an upgrade.
contract UpgradeAuthorityTest is DeployerBase {

    /// @dev ERC-1967 implementation slot, keccak256("eip1967.proxy.implementation") - 1
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Moves ownership through both legs of the two-step transfer.
    /// @param _target Proxy whose ownership is moving
    /// @param _newOwner Address taking over
    function _handOver(address _target, address _newOwner) internal {
        address currentOwner = Ownable2StepUpgradeable(_target).owner();

        vm.prank(currentOwner);
        Ownable2StepUpgradeable(_target).transferOwnership(_newOwner);

        vm.prank(_newOwner);
        Ownable2StepUpgradeable(_target).acceptOwnership();
    }

    function _implementationOf(address _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(_proxy, IMPLEMENTATION_SLOT))));
    }

    /// @notice Both contracts report the address that can actually authorise an upgrade.
    function test_upgradeManager_matchesTheOwner() public view {
        assertEq(registry.upgradeManager(), registry.owner(), "The registry must report its owner");
        assertEq(
            lazyWalletRegistry.upgradeManager(),
            lazyWalletRegistry.owner(),
            "The lazy wallet registry must report its owner"
        );
    }

    /// @notice The reported authority moves with ownership.
    /// @dev This is the case a stored copy got wrong. Ownership transfer is the only way the
    ///      upgrade authority ever changes, and there was no setter to keep a copy in step.
    function test_upgradeManager_followsAnOwnershipTransferOnTheRegistry() public {
        _handOver(address(registry), user2);

        assertEq(registry.owner(), user2, "Ownership must have moved");
        assertEq(registry.upgradeManager(), user2, "The reported authority must move with it");
    }

    function test_upgradeManager_followsAnOwnershipTransferOnTheLazyWalletRegistry() public {
        _handOver(address(lazyWalletRegistry), user2);

        assertEq(lazyWalletRegistry.owner(), user2, "Ownership must have moved");
        assertEq(lazyWalletRegistry.upgradeManager(), user2, "The reported authority must move with it");
    }

    /// @notice The retired owner can no longer upgrade, and the reported authority says so.
    /// @dev Asserting the getter alone would not catch a getter that tracks the wrong thing. This
    ///      pairs it with the guard it is supposed to describe.
    function test_upgradeManager_theRetiredOwnerCannotUpgrade() public {
        address retiredOwner = registry.owner();
        _handOver(address(registry), user2);

        Registry newImplementation = new Registry();

        vm.prank(retiredOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", retiredOwner));
        UUPSUpgradeable(address(registry)).upgradeToAndCall(address(newImplementation), "");

        assertEq(registry.upgradeManager(), user2, "The reported authority must be the one that can upgrade");
    }

    /// @notice A contract can hold the upgrade authority and use it.
    /// @dev The deployment plan moves ownership from a single key to a multisig, which is a
    ///      contract. Nothing in the protocol treats an owner as a key, and this is what says so:
    ///      the two-step handover completes, the getter reports the contract, and the contract
    ///      drives a real upgrade through to the implementation slot.
    function test_upgradeManager_acceptsAContractAsTheUpgradeAuthority() public {
        ContractOwner multisig = new ContractOwner();

        vm.prank(registry.owner());
        Ownable2StepUpgradeable(address(registry)).transferOwnership(address(multisig));
        multisig.acceptOwnershipOf(address(registry));

        assertEq(registry.upgradeManager(), address(multisig), "A contract must be reportable as the authority");

        Registry newImplementation = new Registry();
        multisig.upgrade(address(registry), address(newImplementation));

        assertEq(
            _implementationOf(address(registry)),
            address(newImplementation),
            "The contract owner must be able to complete an upgrade"
        );
    }
}
