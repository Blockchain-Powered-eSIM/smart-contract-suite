# Solidity API

## Settlement

Which contract, if any, saw the money for a data bundle move

`DeviceWallet` means the money moved through the purchase path, not that the price matches
     an order. The other two are the admin's word, bounded only by the price cap.

```solidity
enum Settlement {
  DeviceWallet,
  ExternalWallet,
  Fiat
}
```

## DataBundleDetails

Data Bundle related details stored in the eSIM wallet

Two slots. `id` is `bytes32` since provider ids fit and a `string` costs an extra slot per
     entry. No timestamp: the event log already has one.

```solidity
struct DataBundleDetails {
  bytes32 id;
  uint64 priceUSDCents;
  enum Settlement settlement;
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

Decoded from calldata by `WebAuthn.tryDecodeSignature`, which zeroes the whole struct on a
     malformed body rather than reverting. A zeroed struct fails verification.

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

