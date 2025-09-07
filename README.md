# Death of Pengu Marketplace (Full Implementation)

Hardhat project implementing the complete Death of Pengu marketplace as specified in the white paper:

## Core Features

- **User Profiles & Portfolios**: Rich profiles with bio, skills, portfolio URIs, and user types (Artist, Developer, KOL, Project Owner)
- **Two-Sided Listings**: Briefs (projects) & Gigs (services) with category filtering
- **Dual-Validation Escrow**: Secure payments requiring both party validation
- **Enhanced Fee Structure**: 20% USDC/ETH fees (with buyback & burn), 10% DOP fees (direct burn)
- **Boost System**: Pay in $DOP to appear at top of category listings
- **Mission History**: Complete on-chain record of all completed work
- **Badge System**: Automatic badges for milestones (Rookie, Expert, Master, Reliable)
- **Dispute Resolution**: Manual arbitration with 3 outcomes (Refund, Split, Pay Provider)
- **Deflationary Tokenomics**: Every transaction burns $DOP tokens

## Environment Variables

```
DOP_ADDRESS=0xExistingDopToken
USDC_ADDRESS=0xOptionalStable
TREASURY_ADDRESS=0xTreasury
DEX_ROUTER_ADDRESS=0xUniswapV2Router  # For buyback functionality
WETH_ADDRESS=0xWETHAddress
PRIVATE_KEY=0xyourkey
ALCHEMY_RPC=https://...
```

## Commands

```
npm install
npx hardhat compile
npx hardhat test
npx hardhat run scripts/deploy.js --network sepolia
```

## Upgradeable Version

Proxy deployment (UUPS):

```
export DOP_ADDRESS=0xExisting
export TREASURY_ADDRESS=0xTreasury
npx hardhat run scripts/deployProxy.js --network sepolia
```

Upgrade after modifying `MarketplaceUpgradeable`:

```
export MARKETPLACE_PROXY=0xProxy
npx hardhat run scripts/upgrade.js --network sepolia
```

## Notes

- **Buyback & Burn**: USD fees trigger automatic DOP buyback & burn via DEX router (Uniswap V2/V3)
- **User Profiles**: Rich profiles with portfolios, skills, and automatic verification system
- **Badge System**: Automatic milestone badges (Rookie: 1+, Experienced: 6+, Expert: 21+, Master: 51+, Reliable: 95%+ success)
- **Mission History**: Complete on-chain record of all work with dispute flags
- **Category System**: Filter by user types (Artist, Developer, KOL, Project Owner)
- **Metadata Storage**: Profile data and portfolios stored off-chain (IPFS) with URI references on-chain
- **Deflationary Model**: Every transaction reduces $DOP supply through burns and buybacks
