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
/// @dev    The owner never sends a transaction itself. It signs a WebAuthn assertion, and either
///         the EntryPoint or this account calling into itself turns that into a call. Two entry
///         points read signatures, `validateUserOp` for user operations and `isValidSignature` for
///         ERC-1271, and each hashes a different precursor, so a signature made for one is not
///         accepted by the other.
contract Account4337 is IAccount, Initializable, TokenCallbackHandler, IERC1271 {
    using UserOperationLib for PackedUserOperation;

    /// @dev The EIP-191 prefix, "\x19Ethereum Signed Message:\n"
    string private constant EIP191_PREFIX = "\x19Ethereum Signed Message:\n";

    /// @dev Byte length of the user operation precursor:
    ///      version (1) + validUntil (6) + userOpHash (32).
    ///      A string because it is concatenated after the prefix before hashing.
    string private constant USEROP_PRECURSOR_LENGTH = "39";

    /// @dev Byte length of the ERC-1271 precursor:
    ///      version (1) + validUntil (6) + chain id (32) + wallet (20) + message hash (32).
    string private constant ERC1271_PRECURSOR_LENGTH = "91";

    /// @dev The fixed header on every signature this account accepts.
    ///      version (uint8) + validUntil (uint48)
    uint256 private constant SIGNATURE_HEADER_LENGTH = 7;

    /// @notice The ERC-4337 EntryPoint singleton this account answers to
    /// @dev    Immutable to keep validation cheap, which means moving to a new EntryPoint version
    ///         is a new implementation rather than a setter call.
    IEntryPoint public immutable entryPoint;

    /// @notice Contract that verifies every WebAuthn assertion for this account
    P256Verifier public immutable verifier;

    /// @notice X and Y co-ordinates of the P256 key that owns this account
    /// @dev DeviceWallet inherits this contract, and base storage comes first, so its own
    ///      variables begin immediately after this one. A state variable added here moves all of
    ///      them on wallets that are already deployed, which then read back as zero. Anything
    ///      this contract needs later belongs in its own ERC-7201 namespace, not in a slot
    ///      following `owner`.
    bytes32[2] public owner;

    /// @notice Emitted once, when the account's owner key is first set
    event Account4337Initialized(IEntryPoint indexed entryPoint, bytes32[2] owner);

    /// @notice Emitted when the owner key is replaced
    event AccountOwnershipTransferred(bytes32[2] newOwner);

    /// @notice Restricts a call to the account itself
    /// @dev The only way to satisfy this from outside is `execute` or `executeBatch` targeting this
    ///      address, which the owner key has to have signed for.
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
    /// @dev Internal on purpose. A public setup function guarded only by `initializer` names no
    ///      caller, so a proxy created without its init call in the same transaction could be
    ///      claimed by anyone with an owner key of their choosing and none of the protocol wiring.
    ///      Internal keeps the subclass path working and leaves no other way in.
    /// @param anOwner X,Y co-ordinates of the P256 key taking ownership
    function initialize(bytes32[2] memory anOwner) internal virtual initializer {
        _initialize(anOwner);
    }

    /// @notice Writes the owner key without the initializer guard
    /// @dev Split out so a subclass can reuse the write from its own initializer.
    /// @param anOwner X,Y co-ordinates of the P256 key taking ownership
    function _initialize(bytes32[2] memory anOwner) internal virtual {
        owner = anOwner;
        emit Account4337Initialized(entryPoint, owner);
    }

    // ---------------------------------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------------------------------

    /// @notice Makes one call from this account
    /// @dev Callable by the EntryPoint or by this account. There is no path here for the P256 key
    ///      directly: it holds no address, so it reaches this only by signing a user operation.
    /// @param call Target, value and calldata of the call to make
    function execute(
        Call calldata call
    ) external {
        _requireFromEntryPointOrOwner();
        _call(call.dest, call.value, call.data);
    }

    /// @notice Makes a sequence of calls from this account, reverting all of them if one fails
    /// @dev Same callers as `execute`. Each entry carries its own value, so a batch that moves no
    ///      ETH simply leaves every value at zero.
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
    /// @dev The challenge inside `clientDataJSON` is not `_messageHash`. It is the EIP-191 digest
    ///      over version, validUntil, chain id, this address and `_messageHash`, so an offchain
    ///      signer needs all five. Signature layout is version (1 byte) then validUntil (6 bytes)
    ///      then the ABI-encoded WebAuthn assertion.
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

            // Everything the caller can see has to be inside what was signed, otherwise it can be
            // edited after the fact. validUntil is checked just above but was not part of the
            // challenge, so an expired signature could be revived by rewriting those six bytes.
            // The chain id and this address are here because neither is implied by the message:
            // wallets sit at the same CREATE2 address on every chain, and createAccount will deploy
            // a second wallet at another salt holding the same owner key.
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
            // WebAuthn.sol expects the challenge as bytes
            bytes memory challengeBytes = abi.encodePacked(challengeDigest);
            if(_validateSignature(challengeBytes, webAuthnSignatureBytes)) {
                return IERC1271(this).isValidSignature.selector;    // magic value: `0x1626ba7e`
            }
        }
        return 0xffffffff;
    }

    /// @inheritdoc IAccount
    /// @dev Must stay within the ERC-4337 validation rules: no banned opcodes, no external calls
    ///      to other contracts, no TIMESTAMP. Expiry is handed to the EntryPoint through the packed
    ///      return value instead of being checked here.
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
    /// @dev Reachable only through `execute` or `executeBatch` with this account as the target, so
    ///      the current owner has to sign for it. Nothing outside this contract is told: a
    ///      subclass holding its own record of the owner has to override this and keep that record
    ///      in step.
    /// @param newOwner X,Y co-ordinates of the P256 key taking over
    /// @return The owner key now in force
    function transferOwnership(bytes32[2] memory newOwner) onlySelf public virtual returns (bytes32[2] memory) {
        owner = newOwner;
        emit AccountOwnershipTransferred(newOwner);
        return owner;
    }

    // ---------------------------------------------------------------------------------------------
    // EntryPoint deposit
    // ---------------------------------------------------------------------------------------------

    /// @notice This account's gas deposit held by the EntryPoint
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice Tops up this account's gas deposit at the EntryPoint
    /// @dev Open to anyone, since paying another account's gas costs the payer and nobody else.
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
    /// @dev "Owner" in the name means `address(this)`, not the P256 key, which has no address to
    ///      call from.
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
            // Assembly because Solidity has no way to revert with an existing bytes buffer. It
            // returns the callee's own revert reason instead of a generic failure, which matters
            // when the call ran inside a batch signed offchain. `result` is memory returned by
            // `call`, so its first word is the length and the payload starts 32 bytes in.
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Signature verification and prefund
    // ---------------------------------------------------------------------------------------------

    /// @notice Verifies the signature carried by a user operation
    /// @dev The challenge is the EIP-191 digest over version, validUntil and `userOpHash`. The
    ///      user operation's own fields need no separate binding because the EntryPoint already
    ///      folds them into `userOpHash`.
    /// @param userOp The packed user operation
    /// @param userOpHash Hash the EntryPoint computed for it
    /// @return validationData Packed validAfter (0) and validUntil, or SIG_VALIDATION_FAILED
    function _validateUserOpSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) private view returns (uint256 validationData) {
        bytes calldata signature = userOp.signature;
        uint256 sigLength = signature.length;
        // Not 0xffffffff. This is packed validationData, not a bytes4, and the EntryPoint reads
        // its low 160 bits as an authorizer. 0xffffffff decodes as an aggregator address that
        // does not exist, so the whole bundle reverts instead of this one operation failing.
        if(sigLength <= SIGNATURE_HEADER_LENGTH + 32) return SIG_VALIDATION_FAILED;

        uint8 version = uint8(signature[0]);
        if(version == 1) {
            uint48 validUntil = uint48(bytes6(signature[1:SIGNATURE_HEADER_LENGTH]));
            bytes calldata webAuthnSignatureBytes = bytes(signature[SIGNATURE_HEADER_LENGTH:]);

            bytes memory precursorBytes = abi.encodePacked(version, validUntil, userOpHash);
            bytes32 challengeDigest = keccak256(
                abi.encodePacked(
                    EIP191_PREFIX,
                    USEROP_PRECURSOR_LENGTH,
                    precursorBytes
                )
            );
            // WebAuthn.sol expects the challenge as bytes
            bytes memory challengeBytes = abi.encodePacked(challengeDigest);

            if(_validateSignature(challengeBytes, webAuthnSignatureBytes)) {
                // TIMESTAMP is a banned opcode here, so validUntil goes back to the EntryPoint to
                // enforce. validAfter is 0, and false means the signature itself checked out.
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
        // Decoded rather than abi.decode'd, because a malformed body has to be rejected here and
        // not reverted on. This runs inside ERC-4337 validation, where a revert fails the whole
        // bundle rather than the one operation, and behind isValidSignature, where it reaches the
        // integrating contract as an error. A failed decode leaves the struct zeroed, which
        // verifySignature returns false for.
        WebAuthnSignature memory sig = WebAuthn.tryDecodeSignature(webAuthnSignatureBytes);

        return verifier.verifySignature({
            message: challenge,
            requireUserVerification: true,
            webAuthnSignature: sig,
            x: uint256(owner[0]),
            y: uint256(owner[1])
        });
    }

    /// @notice Repays the EntryPoint for gas it fronted on this account's behalf
    /// @dev Only ever called from `validateUserOp`, so `msg.sender` is the EntryPoint. The result
    ///      is deliberately ignored: the EntryPoint checks the balance it ended up with, and
    ///      reverting here would fail validation for a shortfall it is about to catch anyway.
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
