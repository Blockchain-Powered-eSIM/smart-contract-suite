// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Every path ETH takes into and out of a device wallet, and who may open each one.
contract DeviceWalletETHTest is DeviceWalletFixture {

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

    /// @notice One write in the registry has to reach every wallet, because a wallet reads the vault
    /// on each purchase rather than caching it.
    /// @dev The address used to sit on the device wallet factory as well, where nothing on the
    /// payment path ever read it, so the only copy anyone could rotate was the one that never
    /// received the money.
    function test_getVaultAddress_followsTheRegistry() public {
        deployWallets();

        assertEq(deviceWallet.getVaultAddress(), vault, "The wallet must start on the deployed vault");
        assertEq(deviceWallet2.getVaultAddress(), vault, "The second wallet must start there too");

        vm.prank(registry.owner());
        registry.updateVaultAddress(user5);

        assertEq(deviceWallet.getVaultAddress(), user5, "The wallet must follow in the same transaction");
        assertEq(deviceWallet2.getVaultAddress(), user5, "Every wallet must follow, not just one");
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

    // ---------------------------------------------------------------------------------------------
    // A bind never carries ETH access
    // ---------------------------------------------------------------------------------------------

    /// @notice The admin cannot hand a wallet ETH access at the moment it deploys it
    /// @dev The flag used to be the admin's to set, which is what made a signed revocation
    ///      pointless. It reverts now rather than being downgraded, so a caller that thinks it
    ///      granted access finds out at the call.
    function test_deployESIMWallet_cannotGrantETHAccess() public {
        deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectPartialRevert(Errors.ETHAccessNotGrantableAtBind.selector);
        deviceWallet.deployESIMWallet(true, 4242);
    }

    /// @notice Not even the device wallet itself may grant access at bind time
    /// @dev Pins that `toggleAccessToETH` is the single grant path rather than merely the non-admin
    ///      one. The owner has a way to grant, and this is not it.
    function test_addESIMWallet_cannotGrantETHAccessEvenFromTheWalletItself() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ETHAccessNotGrantableAtBind.selector, address(eSIMWallet3)
        ));
        deviceWallet.addESIMWallet(address(eSIMWallet3), true);
    }

    /// @notice A signed revocation stands, whatever the admin deploys afterwards
    /// @dev The finding itself. The owner revokes on one wallet, the admin reaches for a second
    ///      carrying access and is refused, and the wallet it can deploy reaches no further than
    ///      the first: the device wallet's balance is untouched and the purchase is refused.
    function test_theAdminCannotUndoARevocationByDeployingAnotherWallet() public {
        deployWallets();
        vm.deal(address(deviceWallet), 10 ether);

        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(address(eSIMWallet1), false);

        vm.prank(eSIMWalletAdmin);
        vm.expectPartialRevert(Errors.ETHAccessNotGrantableAtBind.selector);
        deviceWallet.deployESIMWallet(true, 4243);

        vm.prank(eSIMWalletAdmin);
        address fresh = deviceWallet.deployESIMWallet(false, 4243);

        assertFalse(deviceWallet.canPullETH(fresh), "The fresh wallet must arrive with no ETH access");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.ETHAccessRevoked.selector, fresh));
        MockESIMWallet(payable(fresh)).buyDataBundle(DataBundleDetails("DB_ID_0", 1 ether));

        assertEq(address(deviceWallet).balance, 10 ether, "No ETH may leave through a wallet the user never granted");
        assertEq(vault.balance, 0, "The vault must have been paid nothing");
    }

    /// @notice Both deployment routes leave a wallet without ETH access
    /// @dev The batch route the factory drives and the single deploy the admin drives used to pass
    ///      the flag set, so a wallet arrived able to pull before the owner had said anything. The
    ///      batch is run here rather than through the fixture, which grants access on its way past.
    function test_aFreshESIMWalletStartsWithNoETHAccess() public {
        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = customDeviceUniqueIdentifiers[3];
        keys[0] = listOfOwnerKeys[3];
        salts[0] = 4244;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets memory batch = deviceWalletFactory.deployDeviceWalletForUsers(
            identifiers,
            keys,
            salts,
            deposits
        )[0];

        MockDeviceWallet fresh = MockDeviceWallet(payable(batch.deviceWallet));
        assertFalse(
            fresh.canPullETH(batch.eSIMWallet),
            "The batch deployed wallet must arrive with no ETH access"
        );

        vm.prank(eSIMWalletAdmin);
        address second = fresh.deployESIMWallet(false, 4245);
        assertFalse(fresh.canPullETH(second), "The admin deployed wallet must arrive with no ETH access");
    }

    /// @notice The owner grants after the bind, and the purchase then goes through
    /// @dev The regression guard on the other side of the change. Withholding access at bind time
    ///      is only correct if the owner still has a way to hand it over.
    function test_theOwnerGrantsAfterBinding() public {
        deployWallets();
        vm.deal(address(deviceWallet), 10 ether);

        vm.prank(eSIMWalletAdmin);
        address fresh = deviceWallet.deployESIMWallet(false, 4245);

        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToETH(fresh, true);
        assertTrue(deviceWallet.canPullETH(fresh), "The grant must land");

        vm.prank(eSIMWalletAdmin);
        MockESIMWallet(payable(fresh)).buyDataBundle(DataBundleDetails("DB_ID_0", 1 ether));

        assertEq(vault.balance, 1 ether, "The vault must have been paid");
        assertEq(address(deviceWallet).balance, 9 ether, "The price must have come out of the device wallet");
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
