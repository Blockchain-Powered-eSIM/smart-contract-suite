// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";
import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {ReentrantESIMWallet} from "test/utils/mocks/ReentrantESIMWallet.sol";
import {MockDeviceWallet} from "test/utils/mocks/MockDeviceWallet.sol";
import {MockESIMWallet} from "test/utils/mocks/MockESIMWallet.sol";

/// @notice Which eSIM wallets a device wallet holds, and how one moves between devices.
contract DeviceWalletESIMWalletsTest is DeviceWalletFixture {

    /// @notice The second device wallet takes the eSIM wallet, grants it access and buys through it
    /// @dev Shared by the two handover tests, which are otherwise long enough that their locals push
    ///      the via-IR build over its stack limit.
    function _handOverToSecondDeviceAndBuy() private {
        vm.deal(address(deviceWallet2), 5 ether);
        vm.prank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();

        assertEq(eSIMWallet1.owner(), address(deviceWallet2), "newOwner should have accepted the ownership");
        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "newRequestedOwner should have reset to address(0)");

        vm.prank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), false);

        _assertESIMWalletBinding(deviceWallet2, eSIMWallet1, false, address(deviceWallet2), false, true);
        _grantAccessAndBuy();
    }

    /// @notice The second half of the handover, split so neither function overflows the IR stack
    function _grantAccessAndBuy() private {
        assertEq(address(deviceWallet2).balance, 5 ether, "Device wallet balance should have been the same");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        vm.prank(address(deviceWallet2));
        deviceWallet2.toggleAccessToFunds(address(eSIMWallet1), true);

        assertTrue(deviceWallet2.canPullFunds(address(eSIMWallet1)), "eSIMWallet1 should be able to spend");

        _buyThroughDeviceWallet(deviceWallet2, eSIMWallet1);
    }

    /// @notice Funds a device wallet and buys one bundle through the eSIM wallet it holds
    function _buyThroughDeviceWallet(MockDeviceWallet _device, MockESIMWallet _wallet) private {
        uint256 needed = settlementAmount(TEST_PRICE_CENTS);
        fundSettlementToken(address(_device), needed);

        vm.prank(eSIMWalletAdmin);
        _wallet.buyDataBundleWithToken(bundle("DB_ID_0", TEST_PRICE_CENTS), ASSET_USDC, needed, nextRef());

        _assertBundlePaidFor(_device, _wallet, needed);
    }

    /// @notice Split out of the caller so the via-IR build stays inside its stack limit
    function _assertBundlePaidFor(MockDeviceWallet _device, MockESIMWallet _wallet, uint256 _needed)
        private
        view
    {
        assertEq(settlementERC20.balanceOf(address(_device)), 0, "The whole amount came from the device wallet");
        assertEq(settlementERC20.balanceOf(vault), _needed, "The vault must hold the price");

        (bytes32 id, uint64 price,) = _wallet.transactionHistory(0);
        assertEq(id, bytes32("DB_ID_0"), "The recorded data bundle ID should have been correct");
        assertEq(price, TEST_PRICE_CENTS, "The recorded price should have been correct");
    }

    function test_deployESIMWallet() public {
        deployWallets();
    }

    function test_setESIMUniqueIdentifierForAnESIMWallet_empty() public {
        deployWallets();

        vm.startPrank(eSIMWalletAdmin);
        vm.expectRevert(Errors.EmptyESIMIdentifier.selector);
        registry.assignESIMIdentifier(address(eSIMWallet2), "");
        vm.stopPrank();
    }

    function test_setESIMUniqueIdentifierForAnESIMWallet() public {
        deployWallets();

        vm.startPrank(eSIMWalletAdmin);
        registry.assignESIMIdentifier(address(eSIMWallet2), "ESIM_0_2");
        vm.stopPrank();

        assertEq(eSIMWallet2.eSIMUniqueIdentifier(), "ESIM_0_2", "ESIM unique identifier should have been initialised");
    }

    function test_removeESIMWallet_unauthorised() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlySelfOrAssociatedESIMWallet()")));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();
    }

    function test_removeESIMWallet() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);
    }

    function test_removeESIMWallet_noETHToCallBack() public {
        deployWallets();

        vm.deal(address(deviceWallet), 10 ether);

        vm.startPrank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 10 ether, "Device wallet balance should have been the same, 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have been the same, 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);
    }

    /// @notice An associated eSIM wallet may remove itself but not a sibling
    function test_removeESIMWallet_siblingCannotRemoveAnother() public {
        deployWallets();

        vm.deal(address(eSIMWallet2), 1 ether);

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.OnlySelfOrAssociatedESIMWallet.selector);
        deviceWallet.removeESIMWallet(address(eSIMWallet2), true);

        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet2)), true, "The sibling must still be bound");
        assertEq(address(eSIMWallet2).balance, 1 ether, "The sibling must keep its ETH");

        // The same caller removing itself is still allowed
        vm.prank(address(eSIMWallet1));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), false);
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), false, "A wallet must still be able to remove itself");
    }

    /// @notice A wallet whose logic re-enters the device wallet during its own removal must find
    /// that it has already lost both its association and its right to spend
    function test_removeESIMWallet_reentrantCallbackCannotPull() public {
        deployWallets();

        fundSettlementToken(address(deviceWallet), 1_000e6);

        ReentrantESIMWallet handler = _etchReentrantLogicOverESIMWallet1();

        vm.prank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);

        _assertCallbackReachedNothing(handler);
    }

    /// @notice Puts re-entering logic behind eSIMWallet1's address, keeping its bindings
    /// @dev Deployed through `deployCode` rather than `new`, which keeps the mock's creation code
    ///      out of this contract. Inlined, it puts the via-IR build over its stack limit.
    function _etchReentrantLogicOverESIMWallet1() private returns (ReentrantESIMWallet) {
        address impl = deployCode(
            "ReentrantESIMWallet.sol:ReentrantESIMWallet",
            abi.encode(address(deviceWallet), settlementToken)
        );
        vm.etch(address(eSIMWallet1), impl.code);

        return ReentrantESIMWallet(payable(address(eSIMWallet1)));
    }

    /// @notice What the re-entering wallet found, split out so the caller stays inside the IR stack
    function _assertCallbackReachedNothing(ReentrantESIMWallet _handler) private view {
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), 1_000e6, "nothing lost to the callback");
        assertFalse(_handler.pullSucceededDuringRemoval(), "a pull must not succeed mid-removal");
        assertFalse(_handler.wasStillValidDuringRemoval(), "the wallet must already be unbound");
        assertFalse(_handler.couldStillPullDuringRemoval(), "the wallet must already have lost access");
        assertFalse(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), "the wallet must be unbound after");
    }

    function test_addESIMWallet_unauthorised() public {
        deployWallets();

        vm.startPrank(user1);
        vm.expectRevert(bytes4(keccak256("OnlyRegistryOrDeviceWalletFactoryOrOwner()")));
        deviceWallet.addESIMWallet(
            address(eSIMWallet1),
            true
        );
        vm.stopPrank();
    }

    function test_addESIMWallet_withoutTransferringOwnership() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ESIMWalletNotOwnedByThisDeviceWallet.selector, address(eSIMWallet3), eSIMWallet3.owner()
        ));
        deviceWallet.addESIMWallet(
            address(eSIMWallet3),
            false
        );
        vm.stopPrank();
    }

    function test_addESIMWallet_alreadyOwnedBySelf() public {
        deployWallets();

        vm.startPrank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.ESIMWalletAlreadyAdded.selector, address(eSIMWallet1)));
        deviceWallet.addESIMWallet(
            address(eSIMWallet1),
            false
        );
        vm.stopPrank();
    }

    function test_addESIMWallet_afterRemoveESIMWallet_andETHCallback() public {
        deployWallets();
        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        // 1. deviceWallet requests transfer of ownership
        // 2. remove eSIM wallet from the device wallet
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        // Releasing raises the flag and leaves the association naming this device wallet. That is
        // what keeps the eSIM wallet recognisable to the protocol while the transfer is outstanding
        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);

        vm.startPrank(currentOwner);
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ESIMWalletOwnershipTransferPending.selector,
            address(eSIMWallet1),
            eSIMWallet1.newRequestedOwner()
        ));
        registry.bindESIMWallet(address(eSIMWallet1), currentOwner);
        vm.stopPrank();

        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet), "Previous owner should not be able to take the eSIM wallet back mid-transfer");

        // Since the eSIM wallet was already removed, the user cannot do the operation again
        vm.startPrank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownESIMWallet.selector, address(eSIMWallet1)));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        // 3. deviceWallet2 takes the wallet, grants access and buys through it
        _handOverToSecondDeviceAndBuy();
    }

    /// @notice A registered device wallet cannot release an eSIM wallet another one holds
    /// @dev Releasing is now the standby flag alone, so this is the gate that stops a sibling
    ///      reaching it. The gate checks the real owner rather than the registry's own association,
    ///      so a sibling fails it the same way an unrelated caller would. Both halves are asserted
    ///      afterwards to show a refused call moved neither.
    function test_toggleESIMWalletStandbyStatus_rejectsAReleaseFromADeviceWalletThatDoesNotHoldIt()
        public
    {
        deployWallets();

        vm.prank(address(deviceWallet2));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.NotTheESIMWalletOwnerOrItsDeviceWallet.selector, address(eSIMWallet1)
        ));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet1), true);

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, false, address(deviceWallet), true, true);
    }

    /// @notice The association can never be driven back to zero
    /// @dev Zero is how the registry spells an address it has never heard of, so a registered eSIM
    ///      wallet must never read it. Releasing is the standby flag's job and this entry point
    ///      refuses to express it, which is what makes the registration permanent.
    function test_bindESIMWallet_rejectsTheZeroAddress() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ZeroAddress.selector, "_deviceWalletAddress"
        ));
        registry.bindESIMWallet(address(eSIMWallet1), address(0));

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, false, address(deviceWallet), true, true);
    }

    /// @notice An eSIM wallet cannot be bound again while its ownership transfer is still pending
    /// @dev Requesting the transfer already released it, so the caller is still the associated
    ///      device wallet and the owner check passes. The pending owner is the only thing refusing
    ///      the call, which is what stops a release being walked back once someone else is named.
    function test_bindESIMWallet_rejectsABindWhileOwnershipTransferIsPending() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ESIMWalletOwnershipTransferPending.selector,
            address(eSIMWallet1),
            address(deviceWallet2)
        ));
        registry.bindESIMWallet(address(eSIMWallet1), address(deviceWallet));

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);
    }

    /// @notice Releasing an eSIM wallet leaves it recognisable to the protocol
    /// @dev The registration and the transient marker are unrelated facts. Releasing moves only the
    ///      marker, so the eSIM wallet keeps naming the device wallet that last held it and the
    ///      rest of its pre-deployment history can still be delivered while the transfer is open.
    function test_removeESIMWallet_keepsTheRegistrationAndStillAcceptsHistory() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), false);

        // Marker raised, registration still naming the device wallet that last held it
        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);

        DataBundleDetails[] memory batch = new DataBundleDetails[](1);
        batch[0] = bundle("DB_ID_0", TEST_PRICE_CENTS);

        vm.prank(address(lazyWalletRegistry));
        registry.populateLazyHistory(address(eSIMWallet1), batch);

        DataBundleDetails[] memory history = eSIMWallet1.getTransactionHistory();
        assertEq(history.length, 1, "History was delivered while the wallet was released");
    }

    /// @notice Taking an eSIM wallet on clears the transient marker in the same call
    /// @dev The one moment both facts move together, which is why it is one call rather than two.
    function test_addESIMWallet_clearsTheStandbyMarkerRaisedByTheRelease() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);

        vm.prank(address(deviceWallet2));
        eSIMWallet1.acceptOwnershipTransfer();

        // The registry has not moved yet: ownership and registration are separate steps, and the
        // registration follows the bind rather than the acceptance
        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);

        vm.prank(address(deviceWallet2));
        deviceWallet2.addESIMWallet(address(eSIMWallet1), false);

        _assertESIMWalletBinding(deviceWallet2, eSIMWallet1, false, address(deviceWallet2), false, true);
    }

    /// @notice The outgoing device wallet can lower the marker while its own transfer is pending
    /// @dev Pinned rather than prevented. It stays the associated device wallet until the new one
    ///      binds, and it is still the eSIM wallet's owner through this window, so this is the
    ///      party reversing its own release rather than a third one interfering. It buys back no
    ///      authority: the device wallet cleared `isValidESIMWallet` and `canPullFunds` on itself
    ///      when it released, and the pending owner still refuses a rebind.
    function test_toggleESIMWalletStandbyStatus_letsTheOutgoingDeviceWalletLowerTheMarker() public {
        deployWallets();

        vm.prank(address(deviceWallet));
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));

        vm.prank(address(deviceWallet));
        registry.toggleESIMWalletStandbyStatus(address(eSIMWallet1), false);

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, false, address(deviceWallet), false, false);

        vm.prank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.ESIMWalletOwnershipTransferPending.selector,
            address(eSIMWallet1),
            address(deviceWallet2)
        ));
        registry.bindESIMWallet(address(eSIMWallet1), address(deviceWallet));
    }

    /// A registered but malicious device wallet must not be able to steal an eSIM wallet:
    /// 1. Alice owns eSIM wallet 0xESIM1, linked to her device 0xDeviceAlice
    /// 2. Alice requests an ownership transfer of 0xESIM1 to Bob
    /// 3. Before Bob accepts, Carol calls bindESIMWallet(0xESIM1, 0xDeviceCarol)
    /// 4. Carol's device would own Alice's eSIM wallet, and Carol would control it
    function test_transferESIMWallet_frontrun() public {
        deployWallets();
        vm.deal(address(deviceWallet), 10 ether);
        vm.deal(address(eSIMWallet1), 1 ether);

        address currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should have been device wallet");

        vm.startPrank(currentOwner);
        // 1. deviceWallet requests transfer of ownership
        // 2. Alice (deviceWallet) unbinds/removes eSIMWallet1
        eSIMWallet1.requestTransferOwnership(address(deviceWallet2));
        vm.stopPrank();

        assertEq(eSIMWallet1.newRequestedOwner(), address(deviceWallet2), "newRequestedOwner should have been updated");

        currentOwner = eSIMWallet1.owner();
        assertEq(currentOwner, address(deviceWallet), "Owner should not have changed yet");

        vm.startPrank(address(deviceWallet));
        vm.expectRevert(abi.encodeWithSelector(Errors.UnknownESIMWallet.selector, address(eSIMWallet1)));
        deviceWallet.removeESIMWallet(address(eSIMWallet1), true);
        vm.stopPrank();

        assertEq(address(deviceWallet).balance, 11 ether, "Device wallet balance should have increased to 11 ETH");
        assertEq(address(eSIMWallet1).balance, 0, "eSIM wallet balance should have decreased to 0 ETH");

        _assertESIMWalletBinding(deviceWallet, eSIMWallet1, true, address(deviceWallet), false, false);

        // 3. Carol (deviceWallet3) tries to steal standby eSIMWallet (eSIMWallet1)
        vm.startPrank(address(deviceWallet3));
        vm.expectRevert(abi.encodeWithSelector(
            Errors.NotTheESIMWalletOwnerOrItsDeviceWallet.selector, address(eSIMWallet1)
        ));
        registry.bindESIMWallet(
            address(eSIMWallet1),
            address(deviceWallet3)
        );
        vm.stopPrank();

        currentOwner = eSIMWallet1.owner();
        assertNotEq(address(deviceWallet3), eSIMWallet1.owner(), "Critical Error: ESIMWallet stolen");

        // 4. deviceWallet2 takes the wallet, grants access and buys through it
        _handOverToSecondDeviceAndBuy();
    }
}
