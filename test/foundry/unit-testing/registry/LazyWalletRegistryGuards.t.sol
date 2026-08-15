// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockLazyWalletRegistry.sol";

/// @notice Covers the input guards on `LazyWalletRegistry`.
/// @dev The population, switching and deployment behaviour is covered in
///      `LazyWalletRegistry.t.sol`. What is here is the initialiser, the array shape checks, and
///      every arm that refuses a malformed identifier.
contract LazyWalletRegistryGuardsTest is DeployerBase {

    string constant DEVICE = "Device_Guarded";
    string constant OTHER_DEVICE = "Device_Guarded_Other";
    string constant ESIM = "eSIM_Guarded_1";

    /// @notice Binds one eSIM identifier to one device identifier with a single purchase
    function _bindOneESIM() internal {
        string[] memory devices = new string[](1);
        string[][] memory eSIMs = new string[][](1);
        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);

        devices[0] = DEVICE;
        eSIMs[0] = new string[](1);
        eSIMs[0][0] = ESIM;
        bundles[0] = new DataBundleDetails[](1);
        bundles[0][0] = DataBundleDetails("DB_ID_1", 11);

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }

    /// @notice Calls batchPopulateHistory with arrays of the given lengths, expecting a revert
    /// @param _deviceCount Length of the device identifier array
    /// @param _eSIMCount Length of the outer eSIM identifier array
    /// @param _bundleCount Length of the outer data bundle array
    /// @param _error The encoded error expected
    function _expectBatchToRevert(
        uint256 _deviceCount,
        uint256 _eSIMCount,
        uint256 _bundleCount,
        bytes memory _error
    ) internal {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(_error);
        lazyWalletRegistry.batchPopulateHistory(
            new string[](_deviceCount), new string[][](_eSIMCount), new DataBundleDetails[][](_bundleCount)
        );
    }

    /// @notice Calls switchESIMIdentifierToNewDeviceIdentifier, expecting a revert
    /// @param _eSIM The eSIM identifier to move
    /// @param _oldDevice The device it is claimed to be on
    /// @param _newDevice The device it should move to
    /// @param _error The encoded error expected
    function _expectSwitchToRevert(
        string memory _eSIM,
        string memory _oldDevice,
        string memory _newDevice,
        bytes memory _error
    ) internal {
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(_error);
        lazyWalletRegistry.switchESIMIdentifierToNewDeviceIdentifier(_eSIM, _oldDevice, _newDevice);
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice The lazy wallet registry cannot be initialised without a registry
    /// @dev Its admin gate reads the registry, so a zero here closes every function on it.
    function test_initialize_rejectsAZeroRegistry() public {
        MockLazyWalletRegistry implementation = new MockLazyWalletRegistry();

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_registry"));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(implementation.initialize, (address(0), upgradeManager))
        );
    }

    /// @notice The lazy wallet registry cannot be initialised without an owner
    function test_initialize_rejectsAZeroUpgradeManager() public {
        MockLazyWalletRegistry implementation = new MockLazyWalletRegistry();
        address registryAddress = address(registry);

        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_upgradeManager"));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(implementation.initialize, (registryAddress, address(0)))
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Batch shape
    // ---------------------------------------------------------------------------------------------

    /// @notice Fewer eSIM identifier lists than devices is refused
    /// @dev Each device gets one list. A mismatch here pairs one device's eSIMs with another's.
    function test_batchPopulateHistory_rejectsAShortESIMIdentifierArray() public {
        _expectBatchToRevert(2, 1, 2, abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 2, 1));
    }

    /// @notice Fewer data bundle lists than devices is refused
    function test_batchPopulateHistory_rejectsAShortDataBundleArray() public {
        _expectBatchToRevert(2, 2, 1, abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 2, 1));
    }

    /// @notice A device with more eSIM identifiers than purchase records is refused
    /// @dev This is the inner check, one level below the two above. It pairs identifiers with
    ///      bundles inside a single device's entry.
    function test_batchPopulateHistory_rejectsUnpairedESIMsAndBundles() public {
        string[] memory devices = new string[](1);
        string[][] memory eSIMs = new string[][](1);
        devices[0] = DEVICE;
        eSIMs[0] = new string[](2);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.ArrayLengthMismatch.selector, 2, 0));
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, new DataBundleDetails[][](1));
    }

    // ---------------------------------------------------------------------------------------------
    // Empty identifiers
    // ---------------------------------------------------------------------------------------------

    /// @notice A device identifier cannot be empty
    /// @dev Every empty identifier resolves to the same storage slot, so one accepted here would
    ///      pool unrelated devices' eSIMs together.
    function test_batchPopulateHistory_rejectsAnEmptyDeviceIdentifier() public {
        _expectBatchToRevert(1, 1, 1, abi.encodeWithSelector(Errors.EmptyDeviceIdentifier.selector));
    }

    /// @notice An eSIM identifier cannot be empty
    function test_batchPopulateHistory_rejectsAnEmptyESIMIdentifier() public {
        string[] memory devices = new string[](1);
        string[][] memory eSIMs = new string[][](1);
        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);

        devices[0] = DEVICE;
        eSIMs[0] = new string[](1);
        bundles[0] = new DataBundleDetails[](1);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyESIMIdentifier.selector);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice A deployment cannot claim a deposit larger than the ETH that came with it
    /// @dev The claimed amount is what the factory hands to the wallet, so accepting a larger one
    ///      would spend ETH sent for a different deployment in the same batch.
    function test_deployLazyWalletAndSetESIMIdentifier_rejectsADepositThatDoesNotMatchTheETHSent() public {
        _bindOneESIM();
        vm.deal(eSIMWalletAdmin, 1 ether);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.DepositDoesNotMatchValue.selector, 2 ether, 1 ether));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier{value: 1 ether}(pubKey1, DEVICE, 11001, 2 ether, 1);
    }

    /// @notice A batch size of zero or above the cap is refused rather than clamped
    /// @dev Refusing is what keeps the return value honest. Clamping a request of a thousand down to
    ///      twenty would tell a caller it deployed a thousand wallets.
    function test_deployLazyWalletAndSetESIMIdentifier_rejectsABatchOutsideTheCap() public {
        _bindOneESIM();
        uint256 cap = lazyWalletRegistry.MAX_ESIM_WALLETS_PER_CALL();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyESIMWallets.selector, 0, cap));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, DEVICE, 11002, 0, 0);

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.TooManyESIMWallets.selector, cap + 1, cap));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, DEVICE, 11003, 0, cap + 1);
    }

    /// @notice The continuation refuses a device this contract never deployed
    /// @dev The cursor is the marker, not the registry's device wallet record. A device deployed
    ///      through the ordinary route under an identifier a fiat user's eSIMs are bound to would
    ///      otherwise receive their wallets, and later their purchase history.
    function test_deployMoreESIMWalletsForLazyDevice_rejectsADeviceItNeverDeployed() public {
        _bindOneESIM();

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.LazyWalletNotDeployed.selector, DEVICE));
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(DEVICE, 1);
    }

    /// @notice The continuation refuses a caller other than the admin
    function test_deployMoreESIMWalletsForLazyDevice_rejectsANonAdminCaller() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyESIMWalletAdmin.selector);
        lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(DEVICE, 1);
    }

    /// @notice A salt with no room left for the whole eSIM list is refused
    /// @dev Each eSIM wallet is deployed at the device salt plus its position in the list, so a salt
    ///      within the list length of the maximum would wrap partway through and land a later batch
    ///      on an address another device already holds. The whole range is checked here rather than
    ///      one batch at a time, because a device that runs out of salt halfway can neither be
    ///      finished nor redeployed.
    function test_deployLazyWalletAndSetESIMIdentifier_rejectsASaltWithNoRoomForTheESIMWallets() public {
        _bindOneESIM();
        uint256 salt = type(uint256).max - 1;

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.SaltTooHigh.selector, salt, 1));
        lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(pubKey1, DEVICE, salt, 0, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Switching a device
    // ---------------------------------------------------------------------------------------------

    /// @notice An eSIM identifier has to be named to be moved
    function test_switchESIMIdentifierToNewDeviceIdentifier_rejectsAnEmptyESIMIdentifier() public {
        _expectSwitchToRevert("", DEVICE, OTHER_DEVICE, abi.encodeWithSelector(Errors.EmptyESIMIdentifier.selector));
    }

    /// @notice A destination device has to be named
    function test_switchESIMIdentifierToNewDeviceIdentifier_rejectsAnEmptyNewDeviceIdentifier() public {
        _expectSwitchToRevert(ESIM, DEVICE, "", abi.encodeWithSelector(Errors.EmptyDeviceIdentifier.selector));
    }

    /// @notice The caller has to name the device the eSIM is actually on
    /// @dev Checked by length first and then by hash. This case fails the length check.
    function test_switchESIMIdentifierToNewDeviceIdentifier_rejectsAnOldDeviceOfADifferentLength() public {
        _bindOneESIM();

        _expectSwitchToRevert(ESIM, "Short", OTHER_DEVICE, abi.encodeWithSelector(Errors.ESIMBoundToADifferentDevice.selector, ESIM, DEVICE));
    }

    /// @notice A device of the right length but the wrong name is refused too
    /// @dev This is the arm the length check cannot catch, and the one that matters: the old device
    ///      identifier decides whose purchase history gets deleted.
    function test_switchESIMIdentifierToNewDeviceIdentifier_rejectsAnOldDeviceOfTheSameLength() public {
        _bindOneESIM();

        _expectSwitchToRevert(ESIM, "Device_GuardeX", OTHER_DEVICE, abi.encodeWithSelector(Errors.ESIMBoundToADifferentDevice.selector, ESIM, DEVICE));
    }

    /// @notice Moving an eSIM to the device it is already on is refused
    /// @dev The move removes the identifier from the old list and pushes it onto the new one. With
    ///      the same list on both sides that is a pop followed by a push, which would leave the
    ///      history deleted and the binding intact.
    function test_switchESIMIdentifierToNewDeviceIdentifier_rejectsSwitchingToTheSameDevice() public {
        _bindOneESIM();

        _expectSwitchToRevert(ESIM, DEVICE, DEVICE, abi.encodeWithSelector(Errors.CannotSwitchToTheSameDevice.selector, DEVICE));
    }

    /// @notice A desynced association record reverts cleanly instead of panicking
    /// @dev The two records are always written together in production, so this forces the gap
    ///      directly: the identifier names DEVICE without ever entering DEVICE's associated
    ///      list. The find-and-swap-remove loop then never finds it, and on an empty list the
    ///      unguarded version underflows computing the last index instead of reverting cleanly.
    function test_switchESIMIdentifierToNewDeviceIdentifier_revertsWhenTheIdentifierIsNotFound() public {
        lazyWalletRegistry.setESIMIdentifierToDeviceIdentifier(ESIM, DEVICE);

        _expectSwitchToRevert(
            ESIM, DEVICE, OTHER_DEVICE,
            abi.encodeWithSelector(Errors.ESIMIdentifierNotFound.selector, ESIM, DEVICE)
        );
    }
}
