// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// Libraries
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {SIG_VALIDATION_FAILED, _packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {WebAuthn} from "../WebAuthn.sol";
import {Errors} from "../Errors.sol";

// Types
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {Call, WebAuthnSignature} from "../CustomStructs.sol";

// Interfaces
import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

// Contracts
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// Lets the wallet receive ERC-721 and ERC-1155 transfers
import {TokenCallbackHandler} from "@account-abstraction/contracts/accounts/callback/TokenCallbackHandler.sol";
import {P256Verifier} from "../P256Verifier.sol";

/// @notice ERC-4337 account owned by a P256 key rather than by an address
/// @dev    `validateUserOp` and `isValidSignature` each hash a different precursor, so a signature
///         made for one is never accepted by the other.
contract Account4337 is IAccount, Initializable, TokenCallbackHandler, IERC1271 {
    using UserOperationLib for PackedUserOperation;

    string private constant EIP191_PREFIX = "\x19Ethereum Signed Message:\n";

    /// @dev version (1) + validUntil (6) + userOpHash (32). A string because it is hashed as
    ///      text after the EIP-191 prefix.
    string private constant USEROP_PRECURSOR_LENGTH = "39";

    /// @dev version (1) + validUntil (6) + chain id (32) + wallet (20) + message hash (32)
    string private constant ERC1271_PRECURSOR_LENGTH = "91";

    /// @dev chain id (32) + wallet (20) + new key (64)
    string private constant ROTATION_PRECURSOR_LENGTH = "116";

    /// @dev version (uint8) + validUntil (uint48), at the front of every signature
    uint256 private constant SIGNATURE_HEADER_LENGTH = 7;

    /// @notice The ERC-4337 EntryPoint singleton this account answers to
    /// @dev    Immutable to keep validation cheap, so a new EntryPoint needs a new implementation.
    IEntryPoint public immutable entryPoint;

    /// @notice Contract that verifies every WebAuthn assertion for this account
    P256Verifier public immutable verifier;

    /// @notice X and Y co-ordinates of the P256 key that owns this account
    /// @dev DeviceWallet's storage starts right after this slot. A new state variable here would
    ///      shift it on deployed wallets, which then read zeros. Put new state in an ERC-7201
    ///      namespace instead.
    bytes32[2] public owner;

    /// @notice Emitted once, when the account's owner key is first set
    event Account4337Initialized(IEntryPoint indexed entryPoint, bytes32[2] owner);

    /// @notice Emitted when the owner key is replaced
    event AccountOwnershipTransferred(bytes32[2] newOwner);

    /// @notice Restricts a call to the account itself
    /// @dev Reached from outside only by an owner-signed `execute` or `executeBatch` to this address
    modifier onlySelf() {
        if(msg.sender != address(this)) revert Errors.OnlySelf();
        _;
    }

    /// @notice Restricts a call to the EntryPoint singleton
    modifier onlyEntryPoint() {
        if(msg.sender != address(entryPoint)) revert Errors.OnlyEntryPoint();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------------------------------

    /// @notice Wires the entry point and WebAuthn verifier used by this account
    /// @param _entryPoint EntryPoint singleton this account validates against
    /// @param _verifier Contract used to verify WebAuthn assertions
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint _entryPoint,
        P256Verifier _verifier
    ) {
        entryPoint = _entryPoint;
        verifier = _verifier;
        _disableInitializers();
    }

    /// @notice Sets the owner key on a freshly deployed account
    /// @dev Internal so a proxy deployed without its init call cannot be claimed by anyone with a
    ///      key of their choosing. Only a subclass initializer can reach it.
    /// @param anOwner X,Y co-ordinates of the P256 key taking ownership
    function initialize(bytes32[2] memory anOwner) internal virtual initializer {
        _initialize(anOwner);
    }

    /// @notice Writes the owner key without the initializer guard
    /// @param anOwner X,Y co-ordinates of the P256 key taking ownership
    function _initialize(bytes32[2] memory anOwner) internal virtual {
        owner = anOwner;
        emit Account4337Initialized(entryPoint, owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------------------------------

    /// @notice Makes one call from this account
    /// @dev Callable by the EntryPoint or this account. The P256 key has no address, so it reaches
    ///      this only through a signed user operation.
    /// @param call Target, value and calldata of the call to make
    function execute(
        Call calldata call
    ) external {
        _requireFromEntryPointOrOwner();
        _call(call.dest, call.value, call.data);
    }

    /// @notice Makes a sequence of calls from this account, reverting all of them if one fails
    /// @dev Same callers as `execute`
    /// @param calls Targets, values and calldata, executed in order
    function executeBatch(
        Call[] calldata calls
    ) external {
        _requireFromEntryPointOrOwner();

        for (uint256 i = 0; i < calls.length; i++) {
            _call(calls[i].dest, calls[i].value, calls[i].data);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Signature validation
    // ---------------------------------------------------------------------------------------------

    /// @notice Validates a signature over an arbitrary message, per ERC-1271
    /// @dev The signed challenge is not `_messageHash` but the EIP-191 digest over version,
    ///      validUntil, chain id, this address and `_messageHash`, so a signer needs all five.
    /// @param _messageHash EIP-191 digest of the original message
    /// @param _signature Packed version, validUntil and WebAuthn assertion
    /// @return magicValue `0x1626ba7e` when the signature is valid and unexpired, `0xffffffff` otherwise
    function isValidSignature(
        bytes32 _messageHash,
        bytes calldata _signature
    ) external view override returns (bytes4 magicValue) {
        uint256 sigLength = _signature.length;
        if(sigLength <= SIGNATURE_HEADER_LENGTH + 32) return 0xffffffff;

        uint8 version = uint8(_signature[0]);
        if(version == 1) {
            uint48 validUntil = uint48(bytes6(_signature[1:SIGNATURE_HEADER_LENGTH]));
            bytes calldata webAuthnSignatureBytes = bytes(_signature[SIGNATURE_HEADER_LENGTH:]);

            // TIMESTAMP is only barred inside validateUserOp, so reading it here is fine
            if(block.timestamp > validUntil) {
                return 0xffffffff;
            }

            // validUntil is signed so an expired signature cannot be revived by rewriting it.
            // Chain id and address are signed because a wallet has the same address on every
            // chain, and createAccount can deploy a second wallet with the same key at another salt.
            bytes memory precursorBytes = abi.encodePacked(
                version,
                validUntil,
                block.chainid,
                address(this),
                _messageHash
            );
            bytes32 challengeDigest = keccak256(
                abi.encodePacked(
                    EIP191_PREFIX,
                    ERC1271_PRECURSOR_LENGTH,
                    precursorBytes
                )
            );
            bytes memory challengeBytes = abi.encodePacked(challengeDigest);
            if(_validateSignature(challengeBytes, webAuthnSignatureBytes)) {
                return IERC1271(this).isValidSignature.selector;    // magic value: `0x1626ba7e`
            }
        }
        return 0xffffffff;
    }

    /// @inheritdoc IAccount
    /// @dev TIMESTAMP is banned here, so expiry goes back in the packed result. The beacon read
    ///      may need a staked entity on a strict ERC-7562 bundler.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    )
        external virtual override onlyEntryPoint returns (uint256 validationData) {
        // `forge coverage` incorrectly marks this function and everything downstream as uncovered
        validationData = _validateUserOpSignature(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership handover
    // ---------------------------------------------------------------------------------------------

    /// @notice Replaces the P256 key that owns this account
    /// @dev The current owner signs the call, and the new key must sign `rotationChallenge`, so
    ///      an owner cannot rotate onto a key it does not control.
    /// @param newOwner X,Y co-ordinates of the P256 key taking over
    /// @param newOwnerSignature ABI-encoded WebAuthn assertion by the new key over the challenge
    /// @return The owner key now in force
    function transferOwnership(bytes32[2] memory newOwner, bytes calldata newOwnerSignature)
        onlySelf
        public
        returns (bytes32[2] memory)
    {
        _transferOwnership(newOwner, newOwnerSignature);
        return owner;
    }

    /// @notice Moves ownership to a new key once that key has proved it can sign
    /// @dev The single rotation path, so any later recovery route gets the same check. A subclass
    ///      with its own owner record overrides this to keep it in step.
    /// @param newOwner X,Y co-ordinates of the P256 key taking over
    /// @param newOwnerSignature ABI-encoded WebAuthn assertion by the new key over the challenge
    function _transferOwnership(bytes32[2] memory newOwner, bytes calldata newOwnerSignature) internal virtual {
        if(!_verifyWebAuthn(rotationChallenge(newOwner), newOwnerSignature, newOwner)) {
            revert Errors.NewOwnerKeyCannotSign();
        }

        owner = newOwner;
        emit AccountOwnershipTransferred(newOwner);
    }

    /// @notice The challenge a new owner key signs to accept this account
    /// @dev Binds chain, wallet and key, and its length differs from the other two precursors, so
    ///      the proof cannot be reused anywhere else.
    /// @param newOwner X,Y co-ordinates of the P256 key taking over
    /// @return The raw challenge bytes the WebAuthn assertion must carry
    function rotationChallenge(bytes32[2] memory newOwner) public view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                EIP191_PREFIX,
                ROTATION_PRECURSOR_LENGTH,
                block.chainid,
                address(this),
                newOwner[0],
                newOwner[1]
            )
        );
        return abi.encodePacked(digest);
    }

    // ---------------------------------------------------------------------------------------------
    // EntryPoint deposit
    // ---------------------------------------------------------------------------------------------

    /// @notice This account's gas deposit held by the EntryPoint
    /// @return The deposited amount
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice Tops up this account's gas deposit at the EntryPoint
    /// @dev Open to anyone, since only the payer loses anything.
    function addDeposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Withdraws part of this account's gas deposit from the EntryPoint
    /// @param withdrawAddress Recipient of the withdrawn ETH
    /// @param amount Amount to withdraw
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public onlySelf {
        if(withdrawAddress == address(0)) revert Errors.ZeroAddress("withdrawAddress");
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Caller checks and outward calls
    // ---------------------------------------------------------------------------------------------

    /// @notice Reverts unless the caller is the EntryPoint or this account itself
    /// @dev "Owner" here means `address(this)`, since the P256 key has no address.
    function _requireFromEntryPointOrOwner() internal view {
        if(msg.sender != address(entryPoint) && msg.sender != address(this)) {
            revert Errors.OnlyEntryPointOrSelf();
        }
    }

    /// @notice Calls a target and bubbles its revert data unchanged
    /// @param target Address to call
    /// @param value ETH to send with the call
    /// @param data Calldata for the call
    function _call(
        address target,
        uint256 value,
        bytes memory data
    ) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            // Solidity cannot revert with an existing bytes buffer. `result` is length-prefixed
            // memory from `call`, so the payload starts 32 bytes in.
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Signature verification and prefund
    // ---------------------------------------------------------------------------------------------

    /// @notice Verifies the signature carried by a user operation
    /// @dev The challenge is the EIP-191 digest over version, validUntil and `userOpHash`, which
    ///      already covers the operation's fields and the chain.
    /// @param userOp The packed user operation
    /// @param userOpHash Hash the EntryPoint computed for it
    /// @return validationData Packed validAfter (0) and validUntil, or SIG_VALIDATION_FAILED for a
    ///         signature that fails to verify or carries a zero validUntil
    function _validateUserOpSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) private view returns (uint256 validationData) {
        bytes calldata signature = userOp.signature;
        uint256 sigLength = signature.length;
        // Fail without reverting, so only this operation fails and not the bundle. Not 0xffffffff:
        // the EntryPoint reads the low 160 bits as an aggregator and would revert the bundle.
        if(sigLength <= SIGNATURE_HEADER_LENGTH + 32) return SIG_VALIDATION_FAILED;

        uint8 version = uint8(signature[0]);
        if(version == 1) {
            uint48 validUntil = uint48(bytes6(signature[1:SIGNATURE_HEADER_LENGTH]));
            // Zero means "no expiry" to the EntryPoint but "expired" to isValidSignature. Refusing
            // it keeps one header from meaning two things.
            if(validUntil == 0) return SIG_VALIDATION_FAILED;
            bytes calldata webAuthnSignatureBytes = bytes(signature[SIGNATURE_HEADER_LENGTH:]);

            bytes memory precursorBytes = abi.encodePacked(version, validUntil, userOpHash);
            bytes32 challengeDigest = keccak256(
                abi.encodePacked(
                    EIP191_PREFIX,
                    USEROP_PRECURSOR_LENGTH,
                    precursorBytes
                )
            );
            bytes memory challengeBytes = abi.encodePacked(challengeDigest);

            if(_validateSignature(challengeBytes, webAuthnSignatureBytes)) {
                // TIMESTAMP is banned here, so the EntryPoint enforces validUntil
                return _packValidationData(false, validUntil, 0);
            }
            else {
                return SIG_VALIDATION_FAILED;
            }
        }
        return SIG_VALIDATION_FAILED;
    }

    /// @notice Verifies a WebAuthn assertion against the owner key
    /// @param challenge Raw bytes that must appear, Base64Url encoded, in the assertion's
    ///                  `clientDataJSON` challenge field
    /// @param webAuthnSignatureBytes ABI-encoded WebAuthn assertion
    /// @return True when the assertion is valid for the owner key
    function _validateSignature(
        bytes memory challenge,
        bytes calldata webAuthnSignatureBytes
    ) private view returns (bool) {
        return _verifyWebAuthn(challenge, webAuthnSignatureBytes, owner);
    }

    /// @notice Verifies a WebAuthn assertion against any P256 key
    /// @param challenge Raw bytes that must appear, Base64Url encoded, in the assertion's challenge
    /// @param webAuthnSignatureBytes ABI-encoded WebAuthn assertion
    /// @param key X,Y co-ordinates of the key that must have signed
    /// @return True when the assertion is valid for that key
    function _verifyWebAuthn(
        bytes memory challenge,
        bytes calldata webAuthnSignatureBytes,
        bytes32[2] memory key
    ) private view returns (bool) {
        // Not abi.decode, which reverts on malformed input. In validation a revert fails the whole
        // bundle, and behind isValidSignature it reaches the caller as an error. A failed decode
        // leaves the struct zeroed, which verifySignature rejects.
        WebAuthnSignature memory sig = WebAuthn.tryDecodeSignature(webAuthnSignatureBytes);

        return verifier.verifySignature({
            message: challenge,
            requireUserVerification: true,
            webAuthnSignature: sig,
            x: uint256(key[0]),
            y: uint256(key[1])
        });
    }

    /// @notice Repays the EntryPoint for gas it fronted on this account's behalf
    /// @dev Only called from `validateUserOp`, so `msg.sender` is the EntryPoint. The result is
    ///      ignored because the EntryPoint checks the balance it received itself.
    /// @param missingAccountFunds Amount the EntryPoint asked for, zero when the deposit covers it
    function _payPrefund(uint256 missingAccountFunds) private {
        if (missingAccountFunds != 0) {
            (bool success, ) = payable(msg.sender).call{
                value: missingAccountFunds,
                gas: type(uint256).max
            }("");
            (success); // no-op; silence unused variable warning
        }
    }

    /// @notice Accepts plain ETH transfers
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}
