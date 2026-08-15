// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {SIG_VALIDATION_FAILED} from "@account-abstraction/contracts/core/Helpers.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";

import "contracts/CustomStructs.sol";
import {DeviceWallet} from "contracts/device-wallet/DeviceWallet.sol";

import {DeviceWalletFixture} from "test/foundry/unit-testing/device-wallet/base/DeviceWalletFixture.sol";
import {WebAuthnSigner} from "test/utils/WebAuthnSigner.sol";

/// @notice What a device wallet accepts as proof its owner authorised something.
/// @dev Everything here that signs goes through WebAuthnSigner, which shells out to a node script
///      over vm.ffi. A captured assertion is pinned to the challenge inside its own clientDataJSON,
///      so a test cannot reuse one across a different message, wallet or expiry.
contract DeviceWalletSignaturesTest is DeviceWalletFixture {

    /// @notice A real assertion captured from a device, checked against the verifier directly.
    /// It is the only evidence the client data checks agree with what authenticators actually
    /// emit: challengeIndex 23 lands on the real `"challenge":"` key, the type field sits where
    /// the library expects it, and the flags byte carries user verification. It cannot go through
    /// isValidSignature, whose challenge is derived from the message rather than being it, because
    /// the key that signed this is not in the repo and the assertion cannot be remade.
    function test_verifySignature_acceptsACapturedDeviceAssertion() public view {
        WebAuthnSignature memory assertion = abi.decode(
            hex"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000001700000000000000000000000000000000000000000000000000000000000000016e45bdb082f70af9ae84d4fe8a7d1bf69e59389ca10b52504d6abb7fa664ba137051a8ff68e294989e5287df16f036f581d838468abf2680611ea9bc18386943000000000000000000000000000000000000000000000000000000000000002593613e408a25dbfc09d33b17fdc30d43e4b61f59a2ff388f28dd4e073ba058fb1d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000be7b2274797065223a22776562617574686e2e676574222c226368616c6c656e6765223a224b364e437358484c632d5a4b69455a37733561526b524955655f384139687646374451486f642d686b7177222c226f726967696e223a22616e64726f69643a61706b2d6b65792d686173683a53447852554851355957742d6475656744537a4766515f4757455f4146314556796e6d2d6b73544e474755222c22616e64726f69645061636b6167654e616d65223a226170702e6b6f6b696f227d0000",
            (WebAuthnSignature)
        );

        bool valid = p256Verifier.verifySignature({
            message: hex"2ba342b171cb73e64a88467bb396919112147bff00f61bc5ec3407a1dfa192ac",
            requireUserVerification: true,
            webAuthnSignature: assertion,
            x: uint256(bytes32(hex"827b60c4e33f9796284180b39a6e02d7442b2d5189eb3c7d21f384e787104655")),
            y: uint256(bytes32(hex"0dbb6683c742e4d0a03c004e55a0c7c1c241ac30bf59711f7c8d2d51cf41f4df"))
        });

        assertTrue(valid, "A real device assertion must verify");
    }

    /// @notice The challenge the wallet expects for a given message, chain and expiry. A test that
    /// signs has to derive this the same way the wallet does, which is the point: the two
    /// derivations agreeing is what the format guarantees.
    function _erc1271Challenge(
        address _wallet,
        uint48 _validUntil,
        bytes32 _messageHash
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n91",
                    uint8(1),
                    _validUntil,
                    block.chainid,
                    _wallet,
                    _messageHash
                )
            )
        );
    }

    /// @notice An assertion made for this exact message, wallet and expiry is accepted
    function test_isValidSignature_acceptsAnAssertionSignedForThisMessage() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(_erc1271Challenge(address(userDeviceWallet), validUntil, messageHash))
        );

        bytes4 returnValue = userDeviceWallet.isValidSignature(messageHash, signature);
        assertEq(hex"1626ba7e", returnValue, "An assertion signed for this message hash must be accepted");
    }

    /// @notice Holding the owner key is not enough. An assertion made for a different message
    /// carries a different challenge in its clientDataJSON, and the comparison has to catch that.
    function test_isValidSignature_rejectsAnAssertionSignedForAnotherMessage() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(
                _erc1271Challenge(
                    address(userDeviceWallet),
                    validUntil,
                    keccak256("a message the wallet was never asked about")
                )
            )
        );

        bytes4 returnValue = userDeviceWallet.isValidSignature(
            keccak256("a message the wallet was asked to sign"),
            signature
        );
        assertEq(hex"ffffffff", returnValue, "An assertion made for another message must be rejected");
    }

    /// @notice validUntil is checked against the clock but was not part of what the authenticator
    /// signed, so rewriting those six bytes used to extend any expired signature indefinitely.
    function test_isValidSignature_rejectsATamperedValidUntil() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory assertion = WebAuthnSigner.sign(
            _erc1271Challenge(address(userDeviceWallet), validUntil, messageHash)
        );

        assertEq(
            hex"1626ba7e",
            userDeviceWallet.isValidSignature(messageHash, abi.encodePacked(uint8(1), validUntil, assertion)),
            "The expiry it was made under must be accepted"
        );
        assertEq(
            hex"ffffffff",
            // The same assertion, presented with a later expiry than the one it was made under
            userDeviceWallet.isValidSignature(messageHash, abi.encodePacked(uint8(1), validUntil + 1 days, assertion)),
            "A rewritten expiry must invalidate the signature"
        );
    }

    /// @notice A genuine assertion stops being accepted once its own expiry has passed
    /// @dev The pair with the test above. That one holds the clock still and rewrites the expiry;
    /// this one leaves the signature untouched and moves the clock, which is the case the field
    /// exists for. Both have to hold, because the check and the binding are separate mechanisms:
    /// the binding alone would accept a signature forever, and the check alone could be edited away.
    function test_isValidSignature_rejectsAnAssertionPastItsExpiry() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(_erc1271Challenge(address(userDeviceWallet), validUntil, messageHash))
        );

        assertEq(
            hex"1626ba7e",
            userDeviceWallet.isValidSignature(messageHash, signature),
            "The signature must be accepted while it is still current"
        );

        // One second past the expiry, which is the first moment the check refuses
        vm.warp(uint256(validUntil) + 1);

        assertEq(
            hex"ffffffff",
            userDeviceWallet.isValidSignature(messageHash, signature),
            "The same signature must be refused once its expiry has passed"
        );
    }

    /// @notice createAccount is public and does not touch the registry, so a second wallet can be
    /// deployed at another salt holding the same owner key. Its address has to be part of what was
    /// signed, otherwise one wallet's signatures are accepted by the other.
    function test_isValidSignature_rejectsASignatureMadeForAnotherWallet() public {
        bytes32[2] memory ownerKey = WebAuthnSigner.publicKey();
        deployCustomWallet("Device_Harness", ownerKey[0], ownerKey[1], 25042025);

        DeviceWallet siblingWallet = deviceWalletFactory.createAccount("Device_Sibling", ownerKey, 25042026);
        assertTrue(address(siblingWallet) != address(userDeviceWallet), "The two wallets must be distinct");

        bytes32 messageHash = keccak256("a message the wallet was asked to sign");
        uint48 validUntil = uint48(block.timestamp + 1 days);
        bytes memory signature = abi.encodePacked(
            uint8(1),
            validUntil,
            WebAuthnSigner.sign(_erc1271Challenge(address(userDeviceWallet), validUntil, messageHash))
        );

        assertEq(
            hex"1626ba7e",
            userDeviceWallet.isValidSignature(messageHash, signature),
            "The wallet it was signed for must accept it"
        );
        assertEq(
            hex"ffffffff",
            siblingWallet.isValidSignature(messageHash, signature),
            "A sibling holding the same owner key must reject it"
        );
    }

    /// @notice A signature too short to carry a header and a challenge must fail the operation,
    /// not the bundle. validateUserOp returns packed validationData whose low 160 bits the
    /// EntryPoint reads as an authorizer, so anything other than 0 or SIG_VALIDATION_FAILED names
    /// an aggregator. 0xffffffff named one that does not exist.
    function test_validateUserOp_shortSignatureFailsGracefully() public {
        deployWallets();

        PackedUserOperation memory userOp;
        userOp.sender = address(deviceWallet);
        // Exactly a version byte, six validUntil bytes and a 32 byte challenge, which the guard
        // rejects because it leaves no room for the WebAuthn assertion itself
        userOp.signature = new bytes(39);

        vm.prank(address(deviceWallet.entryPoint()));
        uint256 validationData = deviceWallet.validateUserOp(userOp, bytes32(0), 0);

        assertEq(validationData, SIG_VALIDATION_FAILED, "A short signature must fail the operation");
        assertEq(
            validationData >> 160,
            0,
            "Failure must carry no validity window, otherwise the EntryPoint reads a time range"
        );
    }
}
