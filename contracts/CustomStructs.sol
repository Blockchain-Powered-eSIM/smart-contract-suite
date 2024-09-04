pragma solidity ^0.8.18;

// SPDX-License-Identifier: MIT

/// @notice Data Bundle related details stored in the eSIM wallet
struct DataBundleDetails {
    string dataBundleID;
    uint256 dataBundlePrice;
}

/// @notice Details related to eSIM purchased by the fiat user
struct ESIMDetails {
    string eSIMUniqueIdentifier;
    DataBundleDetails[] history;
}

/// @notice Struct to store list of all eSIMs associated with a device
struct AssociatedESIMIdentifiers {
    string deviceUniqueIdentifier;
    string[] eSIMIdentifiers;
}

struct WebAuthnSignature {
    /// @dev The WebAuthn authenticator data.
    ///      See https://www.w3.org/TR/webauthn-2/#dom-authenticatorassertionresponse-authenticatordata.
    bytes authenticatorData;
    /// @dev The WebAuthn client data JSON.
    ///      See https://www.w3.org/TR/webauthn-2/#dom-authenticatorresponse-clientdatajson.
    string clientDataJSON;
    /// @dev The index at which "challenge":"..." occurs in `clientDataJSON`.
    uint256 challengeIndex;
    /// @dev The index at which "type":"..." occurs in `clientDataJSON`.
    uint256 typeIndex;
    /// @dev The r value of secp256r1 signature
    uint256 r;
    /// @dev The s value of secp256r1 signature
    uint256 s;
}
