// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.12;

import "./CustomStructs.sol";
import "./WebAuthn.sol";

// Source: https://github.com/daimo-eth/daimo/blob/master/packages/contract/src/DaimoVerifier.sol
// Proxies a webAuthnSignature verification call to the Webauthn library.
contract P256Verifier {

    /// @dev Signature should expire after 3 minutes.
    function verifySignature(
        bytes memory message,
        bool requireUserVerification,
        WebAuthnSignature memory webAuthnSignature,
        uint256 x,
        uint256 y,
        uint256 deadline
    ) public view returns (bool) {
        require(block.timestamp <= deadline, "Signature expired");

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