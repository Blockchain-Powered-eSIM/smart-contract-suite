// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";
import {ESIMWallet} from "contracts/esim-wallet/ESIMWallet.sol";

import {HandlerBase, HandlerConfig} from "test/foundry/invariant-testing/handler/HandlerBase.sol";
import {MockERC20} from "test/utils/mocks/tokens/MockERC20.sol";

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
        // The registry keeps naming the last holder after a release, so it answers "who held this"
        // rather than "who holds this". Only a device wallet still claiming the eSIM wallet can
        // remove it, and without this check the campaign would spend its removals retrying wallets
        // that were let go several calls ago
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0) || !DeviceWallet(payable(device)).isValidESIMWallet(wallet)) {
            state.recordRevert("removeESIMWallet");
            return;
        }

        vm.prank(viaESIMWallet ? wallet : device);
        try DeviceWallet(payable(device)).removeESIMWallet(wallet, callBackETH) {
            // Removing withdraws the device wallet's own two rights and raises the registry's
            // marker. The registration is deliberately left alone: it is what keeps the eSIM
            // wallet recognisable to the protocol while nobody is holding it
            assertFalse(
                DeviceWallet(payable(device)).isValidESIMWallet(wallet),
                "A removed eSIM wallet is still claimed by its device wallet"
            );
            assertFalse(
                DeviceWallet(payable(device)).canPullFunds(wallet),
                "A removed eSIM wallet kept its right to pull ETH"
            );
            assertEq(
                registry.isESIMWalletValid(wallet),
                device,
                "A removed eSIM wallet lost its registration"
            );
            assertTrue(
                registry.isESIMWalletOnStandby(wallet),
                "A removed eSIM wallet was not put on standby"
            );

            state.setESIMOwner(wallet, address(0));
            state.clearETHAccessGrant(device, wallet);
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
            // A transfer that completed while leaving the offer standing would let the same
            // address take the wallet again after it had moved on to someone else
            assertEq(
                ESIMWallet(payable(wallet)).owner(),
                requested,
                "The accepted transfer did not move the wallet to the address that accepted it"
            );
            assertEq(
                ESIMWallet(payable(wallet)).newRequestedOwner(),
                address(0),
                "An accepted transfer left its offer outstanding"
            );

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
        try DeviceWallet(payable(device)).addESIMWallet(wallet, false) {
            // The mirror of the removal check. Three writes go in together, and a wallet that
            // arrived with only some of them set is one the two contracts disagree about from the
            // moment it is added
            assertTrue(
                DeviceWallet(payable(device)).isValidESIMWallet(wallet),
                "An added eSIM wallet is not claimed by the device wallet that added it"
            );
            assertFalse(
                DeviceWallet(payable(device)).canPullFunds(wallet),
                "An added eSIM wallet arrived with the right to pull ETH"
            );
            assertEq(
                registry.isESIMWalletValid(wallet),
                device,
                "An added eSIM wallet is not associated in the registry"
            );

            state.setESIMOwner(wallet, device);
            state.clearETHAccessGrant(device, wallet);
            state.recordCall("addESIMWallet");
        } catch {
            state.recordRevert("addESIMWallet");
        }
    }

    /// @notice The wallet owner revokes or restores an eSIM wallet's right to pull ETH
    /// @param eSIMIndex Which eSIM wallet to toggle
    /// @param hasAccessToFunds The access it should end up with
    function toggleAccessToFunds(uint256 eSIMIndex, bool hasAccessToFunds) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("toggleAccessToFunds");
            return;
        }
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0)) {
            state.recordRevert("toggleAccessToFunds");
            return;
        }

        vm.prank(device);
        try DeviceWallet(payable(device)).toggleAccessToFunds(wallet, hasAccessToFunds) {
            // Recorded in ghost state rather than asserted here: an assertion that trips inside a
            // handler reverts the call and the campaign reads it as a skipped action
            if (hasAccessToFunds) {
                state.recordETHAccessGrant(device, wallet);
            } else {
                state.clearETHAccessGrant(device, wallet);
            }
            state.recordCall("toggleAccessToFunds");
        } catch {
            state.recordRevert("toggleAccessToFunds");
        }
    }

    /// @notice An eSIM wallet pulls an ERC-20 from the device wallet that owns it
    /// @dev The amount is allowed to exceed the device wallet's balance, which is the case the
    ///      transfer has to refuse rather than partially serve.
    /// @param eSIMIndex Which eSIM wallet pulls
    /// @param amount How much it asks for
    /// @param fundingSeed How much the device wallet is holding when it asks
    function pullToken(uint256 eSIMIndex, uint256 amount, uint256 fundingSeed) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("pullToken");
            return;
        }
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0)) {
            state.recordRevert("pullToken");
            return;
        }
        amount = bound(amount, 0, 20_000e6);
        MockERC20(settlementToken).mint(device, bound(fundingSeed, 0, 10_000e6));

        vm.prank(wallet);
        try DeviceWallet(payable(device)).pullToken(settlementToken, amount) {
            state.recordCall("pullToken");
        } catch {
            state.recordRevert("pullToken");
        }
    }

    /// @notice The wallet owner sets the most this eSIM wallet may be charged for one bundle
    /// @dev The ceiling comes off a ladder, so zero is reached. Zero is the value that hands the
    ///      wallet back to the registry's fallback rather than a ceiling of zero, and a range wide
    ///      enough to sit above what the admin charges would never land on it.
    /// @param eSIMIndex Which eSIM wallet gets the ceiling
    /// @param seed Chooses the ceiling
    function setESIMWalletPriceCap(uint256 eSIMIndex, uint256 seed) external counted {
        address wallet = _pickESIMWallet(eSIMIndex);
        if (wallet == address(0)) {
            state.recordRevert("setESIMWalletPriceCap");
            return;
        }
        address device = registry.isESIMWalletValid(wallet);
        if (device == address(0)) {
            state.recordRevert("setESIMWalletPriceCap");
            return;
        }
        // Zero is in the ladder because it is what hands the wallet back to the registry ceiling.
        uint64[4] memory ladder = [uint64(0), 1, 1_000, 100_000_000];

        vm.prank(device);
        try ESIMWallet(payable(wallet)).setPriceCapUSDCents(ladder[bound(seed, 0, 3)]) {
            state.recordCall("setESIMWalletPriceCap");
        } catch {
            state.recordRevert("setESIMWalletPriceCap");
        }
    }
}
