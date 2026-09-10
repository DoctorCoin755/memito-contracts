# Tokenomics

All figures below are constants in the deployed contracts and can be read from
Etherscan. Where a name is given in `code font`, that is the exact function or
constant you can call.

## Supply

| | |
|---|---|
| Total supply (`TOTAL_SUPPLY`) | 420,690,000,000,000 MEMITO |
| Decimals | 18 |
| Presale allocation (`SALE_CAP`) | 252,414,000,000,000 — 60% of supply |
| Held by the deployer at launch | 0 |
| Unsold presale tokens | burned |

## Distribution

| Share | Portion | Note |
|---|---|---|
| Presale buyers and referrals | 60% | `BUYER_SHARE`, includes the 15% referral reward |
| Game treasury | 15% | `GAME_SHARE` |
| Founder | 15% | `FOUNDER_SHARE`, cut only when trading opens, into the Ecosystem Wallet contract |
| NFT collection | 10% | `NFT_SHARE` |

## Price

| | |
|---|---|
| Start price (`START_PRICE_USD`) | $0.00000018585 |
| Listing price (`LISTING_PRICE_USD`) | $0.0000040510 |
| Curve step (`CURVE_STEP_USD`) | $50,000 of collected value |
| Minimum purchase (`MIN_USD_PURCHASE`) | $1 |
| Maximum per purchase (`MAX_USD_PURCHASE`) | $10,000 |

The price is a single continuous curve computed from the dollars already
collected. There are no rounds and no countdown. It rises to the listing price
and stops there, so late buyers never pay more than the pool price.

## Where the money goes

Of every purchase, in the same transaction:

- **30%** (`LIQ_PERCENT`) is swapped into the MEMITO/WETH Uniswap V2 pool. The
  LP tokens are sent to the burn address, so the liquidity cannot be withdrawn
  by anyone.
- **70%** (`ECOSYSTEM_PERCENT`) goes to the Ecosystem Wallet contract in the
  same coin that was paid.

## Referral

`REFERRAL_PERCENT` is 15. A referrer receives 15% in MEMITO of what their buyer
receives — one level only, paid by the contract in the same transaction. The
referrer must already hold MEMITO.

## Trading lock

Transfers are locked until `startTrade()` is called on the token contract. That
call is the founder's only privileged action in the whole system, and it is
planned roughly a year after launch. Until then the pool exists and shows a
price, but nobody can sell — including the founder.

## NFT collection

| | |
|---|---|
| Cards | 10,000, sealed; none can be minted afterwards |
| Artworks | 150, in five rarities |
| Price | $40 per card, in ETH, USDT, USDC, DAI or WBTC |
| Limit | 20 cards per wallet |
| Split of a card sale | 50% to the game treasury, 50% to the Ecosystem Wallet, in the same transaction |
| Secondary royalty | 5% declared via ERC-2981 |

Rarities, exactly as named in the contract: Common (60 artworks × 100 = 6,000
cards, ×1 mining), Rare (50 × 60 = 3,000, ×2.5), Legendary (30 × 30 = 900,
×7.5), Mythic (9 × 10 = 90, ×26), Genesis (1 × 10 = **10 cards**, ×100).

The weighted average works out to 2.359, which is the `SEALED_PRODUCTION_BP`
constant in the contract, stored as 23,590 basis points — a table that does not
sum to that figure is not ours.

Reveals happen a thousand cards at a time, drawn with Chainlink VRF. Anyone can
trigger a reveal; the founder cannot influence the draw. The deck order was
hashed before the first sale.

## Honest caveats

- MEMITO that ends up in the treasury is **not** backing. It is neither valued
  nor paid out — it stays there permanently, which makes it a burn, not a
  reserve. Only ETH, USDT, USDC, DAI and WBTC back the game's payouts.
- Land inside the game speeds up one player's mining at the expense of the
  others: the daily pot is fixed, so land changes the split, not the total.
- The dollar price of land floats with the market price of MEMITO, in both
  directions.
