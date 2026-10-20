# Solidity API

## WebAuthn

A library for verifying WebAuthn Authentication Assertions, built off the work
        of Daimo.

_Attempts to use the RIP-7212 precompile for signature verification.
     If precompile verification fails, it falls back to FreshCryptoLib._

### tryDecodeSignature

```solidity
function tryDecodeSignature(bytes encodedSignature) internal pure returns (struct WebAuthnSignature decoded)
```

Decodes an encoded `WebAuthnSignature` without reverting on a malformed encoding.

_`abi.decode` reverts on bad input. Inside ERC-4337 validation that fails the whole
     bundle, and behind `isValidSignature` it reaches the caller as an error, not a rejection.

     On a failed bound `decoded` stays as solc allocated it, both dynamic members empty, and
     `verifySignature` returns false since an empty `clientDataJSON` holds no valid index.

     Inherited from solady: the length checks wrap, so a crafted length can run out of gas.
     That reverts, it never accepts a signature.

     Copied from solady's `WebAuthn.tryDecodeAuth` (identical struct layout) rather than
     rewriting an ABI bounds check by hand. Memory-safe: every read is inside
     `encodedSignature`, and the only writes are to the six words solc reserved for `decoded`._

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| encodedSignature | bytes | `abi.encode` of a `WebAuthnSignature`, as supplied by the caller. |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| decoded | struct WebAuthnSignature | The signature, or a zeroed struct when the encoding is malformed. |

### verifySignature

```solidity
function verifySignature(bytes challenge, bool requireUV, struct WebAuthnSignature webAuthnSignature, uint256 x, uint256 y) internal view returns (bool)
```

Verifies a Webauthn Authentication Assertion as described
in https://www.w3.org/TR/webauthn-2/#sctn-verifying-assertion.

_Only the spec steps relevant here are checked. Read this list before using it.

     Verified:
        - authenticatorData has the user present bit set, and the user verified bit too when
          `requireUV` is set (require it only if options.userVerification was "required").
        - The client JSON has type "webauthn.get".
        - The client JSON carries the requested challenge.
        - (r, s) is a valid signature by (x, y) over authenticatorData and the client JSON.

     NOT verified:
        - `clientDataJSON.origin`: trusted to the authenticator's own cross-origin policy.
        - `clientDataJSON.topOrigin`: assumed absent, i.e. no cross-origin/iframe usage.
        - `authenticatorData.rpIdHash`: trusted to the authenticator. Sign messages with an
          expiry to limit exposure if a linked RP ID is later removed.
        - Credential backup state: assumed unused in Relying Party policy.
        - Client extension outputs: assumed unused.
        - The signature counter: assumed unused for risk scoring.
        - The attestation object: assumed absent from the response._

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

