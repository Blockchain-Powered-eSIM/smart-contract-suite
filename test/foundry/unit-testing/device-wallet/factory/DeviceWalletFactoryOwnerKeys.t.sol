// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "contracts/CustomStructs.sol";
import {Errors} from "contracts/Errors.sol";

import {DeviceWalletFactoryFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFactoryFixture.sol";

/// @notice A P256 key that cannot verify a signature must never reach a wallet.
/// @dev Three ways in reach the same check: the admin batch, the permissionless createAccount, and
///      preCreateAccountValidation, which is what the offchain side calls before submitting a
///      userOp. They are tested together because the check only holds if all three agree. A wallet
///      deployed under a key that can never sign consumes its device identifier for good.
contract DeviceWalletFactoryOwnerKeysTest is DeviceWalletFactoryFixture {

    /// @notice Both co-ordinates are non-zero and inside the field, and the pair still fails
    /// y^2 = x^3 - 3x + b, so signature verification would reject it for the wallet's whole life.
    function _offCurveKey() internal pure returns (bytes32[2] memory) {
        return [bytes32(uint256(1)), bytes32(uint256(1))];
    }

    /// @notice A coordinate at or above the field prime is not a field element at all
    function _outOfFieldKey() internal view returns (bytes32[2] memory) {
        return [bytes32(type(uint256).max), pubKey1[1]];
    }

    /// @notice A zero P256 key can never sit on the curve, so the wallet it produces could never
    /// authorise anything while still consuming its device identifier permanently.
    function test_deployDeviceWalletForUsers_revertsOnZeroOwnerKey() public {
        bytes32[2] memory zeroKey = [bytes32(0), bytes32(0)];
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], zeroKey, uint256(781), 1 ether);

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "Identifier must not have been consumed");
        assertEq(registry.registeredP256Keys(keccak256(abi.encode(zeroKey[0], zeroKey[1]))), address(0), "Zero key must not have been registered");
    }

    /// @notice The permissionless deploy path has to reject the same key, and a single zero
    /// coordinate is already off the curve.
    function test_createAccount_revertsOnZeroOwnerKeyComponent() public {
        bytes32[2] memory halfZeroKey = [pubKey1[0], bytes32(0)];

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], halfZeroKey, uint256(782));

        address counterfactual = deviceWalletFactory.getCounterFactualAddress(
            halfZeroKey,
            customDeviceUniqueIdentifiers[0],
            uint256(782)
        );
        assertEq(counterfactual.code.length, 0, "No wallet should have been deployed");
    }

    /// @notice The off-chain pre-check for the userop deploy path must agree with the deploy path.
    function test_preCreateAccountValidation_revertsOnZeroOwnerKey() public {
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.preCreateAccountValidation(
            customDeviceUniqueIdentifiers[0],
            [bytes32(0), bytes32(0)]
        );
    }

    /// @notice The admin batch path must refuse a key that is not on the curve
    function test_deployDeviceWalletForUsers_revertsOnOffCurveOwnerKey() public {
        bytes32[2] memory offCurveKey = _offCurveKey();
        (
            string[] memory identifiers,
            bytes32[2][] memory keys,
            uint256[] memory salts,
            uint256[] memory deposits
        ) = _singleEntryBatch(customDeviceUniqueIdentifiers[0], offCurveKey, uint256(783), 1 ether);

        vm.deal(eSIMWalletAdmin, 1 ether);
        vm.prank(eSIMWalletAdmin);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.deployDeviceWalletForUsers{value: 1 ether}(
            identifiers,
            keys,
            salts,
            deposits
        );

        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "Identifier must not have been consumed");
        assertEq(registry.registeredP256Keys(keccak256(abi.encode(offCurveKey[0], offCurveKey[1]))), address(0), "Off-curve key must not have been registered");
    }

    /// @notice The permissionless deploy path must refuse the same key
    function test_createAccount_revertsOnOffCurveOwnerKey() public {
        bytes32[2] memory offCurveKey = _offCurveKey();

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], offCurveKey, uint256(783));

        address counterfactual = deviceWalletFactory.getCounterFactualAddress(
            offCurveKey,
            customDeviceUniqueIdentifiers[0],
            uint256(783)
        );
        assertEq(counterfactual.code.length, 0, "No wallet should have been deployed");
    }

    /// @notice A coordinate outside the field is refused rather than reduced into it
    function test_createAccount_revertsOnOutOfFieldOwnerKey() public {
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.createAccount(customDeviceUniqueIdentifiers[0], _outOfFieldKey(), uint256(784));

        assertEq(registry.uniqueIdentifierToDeviceWallet(customDeviceUniqueIdentifiers[0]), address(0), "Identifier must not have been consumed");
    }

    /// @notice The off-chain pre-check must agree with the deploy paths on an off-curve key too
    function test_preCreateAccountValidation_revertsOnOffCurveOwnerKey() public {
        vm.expectRevert(Errors.InvalidDeviceWalletOwnerKey.selector);
        deviceWalletFactory.preCreateAccountValidation(
            customDeviceUniqueIdentifiers[0],
            _offCurveKey()
        );
    }
}
