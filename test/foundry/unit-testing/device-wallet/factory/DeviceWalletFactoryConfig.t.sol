// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFactoryFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFactoryFixture.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockDeviceWalletV2.sol";

/// @notice The addresses the factory holds, and who may change each one.
contract DeviceWalletFactoryConfigTest is DeviceWalletFactoryFixture {

    function test_addRegistryAddress_withoutOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    /// @notice The admin cannot wire up the registry, because the admin is read out of it
    /// @dev Gating this on the admin would be circular: with no registry set there is no admin to
    ///      check the caller against, so the call could never be made.
    function test_addRegistryAddress_withoutAdmin() public {
        vm.startPrank(deviceWalletFactory.eSIMWalletAdmin());
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", eSIMWalletAdmin));
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    function test_addRegistryAddress_onlyOnce() public {
        vm.startPrank(deviceWalletFactory.owner());
        vm.expectRevert(abi.encodeWithSelector(Errors.RegistryAlreadySet.selector, address(registry)));
        deviceWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();
    }

    function test_updateDeviceWalletImplementation_admin() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, admin));
        deviceWalletFactory.updateDeviceWalletImplementation(user2);
        vm.stopPrank();
    }

    function test_updateDeviceWalletImplementation() public {
        // First deploy a device wallet
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[0];
        listOfKeys[0] = listOfOwnerKeys[0];
        salts[0] = 999;
        deposits[0] = 0;

        vm.startPrank(admin);
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        )[0];
        vm.stopPrank();

        // Granted before the upgrade so the assertion below checks a true survives the move,
        // which the deploy path no longer sets on its own.
        vm.prank(wallet.deviceWallet);
        MockDeviceWallet(payable(wallet.deviceWallet)).toggleAccessToETH(wallet.eSIMWallet, true);

        // Now upgrade the Device Wallet implementation contract
        address owner = deviceWalletFactory.owner();
        assertEq(owner, upgradeManager, "Upgrade manager should have been the owner");

        MockDeviceWalletV2 newDeviceWalletImpl = new MockDeviceWalletV2(
            typeCastEntryPoint,
            p256Verifier
        );
        assertNotEq(address(newDeviceWalletImpl), deviceWalletFactory.getCurrentDeviceWalletImplementation(), "Should have been different implementations");

        vm.prank(owner);
        deviceWalletFactory.updateDeviceWalletImplementation(address(newDeviceWalletImpl));
        vm.stopPrank();

        address currentImpl = deviceWalletFactory.getCurrentDeviceWalletImplementation();
        assertEq(currentImpl, address(newDeviceWalletImpl), "Device wallet implementation should have been updated");

        // Check if the new implementation works
        MockDeviceWalletV2 upgradedDeviceWallet = MockDeviceWalletV2(payable(wallet.deviceWallet));
        uint256 result = upgradedDeviceWallet.addTwoNumbers(2, 3);
        assertEq(result, 5, "Device wallet should have been upgraded");

        // Check storage variables in device wallet are still the same
        assertEq(upgradedDeviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched");
        assertEq(address(upgradedDeviceWallet.registry()), address(registry), "Registry should have been correct");
        assertEq(address(upgradedDeviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in device wallet should have matched");
        assertEq(upgradedDeviceWallet.isValidESIMWallet(wallet.eSIMWallet), true, "ESIMWallet should have been set to valid");
        assertEq(upgradedDeviceWallet.canPullETH(wallet.eSIMWallet), true, "ESIMWallet should be able to pull ETH");
    }
}
