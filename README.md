# $MEMITO — contracts

Solidity sources of the $MEMITO contracts on Ethereum mainnet.

Every contract in this repository is deployed and source-verified on Etherscan.
The code here is the code that is running — you do not have to take our word for
anything, and this repository exists so you do not have to.

## Deployed addresses

| Contract | Address |
|---|---|
| MEMITO token (ERC-20) | [`0xe02AD79732658a2ec2C85Ecd15De5E08A311373C`](https://etherscan.io/token/0xe02AD79732658a2ec2C85Ecd15De5E08A311373C) |
| Ecosystem Wallet | [`0x19F91decb2ED4503AEE79aaf09b0DF48ca073C67`](https://etherscan.io/address/0x19F91decb2ED4503AEE79aaf09b0DF48ca073C67) |
| NFT collection (MemitoFrogs) | [`0xf485B51f2e7d7286DAC54504acb238fcdFcC1fAB`](https://etherscan.io/address/0xf485B51f2e7d7286DAC54504acb238fcdFcC1fAB) |
| Game (MemelandCity) | [`0x68465F1d0c37B8947EB0517f233152D65eD8BcB3`](https://etherscan.io/address/0x68465F1d0c37B8947EB0517f233152D65eD8BcB3) |
| Treasury (CityTreasury) | [`0x9216d94f5C4e045fEE67c8968a8f737b9f3c32D1`](https://etherscan.io/address/0x9216d94f5C4e045fEE67c8968a8f737b9f3c32D1) |
| Price oracle | [`0x0131730F692c71b893FaA4329ca8bEdF08fe69A5`](https://etherscan.io/address/0x0131730F692c71b893FaA4329ca8bEdF08fe69A5) |
| Frog market | [`0x780874a3ee25771F758De9Fc55c8c607FA466920`](https://etherscan.io/address/0x780874a3ee25771F758De9Fc55c8c607FA466920) |
| Royalty splitter | [`0x767dCe3d5334C425a7F080122c7386EBd832Cf89`](https://etherscan.io/address/0x767dCe3d5334C425a7F080122c7386EBd832Cf89) |
| Uniswap V2 pair MEMITO/WETH | [`0xA01548a1109E8E05Bc1B1f2837a85dEB823BC2c4`](https://etherscan.io/address/0xA01548a1109E8E05Bc1B1f2837a85dEB823BC2c4) |

Compiler: solc `0.8.28`, optimizer enabled, 200 runs. Licence: MIT.

## Design: no owner, no keeper, no buttons

The property this codebase is built around is that nobody — including the
people who wrote it — can change anything after deployment.

- Ownership of the token contract is renounced in the constructor, so `owner()`
  returns the zero address.
- The six collection and game contracts have no owner at all. There is no
  proxy, no pause switch, no upgrade path and no admin function.
- There is no maintenance call of any kind: no bot, no keeper, no cron.
  `MemitoPriceOracle` has seventeen functions and **none of them changes state**.
- The founder holds exactly one callable function for the entire life of the
  project: `startTrade()` on the token contract, which unlocks trading.

## Sale mechanics, in short

- Buyers are paid in the same transaction they pay in. There is no claim page
  and no vesting schedule.
- Payment is accepted in ETH, USDT, USDC, DAI and WBTC. Amounts are normalised
  for 6, 8 and 18 decimals; ETH and BTC prices come from Chainlink feeds with a
  staleness check.
- 30% of every purchase is swapped into the MEMITO/WETH Uniswap V2 pool inside
  the same transaction, and the LP tokens are sent to the burn address as they
  are created. Liquidity therefore belongs to nobody.
- The price follows one continuous curve rather than rounds, and stops rising
  at the listing price.
- Tokens not sold during the presale are burned.

See [docs/TOKENOMICS.md](docs/TOKENOMICS.md) for the numbers.

## Things we do not claim

- **There is no third-party audit.** We would rather say that than buy a badge.
  The sources are verified on Etherscan and are in this repository; read them.
- **The team is anonymous.** We did not try to make that comfortable with a
  photo page — we made it irrelevant by leaving no admin function to abuse.
- We do not forecast price, and no return is promised or implied.

## Verify it yourself

```bash
# the entire supply sits in the contract, the deployer holds zero
cast call 0xe02AD79732658a2ec2C85Ecd15De5E08A311373C "owner()(address)"
cast call 0xe02AD79732658a2ec2C85Ecd15De5E08A311373C "viewSale()"
```

Or simply open the `#code` and `#readContract` tabs on Etherscan.

## Links

- Website: <https://memito.org>
- Telegram: <https://t.me/memito_coin>
- X: <https://x.com/MEMITO_COIN>
- YouTube: <https://www.youtube.com/@MEMITOCoin>

Crypto carries risk. Nothing here is financial advice.
