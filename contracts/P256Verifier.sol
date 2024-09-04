// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.12;

import "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "./CustomStructs.sol";
import "./WebAuthn.sol";

// import "p256-verifier/WebAuthn.sol";

/// Proxy using the UUPSUpgradeable pattern. Named for Etherscan verification.
contract P256VerifierProxy is ERC1967Proxy {
    constructor(
        address _logic,
        bytes memory _data
    ) ERC1967Proxy(_logic, _data) {}
}

// Source: https://github.com/daimo-eth/daimo/blob/master/packages/contract/src/DaimoVerifier.sol
// Proxies a webAuthnSignature verification call to the Webauthn library.
contract P256Verifier is OwnableUpgradeable, UUPSUpgradeable {
    constructor() {
        _disableInitializers();
    }

    /// We specify the initial owner (rather than using msg.sender) so that we
    /// can deploy the proxy at a deterministic CREATE2 address.
    function init(address initialOwner) public initializer {
        _transferOwnership(initialOwner);
    }

    /// UUPSUpsgradeable: only allow owner to upgrade
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyOwner {
        (newImplementation); // No-op; silence unused parameter warning
    }

    /// UUPSUpgradeable: expose implementation
    function implementation() public view returns (address) {
        return _getImplementation();
    }

    function verifySignature(
        bytes memory message,
        bool requireUV,
        WebAuthnSignature memory webAuthnSignature,
        uint256 x,
        uint256 y
    ) public view returns (bool) {

        return
            WebAuthn.verifySignature({
                challenge: message,
                authenticatorData: webAuthnSignature.authenticatorData,
                requireUserVerification: false,
                clientDataJSON: webAuthnSignature.clientDataJSON,
                challengeLocation: webAuthnSignature.challengeLocation,
                responseTypeLocation: webAuthnSignature.responseTypeLocation,
                r: webAuthnSignature.r,
                s: webAuthnSignature.s,
                x: x,
                y: y
            });
    }
}