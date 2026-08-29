// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Who may reach a device wallet's money, and where the vault address comes from.
/// @dev The pull itself is covered in DeviceWalletTokens. What is here is the access flag seen
///      through a purchase, which is the only thing that spends on a user's behalf.
contract DeviceWalletETHTest is DeviceWalletFixture {

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

    // ---------------------------------------------------------------------------------------------
    // The access flag, seen through a purchase
    // ---------------------------------------------------------------------------------------------

    function test_toggleAccessToFunds_unauthorised() public {
        deployWallets();

        assertEq(deviceWallet.canPullFunds(address(eSIMWallet1)), true, "eSIMWallet1 should be able to spend");

        vm.startPrank(user1);
        vm.expectRevert(Errors.OnlySelf.selector);
        deviceWallet.toggleAccessToFunds(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();
    }

    /// @notice A revoked wallet cannot reach the device wallet's balance
    function test_toggleAccessToFunds_revoke_deviceWalletHoldsTheToken() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), false);
        vm.stopPrank();

        assertEq(deviceWallet.canPullFunds(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to spend");

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(deviceWallet), needed);

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.FundsAccessRevoked.selector, address(eSIMWallet1)));
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_ID_0", TEST_PRICE_CENTS), ASSET_USDC, needed, nextRef());
        vm.stopPrank();
    }

    /// @notice A revoked wallet still spends what it already holds itself
    /// @dev The flag governs the pull, not the wallet's own balance. Revoking it must not strand a
    ///      wallet that was funded directly.
    function test_toggleAccessToFunds_revoke_eSIMWalletHoldsTheToken() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), false);
        vm.stopPrank();

        assertEq(deviceWallet.canPullFunds(address(eSIMWallet1)), false, "eSIMWallet1 should not be able to spend");

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(eSIMWallet1), needed);

        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet1.buyDataBundleWithToken(bundle("DB_ID_0", TEST_PRICE_CENTS), ASSET_USDC, needed, nextRef());
        vm.stopPrank();

        assertEq(settlementERC20.balanceOf(address(eSIMWallet1)), 0, "The wallet must have spent what it held");
        assertEq(settlementERC20.balanceOf(vault), needed, "The vault must hold the price");

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].id, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].priceUSDCents, TEST_PRICE_CENTS, "Data bundle price should have been correct");
    }

    /// @notice A granted wallet reaches the device wallet's balance
    function test_toggleAccessToFunds_grant_deviceWalletHoldsTheToken() public {
        deployWallets();

        assertEq(deviceWallet.canPullFunds(address(eSIMWallet2)), false, "eSIMWallet2 should not be able to spend");

        vm.startPrank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet2), true);
        vm.stopPrank();

        assertEq(deviceWallet.canPullFunds(address(eSIMWallet2)), true, "eSIMWallet2 should be able to spend");

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(deviceWallet), needed);

        vm.startPrank(eSIMWalletAdmin);
        eSIMWallet2.buyDataBundleWithToken(bundle("DB_ID_0", TEST_PRICE_CENTS), ASSET_USDC, needed, nextRef());
        vm.stopPrank();

        assertEq(settlementERC20.balanceOf(vault), needed, "The vault must hold the price");
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), 0, "The price must have come out of the device wallet");

        DataBundleDetails[] memory history = eSIMWallet2.getTransactionHistory();
        assertEq(history.length, 1, "Transaction history should have been updated");
        assertEq(history[0].id, "DB_ID_0", "Data bundle ID should have been correct");
        assertEq(history[0].priceUSDCents, TEST_PRICE_CENTS, "Data bundle price should have been correct");
    }

    // ---------------------------------------------------------------------------------------------
    // A bind never carries funds access
    // ---------------------------------------------------------------------------------------------

    /// @notice The admin cannot hand a wallet access at the moment it deploys it
    /// @dev The flag used to be the admin's to set, which made a signed revocation pointless. It
    ///      reverts now rather than being downgraded in silence.
    function test_deployESIMWallet_cannotGrantFundsAccess() public {
        deployWallets();

        vm.prank(eSIMWalletAdmin);
        vm.expectPartialRevert(Errors.FundsAccessNotGrantableAtBind.selector);
        deviceWallet.deployESIMWallet(true, 4242);
    }

    /// @notice Not even the device wallet itself may grant access at bind time
    /// @dev Pins `toggleAccessToFunds` as the single grant path, not merely the non-admin one.
    function test_addESIMWallet_cannotGrantFundsAccessEvenFromTheWalletItself() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.FundsAccessNotGrantableAtBind.selector, address(eSIMWallet3)
        ));
        deviceWallet.addESIMWallet(address(eSIMWallet3), true);
    }

    /// @notice A signed revocation stands, whatever the admin deploys afterwards
    /// @dev The finding itself. The owner revokes on one wallet, and the second the admin deploys
    ///      reaches no further: the purchase is refused and the balance is untouched.
    function test_theAdminCannotUndoARevocationByDeployingAnotherWallet() public {
        deployWallets();

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(deviceWallet), needed);

        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), false);

        vm.prank(eSIMWalletAdmin);
        vm.expectPartialRevert(Errors.FundsAccessNotGrantableAtBind.selector);
        deviceWallet.deployESIMWallet(true, 4243);

        vm.prank(eSIMWalletAdmin);
        address fresh = deviceWallet.deployESIMWallet(false, 4243);

        assertFalse(deviceWallet.canPullFunds(fresh), "The fresh wallet must arrive with no access");

        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(abi.encodeWithSelector(Errors.FundsAccessRevoked.selector, fresh));
        MockESIMWallet(payable(fresh)).buyDataBundleWithToken(
            bundle("DB_ID_0", TEST_PRICE_CENTS),
            ASSET_USDC,
            needed,
            nextRef()
        );

        assertEq(
            settlementERC20.balanceOf(address(deviceWallet)),
            needed,
            "Nothing may leave through a wallet the user never granted"
        );
        assertEq(settlementERC20.balanceOf(vault), 0, "The vault must have been paid nothing");
    }

    /// @notice Both deployment routes leave a wallet without funds access
    /// @dev Both routes used to pass the flag set. The batch is run here rather than through the
    ///      fixture, which grants access on its way past.
    function test_aFreshESIMWalletStartsWithNoFundsAccess() public {
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
            fresh.canPullFunds(batch.eSIMWallet),
            "The batch deployed wallet must arrive with no access"
        );

        vm.prank(eSIMWalletAdmin);
        address second = fresh.deployESIMWallet(false, 4245);
        assertFalse(fresh.canPullFunds(second), "The admin deployed wallet must arrive with no access");
    }

    /// @notice The owner grants after the bind, and the purchase then goes through
    /// @dev The regression guard on the other side of the change. Withholding access at bind time
    ///      is only correct if the owner still has a way to hand it over.
    function test_theOwnerGrantsAfterBinding() public {
        deployWallets();

        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(deviceWallet), needed);

        vm.prank(eSIMWalletAdmin);
        address fresh = deviceWallet.deployESIMWallet(false, 4245);

        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(fresh, true);
        assertTrue(deviceWallet.canPullFunds(fresh), "The grant must land");

        vm.prank(eSIMWalletAdmin);
        MockESIMWallet(payable(fresh)).buyDataBundleWithToken(
            bundle("DB_ID_0", TEST_PRICE_CENTS),
            ASSET_USDC,
            needed,
            nextRef()
        );

        assertEq(settlementERC20.balanceOf(vault), needed, "The vault must have been paid");
        assertEq(
            settlementERC20.balanceOf(address(deviceWallet)),
            0,
            "The price must have come out of the device wallet"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // ETH the owner still holds
    // ---------------------------------------------------------------------------------------------

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
