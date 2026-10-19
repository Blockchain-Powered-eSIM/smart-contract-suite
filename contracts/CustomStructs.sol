// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Which contract, if any, saw the money for a data bundle move
/// @dev `DeviceWallet` means the money moved through the purchase path, not that the price matches
///      an order. The other two are the admin's word, bounded only by the price cap.
enum Settlement {
    DeviceWallet,
    ExternalWallet,
    Fiat
}

/// @notice Data Bundle related details stored in the eSIM wallet
/// @dev Two slots. `id` is `bytes32` since provider ids fit and a `string` costs an extra slot per
///      entry. No timestamp: the event log already has one.
struct DataBundleDetails {
    bytes32 id;
    uint64 priceUSDCents;   // 123456 reads as $1234.56
    Settlement settlement;
}

/// @notice Object returned when a new device and eSIM wallet is deployed
struct Wallets {
    address deviceWallet;
    address eSIMWallet;
}

/// @notice One WebAuthn assertion, as the authenticator produced it
/// @dev Decoded from calldata by `WebAuthn.tryDecodeSignature`, which zeroes the whole struct on a
///      malformed body rather than reverting. A zeroed struct fails verification.
struct WebAuthnSignature {
    bytes authenticatorData;    // The WebAuthn authenticator data.
                                // See https://www.w3.org/TR/webauthn-2/#dom-authenticatorassertionresponse-authenticatordata.
    string clientDataJSON;      // The WebAuthn client data JSON.
                                // See https://www.w3.org/TR/webauthn-2/#dom-authenticatorresponse-clientdatajson.
    uint256 challengeIndex;     // The index at which "challenge":"..." occurs in `clientDataJSON`.
    uint256 typeIndex;          // The index at which "type":"..." occurs in `clientDataJSON`.
    uint256 r;                  // The r value of secp256r1 signature
    uint256 s;                  // The s value of secp256r1 signature
}

/// @notice One call an account makes on its owner's behalf
struct Call {
    address dest;
    uint256 value;
    bytes data;
}
