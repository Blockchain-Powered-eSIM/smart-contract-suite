# Solidity API

## Settlement

Which contract, if any, saw the money for a data bundle move

_Only `DeviceWallet` can be proven onchain. The other two are the admin's word, so the
     price cap is the only check on them._

```solidity
enum Settlement {
  DeviceWallet,
  ExternalWallet,
  Fiat
}
```

## DataBundleDetails

Data Bundle related details stored in the eSIM wallet

_Two slots: `id`, then `priceUSDCents` and `settlement` packed together. `id` is
     `bytes32` because the provider's ids fit in 32 bytes and a `string` would cost an extra
     slot on every entry. No timestamp field: the event log already has one._

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

