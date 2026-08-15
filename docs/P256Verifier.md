# Solidity API

## P256Verifier

Thin contract wrapper around the WebAuthn verification library

_Adapted from Daimo's DaimoVerifier:
     https://github.com/daimo-eth/daimo/blob/master/packages/contract/src/DaimoVerifier.sol
     It exists as a contract so accounts hold one immutable address to verify through, rather
     than linking the library into every implementation._

### verifySignature

```solidity
function verifySignature(bytes message, bool requireUserVerification, struct WebAuthnSignature webAuthnSignature, uint256 x, uint256 y) public view returns (bool)
```

Verifies a WebAuthn assertion against a P256 public key

#### Parameters

| Name | Type | Description |
| ---- | ---- | ----------- |
| message | bytes | Raw challenge bytes expected inside the assertion's clientDataJSON |
| requireUserVerification | bool | True to demand the authenticator's user verification flag |
| webAuthnSignature | struct WebAuthnSignature | The assertion to check |
| x | uint256 | X co-ordinate of the P256 public key |
| y | uint256 | Y co-ordinate of the P256 public key |

#### Return Values

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | True when the assertion is valid for that key |

