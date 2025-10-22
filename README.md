# UNO Router

Swap router for UNO wallet with Permit2 integration for gasless transactions.

## Overview

UnoRouter enables token swaps through multiple DEX aggregators with support for:

- Token-to-token swaps
- ETH-to-token swaps
- Token-to-ETH swaps
- Permit2 signature-based transfers for gasless transactions
- Configurable swap targets and fee collection

## Contracts

- `UnoRouter`: Main router contract with owner controls
- `BaseAggregator`: Core swap logic with Permit2 integration

## Development

```sh
# Install dependencies
bun install

# Build contracts
forge build

# Run tests
forge test

# Deploy
forge script script/Deploy.s.sol --broadcast
```
