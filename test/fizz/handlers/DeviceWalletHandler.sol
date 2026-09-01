// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with DeviceWallet
/// @dev Three different callers reach this contract and they are not interchangeable.
///      `toggleAccessToFunds` and `transferOwnership` are `onlySelf`, so they are pranked as the
///      wallet itself, which is what an owner-signed `execute` amounts to onchain. `pullToken` is
///      pranked as an eSIM wallet the device wallet holds. `deployESIMWallet` is the admin's.
abstract contract DeviceWalletHandler is Properties {

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice An eSIM wallet drawing on its device wallet's token balance
    function deviceWallet_pullToken_clamped(uint256 walletSeed, uint256 amount) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        uint256 held = settlementERC20.balanceOf(deviceWallet);
        if (held == 0) return;

        amount = clampBetween(amount, 1, held);
        deviceWallet_pullToken(eSIMWallet, deviceWallet, settlementToken, amount);
    }

    /// @notice A pull for the device wallet's entire token balance
    /// @dev The grant is per wallet with no amount on it, so what one eSIM wallet may take is
    ///      everything. Worth reaching deliberately rather than waiting for a random draw to sum
    ///      to the balance.
    function deviceWallet_pullToken_fullBalance(uint256 walletSeed) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        uint256 held = settlementERC20.balanceOf(deviceWallet);
        if (held == 0) return;

        deviceWallet_pullToken(eSIMWallet, deviceWallet, settlementToken, held);
    }

    /// @notice The admin deploying another eSIM wallet under an existing device wallet
    function deviceWallet_deployESIMWallet_clamped(uint256 walletSeed, uint256 salt) public {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        if (deviceWallet == address(0)) return;

        deviceWallet_deployESIMWallet(deviceWallet, false, ++saltNonce + (salt % 8));
    }

    /// @notice Grants or revokes an eSIM wallet's right to spend its device wallet's money
    function deviceWallet_toggleAccessToFunds_clamped(uint256 walletSeed, bool hasAccess) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        deviceWallet_toggleAccessToFunds(deviceWallet, eSIMWallet, hasAccess);
    }

    /// @notice Releases an eSIM wallet, which is what raises its standby flag
    function deviceWallet_removeESIMWallet_clamped(uint256 walletSeed, bool callBackETH) public {
        (address eSIMWallet, address deviceWallet) = _pickOwnedPair(walletSeed);
        if (eSIMWallet == address(0)) return;

        deviceWallet_removeESIMWallet(deviceWallet, deviceWallet, eSIMWallet, callBackETH);
    }

    /// @notice Re-adds an eSIM wallet that already names this device wallet as its owner
    /// @dev The binding guard reads the eSIM wallet's live `owner()`, so this only goes through
    ///      after a handover has moved it. That ordering is the point.
    function deviceWallet_addESIMWallet_clamped(uint256 walletSeed, bool hasAccess) public {
        address eSIMWallet = _pickESIMWallet(walletSeed);
        if (eSIMWallet == address(0)) return;

        address owner = MockESIMWallet(payable(eSIMWallet)).owner();
        if (owner == address(0)) return;

        deviceWallet_addESIMWallet(owner, owner, eSIMWallet, hasAccess);
    }

    /// @notice ETH arriving at a device wallet from outside any protocol path
    function deviceWallet_donateETH(uint256 walletSeed, uint256 amount) public {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        if (deviceWallet == address(0) || actor.balance == 0) return;

        amount = clampBetween(amount, 1, actor.balance);
        Actor(payable(actor)).forceSendETH(deviceWallet, amount);
    }

    /// @notice Settlement token arriving at a device wallet from outside any protocol path
    function deviceWallet_donateERC20(uint256 walletSeed, uint256 amount) public {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        if (deviceWallet == address(0)) return;

        uint256 balance = settlementERC20.balanceOf(actor);
        if (balance == 0) return;

        amount = clampBetween(amount, 1, balance);
        vm.prank(actor);
        settlementERC20.transfer(deviceWallet, amount);
    }

    function deviceWallet_secondary(uint8 selector, uint256 walletSeed, uint256 arg) public {
        selector = uint8(selector % 2);
        if (selector == 0) _deviceWallet_transferOwnership(walletSeed, arg);
        else _deviceWallet_pullTokenAsStranger(walletSeed, arg);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev The association and the funds grant are separate guards, and a caller failing the first
    ///      never reaches the second, so both are read before the call rather than inferred after.
    function deviceWallet_pullToken(address caller, address deviceWallet, address _token, uint256 _amount) public {
        bool associated = MockDeviceWallet(payable(deviceWallet)).isValidESIMWallet(caller);
        bool granted = MockDeviceWallet(payable(deviceWallet)).canPullFunds(caller);
        bool wasPaused = registry.paused();

        vm.prank(caller);
        MockDeviceWallet(payable(deviceWallet)).pullToken(_token, _amount);

        if (!associated || !granted) ghosts.unauthorizedPull = true;
        if (wasPaused) ghosts.pausedCallSucceeded = true;
    }

    function deviceWallet_deployESIMWallet(address deviceWallet, bool _hasAccessToFunds, uint256 _salt) public {
        vm.prank(registry.eSIMWalletAdmin());
        address deployed = MockDeviceWallet(payable(deviceWallet)).deployESIMWallet(_hasAccessToFunds, _salt);
        _trackESIMWallet(deployed);
    }

    function deviceWallet_toggleAccessToFunds(address deviceWallet, address _eSIMWallet, bool _hasAccess) public {
        vm.prank(deviceWallet);
        MockDeviceWallet(payable(deviceWallet)).toggleAccessToFunds(_eSIMWallet, _hasAccess);
    }

    function deviceWallet_removeESIMWallet(
        address caller,
        address deviceWallet,
        address _eSIMWallet,
        bool _callBackETH
    ) public {
        vm.prank(caller);
        MockDeviceWallet(payable(deviceWallet)).removeESIMWallet(_eSIMWallet, _callBackETH);

        _prop_removalStripsAccess(deviceWallet, _eSIMWallet);
    }

    function deviceWallet_addESIMWallet(
        address caller,
        address deviceWallet,
        address _eSIMWallet,
        bool _hasAccess
    ) public {
        vm.prank(caller);
        MockDeviceWallet(payable(deviceWallet)).addESIMWallet(_eSIMWallet, _hasAccess);

        _prop_bindingGrantsNoAccess(deviceWallet, _eSIMWallet);
    }

    /// @notice Rotates a device wallet's P256 key
    /// @dev The key has to be on the curve or the wallet is bricked for good, and the deploy paths
    ///      refuse an off-curve one, so this path has to as well.
    function _deviceWallet_transferOwnership(uint256 walletSeed, uint256 keySeed) internal {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        if (deviceWallet == address(0)) return;

        vm.prank(deviceWallet);
        MockDeviceWallet(payable(deviceWallet)).transferOwnership(_ownerKey(keySeed));
    }

    /// @notice An eSIM wallet reaching for a device wallet that does not hold it
    /// @dev The association check and the funds-access check are separate guards, and a caller that
    ///      fails the first never reaches the second. This is the call that fails the first.
    function _deviceWallet_pullTokenAsStranger(uint256 walletSeed, uint256 amount) internal {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        address stranger = _pickESIMWallet(walletSeed + 1);
        if (deviceWallet == address(0) || stranger == address(0)) return;
        if (MockDeviceWallet(payable(deviceWallet)).isValidESIMWallet(stranger)) return;

        deviceWallet_pullToken(stranger, deviceWallet, settlementToken, clampBetween(amount, 1, 1e12));
    }
}
