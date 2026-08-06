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

    /// @notice Calls initialize with the given arguments, expecting a ZeroAddress revert
    /// @param _admin The admin address to pass
    /// @param _vault The vault address to pass
    /// @param _upgradeManager The upgrade manager address to pass
    /// @param _entryPoint The entry point to pass
    /// @param _parameter Name of the parameter the revert should name back
    function _expectInitializeToRevert(
        address _admin,
        address _vault,
        address _upgradeManager,
        IEntryPoint _entryPoint,
        string memory _parameter
    ) internal {
        MockRegistry implementation = new MockRegistry();
        address deviceFactory = address(deviceWalletFactory);
        address eSIMFactory = address(eSIMWalletFactory);

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, _parameter));
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
        _expectInitializeToRevert(address(0), vault, upgradeManager, typeCastEntryPoint, "_eSIMWalletAdmin");
    }

    /// @notice A registry cannot be initialised without a vault
    /// @dev Every data bundle payment is sent here, so a zero would burn each one.
    function test_initialize_rejectsAZeroVault() public {
        _expectInitializeToRevert(eSIMWalletAdmin, address(0), upgradeManager, typeCastEntryPoint, "_vault");
    }

    /// @notice A registry cannot be initialised without an owner
    function test_initialize_rejectsAZeroUpgradeManager() public {
        _expectInitializeToRevert(eSIMWalletAdmin, vault, address(0), typeCastEntryPoint, "_upgradeManager");
    }

    /// @notice A registry cannot be initialised without an entry point
    function test_initialize_rejectsAZeroEntryPoint() public {
        _expectInitializeToRevert(eSIMWalletAdmin, vault, upgradeManager, IEntryPoint(address(0)), "_entryPoint");
    }

    // ---------------------------------------------------------------------------------------------
    // Lazy wallet registry address
    // ---------------------------------------------------------------------------------------------

    /// @notice The lazy wallet registry address cannot be cleared
    /// @dev Unlike the two factories this one has a setter, so a zero is recoverable. It would
    ///      still leave the deployment path unreachable until someone noticed.
    function test_addOrUpdateLazyWalletRegistryAddress_rejectsTheZeroAddress() public {
        vm.prank(upgradeManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_lazyWalletRegistry"));
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

    /// @notice Only a registered device wallet may take an eSIM wallet on
    /// @dev This is the only entry point that moves the association, so an open gate would let an
    ///      outsider name itself the device wallet for any eSIM wallet in the protocol.
    function test_bindESIMWallet_rejectsACallerThatIsNotADeviceWallet() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyDeviceWallet.selector);
        registry.bindESIMWallet(user2, user1);
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
            0
        );
    }

    /// @notice Only the lazy wallet registry may push purchase history into an eSIM wallet
    /// @dev eSIM wallets accept history from the registry alone, so this forwarder is the only way
    ///      to reach that entry point. An open gate would let anyone write arbitrary purchases into
    ///      any wallet's history.
    function test_populateLazyHistory_rejectsACallerOtherThanTheLazyWalletRegistry() public {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.OnlyLazyWalletRegistry.selector);
        registry.populateLazyHistory(user2, new DataBundleDetails[](0));
    }

    /// @notice History cannot be forwarded to an address the protocol never deployed
    /// @dev The lazy wallet registry only ever names a wallet it deployed itself, so this is the
    ///      backstop that keeps the registry from making a call into an arbitrary contract.
    function test_populateLazyHistory_rejectsAnAddressThatIsNotAProtocolESIMWallet() public {
        vm.prank(address(lazyWalletRegistry));
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAProtocolESIMWallet.selector, user2));
        registry.populateLazyHistory(user2, new DataBundleDetails[](0));
    }

    /// @notice The continuation refuses a caller other than the lazy wallet registry
    /// @dev It binds eSIM wallets to a device wallet and sets their identifiers, so an open caller
    ///      could attach wallets to any device in the protocol.
    function test_deployMoreLazyESIMWallets_rejectsACallerOtherThanTheLazyRegistry() public {
        vm.prank(user2);
        vm.expectRevert(Errors.OnlyLazyWalletRegistry.selector);
        registry.deployMoreLazyESIMWallets(user1, "device", 0, 0, new string[](0));
    }

    /// @notice A device identifier that already has a wallet cannot be deployed again
    /// @dev A second deployment would overwrite the registry's record of a live wallet, leaving the
    ///      first one's eSIM wallets bound to a device nothing points at.
    function test_deployLazyWallet_rejectsADeviceIdentifierThatAlreadyHasAWallet() public {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[0];
        keys[0] = pubKey1;
        salts[0] = 7002;

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, new uint256[](1));

        address existing = registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]);
        assertNotEq(existing, address(0), "The first deployment must have registered a wallet");

        vm.prank(address(lazyWalletRegistry));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.DeviceWalletAlreadyExists.selector, customDeviceUniqueIdentifiers[0], existing
        ));
        registry.deployLazyWallet(
            pubKey2,
            customDeviceUniqueIdentifiers[0],
            7003,
            new string[](0),
            0
        );

        assertEq(
            registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]),
            existing,
            "A refused deployment must leave the first wallet bound"
        );
    }
}
