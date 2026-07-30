// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice Ownership cannot be renounced on any Ownable contract in the protocol
contract RenounceOwnershipTest is DeployerBase {

    /// @notice Deploys one device wallet and returns it with its first eSIM wallet
    function _deployWalletPair() internal returns (MockDeviceWallet, MockESIMWallet) {
        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = customDeviceUniqueIdentifiers[0];
        listOfKeys[0] = listOfOwnerKeys[0];
        salts[0] = 871;
        deposits[0] = 0;

        vm.startPrank(deviceWalletFactory.eSIMWalletAdmin());
        Wallets memory wallet = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        )[0];
        vm.stopPrank();

        return (
            MockDeviceWallet(payable(wallet.deviceWallet)),
            MockESIMWallet(payable(wallet.eSIMWallet))
        );
    }

    /// @notice The device wallet cannot renounce ownership of its eSIM wallet through execute
    /// @dev This is the only reachable route: the eSIM wallet's owner is the device wallet, which
    ///      reaches arbitrary targets through execute once the EntryPoint has validated the
    ///      passkey signature.
    function test_renounceOwnership_revertsOnESIMWalletViaDeviceWallet() public {
        (MockDeviceWallet deviceWallet, MockESIMWallet eSIMWallet) = _deployWalletPair();

        assertEq(eSIMWallet.owner(), address(deviceWallet), "eSIM wallet owner should be the device wallet");

        Call memory call = Call({
            dest: address(eSIMWallet),
            value: 0,
            data: abi.encodeWithSignature("renounceOwnership()")
        });

        vm.prank(address(entryPoint));
        vm.expectRevert(Errors.OwnershipCannotBeRenounced.selector);
        deviceWallet.execute(call);

        assertEq(eSIMWallet.owner(), address(deviceWallet), "eSIM wallet owner should be unchanged");
        assertEq(
            registry.isESIMWalletValid(address(eSIMWallet)),
            address(deviceWallet),
            "Registry binding should be unchanged"
        );
    }

    /// @notice The owner cannot renounce ownership of the registry
    function test_renounceOwnership_revertsOnRegistry() public {
        assertEq(registry.owner(), upgradeManager, "Registry owner should be the upgrade manager");

        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OwnershipCannotBeRenounced.selector);
        registry.renounceOwnership();

        assertEq(registry.owner(), upgradeManager, "Registry owner should be unchanged");
    }

    /// @notice The owner cannot renounce ownership of the lazy wallet registry
    function test_renounceOwnership_revertsOnLazyWalletRegistry() public {
        assertEq(lazyWalletRegistry.owner(), upgradeManager, "Lazy wallet registry owner should be the upgrade manager");

        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OwnershipCannotBeRenounced.selector);
        lazyWalletRegistry.renounceOwnership();

        assertEq(lazyWalletRegistry.owner(), upgradeManager, "Lazy wallet registry owner should be unchanged");
    }

    /// @notice The owner cannot renounce ownership of the device wallet factory
    /// @dev Renouncing here would also strip the only route to the device wallet beacon
    function test_renounceOwnership_revertsOnDeviceWalletFactory() public {
        assertEq(deviceWalletFactory.owner(), upgradeManager, "Device wallet factory owner should be the upgrade manager");

        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OwnershipCannotBeRenounced.selector);
        deviceWalletFactory.renounceOwnership();

        assertEq(deviceWalletFactory.owner(), upgradeManager, "Device wallet factory owner should be unchanged");
        assertEq(
            deviceWalletFactory.beacon().owner(),
            address(deviceWalletFactory),
            "Beacon should still be owned by the factory"
        );
    }

    /// @notice The owner cannot renounce ownership of the eSIM wallet factory
    /// @dev Renouncing here would also strip the only route to the eSIM wallet beacon
    function test_renounceOwnership_revertsOnESIMWalletFactory() public {
        assertEq(eSIMWalletFactory.owner(), upgradeManager, "eSIM wallet factory owner should be the upgrade manager");

        vm.prank(upgradeManager);
        vm.expectRevert(Errors.OwnershipCannotBeRenounced.selector);
        eSIMWalletFactory.renounceOwnership();

        assertEq(eSIMWalletFactory.owner(), upgradeManager, "eSIM wallet factory owner should be unchanged");
        assertEq(
            eSIMWalletFactory.beacon().owner(),
            address(eSIMWalletFactory),
            "Beacon should still be owned by the factory"
        );
    }
}
