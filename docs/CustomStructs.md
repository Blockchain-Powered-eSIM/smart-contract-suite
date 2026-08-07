# Solidity API

## DataBundleDetails

Data Bundle related details stored in the eSIM wallet

```solidity
struct DataBundleDetails {
  string dataBundleID;
  uint256 dataBundlePrice;
}
```

## Wallets

Object returned when a new device and eSIM wallet is deployed

```solidity
struct Wallets {
  address deviceWallet;
  address eSIMWallet;
}
```

## WebAuthnSignature

One WebAuthn assertion, as the authenticator produced it

_Decoded from calldata by `WebAuthn.tryDecodeSignature`, which zeroes the whole struct on a
     malformed body rather than reverting. A zeroed struct fails verification._

```solidity
struct WebAuthnSignature {
  bytes authenticatorData;
  string clientDataJSON;
  uint256 challengeIndex;
  uint256 typeIndex;
  uint256 r;
  uint256 s;
}
```

## Call

One call an account makes on its owner's behalf

```solidity
struct Call {
  address dest;
  uint256 value;
  bytes data;
}
```

