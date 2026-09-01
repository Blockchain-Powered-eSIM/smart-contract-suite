// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with DeviceWalletFactory
/// @dev `createAccount` is one of the three permissionless entry points in the protocol, so it is
///      the only handler here that is not pranked as a privileged role. It deploys live code at a
///      CREATE2 address without registering it, and `postCreateAccount` is what registers it
///      afterwards; running the two apart is how the gap between them gets exercised.
abstract contract DeviceWalletFactoryHandler is Properties {

    /// @dev What the last `createAccount` produced, so the dispatcher can register it in a later
    ///      call. Registration re-derives the address from the same three inputs, so they have to
    ///      be carried across rather than re-fuzzed.
    address internal lastCounterfactualWallet;
    string internal lastCounterfactualIdentifier;
    bytes32[2] internal lastCounterfactualKey;
    uint256 internal lastCounterfactualSalt;

    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @notice Anyone deploying a device wallet at its deterministic address
    /// @dev Left unregistered on purpose. Only `postCreateAccount` writes the registry, and a
    ///      wallet between the two is the state worth holding: it has code and the protocol does
    ///      not know it.
    function deviceWalletFactory_createAccount_clamped(
        uint256 identifierSeed,
        uint256 keySeed,
        uint256 value,
        bool contested
    ) public {
        string memory identifier =
            contested ? _contestedDeviceIdentifier(identifierSeed) : _deviceIdentifier(identifierSeed);

        vm.deal(actor, actor.balance + 1 ether);
        value = clampBetween(value, 0, _spendable(actor, 1 ether));

        deviceWalletFactory_createAccount(actor, identifier, _ownerKey(keySeed), ++saltNonce, value);
    }

    /// @notice Deploying twice at the same address
    /// @dev The second call forwards its value to the wallet already standing there rather than
    ///      deploying again, and that ETH must stay refundable. Reached only by repeating the exact
    ///      three inputs, which a random draw never does.
    function deviceWalletFactory_createAccount_repeat(uint256 value) public {
        if (lastCounterfactualWallet == address(0)) return;

        vm.deal(actor, actor.balance + 1 ether);
        value = clampBetween(value, 0, _spendable(actor, 1 ether));

        deviceWalletFactory_createAccount(
            actor, lastCounterfactualIdentifier, lastCounterfactualKey, lastCounterfactualSalt, value
        );
    }

    /// @notice The admin batch route, which deploys a device wallet and one eSIM wallet together
    function deviceWalletFactory_deployDeviceWalletForUsers_clamped(
        uint256 identifierSeed,
        uint256 keySeed,
        uint8 batchSize,
        uint256 deposit,
        bool contested
    ) public {
        uint256 count = clampBetween(uint256(batchSize), 1, 3);

        string[] memory identifiers = new string[](count);
        bytes32[2][] memory keys = new bytes32[2][](count);
        uint256[] memory salts = new uint256[](count);
        uint256[] memory deposits = new uint256[](count);

        address caller = registry.eSIMWalletAdmin();
        vm.deal(caller, caller.balance + 10 ether);
        uint256 each = clampBetween(deposit, 0, 1 ether);

        for (uint256 i; i < count; ++i) {
            identifiers[i] = contested
                ? _contestedDeviceIdentifier(identifierSeed + i)
                : _deviceIdentifier(identifierSeed + i);
            keys[i] = _ownerKey(keySeed + i);
            salts[i] = ++saltNonce;
            deposits[i] = each;
        }

        deviceWalletFactory_deployDeviceWalletForUsers(identifiers, keys, salts, deposits, each * count);
    }

    function deviceWalletFactory_secondary(uint8 selector, uint256 arg) public {
        selector = uint8(selector % 2);
        if (selector == 0) _deviceWalletFactory_postCreateAccount();
        else _deviceWalletFactory_updateDeviceWalletImplementation(arg);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function deviceWalletFactory_createAccount(
        address caller,
        string memory _deviceUniqueIdentifier,
        bytes32[2] memory _deviceWalletOwnerKey,
        uint256 _salt,
        uint256 value
    ) public {
        address predicted =
            deviceWalletFactory.getCounterFactualAddress(_deviceWalletOwnerKey, _deviceUniqueIdentifier, _salt);
        bool alreadyRegistered = deviceWalletFactory.deviceWalletInfoAdded(predicted);

        vm.prank(caller);
        address deployed = address(
            deviceWalletFactory.createAccount{value: value}(_deviceUniqueIdentifier, _deviceWalletOwnerKey, _salt)
        );

        _prop_addressMatchesPrediction(predicted, deployed);

        // Only meaningful while nothing has registered the address yet. Once `postCreateAccount`
        // has run, the wallet is supposed to read as valid and claim its identifier.
        if (!alreadyRegistered) _prop_unregisteredWalletIsInert(deployed, _deviceUniqueIdentifier);

        lastCounterfactualWallet = deployed;
        lastCounterfactualIdentifier = _deviceUniqueIdentifier;
        lastCounterfactualKey = _deviceWalletOwnerKey;
        lastCounterfactualSalt = _salt;
    }

    function deviceWalletFactory_deployDeviceWalletForUsers(
        string[] memory _deviceUniqueIdentifiers,
        bytes32[2][] memory _deviceWalletOwnersKey,
        uint256[] memory _salts,
        uint256[] memory _depositAmounts,
        uint256 value
    ) public asAdmin {
        Wallets[] memory deployed = deviceWalletFactory.deployDeviceWalletForUsers{value: value}(
            _deviceUniqueIdentifiers, _deviceWalletOwnersKey, _salts, _depositAmounts
        );

        for (uint256 i; i < deployed.length; ++i) {
            _trackDeviceWallet(deployed[i].deviceWallet);
            _trackESIMWallet(deployed[i].eSIMWallet);
        }
    }

    /// @notice Registers a wallet an earlier `createAccount` left unregistered
    function _deviceWalletFactory_postCreateAccount() internal asAdmin {
        if (lastCounterfactualWallet == address(0)) return;

        deviceWalletFactory.postCreateAccount(
            lastCounterfactualWallet, lastCounterfactualIdentifier, lastCounterfactualKey, lastCounterfactualSalt
        );
        _trackDeviceWallet(lastCounterfactualWallet);
        lastCounterfactualWallet = address(0);
    }

    /// @notice Swaps the implementation behind every device wallet at once
    /// @dev Between two real implementations. A fuzzed address here would leave every wallet in the
    ///      run calling into nothing, and the beacon has no per-wallet opt-out to undo it with.
    function _deviceWalletFactory_updateDeviceWalletImplementation(uint256 which) internal asOwner {
        deviceWalletFactory.updateDeviceWalletImplementation(
            which % 2 == 0 ? spareDeviceWalletImpl : deviceWalletFactory.beacon().implementation()
        );
    }
}
