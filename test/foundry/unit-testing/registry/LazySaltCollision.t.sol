// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice A salt inside a lazy device's reserved range can already be occupied by an eSIM wallet
///         deployed through the ordinary route, since both share one CREATE2 address space and
///         nothing coordinates them.
/// @dev Before the fix, `deployMoreESIMWalletsForLazyDevice` reverted `SaltAlreadyUsed` in that
///      case and the device's remaining identifiers never got wallets, with no onchain recovery.
contract LazySaltCollisionTest is DeployerBase {

    /// @notice A batch that lands on an occupied salt probes forward instead of reverting
    /// @dev The device wallet claims the next natural salt directly through
    ///      `DeviceWallet.deployESIMWallet`, which is exactly the address the lazy batch would have
    ///      landed on. Before the fix this call reverted `SaltAlreadyUsed`.
    function test_deployMoreLazyESIMWallets_survivesAnOccupiedSalt() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 2);

        vm.prank(eSIMWalletAdmin);
        (address deviceWallet,, uint256 remaining) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            9001,
            0,
            1
        );
        assertEq(remaining, 1, "One identifier must still be waiting");

        // The next lazy batch would naturally land on salt 9002. Claim it through the ordinary
        // device-wallet route first.
        uint256 occupiedSalt = 9001 + 1;
        vm.prank(eSIMWalletAdmin);
        MockDeviceWallet(payable(deviceWallet)).deployESIMWallet(false, occupiedSalt);

        vm.prank(eSIMWalletAdmin);
        (address[] memory eSIMWallets, uint256 left) = lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(
            device,
            1
        );

        assertEq(left, 0, "The batch must still finish the device");
        assertEq(eSIMWallets.length, 1, "The probed batch must still deploy one wallet");
        assertNotEq(eSIMWallets[0], address(0), "The probed wallet must exist");
    }

    /// @notice A wallet deployed at a probed salt is bound exactly like any other lazy wallet
    function test_deployMoreLazyESIMWallets_probedWalletsAreStillBound() public {
        string memory device = customDeviceUniqueIdentifiers[0];
        _bindESIMs(device, 2);

        vm.prank(eSIMWalletAdmin);
        (address deviceWallet,,) = lazyWalletRegistry.deployLazyWalletAndSetESIMIdentifier(
            pubKey1,
            device,
            9101,
            0,
            1
        );

        vm.prank(eSIMWalletAdmin);
        MockDeviceWallet(payable(deviceWallet)).deployESIMWallet(false, 9101 + 1);

        vm.prank(eSIMWalletAdmin);
        (address[] memory eSIMWallets,) = lazyWalletRegistry.deployMoreESIMWalletsForLazyDevice(device, 1);
        address probedWallet = eSIMWallets[0];

        assertEq(
            registry.isESIMWalletValid(probedWallet),
            deviceWallet,
            "The probed wallet must be recorded against its device wallet"
        );
        assertTrue(
            MockDeviceWallet(payable(deviceWallet)).isValidESIMWallet(probedWallet),
            "The device wallet must recognise the probed wallet"
        );
        assertEq(
            MockESIMWallet(payable(probedWallet)).eSIMUniqueIdentifier(),
            _eSIMName(1),
            "The probed wallet must carry the identifier it was deployed for"
        );
    }

    /// @notice The predicted address matches what the factory actually deploys
    function test_getCounterFactualAddress_matchesTheDeployedAddress() public {
        address predicted = eSIMWalletFactory.getCounterFactualAddress(user2, 9201);

        vm.prank(address(registry));
        address deployed = eSIMWalletFactory.deployESIMWallet(user2, 9201);

        assertEq(predicted, deployed, "The predicted address must match the deployed one");
    }

    /// @notice The identifier the binding gives the eSIM at a given position
    function _eSIMName(uint256 _index) private pure returns (string memory) {
        return string.concat("batch_esim_", vm.toString(_index));
    }

    /// @notice Binds `_count` eSIM identifiers to a device, each with one purchase entry
    function _bindESIMs(string memory _device, uint256 _count) private {
        string[] memory devices = new string[](1);
        devices[0] = _device;

        string[][] memory eSIMs = new string[][](1);
        eSIMs[0] = new string[](_count);

        DataBundleDetails[][] memory bundles = new DataBundleDetails[][](1);
        bundles[0] = new DataBundleDetails[](_count);

        for(uint256 i=0; i<_count; ++i) {
            eSIMs[0][i] = _eSIMName(i);
            bundles[0][i] = bundle("DB_BATCH", TEST_PRICE_CENTS);
        }

        vm.prank(eSIMWalletAdmin);
        lazyWalletRegistry.batchPopulateHistory(devices, eSIMs, bundles);
    }
}
