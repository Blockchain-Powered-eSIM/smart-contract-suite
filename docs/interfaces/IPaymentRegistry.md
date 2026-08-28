# Solidity API

## IPaymentRegistry

The two things the payment adapter asks the registry on a settlement

_An interface rather than an import of `Registry`, which already imports the adapter. It
     also keeps the adapter's view of the registry down to what it reads._

### vault

```solidity
function vault() external view returns (address)
```

Address that receives payments for data bundles

### isESIMWalletValid

```solidity
function isESIMWalletValid(address eSIMWallet) external view returns (address)
```

The device wallet an eSIM wallet belongs to, or zero if the registry has no record

