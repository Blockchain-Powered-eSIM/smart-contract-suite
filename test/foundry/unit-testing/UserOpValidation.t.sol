// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";

import "test/utils/DeployerBase.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

/// @notice Covers the user operation signature path end to end through the mock entry point,
///         which until now emitted an event and never called validateUserOp at all.
contract UserOpValidationTest is DeployerBase {

    DeviceWallet wallet;

    /// @notice Deploys a wallet owned by the signing harness. Called per test rather than from
    /// setUp, which DeployerBase does not declare virtual.
    function _deployWallet() internal {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();

        string[] memory identifiers = new string[](1);
        bytes32[2][] memory keys = new bytes32[2][](1);
        uint256[] memory salts = new uint256[](1);
        uint256[] memory deposits = new uint256[](1);

        identifiers[0] = "Device_UserOp";
        keys[0] = ownerKey;
        salts[0] = 31072026;
        deposits[0] = 0;

        vm.prank(eSIMWalletAdmin);
        Wallets[] memory wallets = deviceWalletFactory.deployDeviceWalletForUsers(identifiers, keys, salts, deposits);
        wallet = DeviceWallet(payable(wallets[0].deviceWallet));
    }

    /// @notice The challenge the wallet expects for a user operation. Unlike the ERC-1271 path this
    /// carries no chain id or wallet address, because both are already inside the operation hash.
    function _userOpChallenge(uint48 _validUntil, bytes32 _userOpHash) internal pure returns (bytes memory) {
        return abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n39",
                    uint8(1),
                    _validUntil,
                    _userOpHash
                )
            )
        );
    }

    function _operation(uint256 _nonce) internal view returns (PackedUserOperation memory op) {
        op.sender = address(wallet);
        op.nonce = _nonce;
    }

    function _sign(PackedUserOperation memory _op, uint48 _validUntil) internal returns (bytes memory) {
        return abi.encodePacked(
            uint8(1),
            _validUntil,
            WebAuthnSigner.sign(_userOpChallenge(_validUntil, entryPoint.getUserOpHash(_op)))
        );
    }

    function test_handleOps_acceptsAnOperationSignedByTheOwner() public {
        _deployWallet();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _operation(1);

        uint48 validUntil = uint48(block.timestamp + 1 days);
        ops[0].signature = _sign(ops[0], validUntil);

        entryPoint.handleOps(ops, payable(vault));
    }

    /// @notice A signature made for one operation must not carry another. The entry point hash is
    /// what separates them, and it used to be one constant for every operation.
    function test_handleOps_rejectsASignatureMadeForAnotherOperation() public {
        _deployWallet();
        uint48 validUntil = uint48(block.timestamp + 1 days);

        PackedUserOperation memory signedOperation = _operation(1);
        bytes memory signature = _sign(signedOperation, validUntil);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _operation(2);
        ops[0].signature = signature;

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(ops, payable(vault));
    }

    /// @notice A signature too short to hold an assertion returns SIG_VALIDATION_FAILED, and the
    /// entry point has to read that as a rejection rather than as an aggregator address.
    function test_handleOps_rejectsAnUnparseableSignature() public {
        _deployWallet();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _operation(1);
        ops[0].signature = new bytes(39);

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        entryPoint.handleOps(ops, payable(vault));
    }

    /// @notice The wallet returns its expiry as packed validation data rather than checking the
    /// clock itself, because TIMESTAMP is not allowed during validation. The entry point is what
    /// enforces it.
    function test_handleOps_rejectsAnExpiredOperation() public {
        _deployWallet();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _operation(1);

        uint48 validUntil = uint48(block.timestamp + 1 days);
        ops[0].signature = _sign(ops[0], validUntil);

        vm.warp(uint256(validUntil) + 1);

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA22 expired or not due"));
        entryPoint.handleOps(ops, payable(vault));
    }
}
