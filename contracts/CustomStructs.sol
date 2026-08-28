// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Which contract, if any, saw the money for a data bundle move
/// @dev Only `DeviceWallet` can be proven onchain. The other two are the admin's word, so the
///      price cap is the only check on them.
enum Settlement {
    DeviceWallet,
    ExternalWallet,
    Fiat
}

/// @notice Data Bundle related details stored in the eSIM wallet
/// @dev Two slots: `id`, then `priceUSDCents` and `settlement` packed together. `id` is
///      `bytes32` because the provider's ids fit in 32 bytes and a `string` would cost an extra
///      slot on every entry. No timestamp field: the event log already has one.
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
