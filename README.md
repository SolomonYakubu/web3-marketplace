# Decentralized Web3 Marketplace

A complete decentralized marketplace as specified in the white paper. This marketplace facilitates interactions between clients and service providers through listings, escrow services, and a dispute resolution mechanism.

## Core Features

- **User Profiles & Portfolios**: Rich profiles with bio, skills, portfolio URIs, and user types (Service Provider, Client, etc.).
- **Two-Sided Listings**: Projects (briefs) & Services (gigs) with category filtering.
- **Dual-Validation Escrow**: Secure payments requiring validation from both parties involved.
- **Fee Structure**: Flexible fee structure supporting different token types and actions (buyback & burn, direct burn).
- **Boost System**: Option to pay in a specific token to increase listing visibility.
- **Mission History**: Complete on-chain record of all completed work.
- **Badge System**: Automatic badges for milestones (e.g., Rookie, Expert, Master, Reliable).
- **Dispute Resolution**: Manual arbitration with defined outcomes (Refund, Split, Pay Provider).
- **Tokenomics**: Supports various tokenomic models, including deflationary mechanisms.
- **Reviews**: Users can leave reviews and ratings for service providers upon completion of a project.

## Contract Overview

The marketplace operates through a series of interconnected smart contracts to facilitate seamless interactions between users:

- **Profile Management**: Users can create and manage their profiles, showcasing their skills, experience, and portfolio. Profiles are categorized by user type, enabling efficient filtering and matching. The `createProfile` and `updateProfile` functions allow users to manage their profiles, while the `verifyProfile` function is used by the owner to verify profiles. The `getProfile` function allows retrieval of profile information.
- **Listing Management**: The platform supports two types of listings: Projects (briefs) and Services (gigs). These listings can be filtered by category, making it easy for users to find relevant opportunities or providers. The `createListing` function allows users to create new listings, and the `setListingActive` function allows users to activate or deactivate their listings.
- **Offer Management**: Clients can make offers on listings, and service providers can accept these offers. The `makeOffer` function allows users to make offers on listings, and the `acceptOffer` function allows the listing creator to accept an offer. Offers can be cancelled using the `cancelOffer` function before they are accepted.
- **Escrow Service**: Secure payments are facilitated through a dual-validation escrow system. Funds are held in escrow until both parties (the client and the service provider) validate the completion of the work. The `validateWork` function allows users to validate the completion of work, and the `_completeEscrow` function is called when both parties have validated the work. The `getEscrow` function allows retrieval of escrow information.
- **Fee Handling**: The contract supports a flexible fee structure, allowing for fees to be paid in various tokens. These fees can be used for different purposes, such as buyback and burn mechanisms or direct token burns. The `_processUsdFee` and `_processDopFee` functions handle the processing of fees.
- **Reputation System**: A badge system automatically awards badges to users based on their completed milestones and success rates. This system helps to build trust and credibility within the marketplace. The `_updateBadges` function updates the badges for a user based on their mission history. The `getUserBadges` function allows retrieval of a user's badges.
- **Dispute Resolution**: In the event of a disagreement, a manual arbitration process is available. Arbitrators can choose from three outcomes: refund the client, split the funds, or pay the service provider. The `openDispute`, `openDisputeWithCID`, `appealDispute`, and `resolveDispute` functions handle the dispute resolution process. The `getDisputeHeader` and `getDisputeAppeal` functions allow retrieval of dispute information.
- **Tokenomics**: The contract supports various tokenomic models, including deflationary mechanisms. The `_buyDopAndBurnFromETH` and `_buyDopAndBurnFromToken` functions handle the buyback and burn mechanisms.
- **Reviews**: The `leaveReview` function allows users to leave reviews for each other after a service is completed. The `getReviews` and `getAverageRating` functions allow retrieval of review information.

## Environment Variables

```
DOP_ADDRESS=0xExistingDopToken (Optional: Token address for boost and fee mechanisms)
USDC_ADDRESS=0xOptionalStable (Optional: Stablecoin address for payments)
TREASURY_ADDRESS=0xTreasury (Address to receive fees)
DEX_ROUTER_ADDRESS=0xUniswapV2Router  (Optional: For buyback functionality)
WETH_ADDRESS=0xWETHAddress (Optional: WETH address for DEX interactions)
PRIVATE_KEY=0xyourkey (Private key for deployment and testing)
ALCHEMY_RPC=https://... (RPC endpoint for your Ethereum network)
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

- **Buyback & Burn**: Token fees can trigger automatic buyback & burn via a DEX router (e.g., Uniswap V2/V3) to manage token supply.
- **User Profiles**: Profiles include portfolios, skills, and a verification system to enhance credibility.
- **Badge System**: Milestone badges (Rookie, Experienced, Expert, Master, Reliable) are awarded automatically based on performance.
- **Mission History**: A complete on-chain record of all work, including dispute flags, ensures transparency.
- **Category System**: Listings can be filtered by user types (Service Provider, Client, etc.) and categories for efficient matching.
- **Metadata Storage**: Profile data and portfolios are stored off-chain (e.g., IPFS) with URI references on-chain to minimize storage costs.
- **Tokenomics**: The marketplace supports various tokenomic models, including deflationary mechanisms to manage token supply and incentivize participation.
- **Reviews**: Users can leave reviews and ratings for service providers upon completion of a project, enhancing the reputation system.
