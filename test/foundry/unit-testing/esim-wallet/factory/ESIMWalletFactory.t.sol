// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "contracts/esim-wallet/ESIMWalletFactory.sol";
import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";
import "test/utils/mocks/MockESIMWalletV2.sol";

contract ESIMWalletFactoryTest is DeployerBase {

    function test_addRegistryAddress_withoutOwner() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, eSIMWalletAdmin));
        eSIMWalletFactory.addRegistryAddress(user2);
        vm.stopPrank();
    }

    function test_addRegistryAddress_onlyOnce() public {
        address owner = eSIMWalletFactory.owner();
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RegistryAlreadySet.selector, address(registry)));
        eSIMWalletFactory.addRegistryAddress(address(registry));
        vm.stopPrank();

        assertEq(address(eSIMWalletFactory.registry()), address(registry), "Registry address should have been set");
    }

    function test_deployESIMWallet_unauthorised() public {
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyRegistryOrDeviceWalletFactoryOrDeviceWallet()")));
        eSIMWalletFactory.deployESIMWallet(user2, 999);
        vm.stopPrank();
    }

    function test_deployESIMWallet() public {
        address deviceWalletAddress = user2;

        vm.startPrank(address(registry));
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(
            deviceWalletAddress,
            999
        );
        vm.stopPrank();

        MockESIMWallet eSIMWallet = MockESIMWallet(payable(eSIMWalletAddress));

        // Check storage variables in eSIM wallet
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWallet)), true, "isESIMWalletDeployed should have been set to true");
        assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWallet.deviceWallet()), deviceWalletAddress, "ESIM wallet should have correct device wallet");
        assertEq(bytes(eSIMWallet.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWallet.owner(), deviceWalletAddress, "ESIMWallet owner should have been device wallet");
    }

    /// @notice A device wallet cannot deploy an eSIM wallet owned by a different device wallet
    /// @dev After the revert the second device wallet deploys at the same salt successfully, which
    ///      proves the address it would have used was left free.
    function test_deployESIMWallet_revertsWhenDeviceWalletNamesAnother() public {
        MockDeviceWallet deviceWalletA = _deployDeviceWallet(customDeviceUniqueIdentifiers[0], pubKey1, 401);
        MockDeviceWallet deviceWalletB = _deployDeviceWallet(customDeviceUniqueIdentifiers[1], pubKey2, 402);

        vm.prank(address(deviceWalletA));
        vm.expectRevert(Errors.OnlyDeployForSelf.selector);
        eSIMWalletFactory.deployESIMWallet(address(deviceWalletB), 403);

        vm.prank(address(deviceWalletB));
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(address(deviceWalletB), 403);

        assertEq(
            eSIMWalletFactory.isESIMWalletDeployed(eSIMWalletAddress),
            true,
            "The named device wallet should still be able to deploy at that salt"
        );
        assertEq(
            MockESIMWallet(payable(eSIMWalletAddress)).owner(),
            address(deviceWalletB),
            "The eSIM wallet should be owned by the device wallet that deployed it"
        );
    }

    /// @notice A device wallet may still deploy for itself
    function test_deployESIMWallet_allowsDeviceWalletToDeployForItself() public {
        MockDeviceWallet deviceWallet = _deployDeviceWallet(customDeviceUniqueIdentifiers[0], pubKey1, 411);

        vm.prank(address(deviceWallet));
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(address(deviceWallet), 412);

        assertEq(
            address(MockESIMWallet(payable(eSIMWalletAddress)).deviceWallet()),
            address(deviceWallet),
            "The eSIM wallet should point at the deploying device wallet"
        );
    }

    /// @notice The same salt with the same owner names an address that is already taken
    /// @dev CREATE2 reverts with no data in that case, so without the check the caller cannot
    ///      tell a reused salt apart from any other failure inside the deployment.
    function test_deployESIMWallet_revertsWhenTheSameOwnerReusesASalt() public {
        vm.startPrank(address(registry));
        address first = eSIMWalletFactory.deployESIMWallet(user2, 431);

        vm.expectRevert(abi.encodeWithSelector(Errors.SaltAlreadyUsed.selector, user2, uint256(431)));
        eSIMWalletFactory.deployESIMWallet(user2, 431);
        vm.stopPrank();

        assertTrue(
            eSIMWalletFactory.isESIMWalletDeployed(first),
            "The wallet deployed at that salt should still be registered"
        );
    }

    /// @notice The same salt with two different owners already resolves to two addresses
    /// @dev The owner sits in the encoded initialize call, which is a constructor argument and so
    ///      part of the CREATE2 init code. The salt alone does not determine the address.
    function test_deployESIMWallet_sameSaltDifferentOwnersDoNotCollide() public {
        vm.startPrank(address(registry));
        address first = eSIMWalletFactory.deployESIMWallet(user2, 421);
        address second = eSIMWalletFactory.deployESIMWallet(user3, 421);
        vm.stopPrank();

        assertNotEq(first, second, "Two owners at one salt should resolve to different addresses");
        assertEq(
            address(MockESIMWallet(payable(first)).deviceWallet()),
            user2,
            "The first eSIM wallet should point at the first owner"
        );
        assertEq(
            address(MockESIMWallet(payable(second)).deviceWallet()),
            user3,
            "The second eSIM wallet should point at the second owner"
        );
    }

    /// @notice Deploys a device wallet through the factory and completes its registration
    function _deployDeviceWallet(
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _ownerKey,
        uint256 _salt
    ) internal returns (MockDeviceWallet) {
        vm.prank(address(typeCastEntryPoint));
        address deviceWalletAddress = address(deviceWalletFactory.createAccount(
            _deviceUniqueIdentifier,
            _ownerKey,
            _salt
        ));

        vm.prank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(deviceWalletAddress, _deviceUniqueIdentifier, _ownerKey);

        return MockDeviceWallet(payable(deviceWalletAddress));
    }

    function test_updateESIMWalletImplementation_unauthorised() public {
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert();
        eSIMWalletFactory.updateESIMWalletImplementation(user2);
        vm.stopPrank();
    }

    function test_updateESIMWalletImplementation() public {
        // Deploy the device wallet
        vm.startPrank(address(typeCastEntryPoint));
        MockDeviceWallet deviceWallet = MockDeviceWallet(payable(deviceWalletFactory.createAccount(
            customDeviceUniqueIdentifiers[0],
            pubKey1,
            999
        )));
        vm.stopPrank();
        
        // Update storage variables after createAccount
        vm.startPrank(eSIMWalletAdmin);
        deviceWalletFactory.postCreateAccount(
            address(deviceWallet),
            customDeviceUniqueIdentifiers[0],
            pubKey1
        );
        vm.stopPrank();

        // Deploy eSIM wallet
        vm.startPrank(address(deviceWallet));
        address eSIMWalletAddress = eSIMWalletFactory.deployESIMWallet(
            address(deviceWallet),
            999
        );
        vm.stopPrank();

        // Add eSIM wallet to device wallet
        vm.startPrank(address(registry));
        deviceWallet.addESIMWallet(eSIMWalletAddress, true);
        vm.stopPrank();

        // Set eSIM unique identifier
        vm.startPrank(eSIMWalletAdmin);
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(eSIMWalletAddress, "ESIM_0_0");
        vm.stopPrank();

        MockESIMWallet eSIMWallet = MockESIMWallet(payable(eSIMWalletAddress));

        // Check storage variables in eSIM wallet
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWallet)), true, "isESIMWalletDeployed should have been set to true");
        assertEq(address(eSIMWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWallet.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
        assertEq(eSIMWallet.eSIMUniqueIdentifier(), "ESIM_0_0", "ESIM unique identifier should be empty");
        assertEq(eSIMWallet.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWallet.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");

        address oldESIMWalletImpl = eSIMWalletFactory.getCurrentESIMWalletImplementation();

        address owner = eSIMWalletFactory.owner();

        vm.startPrank(owner);
        MockESIMWalletV2 newESIMWalletImpl = new MockESIMWalletV2();
        eSIMWalletFactory.updateESIMWalletImplementation(address(newESIMWalletImpl));
        vm.stopPrank();

        assertNotEq(oldESIMWalletImpl, address(newESIMWalletImpl), "Implementation address should not have been same");
        assertEq(eSIMWalletFactory.getCurrentESIMWalletImplementation(), address(newESIMWalletImpl), "ESIM wallet implementation address should have updated");

        MockESIMWalletV2 eSIMWalletV2 = MockESIMWalletV2(payable(eSIMWalletAddress));

        // Check data stored initially still persists
        assertEq(eSIMWalletFactory.isESIMWalletDeployed(address(eSIMWalletV2)), true, "isESIMWalletDeployed should have been set to true");
        assertEq(address(eSIMWalletV2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet should have matched");
        assertEq(address(eSIMWalletV2.deviceWallet()), address(deviceWallet), "ESIM wallet should have correct device wallet");
        assertEq(eSIMWalletV2.eSIMUniqueIdentifier(), "ESIM_0_0", "ESIM unique identifier should be empty");
        assertEq(eSIMWalletV2.newRequestedOwner(), address(0), "ESIM wallet's new requested owner should have been address(0)");
        assertEq(eSIMWalletV2.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(eSIMWalletV2.owner(), address(deviceWallet), "ESIMWallet owner should have been device wallet");
        assertEq(eSIMWalletV2.addTwoNumbers(2, 3), 5, "ESIMWallet implementation should have updated");
    }
}
