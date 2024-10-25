pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

// import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@account-abstraction/contracts/interfaces/IAccount.sol";
import "@account-abstraction/contracts/core/Helpers.sol";
import "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "@account-abstraction/contracts/core/UserOperationLib.sol";
// To allow the smart wallet to handle ERC20 and ERC721 tokens
import {TokenCallbackHandler} from "@account-abstraction/contracts/samples/callback/TokenCallbackHandler.sol";
import {P256Verifier} from "../P256Verifier.sol";
import {WebAuthn} from "../WebAuthn.sol";
import "../CustomStructs.sol";

contract Account4337 is IAccount, Initializable, TokenCallbackHandler, IERC1271 {
    using UserOperationLib for PackedUserOperation;
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    bytes32[2] public owner;

    /// The ERC-4337 entry point singleton
    IEntryPoint public immutable entryPoint;

    /// Signature verifier contract
    P256Verifier public immutable verifier;
    
    event Account4337Initialized(IEntryPoint indexed entryPoint, bytes32[2] owner);

    event AccountOwnershipTransferred(bytes32[2] newOwner);

    modifier onlySelf() {
        require(msg.sender == address(this), "Only self");
        _;
    }

    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "Only entry point");
        _;
    }

    modifier onlyOwnerOrEntryPoint() {
        _requireFromEntryPointOrOwner();
        _;
    }

    constructor(
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) {
        entryPoint = _entryPoint;
        verifier = _verifier;
        _disableInitializers();
    }

    /**
     * @dev The _entryPoint member is immutable, to reduce gas consumption.  To upgrade EntryPoint,
     * a new implementation of SimpleAccount must be deployed with the new EntryPoint address, then upgrading
     * the implementation by calling `upgradeTo()`
     */
    function initialize(bytes32[2] memory anOwner) public virtual initializer {
        _initialize(anOwner);
    }

    function _initialize(bytes32[2] memory anOwner) internal virtual {
        owner = anOwner;
        emit Account4337Initialized(entryPoint, owner);
    }

    function transferOwnership(bytes32[2] memory newOwner) onlySelf public returns (bytes32[2] memory) {
        owner = newOwner;
        emit AccountOwnershipTransferred(newOwner);
        return owner;
    }

    /**
     * execute a transaction (called directly from owner, or by entryPoint)
     */
    function execute(
        Call calldata call
    ) external {
        _requireFromEntryPointOrOwner();
        _call(call.dest, call.value, call.data);
    }
    
    /**
     * execute a sequence of transactions
     * @dev to reduce gas consumption for trivial case (no value), use a zero-length array to mean zero value
     */
    function executeBatch(
        Call[] calldata calls
    ) external {
        _requireFromEntryPointOrOwner();

        for (uint256 i = 0; i < calls.length; i++) {
            _call(calls[i].dest, calls[i].value, calls[i].data);
        }
    }

    function isValidSignature(
        bytes32 message,
        bytes calldata signature
    ) external view override returns (bytes4 magicValue) {
        if (_validateSignature(abi.encodePacked(message), signature)) {
            return IERC1271(this).isValidSignature.selector;
        }
        return 0xffffffff;
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    )
        external virtual override onlyEntryPoint returns (uint256 validationData) {
        // Note: `forge coverage` incorrectly marks this function and downstream
        // as non-covered.
        validationData = _validateUserOpSignature(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    function _validateUserOpSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) private view returns (uint256 validationData) {
        bytes memory messageToVerify;
        bytes calldata signature;
        ValidationData memory returnIfValid;

        uint256 sigLength = userOp.signature.length;
        if (sigLength == 0) return SIG_VALIDATION_FAILED;

        uint8 version = uint8(userOp.signature[0]);
        if (version == 1) {
            if (sigLength < 7) return SIG_VALIDATION_FAILED;
            uint48 validUntil = uint48(bytes6(userOp.signature[1:7]));

            signature = userOp.signature[7:]; // keySlot, signature
            messageToVerify = abi.encodePacked(version, validUntil, userOpHash);
            returnIfValid.validUntil = validUntil;
        } else {
            return SIG_VALIDATION_FAILED;
        }

        if (_validateSignature(messageToVerify, signature)) {
            return _packValidationData(returnIfValid);
        }
        return SIG_VALIDATION_FAILED;
    }

    // Require the function call went through EntryPoint or owner
    function _requireFromEntryPointOrOwner() internal view {
        require(
            msg.sender == address(entryPoint) || msg.sender == address(this),
            "account: not Owner or EntryPoint"
        );
    }

    function _validateSignature(
        bytes memory message,
        bytes calldata signature
    ) private view returns (bool) {
        WebAuthnSignature memory sig = abi.decode(signature, (WebAuthnSignature));

        return verifier.verifySignature({
            message: message,
            requireUserVerification: false,
            webAuthnSignature: sig,
            x: uint256(owner[0]),
            y: uint256(owner[1])
        });
    }

    function _call(
        address target,
        uint256 value,
        bytes memory data
    ) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _payPrefund(uint256 missingAccountFunds) private {
        if (missingAccountFunds != 0) {
            (bool success, ) = payable(msg.sender).call{
                value: missingAccountFunds,
                gas: type(uint256).max
            }("");
            (success); // no-op; silence unused variable warning
        }
    }

    /**
     * check current account deposit in the entryPoint
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * deposit more funds for this account in the entryPoint
     */
    function addDeposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * withdraw value from the account's deposit
     * @param withdrawAddress target to send to
     * @param amount to withdraw
     */
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public onlySelf {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    // solhint-disable-next-line no-empty-blocks
    fallback() external payable {}
}
