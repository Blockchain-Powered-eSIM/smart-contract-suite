// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

// Libraries
import {WebAuthn} from "./WebAuthn.sol";

// Types
import {WebAuthnSignature} from "./CustomStructs.sol";

/// @notice Thin contract wrapper around the WebAuthn verification library
/// @dev Adapted from Daimo's DaimoVerifier:
///      https://github.com/daimo-eth/daimo/blob/master/packages/contract/src/DaimoVerifier.sol
///      It exists as a contract so accounts hold one immutable address to verify through, rather
///      than linking the library into every implementation.
contract P256Verifier {

    /// @notice Verifies a WebAuthn assertion against a P256 public key
    /// @param message Raw challenge bytes expected inside the assertion's clientDataJSON
    /// @param requireUserVerification True to demand the authenticator's user verification flag
    /// @param webAuthnSignature The assertion to check
    /// @param x X co-ordinate of the P256 public key
    /// @param y Y co-ordinate of the P256 public key
    /// @return True when the assertion is valid for that key
    function verifySignature(
        bytes memory message,
        bool requireUserVerification,
        WebAuthnSignature memory webAuthnSignature,
        uint256 x,
        uint256 y
    ) public view returns (bool) {
        return
            WebAuthn.verifySignature({
                challenge: message,
                requireUV: requireUserVerification,
                webAuthnSignature: webAuthnSignature,
                x: x,
                y: y
            });
    }
}