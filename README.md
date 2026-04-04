# Fiatsend Smart Contracts

> Payment infrastructure for businesses paying into Africa.

## What is Fiatsend

Fiatsend enables companies (like Deel, Payoneer, or any payroll API) to pay employees and contractors in Ghana using stablecoins. The recipient experience starts with an SMS: *"You received a payment via Fiatsend — claim it here."* Recipients can then hold, earn yield, transfer P2P, or cash out to MTN/Telecel/AirtelTigo mobile money instantly.

## User Journey

```
Business API (Deel, Payoneer, etc.)
    │
    │ sends USDC/USDT/GHSFIAT
    ▼
PayoutEscrow  ← funds held here until claimed
    │
    │ recipient gets SMS link
    ▼
Recipient claims (MobileNumberNFT identity check)
    │
    ├─── Hold stablecoins in wallet
    ├─── Earn yield in VaultController
    ├─── Send P2P via PaymentRouter
    ├─── Trade via P2PExchange (Binance P2P, etc.)
    └─── Cash out to MoMo via FiatsendGateway
```

## Architecture

```
MobileNumberNFT       — Soulbound identity NFT tied to encrypted phone number
GHSFIAT               — ERC-20 stablecoin pegged to Ghana Cedi (GHS)
FiatsendGateway       — Core gateway: onramp/offramp, KYC, fees (UUPS upgradeable)
                         includes offrampFor() for one-tx claim+cashout via PayoutEscrow
PayoutEscrow          — Holds inbound B2B payouts until recipient claims
PaymentRouter         — P2P transfers and payment requests; references PayoutEscrow
P2PExchange           — P2P orders with exact exchange references (Binance P2P, Paxful)
Withdrawals           — Withdrawal lifecycle: pending → processing → completed / failed
LiquidityPool         — LP deposits earn fee rewards from conversions
VaultController       — Passive yield vault for stablecoin deposits
```

### Upgrade Strategy

| Contract | Pattern |
|---|---|
| FiatsendGateway | UUPS upgradeable proxy |
| All others | Standalone (non-upgradeable) |

### Contract Wiring

```
Withdrawals  ←──────── setGateway ───────────── FiatsendGateway
FiatsendGateway ←───── setWithdrawalsContract ── Withdrawals
FiatsendGateway ←───── setAuthorizedContract ─── PayoutEscrow  (for offrampFor)
PaymentRouter ←──────── setPayoutEscrow ─────── PayoutEscrow
PayoutEscrow ──────────► mobileNumberNFT         (resolves phone hash on claim)
PayoutEscrow ──────────► gateway                 (routes claimToMoMo)
```

## Setup

### Prerequisites
- [Foundry](https://getfoundry.sh/) installed
- Git

### Install

```bash
git clone https://github.com/fiatsend/contracts
cd contracts
forge install
```

### Dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.2
forge install foundry-rs/forge-std
```

## Build

```bash
forge build
```

## Test

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test files
forge test --match-path test/PayoutEscrow.t.sol -vvv
forge test --match-path test/P2PExchange.t.sol -vvv
forge test --match-path test/FiatsendGateway.t.sol -vvv

# Generate coverage report
forge coverage
```

## Format

```bash
forge fmt
```

## Deploy

### Testnet (Sepolia / BSC Testnet)

```bash
cp .env.example .env
# Fill in PRIVATE_KEY, RPC URLs, and API keys

source .env
forge script script/DeployTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

### Production (All Contracts)

```bash
# Required env vars: PRIVATE_KEY, TREASURY_ADDRESS, DISPUTE_RESOLVER_ADDRESS
forge script script/DeployAll.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify
```

## Contract Addresses

| Contract | BSC | Polygon | Sepolia |
|---|---|---|---|
| MobileNumberNFT | — | — | — |
| GHSFIAT | — | — | — |
| FiatsendGateway (proxy) | — | — | — |
| PayoutEscrow | — | — | — |
| P2PExchange | — | — | — |
| PaymentRouter | — | — | — |
| Withdrawals | — | — | — |
| LiquidityPool | — | — | — |
| VaultController | — | — | — |

## Environment Variables

```bash
# RPC endpoints
BSC_RPC_URL=
BSC_TESTNET_RPC_URL=
POLYGON_RPC_URL=
SEPOLIA_RPC_URL=

# Etherscan API keys
BSCSCAN_API_KEY=
POLYGONSCAN_API_KEY=
ETHERSCAN_API_KEY=

# Deployment
PRIVATE_KEY=
TREASURY_ADDRESS=
DISPUTE_RESOLVER_ADDRESS=
```

## Key Design Decisions

### Why PayoutEscrow instead of direct transfer?
Businesses pay before the recipient has a wallet. Funds sit in escrow until the recipient registers (mints a MobileNumberNFT) and claims. This is the same model as a payroll check — issued by the employer, cashed by the employee.

### Why bytes32 phoneHash for identity?
The MobileNumberNFT stores encrypted phone bytes. Payouts reference `keccak256(encryptedPhone)`. When a recipient claims, the escrow resolves their NFT's phone hash on-chain — no off-chain oracle needed.

### Why P2PExchange alongside PaymentRouter?
PaymentRouter is for direct wallet-to-wallet transfers within the Fiatsend ecosystem. P2PExchange is for traders who want to sell stablecoins on external exchange platforms (Binance P2P, Paxful, Noones) using an exact payment reference for auto-completion.

### claimToMoMo — one transaction
Recipients can claim and immediately offramp to mobile money in a single transaction. PayoutEscrow calls `gateway.offrampFor()` which is an authorized-contract-only function added for this flow. Tokens never touch the user's wallet — escrow → gateway → withdrawal queue.

## Security

- `ReentrancyGuard` on all fund-moving functions
- `SafeERC20` for all token transfers
- UUPS proxy pattern with owner-controlled upgrades on Gateway
- Pausable for emergency stops on all contracts
- KYC gating on Gateway for large offramps
- Soulbound MobileNumberNFT (non-transferable identity)
- `offrampFor` is restricted to authorized contracts only (`setAuthorizedContract`)
- Payout expiry + refund mechanism prevents funds being locked forever
- Dispute resolution on P2PExchange via dedicated resolver address

## License

MIT
