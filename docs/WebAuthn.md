# Solidity API

## WebAuthn

A library for verifying WebAuthn Authentication Assertions, built off the work
        of Daimo.

_Attempts to use the RIP-7212 precompile for signature verification.
     If precompile verification fails, it falls back to FreshCryptoLib._

### verifySignature

```solidity
function verifySignature(bytes challenge, bool requireUV, struct WebAuthnSignature webAuthnSignature, uint256 x, uint256 y) internal view returns (bool)
```

Verifies a Webauthn Authentication Assertion as described
in https://www.w3.org/TR/webauthn-2/#sctn-verifying-assertion.

_We do not verify all the steps as described in the specification, only ones relevant to our context.
     Please carefully read through this list before usage.

     Specifically, we do verify the following:
        - Verify that authenticatorData (which comes from the authenticator, such as iCloud Keychain) indicates
          a well-formed assertion with the user present bit set. If `requireUV` is set, checks that the authenticator
          enforced user verification. User verification should be required if, and only if, options.userVerification
          is set to required in the request.
        - Verifies that the client JSON is of type "webauthn.get", i.e. the client was responding to a request to
          assert authentication.
        - Verifies that the client JSON contains the requested challenge.
        - Verifies that (r, s) constitute a valid signature over both the authenicatorData and client JSON, for public
           key (x, y).

     We make some assumptions about the particular use case of this verifier, so we do NOT verify the following:
        - Does NOT verify that the origin in the `clientDataJSON` matches the Relying Party's origin: tt is considered
          the authenticator's responsibility to ensure that the user is interacting with the correct RP. This is
          enforced by most high quality authenticators properly, particularly the iCloud Keychain and Google Password
          Manager were tested.
        - Does NOT verify That `topOrigin` in `clientDataJSON` is well-formed: We assume it would never be present, i.e.
          the credentials are never used in a cross-origin/iframe context. The website/app set up should disallow
          cross-origin usage of the credentials. This is the default behaviour for created credentials in common settings.
        - Does NOT verify that the `rpIdHash` in `authenticatorData` is the SHA-256 hash of the RP ID expected by the Relying
          Party: this means that we rely on the authenticator to properly enforce credentials to be used only by the correct RP.
          This is generally enforced with features like Apple App Site Association and Google Asset Links. To protect from
          edge cases in which a previously-linked RP ID is removed from the authorised RP IDs, we recommend that messages
          signed by the authenticator include some expiry mechanism.
        - Does NOT verify the credential backup state: this assumes the credential backup state is NOT used as part of Relying
          Party business logic or policy.
        - Does NOT verify the values of the client extension outputs: this assumes that the Relying Party does not use client
          extension outputs.
        - Does NOT verify the signature counter: signature counters are intended to enable risk scoring for the Relying Party.
          This assumes risk scoring is not used as part of Relying Party business logic or policy.
        - Does NOT verify the attestation object: this assumes that response.attestationObject is NOT present in the response,
          i.e. the RP does not intend to verify an attestation._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| challenge | bytes | The challenge that was provided by the relying party. |
| requireUV | bool | A boolean indicating whether user verification is required. |
| webAuthnSignature | struct WebAuthnSignature | The `WebAuthnSignature` struct. |
| x | uint256 | The x coordinate of the public key. |
| y | uint256 | The y coordinate of the public key. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | `true` if the authentication assertion passed validation, else `false`. |

