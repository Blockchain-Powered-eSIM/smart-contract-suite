// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";

import "test/utils/DeployerBase.sol";
import "test/utils/mocks/MockDeviceWallet.sol";
import "test/utils/mocks/MockESIMWallet.sol";

/// @notice The wallet set every device wallet test works against.
/// @dev The two deploy helpers are called from the body of each test rather than from setUp,
///      because a test that expects a revert has to control when the deployment happens.
abstract contract DeviceWalletFixture is DeployerBase {

    MockDeviceWallet deviceWallet;
    MockDeviceWallet deviceWallet2;
    MockDeviceWallet deviceWallet3;     // Carol's (Malicious actor) device wallet
    MockESIMWallet eSIMWallet1;         // has access to ETH, has eSIM identifier set, belongs to deviceWallet1
    MockESIMWallet eSIMWallet2;         // no access to ETH, no eSIM identifier set, belongs to deviceWallet1
    MockESIMWallet eSIMWallet3;         // has access to ETH, has eSIM identifier set, belongs to deviceWallet2
    MockDeviceWallet userDeviceWallet;  // Custom device wallet deployed with user defined x and y keys
    MockESIMWallet userESIMWallet;      // eSIM wallet associated with user's custom device wallet

    /// @notice Deploys one device wallet under a caller-supplied owner key, with one eSIM wallet
    ///         bound to it, and leaves both in userDeviceWallet and userESIMWallet
    /// @dev Used by the tests that need to sign as the owner, since those need a key whose private
    ///      half the suite holds rather than one of the fixture's fixed keys.
    /// @param _deviceIdentifier The device identifier the wallet claims
    /// @param _x X co-ordinate of the P256 owner key
    /// @param _y Y co-ordinate of the P256 owner key
    /// @param _salt Salt fixing the counterfactual address
    function deployCustomWallet(
        string memory _deviceIdentifier,
        bytes32 _x,
        bytes32 _y,
        uint256 _salt
    ) public {
        bytes32[2] memory pubKey = [
            bytes32(_x),
            bytes32(_y)
        ];

        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](1);
        bytes32[2][] memory listOfKeys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        deviceUniqueIdentifiers[0] = _deviceIdentifier;
        listOfKeys[0] = pubKey;
        salts[0] = _salt;
        deposits[0] = 0;

        vm.startPrank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        );
        vm.stopPrank();

        userDeviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        userESIMWallet = MockESIMWallet(payable(wallets[0].eSIMWallet));

        vm.startPrank(admin);
        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        userDeviceWallet.setESIMUniqueIdentifierForAnESIMWallet(address(userESIMWallet), "ESIM_0_0");
        vm.stopPrank();

        assertNotEq(address(userDeviceWallet), address(0), "deviceWallet address cannot be address(0)");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(userDeviceWallet)), true, "isDeviceWalletValid mapping should have been updated for userDeviceWallet");
        assertEq(registry.uniqueIdentifierToDeviceWallet(_deviceIdentifier), address(userDeviceWallet), "uniqueIdentifierToDeviceWallet should have been updated for userDeviceWallet");
        assertEq(registry.isESIMWalletValid(address(userESIMWallet)), address(userDeviceWallet), "userESIMWallet should have been associated with userDeviceWallet");
        assertEq(registry.isESIMWalletOnStandby(address(userESIMWallet)), false, "userESIMWallet should not have been on standby");

        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(userDeviceWallet));
        assertEq(ownerKeys[0], pubKey[0], "X co-ordinate should have matched for ownerKeys");
        assertEq(ownerKeys[1], pubKey[1], "Y co-ordinate should have matched for ownerKeys");

        // Check storage variables in device wallet
        assertEq(userDeviceWallet.deviceUniqueIdentifier(), _deviceIdentifier, "Device unique identifier should have matched with userDeviceWallet");
        assertEq(address(userDeviceWallet.registry()), address(registry), "Registry should have been correct for userDeviceWallet");
        assertEq(address(userDeviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in userDeviceWallet should have matched");
        assertEq(userDeviceWallet.isValidESIMWallet(address(userESIMWallet)), true, "userESIMWallet should have been set to valid");
        assertEq(userDeviceWallet.canPullETH(address(userESIMWallet)), true, "userESIMWallet should be able to pull ETH");
        assertEq(address(userDeviceWallet.entryPoint()), address(entryPoint), "Entry point address should have been initialised in userDeviceWallet");
        assertEq(address(userDeviceWallet.verifier()), address(p256Verifier), "P256Verifier address should have been initialised in userDeviceWallet");

        bytes32[2] memory deviceWalletOwner = userDeviceWallet.getOwner();
        assertEq(deviceWalletOwner[0], pubKey[0], "X co-ordinate of userDeviceWallet owner should have matched");
        assertEq(deviceWalletOwner[1], pubKey[1], "Y co-ordinate of userDeviceWallet owner should have matched");

        // Check storage variables in eSIM wallet
        assertEq(userESIMWallet.eSIMUniqueIdentifier(), "ESIM_0_0", "ESIM unique identifier should not be empty for userESIMWallet");
        assertEq(userESIMWallet.newRequestedOwner(), address(0), "userESIMWallet's new requested owner should have been address(0)");
        assertEq(userESIMWallet.getTransactionHistory().length, 0, "Transaction history should have been empty");
        assertEq(userESIMWallet.owner(), address(userDeviceWallet), "userESIMWallet owner should have been device wallet");
    }

    /// @notice Deploys the three device wallets and three eSIM wallets the tests share
    /// @dev The three eSIM wallets differ deliberately: eSIMWallet1 has an identifier and may pull
    ///      ETH, eSIMWallet2 has neither, and eSIMWallet3 belongs to a second device wallet so
    ///      cross-owner cases have somewhere to move a wallet to.
    function deployWallets() public {
        address admin = deviceWalletFactory.eSIMWalletAdmin();

        string[] memory deviceUniqueIdentifiers = new string[](3);
        bytes32[2][] memory listOfKeys = new bytes32[2][](3);
        uint256[] memory salts = new uint256[](3);
        uint256[] memory deposits = new uint256[](3);

        deviceUniqueIdentifiers[0] = "Device_1";
        deviceUniqueIdentifiers[1] = "Device_2";
        deviceUniqueIdentifiers[2] = "Device_3";
        listOfKeys[0] = listOfOwnerKeys[0];
        listOfKeys[1] = listOfOwnerKeys[1];
        listOfKeys[2] = listOfOwnerKeys[2];
        salts[0] = 999;
        salts[1] = 919;
        salts[2] = 910;
        deposits[0] = 0;
        deposits[1] = 0;
        deposits[2] = 0;

        vm.startPrank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(
            deviceUniqueIdentifiers,
            listOfKeys,
            salts,
            deposits
        );
        vm.stopPrank();

        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        deviceWallet = MockDeviceWallet(payable(wallets[0].deviceWallet));
        deviceWallet2 = MockDeviceWallet(payable(wallets[1].deviceWallet));
        deviceWallet3 = MockDeviceWallet(payable(wallets[2].deviceWallet));
        eSIMWallet1 = MockESIMWallet(payable(wallets[0].eSIMWallet));
        eSIMWallet3 = MockESIMWallet(payable(wallets[1].eSIMWallet));

        vm.startPrank(admin);
        // eSIMWallet1 -> has access to ETH, has eSIM identifier set
        deviceWallet.setESIMUniqueIdentifierForAnESIMWallet(address(eSIMWallet1), "ESIM_0_1");
        deviceWallet2.setESIMUniqueIdentifierForAnESIMWallet(address(eSIMWallet3), "ESIM_1_1");
        vm.stopPrank();

        vm.startPrank(admin);
        // eSIMWallet2 -> no access to ETH, no eSIM identifier set
        address newESIMWallet = deviceWallet.deployESIMWallet(false, 919);
        vm.stopPrank();

        // eSIMWallet2 -> no access to ETH, no eSIM identifier set
        eSIMWallet2 = MockESIMWallet(payable(newESIMWallet));

        assertNotEq(address(deviceWallet), address(0), "deviceWallet address cannot be address(0)");
        assertNotEq(address(deviceWallet2), address(0), "deviceWallet2 address cannot be address(0)");
        assertNotEq(address(eSIMWallet1), address(0), "ESIMWallet1 address cannot be address(0)");
        assertNotEq(address(eSIMWallet2), address(0), "ESIMWallet2 address cannot be address(0)");
        assertNotEq(address(eSIMWallet2), address(0), "ESIMWallet3 address cannot be address(0)");

        // Check storage variables in registry
        assertEq(registry.isDeviceWalletValid(address(deviceWallet)), true, "isDeviceWalletValid mapping should have been updated for deviceWallet");
        assertEq(registry.isDeviceWalletValid(address(deviceWallet2)), true, "isDeviceWalletValid mapping should have been updated for deviceWallet2");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(deviceWallet), "uniqueIdentifierToDeviceWallet should have been updated for deviceWallet1");
        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[1]), address(deviceWallet2), "uniqueIdentifierToDeviceWallet should have been updated for deviceWallet2");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet1)), address(deviceWallet), "ESIM wallet1 should have been associated with deviceWallet");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet2)), address(deviceWallet), "ESIM wallet2 should have been associated with deviceWallet");
        assertEq(registry.isESIMWalletValid(address(eSIMWallet3)), address(deviceWallet2), "ESIM wallet3 should have been associated with deviceWallet2");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet1)), false, "ESIMWallet1 should not have been on standby");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet2)), false, "ESIMWallet2 should not have been on standby");
        assertEq(registry.isESIMWalletOnStandby(address(eSIMWallet3)), false, "ESIMWallet3 should not have been on standby");

        bytes32[2] memory ownerKeys = registry.getDeviceWalletToOwner(address(deviceWallet));
        assertEq(ownerKeys[0], pubKey1[0], "X co-ordinate should have matched for ownerKeys");
        assertEq(ownerKeys[1], pubKey1[1], "Y co-ordinate should have matched for ownerKeys");

        bytes32[2] memory ownerKeys2 = registry.getDeviceWalletToOwner(address(deviceWallet2));
        assertEq(ownerKeys2[0], pubKey2[0], "X co-ordinate should have matched for ownerKeys2");
        assertEq(ownerKeys2[1], pubKey2[1], "Y co-ordinate should have matched for ownerKeys2");

        // Check storage variables in device wallet
        assertEq(deviceWallet.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[0], "Device unique identifier should have matched with deviceWallet");
        assertEq(deviceWallet2.deviceUniqueIdentifier(), customDeviceUniqueIdentifiers[1], "Device unique identifier should have matched with deviceWallet2");
        assertEq(address(deviceWallet.registry()), address(registry), "Registry should have been correct for deviceWallet");
        assertEq(address(deviceWallet2.registry()), address(registry), "Registry should have been correct for deviceWallet2");
        assertEq(address(deviceWallet.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in deviceWallet should have matched");
        assertEq(address(deviceWallet2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in deviceWallet2 should have matched");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet1)), true, "ESIMWallet1 should have been set to valid");
        assertEq(deviceWallet.isValidESIMWallet(address(eSIMWallet2)), true, "ESIMWallet2 should have been set to valid");
        assertEq(deviceWallet2.isValidESIMWallet(address(eSIMWallet3)), true, "ESIMWallet3 should have been set to valid");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet1)), true, "ESIMWallet1 should be able to pull ETH");
        assertEq(deviceWallet.canPullETH(address(eSIMWallet2)), false, "ESIMWallet2 should not be able to pull ETH");
        assertEq(deviceWallet2.canPullETH(address(eSIMWallet3)), true, "ESIMWallet3 should be able to pull ETH");
        assertEq(address(deviceWallet.entryPoint()), address(entryPoint), "Entry point address should have been initialised in deviceWallet");
        assertEq(address(deviceWallet2.entryPoint()), address(entryPoint), "Entry point address should have been initialised in deviceWallet2");
        assertEq(address(deviceWallet.verifier()), address(p256Verifier), "P256Verifier address should have been initialised in deviceWallet");
        assertEq(address(deviceWallet2.verifier()), address(p256Verifier), "P256Verifier address should have been initialised in deviceWallet2");
        assertEq(address(deviceWallet.getVaultAddress()), address(vault), "Vault address should have matched in deviceWallet");
        assertEq(address(deviceWallet2.getVaultAddress()), address(vault), "Vault address should have matched in deviceWallet2");

        bytes32[2] memory deviceWalletOwner = deviceWallet.getOwner();
        assertEq(deviceWalletOwner[0], pubKey1[0], "X co-ordinate of deviceWallet owner should have matched");
        assertEq(deviceWalletOwner[1], pubKey1[1], "Y co-ordinate of deviceWallet owner should have matched");

        bytes32[2] memory deviceWalletOwner2 = deviceWallet2.getOwner();
        assertEq(deviceWalletOwner2[0], pubKey2[0], "X co-ordinate of deviceWallet2 owner should have matched");
        assertEq(deviceWalletOwner2[1], pubKey2[1], "Y co-ordinate of deviceWallet2 owner should have matched");

        // Check storage variables in eSIM wallet
        assertEq(address(eSIMWallet1.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet1 should have matched");
        assertEq(address(eSIMWallet2.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet2 should have matched");
        assertEq(address(eSIMWallet3.eSIMWalletFactory()), address(eSIMWalletFactory), "eSIMWalletFactory address in eSIM wallet3 should have matched");
        assertEq(address(eSIMWallet1.deviceWallet()), address(deviceWallet), "ESIM wallet1 should have correct device wallet");
        assertEq(address(eSIMWallet2.deviceWallet()), address(deviceWallet), "ESIM wallet2 should have correct device wallet");
        assertEq(address(eSIMWallet3.deviceWallet()), address(deviceWallet2), "ESIM wallet3 should have correct device wallet");
        assertEq(eSIMWallet1.eSIMUniqueIdentifier(), "ESIM_0_1", "ESIM unique identifier should not be empty for eSIMWallet1");
        assertEq(eSIMWallet3.eSIMUniqueIdentifier(), "ESIM_1_1", "ESIM unique identifier should not be empty for eSIMWallet3");
        assertEq(bytes(eSIMWallet2.eSIMUniqueIdentifier()).length, 0, "ESIM unique identifier should be empty");
        assertEq(eSIMWallet1.newRequestedOwner(), address(0), "ESIM wallet1's new requested owner should have been address(0)");
        assertEq(eSIMWallet2.newRequestedOwner(), address(0), "ESIM wallet2's new requested owner should have been address(0)");
        assertEq(eSIMWallet3.newRequestedOwner(), address(0), "ESIM wallet3's new requested owner should have been address(0)");
        assertEq(eSIMWallet1.getTransactionHistory().length, 0, "Transaction history1 should have been empty");
        assertEq(eSIMWallet2.getTransactionHistory().length, 0, "Transaction history2 should have been empty");
        assertEq(eSIMWallet3.getTransactionHistory().length, 0, "Transaction history3 should have been empty");
        assertEq(eSIMWallet1.owner(), address(deviceWallet), "ESIMWallet1 owner should have been device wallet");
        assertEq(eSIMWallet2.owner(), address(deviceWallet), "ESIMWallet2 owner should have been device wallet");
        assertEq(eSIMWallet3.owner(), address(deviceWallet2), "ESIMWallet3 owner should have been device wallet");
    }

    /// @notice Checks the registry and device wallet view of a single eSIM wallet binding.
    /// Kept as a helper rather than four inline assertions because the via-IR pipeline runs out
    /// of stack slots when this many consecutive assertions are fused into one test body.
    function _assertESIMWalletBinding(
        MockDeviceWallet _deviceWallet,
        MockESIMWallet _eSIMWallet,
        bool _onStandby,
        address _associatedDeviceWallet,
        bool _canPullETH,
        bool _isValidForDeviceWallet
    ) internal view {
        assertEq(registry.isESIMWalletOnStandby(address(_eSIMWallet)), _onStandby, "Unexpected standby status for the eSIM wallet");
        assertEq(registry.isESIMWalletValid(address(_eSIMWallet)), _associatedDeviceWallet, "Unexpected device wallet associated with the eSIM wallet");
        assertEq(_deviceWallet.canPullETH(address(_eSIMWallet)), _canPullETH, "Unexpected ETH pull access for the eSIM wallet");
        assertEq(_deviceWallet.isValidESIMWallet(address(_eSIMWallet)), _isValidForDeviceWallet, "Unexpected eSIM wallet validity for the device wallet");
    }
}
