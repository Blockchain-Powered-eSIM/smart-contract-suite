// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

import {HandlerBase, HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";

/// @notice Everything a wallet does on its owner's behalf.
/// @dev Every entry point here impersonates a wallet rather than a person. That is the whole
///      access control story on this side of the protocol: the guards admit the wallet address,
///      and reaching the wallet address means holding the P256 key and going through `execute`.
///      Signing is a unit test concern, so the campaign starts from the point a valid signature
///      would have reached.
contract WalletHandler is HandlerBase {

    constructor(HandlerConfig memory config) HandlerBase(config) {}

    /// @notice A device wallet rotates the P256 key that owns it
    /// @dev Keys come from the same generator the deploy paths use, so a rotation onto a key
    ///      another wallet is already registered under is reached rather than assumed away.
    /// @param deviceIndex Which device wallet rotates
    /// @param seed Drives the key it rotates onto
    function rotateOwnerKey(uint256 deviceIndex, uint256 seed) external counted {
        address device = _pickDeviceWallet(deviceIndex);
        if (device == address(0)) {
            state.recordRevert("rotateOwnerKey");
            return;
        }
        bytes32[2] memory newKey = _ownerKey(seed);

        vm.prank(device);
        try DeviceWallet(payable(device)).transferOwnership(newKey) returns (bytes32[2] memory) {
            state.recordKey(device, newKey);
            state.recordCall("rotateOwnerKey");
        } catch {
            state.recordRevert("rotateOwnerKey");
        }
    }

    /// @notice An eSIM wallet is detached from its device wallet
    /// @dev The caller alternates between the owning device wallet and the eSIM wallet itself,
    ///      which is the pair the removal gate admits. A sibling eSIM wallet attempting the same
    ///      removal is what a cross-wallet bug would show up in, so the index is picked
    ///      independently of the caller.
    /// @param eSIMIndex Which eSIM wallet to remove
    /// @param callBackETH Whether to pull the wallet's remaining ETH back on the way out
    /// @param viaESIMWallet Whether the eSIM wallet removes itself instead of the device wallet
    function removeESIMWallet(uint256 eSIMIndex, bool callBackETH, bool viaESIMWallet)
        external
        counted
    {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("removeESIMWallet");
            return;
        }
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0)) {
            state.recordRevert("removeESIMWallet");
            return;
        }

        vm.prank(viaESIMWallet ? wallet : device);
        try DeviceWallet(payable(device)).removeESIMWallet(wallet, callBackETH) {
            state.setESIMOwner(wallet, address(0));
            state.recordCall("removeESIMWallet");
        } catch {
            state.recordRevert("removeESIMWallet");
        }
    }

    /// @notice A device wallet offers one of its eSIM wallets to another device wallet
    /// @param eSIMIndex Which eSIM wallet to hand over
    /// @param deviceIndex Which device wallet is being offered it
    function requestTransferOwnership(uint256 eSIMIndex, uint256 deviceIndex) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        address newOwner = _pickDeviceWallet(deviceIndex);
        if (wallet == address(0) || newOwner == address(0)) {
            state.recordRevert("requestTransferOwnership");
            return;
        }
        address currentOwner = ESIMWallet(payable(wallet)).owner();
        if (currentOwner == address(0)) {
            state.recordRevert("requestTransferOwnership");
            return;
        }

        vm.prank(currentOwner);
        try ESIMWallet(payable(wallet)).requestTransferOwnership(newOwner) {
            // The request detaches the wallet from its current device on the way through
            state.setESIMOwner(wallet, registry.isESIMWalletValid(wallet));
            state.recordCall("requestTransferOwnership");
        } catch {
            state.recordRevert("requestTransferOwnership");
        }
    }

    /// @notice The device wallet that was offered an eSIM wallet takes it
    /// @param eSIMIndex Which eSIM wallet to accept
    function acceptOwnershipTransfer(uint256 eSIMIndex) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("acceptOwnershipTransfer");
            return;
        }
        address requested = ESIMWallet(payable(wallet)).newRequestedOwner();
        if (requested == address(0)) {
            state.recordRevert("acceptOwnershipTransfer");
            return;
        }

        vm.prank(requested);
        try ESIMWallet(payable(wallet)).acceptOwnershipTransfer() {
            state.recordCall("acceptOwnershipTransfer");
        } catch {
            state.recordRevert("acceptOwnershipTransfer");
        }
    }

    /// @notice A device wallet binds an eSIM wallet it has just been given ownership of
    /// @param deviceIndex Which device wallet makes the claim
    /// @param eSIMIndex Which eSIM wallet it claims
    function addESIMWallet(uint256 deviceIndex, uint256 eSIMIndex) external counted {
        address device = _pickDeviceWallet(deviceIndex);
        address wallet = _pickESIMWallet(eSIMIndex);
        if (device == address(0) || wallet == address(0)) {
            state.recordRevert("addESIMWallet");
            return;
        }

        vm.prank(device);
        try DeviceWallet(payable(device)).addESIMWallet(wallet, true) {
            state.setESIMOwner(wallet, device);
            state.recordCall("addESIMWallet");
        } catch {
            state.recordRevert("addESIMWallet");
        }
    }

    /// @notice The wallet owner revokes or restores an eSIM wallet's right to pull ETH
    /// @param eSIMIndex Which eSIM wallet to toggle
    /// @param hasAccessToETH The access it should end up with
    function toggleAccessToETH(uint256 eSIMIndex, bool hasAccessToETH) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("toggleAccessToETH");
            return;
        }
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0)) {
            state.recordRevert("toggleAccessToETH");
            return;
        }

        vm.prank(device);
        try DeviceWallet(payable(device)).toggleAccessToETH(wallet, hasAccessToETH) {
            state.recordCall("toggleAccessToETH");
        } catch {
            state.recordRevert("toggleAccessToETH");
        }
    }

    /// @notice An eSIM wallet pulls ETH from the device wallet that owns it
    /// @dev The amount is allowed to exceed the device wallet's balance, which is the case the
    ///      transfer guard has to refuse rather than partially serve.
    /// @param eSIMIndex Which eSIM wallet pulls
    /// @param amount How much it asks for
    function pullETH(uint256 eSIMIndex, uint256 amount) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("pullETH");
            return;
        }
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0)) {
            state.recordRevert("pullETH");
            return;
        }
        amount = bound(amount, 0, 20 ether);

        vm.prank(wallet);
        try DeviceWallet(payable(device)).pullETH(amount) {
            state.recordCall("pullETH");
        } catch {
            state.recordRevert("pullETH");
        }
    }
}
