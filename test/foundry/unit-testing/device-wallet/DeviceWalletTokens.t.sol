// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";
import {MockNoReturnERC20} from "test/utils/mocks/tokens/MockNoReturnERC20.sol";

/// @notice Every path an ERC-20 takes out of a device wallet, and who may open it.
contract DeviceWalletTokensTest is DeviceWalletFixture {

    uint256 constant BALANCE = 1_000e6;
    uint256 constant PULL = 250e6;

    event TokenSent(address indexed _token, address indexed _eSIMWalletAddress, uint256 _amount);

    function setUp() public override {
        super.setUp();
        deployWallets();
        fundSettlementToken(address(deviceWallet), BALANCE);
    }

    function test_pullToken_movesTheAmountToTheCallingWallet() public {
        vm.prank(address(eSIMWallet1));
        uint256 pulled = deviceWallet.pullToken(settlementToken, PULL);

        assertEq(pulled, PULL, "The call should report what it moved");
        assertEq(settlementERC20.balanceOf(address(deviceWallet)), BALANCE - PULL, "Device wallet must be down by the amount");
        assertEq(settlementERC20.balanceOf(address(eSIMWallet1)), PULL, "eSIM wallet must be up by the amount");
    }

    function test_pullToken_emitsTokenSent() public {
        vm.expectEmit(true, true, false, true, address(deviceWallet));
        emit TokenSent(settlementToken, address(eSIMWallet1), PULL);

        vm.prank(address(eSIMWallet1));
        deviceWallet.pullToken(settlementToken, PULL);
    }

    function test_pullToken_revertsForAWalletWithoutAccess() public {
        vm.prank(address(eSIMWallet2));
        vm.expectRevert(abi.encodeWithSelector(Errors.FundsAccessRevoked.selector, address(eSIMWallet2)));
        deviceWallet.pullToken(settlementToken, PULL);
    }

    /// @notice Access is one flag, so revoking it closes the token path as well as the ETH one
    function test_pullToken_stopsOnceAccessIsRevoked() public {
        vm.prank(address(eSIMWallet1));
        deviceWallet.pullToken(settlementToken, PULL);

        vm.prank(address(deviceWallet));
        deviceWallet.toggleAccessToFunds(address(eSIMWallet1), false);

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.FundsAccessRevoked.selector, address(eSIMWallet1)));
        deviceWallet.pullToken(settlementToken, PULL);
    }

    function test_pullToken_revertsForACallerThatIsNotAnAssociatedWallet() public {
        vm.prank(user1);
        vm.expectRevert(Errors.OnlyAssociatedESIMWallets.selector);
        deviceWallet.pullToken(settlementToken, PULL);
    }

    /// @notice An eSIM wallet of another device cannot reach this one's balance
    function test_pullToken_revertsForAnotherDevicesWallet() public {
        vm.prank(address(eSIMWallet3));
        vm.expectRevert(Errors.OnlyAssociatedESIMWallets.selector);
        deviceWallet.pullToken(settlementToken, PULL);
    }

    function test_pullToken_revertsOnZeroAmount() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.ZeroAmount.selector);
        deviceWallet.pullToken(settlementToken, 0);
    }

    function test_pullToken_revertsOnTheZeroTokenAddress() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, "_token"));
        deviceWallet.pullToken(address(0), PULL);
    }

    function test_pullToken_revertsWhileTheProtocolIsPaused() public {
        vm.prank(eSIMWalletAdmin);
        registry.pause();

        vm.prank(address(eSIMWallet1));
        vm.expectRevert(Errors.ProtocolPaused.selector);
        deviceWallet.pullToken(settlementToken, PULL);
    }

    /// @notice The token rejects a balance it cannot cover, so there is no second check here
    function test_pullToken_revertsWhenTheBalanceIsShort() public {
        vm.prank(address(eSIMWallet1));
        vm.expectRevert();
        deviceWallet.pullToken(settlementToken, BALANCE + 1);
    }

    /// @notice USDT returns nothing from `transfer`, which only SafeERC20 accepts
    function test_pullToken_movesATokenThatReturnsNothing() public {
        MockNoReturnERC20 token = new MockNoReturnERC20();
        token.mint(address(deviceWallet), BALANCE);

        vm.prank(address(eSIMWallet1));
        deviceWallet.pullToken(address(token), PULL);

        assertEq(token.balanceOf(address(eSIMWallet1)), PULL, "The eSIM wallet must hold the pulled amount");
    }

    /// @notice A token this wallet has never held is not a special case, it just has no balance
    function test_pullToken_revertsForATokenTheWalletDoesNotHold() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);

        vm.prank(address(eSIMWallet1));
        vm.expectRevert();
        deviceWallet.pullToken(address(other), 1);
    }
}
