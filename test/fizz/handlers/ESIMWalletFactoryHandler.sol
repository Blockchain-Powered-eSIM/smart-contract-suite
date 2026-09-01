// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with ESIMWalletFactory
/// @dev A device wallet calling here directly may only name itself. The stranger handler below is
///      the call that rule exists to refuse: without it a device wallet could take the CREATE2
///      address another one would get for the same salt, leaving that deployment to fail with
///      nothing to say why.
abstract contract ESIMWalletFactoryHandler is Properties {

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice A device wallet deploying an eSIM wallet for itself
    function eSIMWalletFactory_deployESIMWallet_clamped(uint256 walletSeed, uint256 salt) public {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        if (deviceWallet == address(0)) return;

        eSIMWalletFactory_deployESIMWallet(deviceWallet, deviceWallet, ++saltNonce + (salt % 8));
    }

    /// @notice A device wallet naming a different one as the owner of what it deploys
    function eSIMWalletFactory_deployESIMWallet_forStranger(uint256 walletSeed, uint256 targetSeed, uint256 salt)
        public
    {
        address caller = _pickDeviceWallet(walletSeed);
        address target = _pickDeviceWallet(targetSeed);
        if (caller == address(0) || target == address(0) || caller == target) return;

        eSIMWalletFactory_deployESIMWallet(caller, target, ++saltNonce + (salt % 8));
    }

    /// @notice A salt some wallet already stands at
    /// @dev CREATE2 reverts with no data on a reused slot, so the factory checks first and names
    ///      the salt back. Reaching it needs the salt repeated deliberately.
    function eSIMWalletFactory_deployESIMWallet_reusedSalt(uint256 walletSeed) public {
        address deviceWallet = _pickDeviceWallet(walletSeed);
        if (deviceWallet == address(0) || saltNonce == 0) return;

        eSIMWalletFactory_deployESIMWallet(deviceWallet, deviceWallet, saltNonce);
    }

    function eSIMWalletFactory_secondary(uint8 selector, uint256 arg) public {
        selector = uint8(selector % 1);
        if (selector == 0) _eSIMWalletFactory_updateESIMWalletImplementation(arg);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function eSIMWalletFactory_deployESIMWallet(address caller, address _deviceWalletAddress, uint256 _salt) public {
        bool callerIsDeviceWallet = registry.isDeviceWalletValid(caller);
        address predicted = eSIMWalletFactory.getCounterFactualAddress(_deviceWalletAddress, _salt);

        vm.prank(caller);
        address deployed = eSIMWalletFactory.deployESIMWallet(_deviceWalletAddress, _salt);

        if (callerIsDeviceWallet && _deviceWalletAddress != caller) ghosts.unauthorizedForeignDeploy = true;
        _prop_addressMatchesPrediction(predicted, deployed);
        _trackESIMWallet(deployed);
    }

    /// @notice Swaps the implementation behind every eSIM wallet at once
    /// @dev Between two real implementations, for the same reason the device wallet beacon is.
    function _eSIMWalletFactory_updateESIMWalletImplementation(uint256 which) internal asOwner {
        eSIMWalletFactory.updateESIMWalletImplementation(
            which % 2 == 0 ? spareESIMWalletImpl : eSIMWalletFactory.beacon().implementation()
        );
    }
}
