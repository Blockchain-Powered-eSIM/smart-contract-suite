// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockRegistry.sol";

/// @notice Covers the initialiser checks and the caller gates on `Registry`.
/// @dev The admin rotation, pause and price cap behaviour is covered in `Registry.t.sol`, and the
///      two factory address checks in `RegistryInitialize.t.sol`. What is left is the four
///      remaining initialiser arguments and every gate that refuses a caller.
contract RegistryGuardsTest is DeployerBase {

    /// @notice Calls initialize with the given arguments, expecting the given revert string
    /// @param _admin The admin address to pass
    /// @param _vault The vault address to pass
    /// @param _upgradeManager The upgrade manager address to pass
    /// @param _entryPoint The entry point to pass
    /// @param _reason The revert string expected
    function _expectInitializeToRevert(
        address _admin,
        address _vault,
        address _upgradeManager,
        IEntryPoint _entryPoint,
        string memory _reason
    ) internal {
        MockRegistry implementation = new MockRegistry();
        address deviceFactory = address(deviceWalletFactory);
        address eSIMFactory = address(eSIMWalletFactory);

        vm.expectRevert(bytes(_reason));
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                implementation.initialize,
                (_admin, _vault, _upgradeManager, deviceFactory, eSIMFactory, _entryPoint)
            )
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice A registry cannot be initialised without an admin
    /// @dev The admin is the only address that can nominate a successor, so a zero here leaves the
    ///      role permanently vacant and every admin gated path in the protocol closed.
    function test_initialize_rejectsAZeroAdmin() public {
        _expectInitializeToRevert(address(0), vault, upgradeManager, typeCastEntryPoint, "_eSIMWalletAdmin 0");
    }

    /// @notice A registry cannot be initialised without a vault
    /// @dev Every data bundle payment is sent here, so a zero would burn each one.
    function test_initialize_rejectsAZeroVault() public {
        _expectInitializeToRevert(eSIMWalletAdmin, address(0), upgradeManager, typeCastEntryPoint, "_vault 0");
    }

    /// @notice A registry cannot be initialised without an owner
    function test_initialize_rejectsAZeroUpgradeManager() public {
        _expectInitializeToRevert(eSIMWalletAdmin, vault, address(0), typeCastEntryPoint, "_upgradeManager 0");
    }

    /// @notice A registry cannot be initialised without an entry point
    function test_initialize_rejectsAZeroEntryPoint() public {
        _expectInitializeToRevert(eSIMWalletAdmin, vault, upgradeManager, IEntryPoint(address(0)), "_entryPoint 0");
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy wallet registry address
    // ---------------------------------------------------------------------------------------------

    /// @notice The lazy wallet registry address cannot be cleared
    /// @dev Unlike the two factories this one has a setter, so a zero is recoverable. It would
    ///      still leave the deployment path unreachable until someone noticed.
    function test_addOrUpdateLazyWalletRegistryAddress_rejectsTheZeroAddress() public {
        vm.prank(upgradeManager);
        vm.expectRevert("_lazyWalletRegistry 0");
        registry.addOrUpdateLazyWalletRegistryAddress(address(0));
    }

    /// @notice Only the owner may repoint the lazy wallet registry
    /// @dev Not the admin. The lazy wallet registry is the one caller allowed to deploy wallets on
    ///      a user's behalf, so repointing it is an upgrade level action.
    function test_addOrUpdateLazyWalletRegistryAddress_rejectsTheAdmin() public {
        address current = registry.lazyWalletRegistry();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, eSIMWalletAdmin));
        registry.addOrUpdateLazyWalletRegistryAddress(user1);

        assertEq(registry.lazyWalletRegistry(), current, "A refused update must leave the address alone");
    }

    // ---------------------------------------------------------------------------------------------
    // Caller gates
    // ---------------------------------------------------------------------------------------------

    /// @notice Only the device wallet factory may record a wallet's details
    /// @dev This write creates the identifier and owner key bindings the whole protocol trusts, so
    ///      an open one would let anyone claim a device identifier.
    function test_updateDeviceWalletInfo_rejectsACallerOtherThanTheFactory() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyDeviceWalletFactory.selector);
        registry.updateDeviceWalletInfo(user1, customDeviceUniqueIdentifiers[0], pubKey1);
    }

    /// @notice Only a registered device wallet may move its own owner key binding
    /// @dev The subject is msg.sender rather than an argument, so the gate is the whole
    ///      authorisation. An unregistered caller must not reach it at all.
    function test_updateDeviceWalletOwnerKey_rejectsACallerThatIsNotADeviceWallet() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        registry.updateDeviceWalletOwnerKey(pubKey2);
    }

    /// @notice Only a registered device wallet may put an eSIM wallet on standby
    function test_toggleESIMWalletStandbyStatus_rejectsACallerThatIsNotADeviceWallet() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        registry.toggleESIMWalletStandbyStatus(user2, true);
    }

    /// @notice Only a registered device wallet may change which device an eSIM wallet belongs to
    function test_updateDeviceWalletAssociatedWithESIMWallet_rejectsACallerThatIsNotADeviceWallet() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        registry.updateDeviceWalletAssociatedWithESIMWallet(user2, user1);
    }

    /// @notice Only the lazy wallet registry may deploy a wallet on a user's behalf
    /// @dev This is the one entry point that mints a device wallet and its eSIM wallets from an
    ///      identifier alone, with no owner signature anywhere in the call. The gate is the whole
    ///      authorisation, so an open one would let anyone deploy a wallet against any identifier
    ///      and claim the purchase history attached to it.
    function test_deployLazyWallet_rejectsACallerOtherThanTheLazyWalletRegistry() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyLazyWalletRegistry.selector);
        registry.deployLazyWallet(
            pubKey1,
            customDeviceUniqueIdentifiers[0],
            7001,
            new string[](0),
            new DataBundleDetails[][](0),
            0
        );
    }
}
