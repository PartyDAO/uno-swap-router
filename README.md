# UNO Swap Router

## Overview

UnoRouterV2 is an upgradeable swap router for the UNO wallet that enables atomic token swaps with optional deposit and send operations. The contract extends the original UnoRouter with new atomic swap functions while maintaining full backward compatibility with existing functionality and events.

**Key Features**:

- Atomic token-to-token swaps via approved aggregators (0x, 1inch)
- Atomic swap and send to any recipient address
- Atomic swap and deposit into ERC4626 vaults (e.g., Morpho)
- Permit2 signature-based approvals for gasless transactions
- Upgradeable via UUPS proxy pattern
- Full backward compatibility with UnoRouter v1 events and functionality

## Architecture

### Core Components

- **UnoRouterV2**: Main upgradeable router contract with atomic swap functions
- **BaseAggregator**: Core swap logic with Permit2 integration (inherited)
- **Permit2Helper**: Helper contract for Permit2 signature transfers
- **SwapParams**: Struct containing swap parameters (sell/buy tokens, target, calldata, amounts, fee)

### Key Functions

- `fillQuoteTokenToToken`: Legacy swap function (unchanged from UnoRouter v1)
- `fillQuoteEthToToken`: ETH-to-token swaps (unchanged)
- `fillQuoteTokenToEth`: Token-to-ETH swaps (unchanged)
- `fillQuoteTokenToTokenAndSend`: NEW - Atomic swap and send to recipient
- `fillQuoteTokenToTokenAndDeposit`: NEW - Atomic swap and deposit to vault
- `updateSwapTargets`: Admin function to manage approved aggregators
- `withdrawToken` / `withdrawEth`: Admin functions for emergency withdrawals

### Events

The contract maintains all legacy events for analytics compatibility:

- `FillQuoteTokenToToken`: Emitted for all token-to-token swaps
- `FillQuoteEthToToken`: Emitted for ETH-to-token swaps
- `FillQuoteTokenToEth`: Emitted for token-to-ETH swaps

New events for atomic operations:

- `FillQuoteAndSend`: Emitted when tokens are sent to recipient after swap
- `FillQuoteAndDeposit`: Emitted when tokens are deposited to vault after swap

## Prerequisites

- [Foundry](https://github.com/foundry-rs/foundry#installation)

## Setup

```bash
# Install dependencies
bun install

# Build contracts
forge build

# Run tests
forge test
```

## Installing Dependencies

Foundry typically uses git submodules to manage dependencies, but this project uses Node.js packages because [submodules don't scale](https://twitter.com/PaulRBerg/status/1736695487057531328).

To add a new dependency:

1. Install the dependency using your preferred package manager, e.g. `bun install dependency-name`
   - Use this syntax to install from GitHub: `bun install github:username/repo-name`
2. Add a remapping for the dependency in [remappings.txt](./remappings.txt), e.g.
   `dependency-name=node_modules/dependency-name`

Note that OpenZeppelin Contracts is pre-installed, so you can follow that as an example.

## Testing

```bash
# Run all tests
forge test

# Run tests with gas report
forge test --gas-report

# Run specific test file
forge test --match-path test/UnoRouterV2.t.sol

# Run tests with verbose output
forge test -vvv
```

## Deployment

### Environment Variables

For production deployment (`DeployUnoRouterV2.s.sol`):

- `PRIVATE_KEY`: Deployer private key (must match `EXPECTED_DEPLOYER`)
- `OWNER`: Address that will own the contract (typically multisig)
- `PERMIT2`: Permit2 contract address on target chain
- `SWAP_TARGETS`: Comma-separated list of approved aggregator addresses (optional, defaults to empty)

### Deployment Commands

```bash
# Deploy to local Anvil
forge script script/DeployUnoRouterV2.s.sol --broadcast --fork-url http://localhost:8545

# Deploy to testnet
forge script script/DeployUnoRouterV2.s.sol --broadcast --rpc-url $WORLDCHAIN_RPC_URL --private-key $PRIVATE_KEY

# Deploy to mainnet
forge script script/DeployUnoRouterV2.s.sol --broadcast --rpc-url $WORLDCHAIN_RPC_URL --private-key $PRIVATE_KEY --verify

# Upgrade contract
forge script script/Upgrade.s.sol:Upgrade --broadcast --rpc-url $WORLDCHAIN_RPC_URL --private-key $PRIVATE_KEY <PROXY_ADDRESS>
```

## Contract Interface

### Core Swap Functions

```solidity
// Legacy token-to-token swap (unchanged from UnoRouter v1)
function fillQuoteTokenToToken(
    address sellTokenAddress,
    address buyTokenAddress,
    address payable target,
    bytes calldata swapCallData,
    uint256 sellAmount,
    FeeToken feeToken,
    uint256 feeAmount,
    Permit2 calldata permit
) external payable;

// Atomic swap and send to recipient
function fillQuoteTokenToTokenAndSend(
    SwapParams calldata params,
    address recipient,
    Permit2 calldata permit
) external payable;

// Atomic swap and deposit to vault
function fillQuoteTokenToTokenAndDeposit(
    SwapParams calldata params,
    address vault,
    address receiver,
    Permit2 calldata permit
) external payable returns (uint256 shares);
```

### Admin Functions

```solidity
// Update swap target approval
function updateSwapTargets(address target, bool add) external onlyOwner;

// Withdraw ERC20 tokens
function withdrawToken(address token, address to, uint256 amount) external onlyOwner;

// Withdraw ETH
function withdrawEth(address to, uint256 amount) external onlyOwner;
```

### Events

```solidity
event FillQuoteTokenToToken(
    address indexed sellToken,
    address indexed buyToken,
    address indexed user,
    address target,
    uint256 amountSold,
    uint256 amountBought,
    FeeToken feeToken,
    uint256 feeAmount
);

event FillQuoteAndSend(
    address indexed buyToken,
    uint256 buyTokenAmount,
    address sendTo
);

event FillQuoteAndDeposit(
    address indexed buyToken,
    uint256 buyTokenAmount,
    address depositTo,
    address vault
);
```

## Security Considerations

### Permit2 Integration

- **Signature Verification**: All token transfers use Permit2 signature-based approvals
- **Nonce Management**: Permit2 handles nonce tracking to prevent replay attacks
- **Deadline Validation**: Permits must have valid expiration and signature deadlines

### Swap Security

- **Target Authorization**: Only approved swap targets can be called
- **Allowance Validation**: All allowances are cleared after swaps to prevent residual approvals
- **Reentrancy Protection**: All external functions are protected with ReentrancyGuard
- **Input Validation**: Zero address checks and amount validations throughout

### Contract Security

- **Upgrade Authorization**: Only owner can upgrade implementation via UUPS pattern
- **Token Rescue**: Owner can rescue tokens in emergency situations
- **Fee Validation**: Fees cannot exceed output amounts
- **Atomic Operations**: All swap+send and swap+deposit operations are atomic

### Known Limitations

- **Fee-on-Transfer Tokens**: Not supported (excluded for safety)
- **Rebasing Tokens**: Not supported (excluded for safety)
- **Vault Pre-checks**: No pre-checks for vault paused/capacity states - vault's own validation handles this

## License

This project is licensed under GPL-3.0.
