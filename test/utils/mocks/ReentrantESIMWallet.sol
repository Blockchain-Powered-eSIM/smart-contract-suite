// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";

/// @notice Stands in for an eSIM wallet whose logic re-enters the device wallet during removal
/// @dev    Etched over a real eSIM wallet address so that it keeps that wallet's bindings. All eSIM
///         wallets share one upgradeable beacon with no per-wallet opt-out, so the logic reached by
///         the removal callback is not fixed for the life of the protocol.
contract ReentrantESIMWallet {
    DeviceWallet public immutable deviceWallet;

    /// @notice What the wallet could still see and do while its own removal was in progress
    bool public wasStillValidDuringRemoval;
    bool public couldStillPullETHDuringRemoval;
    bool public pullETHSucceededDuringRemoval;

    constructor(DeviceWallet _deviceWallet) {
        deviceWallet = _deviceWallet;
    }

    /// @dev The registry reads both of these while the association is being cleared
    function owner() external view returns (address) {
        return address(deviceWallet);
    }

    function newRequestedOwner() external pure returns (address) {
        return address(0);
    }

    /// @notice The callback removeESIMWallet makes, from inside its try/catch
    function sendETHToDeviceWallet(uint256) external returns (uint256) {
        // These are etched over an existing eSIM wallet, so the slots hold that wallet's leftover
        // storage until each one is written. All three have to be set, not just the observed ones.
        wasStillValidDuringRemoval = deviceWallet.isValidESIMWallet(address(this));
        couldStillPullETHDuringRemoval = deviceWallet.canPullFunds(address(this));
        pullETHSucceededDuringRemoval = false;

        try deviceWallet.pullETH(1 ether) returns (uint256) {
            pullETHSucceededDuringRemoval = true;
        } catch {}

        return 0;
    }

    receive() external payable {}
}
