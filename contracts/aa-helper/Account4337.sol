pragma solidity 0.8.25;

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

    /// "\x19Ethereum Signed Message:\n"
    string private constant EIP191_PREFIX = "\x19Ethereum Signed Message:\n";
    /// Length of the packed data: version (1) + validUntil (6) + userOpHash (32) = 39
    string private constant USEROP_PRECURSOR_LENGTH = "39";
    /// version (uint8) + validUntil (uint48)
    uint256 private constant SIGNATURE_HEADER_LENGTH = "7";

    event Account4337Initialized(IEntryPoint indexed entryPoint, bytes32[2] owner);

    event AccountOwnershipTransferred(bytes32[2] newOwner);

    /// @notice Emitted when the signature becomes invalid
    event SignatureExpired(bytes signature, uint256 validUntil, uint256 currentTimestamp);

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

    /**
     * @notice Validates a signature according to EIP-1271 using the WebAuthn verifier.
     * @dev Assumes the `_signature` bytes were encoded off-chain using the `_encodeSignature`
     *      TypeScript function format: `abi.encodePacked(version, validUntil, abi.encode(WebAuthnSigData))`.
     *      Assumes the `_messageHash` provided is the EIP-191 digest that was embedded as the challenge
     *      in the `clientDataJSON` during off-chain signing (i.e., `_messageHash = hashMessage(originalMessage)`).
     * @param _messageHash The EIP-191 digest of the original message (`keccak256("\x19Ethereum Signed Message:\n" + len(message) + message)`).
     * @param _signature The packed signature bytes including version, validUntil, and ABI-encoded WebAuthn data.
     * @return magicValue `0x1626ba7e` if the signature is valid and timely, `0xffffffff` otherwise.
     */
    function isValidSignature(
        bytes32 _messageHash,
        bytes calldata _signature
    ) external view override returns (bytes4 magicValue) {
        uint256 sigLength = _signature.length;
        if(sigLength <= SIGNATURE_HEADER_LENGTH + 32) return 0xffffffff;

        uint8 version = uint8(_signature[0]);
        if(version == 1) {
            // Version 1: version (1 byte) | validUntil (6 bytes) | abi.encode(WebAuthnSignature)
            uint48 validUntil = uint48(bytes6(_signature[1:SIGNATURE_HEADER_LENGTH]));
            // ABI encoded WebAuthnSignature bytes
            bytes memory webAuthnSignatureBytes = bytes(_signature[SIGNATURE_HEADER_LENGTH]);

            if(block.timestamp > validUntil) {
                emit SignatureExpired(_signature, validUntil, block.timestamp);
                return 0xffffffff;
            }

            // The challenge expected by WebAuthn.sol is the EIP-191 digest itself in bytes format
            bytes memory challengeBytes = abi.encodePacked(_messageHash);
            if(_validateSignature(challengeBytes, webAuthnSignatureBytes)) {
                return IERC1271(this).isValidSignature.selector;    // magic value: `0x1626ba7e`
            }
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

    /**
     * @dev Validates the signature of a UserOperation based on the custom versioning scheme using WebAuthn.
     * @param userOp The packed user operation.
     * @param userOpHash The hash calculated by the EntryPoint according to ERC-4337 rules.
     * @return validationData Packed validAfter (0) and validUntil timestamps, or SIG_VALIDATION_FAILED.
     */
    function _validateUserOpSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) private view returns (uint256 validationData) {
        bytes calldata signature = userOp.signature;
        uint256 sigLength = signature.length;
        if(sigLength <= SIGNATURE_HEADER_LENGTH + 32) return 0xffffffff;

        uint8 version = uint8(signature[0]);
        if(version == 1) {
            // Version 1: version (1 byte) | validUntil (6 bytes) | abi.encode(WebAuthnSignature)
            uint48 validUntil = uint48(bytes6(signature[1:SIGNATURE_HEADER_LENGTH]));
            // ABI encoded WebAuthnSignature bytes
            bytes memory webAuthnSignatureBytes = bytes(signature[SIGNATURE_HEADER_LENGTH]);

            if(block.timestamp > validUntil) {
                // true for signature failure
                return _packValidationData(true, 0, 0);
            }

            // Reconstructing the exact bytes that were hashed with EIP-191 prefix off-chain
            bytes memory precursorBytes = abi.encodePacked(version, validUntil, userOpHash);
            // Calculating the EIP-191 digest of the precursor bytes
            // keccak256("\x19Ethereum Signed Message:\n39" + precursorBytes)
            bytes32 challengeDigest = keccak256(
                abi.encodePacked(
                    EIP191_PREFIX,
                    USEROP_PRECURSOR_LENGTH,
                    precursorBytes
                )
            );
            // The challenge expected by the WebAuthn.sol is in bytes format
            bytes memory challengeBytes = abi.encodePacked(challengeDigest);
            
            if(_validateSignature(challengeBytes, webAuthnSignatureBytes)) {
                // False because signature is valid
                return _packValidationData(false, validUntil, 0);
            }
            else {
                return SIG_VALIDATION_FAILED;
            }
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

    /**
     * @dev Internal function to validate a signature using the P256Verifier -> WebAuthn library.
     * @param challenge The raw bytes expected to be found (Base64Url encoded) in the
     *                  `challenge` field of the `clientDataJSON` within the `webAuthnSignatureBytes`.
     * @param webAuthnSignature The ABI-encoded WebAuthnSigData tuple containing authenticatorData,
     *                                    clientDataJSON, indices, r, and s.
     * @return True if the WebAuthn assertion is valid according to the WebAuthn library's checks.
     */
    function _validateSignature(
        bytes memory challenge,
        bytes calldata webAuthnSignatureBytes
    ) private view returns (bool) {
        // Decoding the WebAuthnSignature struct from the provided ABI-encoded bytes
        WebAuthnSignature memory sig = abi.decode(webAuthnSignatureBytes, (WebAuthnSignature));

        WebAuthnSignature memory webAuthnSig = WebAuthnSignature({
            authenticatorData: sig.authenticatorData,
            clienDataJSON: sig.clientDataJSON,
            challengeIndex: sig.challengeIndex,
            typeIndex: sig.typeIndex,
            r: sig.r,
            s: sig.s
        });

        return verifier.verifySignature({
            message: challenge,
            requireUserVerification: false,
            webAuthnSignature: webAuthnSig,
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
        require(withdrawAddress != address(0), "Cannot withdraw to address(0)");
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    // solhint-disable-next-line no-empty-blocks
    fallback() external payable {}
}
