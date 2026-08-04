// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";

/// @notice Every path ETH takes into and out of a device wallet, and who may open each one.
contract DeviceWalletETHTest is DeviceWalletFixture {

    function test_payETHForDataBundles_unauthorised() public {
        deployWallets();

        vm.deal(user1, 0.1 ether);
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAssociatedESIMWallets()")));
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();
    }

    function test_payETHForDataBundles_revokedESIMWallet() public {
        deployWallets();

        vm.deal(address(deviceWallet), 0.1 ether);
        vm.startPrank(address(eSIMWallet2));
        vm.expectRevert(abi.encodeWithSelector(Errors.ETHAccessRevoked.selector, address(eSIMWallet2)));
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();
    }

    function test_payETHForDataBundles_noFunds() public {
        deployWallets();

        vm.startPrank(address(eSIMWallet1));
        vm.expectRevert();
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();
    }

    function test_payETHForDataBundles() public {
        deployWallets();

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(address(eSIMWallet1));
        deviceWallet.payETHForDataBundles(100000000000000000);  // 0.1 ETH
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 0.9 ether, "Device wallet balance should have reduced to 0.9 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have increased to 0.2 ether");
    }

    function test_pullETH_unauthorise() public {
        deployWallets();

        vm.deal(address(deviceWallet), 2 ether);
        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyAssociatedESIMWallets()")));
        deviceWallet.pullETH(1000000000000000000);  // 1 ETH
        vm.stopPrank();
    }

    function test_pullETH_revokedESIMWallet() public {
        deployWallets();

        vm.deal(address(deviceWallet), 2 ether);
        vm.startPrank(address(eSIMWallet2));
        vm.expectRevert(abi.encodeWithSelector(Errors.ETHAccessRevoked.selector, address(eSIMWallet2)));
        deviceWallet.pullETH(1000000000000000000);  // 1 ETH
        vm.stopPrank();
    }

    function test_pullETH() public {
        deployWallets();

        vm.deal(address(deviceWallet), 2 ether);
        vm.startPrank(address(eSIMWallet1));
        deviceWallet.pullETH(1000000000000000000);  // 1 ETH
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 1 ether, "Device wallet balance should have been 1 ETH");
        assertEq(address(eSIMWallet1).balance, 1 ether, "ESIM wallet balance should have been 1 ETH");
    }

    function test_getVaultAddress() public {
        deployWallets();

        vm.startPrank(user1);
        address vaultAddress = deviceWallet.getVaultAddress();
        vm.stopPrank();

        assertEq(vaultAddress, vault, "Vault address should have matched");
    }

    function test_toggleAccessToETH_unauthorised() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlySelf.selector);
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();
    }

    function test_toggleAccessToETH_revoke_deviceWalletHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.ETHAccessRevoked.selector, address(eSIMWallet1)));
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();
    }

    function test_toggleAccessToETH_revoke_eSIMWalletHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(eSIMWallet1), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(eSIMWallet1).balance, 0.9 ether, "ESIMWalletAdmin balance should have been decreased to 0.9 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_toggleAccessToETH_revoke_userHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "eSIMWallet1 should be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundle{value: 0.2 ether}(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(eSIMWallet1).balance, 0.1 ether, "ESIMWallet balance should have been increased to 0.1 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        assertEq(eSIMWalletAdmin.balance, 0.8 ether, "User balance should have been decreased to 0.8 ETH");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_toggleAccessToETH_grant_deviceWalletHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "eSIMWallet2 should not be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet2),
            true
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), true, "eSIMWallet2 should be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(address(deviceWallet), 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet2.buyDataBundle(_dataBundleDetail);
        vm.stopPrank();

        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        assertEq(address(deviceWallet).balance, 0.9 ether, "Device wallet balance should have been decreased to 0.9 ETH");

        DataBundleDetails[] memory history = eSIMWallet2.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    function test_toggleAccessToETH_grant_userHasETH() public {
        deployWallets();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "eSIMWallet2 should not be able to pull ETH");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(
            address(eSIMWallet2),
            true
        );
        vm.stopPrank();

        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), true, "eSIMWallet2 should be able to pull ETH");

        DataBundleDetails memory _dataBundleDetail = DataBundleDetails(
            "DB_ID_0",
            0.1 ether
        );

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet2.buyDataBundle{value: 0.2 ether}(_dataBundleDetail);
        vm.stopPrank();

        assertEq(address(eSIMWallet2).balance, 0.1 ether, "ESIMWallet balance should have been increased to 0.1 ETH");
        assertEq(vault.balance, 0.1 ether, "Vault balance should have updated to 0.1 ETH");
        assertEq(eSIMWalletAdmin.balance, 0.8 ether, "User balance should have been decreased to 0.8 ETH");

        DataBundleDetails[] memory history = eSIMWallet2.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].dataBundleID, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].dataBundlePrice, 0.1 ether, "Data bundle price should have been correct");
    }

    /// @notice Naming a function the wallet does not have must revert, while plain ETH still lands
    /// @dev A payable fallback answered every unknown selector with success, so a mistyped call,
    ///      or one naming a function a later implementation no longer has, looked like it worked.
    function test_deviceWallet_rejectsACallToAFunctionItDoesNotHave() public {
        deployWallets();
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        (bool acceptedETH, ) = address(deviceWallet).call{value: 1 ether}("");
        assertTrue(acceptedETH, "Plain ETH must still be accepted");
        assertEq(address(deviceWallet).balance, 1 ether, "The wallet must hold the ETH it accepted");

        vm.prank(user1);
        (bool acceptedCall, ) = address(deviceWallet).call(abi.encodeWithSignature("noSuchFunction()"));
        assertFalse(acceptedCall, "A call naming a function the wallet does not have must revert");
    }

    /// @notice An associated eSIM wallet can drain the device wallet through pullETH, so a live
    /// incident needs a lever that does not wait on a beacon upgrade.
    function test_pullETH_revertsWhilePaused() public {
        deployWallets();
        vm.deal(address(deviceWallet), 2 ether);

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.ProtocolPaused.selector);
        deviceWallet.pullETH(1 ether);

        assertEq(address(deviceWallet).balance, 2 ether, "No ETH may leave while paused");

        vm.prank(registry.owner());
        registry.unpause();

        vm.prank(address(eSIMWallet1));
        deviceWallet.pullETH(1 ether);
        assertEq(address(deviceWallet).balance, 1 ether, "The release must restore the path");
    }

    /// @notice The other eSIM-driven exit sends straight to the vault, so it needs the same lever
    function test_payETHForDataBundles_revertsWhilePaused() public {
        deployWallets();
        vm.deal(address(deviceWallet), 1 ether);

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.ProtocolPaused.selector);
        deviceWallet.payETHForDataBundles(0.1 ether);

        assertEq(vault.balance, 0, "The vault must receive nothing while paused");
    }

    /// @notice A pause stops the admin-driven and eSIM-driven flows, never an owner spending their
    /// own ETH. Blocking execute would hand the admin key a freeze on user funds, which is worse
    /// than what the pause defends against.
    function test_execute_stillMovesOwnerETHWhilePaused() public {
        deployWallets();
        vm.deal(address(deviceWallet), 1 ether);

        vm.prank(registry.eSIMWalletAdmin());
        registry.pause();

        uint256 balanceBefore = user2.balance;

        vm.prank(address(entryPoint));
        deviceWallet.execute(Call({dest: user2, value: 0.5 ether, data: ""}));

        assertEq(user2.balance - balanceBefore, 0.5 ether, "The owner must still reach their own ETH");
    }
}
