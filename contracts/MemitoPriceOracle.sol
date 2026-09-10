// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title MemitoPriceOracle - Chainlink, and nothing else
/// @notice Everything else (treasury value, box price) is built on the numbers
///         this contract returns. It has no owner, no setters, no constructor
///         arguments and, since this round, not a single storage slot - every
///         address it uses is a mainnet constant written in the source, which
///         means a verifier can check it by reading rather than by trusting a
///         deploy transcript.
///
/// @dev The two attacks this file used to be shaped around are gone by
///      subtraction rather than by defence. Both lived in one place: this
///      oracle priced MEMITO, the game's own coin, off the single Uniswap pool
///      the game itself trades in. Rented money could shove that pool, hold it
///      for thirty-one minutes and walk back out with the half-hour average
///      still up - 150 ETH bought a $400,000 sale for $30,867. The ceiling
///      built against that froze at startTrade() and handed the lever straight
///      back the moment the coin traded below its listing price ($80,352 at
///      -80%, $20,188 at -95%). Three repairs, three new sides.
///
///      So the price was removed instead of repaired. Boxes are paid for in the
///      five coins Chainlink publishes. Land and stray frogs are priced in a
///      fixed number of MEMITO - a constant, not a price. Nothing in the set
///      asks what MEMITO is worth, this contract cannot answer it, and there is
///      no average left to poke, to grief or to rent.
contract MemitoPriceOracle is IPriceOracle {
    /* ------------------------------------------------------------------ */
    /*  Mainnet constants                                                  */
    /* ------------------------------------------------------------------ */

    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 decimals
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18 decimals
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 decimals

    address public constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address public constant USDT_USD_FEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address public constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant DAI_USD_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    /// @notice WBTC/BTC. WBTC is a custodial redemption claim on bitcoin, not
    ///         bitcoin, and the claim has traded away from parity before.
    ///         Priced off BTC/USD alone, a broken claim is booked at par: the
    ///         treasury overstates its whole WBTC line by the size of the break
    ///         and sells boxes paid in WBTC at exactly that discount, with
    ///         nobody able to correct it afterwards. Chainlink publishes the peg
    ///         as a feed of its own, so it is read as a second leg. Eight
    ///         decimals, a small deviation trigger and a 24 hour heartbeat —
    ///         hence MAX_AGE_SLOW, the same class as the two stablecoin feeds.
    address public constant WBTC_BTC_FEED = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;

    /// @dev Parity in the peg feed's own eight decimals.
    uint256 internal constant PEG_PARITY = 1e8;

    /// @dev Chainlink publishes ETH, BTC and DAI on a 1 hour heartbeat and the
    ///      two big stablecoins and the WBTC peg on a 24 hour one. Fast feeds
    ///      are given three heartbeats, the slow ones one and a quarter — a 24
    ///      hour feed cannot be given three heartbeats of slack without
    ///      tolerating a three-day-old price. Long enough that a late
    ///      publication does not freeze the game, short enough that a dead feed
    ///      cannot be used as a price.
    uint256 public constant MAX_AGE_FAST = 3 hours; // ETH, BTC, DAI
    uint256 public constant MAX_AGE_SLOW = 30 hours; // USDT, USDC, WBTC/BTC

    /// @notice There is deliberately no second, longer threshold in this file.
    /// @dev There used to be. A feed was refused for pricing past maxAge but
    ///      only declared gone at maxAge + 2 days, and inside that band a coin
    ///      was neither priceable nor written off. The treasury adds its six
    ///      holdings all or nothing, so the band was a 48-hour outage of the
    ///      WHOLE treasury — every coin, from one ordinary late publication,
    ///      and armable in advance by a stranger for the price of the gas. One
    ///      threshold removes the band by construction: past maxAge the feed
    ///      simply has no price, that one holding counts as nothing, and the
    ///      other five go on paying. See marketAlive.
    ///
    ///      What the removal costs is real and is not hidden: the write-off now
    ///      begins at 3 hours of silence rather than 51, so a player who burns
    ///      golden frogs during an ordinary feed outage is paid less, and burnt
    ///      frogs do not come back. Three things bound it — no more than 1% of
    ///      the treasury may leave in a day, the write-off undoes itself the
    ///      second the feed publishes again, and the exchange takes a
    ///      minAssetOut floor from the player which refuses a payout struck at
    ///      the depressed rate. The freeze it replaces was bounded by nothing:
    ///      everybody, every coin, for ever, with no owner and no rescue.

    error UnsupportedAsset();
    error BadFeedAnswer();
    error StalePrice();

    /// @dev Nothing is stored and nothing is passed in. The six checks are the
    ///      whole constructor: every Chainlink USD feed on mainnet reports 8
    ///      decimals, and asserting it once here makes the scaling below a
    ///      constant instead of a per-call read.
    ///
    ///      This used to read the pool address out of the MEMITO token, which
    ///      meant the oracle could not exist before the coin did. It can now be
    ///      deployed at any point in any order, and its runtime bytecode is
    ///      fully determined by this source: there is no constructor argument
    ///      for a verifier to reconcile, and no storage slot for anyone to move.
    constructor() {
        require(AggregatorV3Interface(ETH_USD_FEED).decimals() == 8, "eth feed decimals");
        require(AggregatorV3Interface(BTC_USD_FEED).decimals() == 8, "btc feed decimals");
        require(AggregatorV3Interface(USDT_USD_FEED).decimals() == 8, "usdt feed decimals");
        require(AggregatorV3Interface(USDC_USD_FEED).decimals() == 8, "usdc feed decimals");
        require(AggregatorV3Interface(DAI_USD_FEED).decimals() == 8, "dai feed decimals");
        require(AggregatorV3Interface(WBTC_BTC_FEED).decimals() == 8, "wbtc peg feed decimals");
    }

    /* ------------------------------------------------------------------ */
    /*  IPriceOracle                                                       */
    /* ------------------------------------------------------------------ */

    /// @notice True if this oracle can price the asset at all.
    /// @dev Five coins, every one of them published by Chainlink and movable by
    ///      nobody in this game. MEMITO is deliberately absent, and this one
    ///      missing line is what closes the box sale to it: MemitoFrogs.mint
    ///      asks exactly this question before it accepts a coin. The game's own
    ///      coin had only one price - the single Uniswap pool this game itself
    ///      trades in - and three rounds of trying to make that price safe each
    ///      broke from a new side. There is no fourth patch: the price is gone.
    function supportsAsset(address asset) public pure override returns (bool) {
        return
            asset == address(0) ||
            asset == USDT ||
            asset == USDC ||
            asset == DAI ||
            asset == WBTC;
    }

    /// @notice May the treasury count this asset as backing, and hand it out?
    /// @dev ONE rule, and it is the whole of this round: an asset that cannot
    ///      be priced RIGHT NOW is worth nothing and cannot be paid out - that
    ///      asset alone, never the other four. There is no third state between
    ///      "fine" and "written off", and the absence of that third state is
    ///      the point. It used to exist: a feed past its own limit but not yet
    ///      past a two-day grace was neither priceable nor written off, and
    ///      because the treasury adds its holdings all or nothing, one late
    ///      publication stopped every payout in EVERY coin for 48 hours -
    ///      armable in advance by any passer-by, for the price of the gas. This
    ///      function and priceUsd() now read the same feed against the same
    ///      limit, so they cannot disagree, and totalValueUsd() cannot revert
    ///      on a price.
    ///
    ///      Anything this oracle does not price answers false rather than
    ///      reverting, and that shape is load-bearing rather than tidy. The
    ///      treasury asks this question about every coin it holds on every
    ///      single valuation, so a revert here would be a permanent, total
    ///      freeze of every cash-out in every coin, with nobody able to unstick
    ///      it. MEMITO is exactly such a coin: it arrives here by the ordinary
    ///      course of the game, it is held for good, and nothing in this file
    ///      can say what it is worth.
    function marketAlive(address asset) public view override returns (bool) {
        if (!supportsAsset(asset)) return false;
        (address feed, uint256 maxAge) = _feedOf(asset);
        return _feedAlive(feed, maxAge);
    }

    /// @dev Can this feed be read for a price right now? Never reverts: it is
    ///      asked precisely when the answer may be that the aggregator behind
    ///      the proxy is gone and the call itself throws. Deliberately the
    ///      exact complement of the checks in _feedRaw, against the same
    ///      maxAge — "alive" here must mean "_feed() will not revert on this
    ///      feed in this same block", or the treasury is back to a sum that can
    ///      throw on a holding it was told to count.
    function _feedAlive(address feed, uint256 maxAge) internal view returns (bool) {
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return false;
            return block.timestamp - updatedAt <= maxAge;
        } catch {
            return false;
        }
    }

    /// @dev Which Chainlink feed prices an asset, and how old it may be.
    function _feedOf(address asset) internal pure returns (address feed, uint256 maxAge) {
        if (asset == address(0)) return (ETH_USD_FEED, MAX_AGE_FAST);
        if (asset == USDT) return (USDT_USD_FEED, MAX_AGE_SLOW);
        if (asset == USDC) return (USDC_USD_FEED, MAX_AGE_SLOW);
        if (asset == DAI) return (DAI_USD_FEED, MAX_AGE_FAST);
        if (asset == WBTC) return (BTC_USD_FEED, MAX_AGE_FAST);
        revert UnsupportedAsset();
    }

    /// @notice Price of ONE whole unit of the asset, in USD with 18 decimals.
    ///         Public because the game front end wants it and because anyone
    ///         auditing a payout should be able to reproduce it in one call.
    function priceUsd(address asset) public view returns (uint256) {
        (address feed, uint256 maxAge) = _feedOf(asset);
        uint256 p = _feed(feed, maxAge);
        if (asset == WBTC) {
            // Second leg: what one WBTC is worth in bitcoin, not what bitcoin is
            // worth. While the two agree this changes nothing; while they do
            // not, the break becomes the price instead of staying invisible.
            //
            // Clamped at par in one direction only. Below par is a market fact
            // and must pass through. Above par is noise or a broken round, and
            // taking it would let a buyer settle a $40 box with less than $40 of
            // bitcoin and would overstate the treasury for every frog at once.
            //
            // A leg that is not publishing means par, not "no price". This is
            // the narrowest of the six feeds and the likeliest to be retired,
            // its address is a constant, and there is nobody here to change it
            // — so the old reading turned one routine retirement into a
            // permanent zero on the entire WBTC line, coins sealed in for good
            // while BTC/USD published happily and WBTC traded everywhere. What
            // the swap costs is the opposite case, a real depeg during the
            // leg's own silence, which reads high on that one line until it
            // speaks again. Temporary and bounded beats permanent and total.
            uint256 peg = _feedAlive(WBTC_BTC_FEED, MAX_AGE_SLOW)
                ? _feedRaw(WBTC_BTC_FEED, MAX_AGE_SLOW)
                : PEG_PARITY;
            if (peg > PEG_PARITY) peg = PEG_PARITY;
            p = (p * peg) / PEG_PARITY;
            if (p == 0) revert BadFeedAnswer();
        }
        return p;
    }

    function usdValue(address asset, uint256 amount) external view override returns (uint256 usd) {
        if (amount == 0) return 0;
        usd = (amount * priceUsd(asset)) / _unit(asset);
    }

    function assetAmount(address asset, uint256 usd) external view override returns (uint256 amount) {
        if (usd == 0) return 0;
        amount = (usd * _unit(asset)) / priceUsd(asset);
    }

    /// @dev One whole token in raw units.
    function _unit(address asset) internal pure returns (uint256) {
        if (asset == address(0) || asset == DAI) return 1e18;
        if (asset == USDT || asset == USDC) return 1e6;
        if (asset == WBTC) return 1e8;
        revert UnsupportedAsset();
    }

    /* ------------------------------------------------------------------ */
    /*  Chainlink                                                          */
    /* ------------------------------------------------------------------ */

    /// @dev Reverting is the point. A wrong price silently accepted would let
    ///      the treasury pay out fifty times what a golden frog is worth; a
    ///      revert only stops the game until the feed catches up.
    function _feed(address feed, uint256 maxAge) internal view returns (uint256) {
        return _feedRaw(feed, maxAge) * 1e10; // 8 decimals -> 18
    }

    /// @dev The same checked answer, left in the decimals of the feed. Ratio
    ///      feeds such as WBTC/BTC are consumed raw and must never be rescaled
    ///      to dollars before they are multiplied in.
    function _feedRaw(address feed, uint256 maxAge) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (updatedAt == 0) revert BadFeedAnswer();
        // A round stamped in the future is a broken aggregator, not a fresh
        // price. Treating it as fresh would disable the staleness check for as
        // long as the bad stamp is in front of us.
        if (updatedAt > block.timestamp) revert BadFeedAnswer();
        if (block.timestamp - updatedAt > maxAge) revert StalePrice();
        return uint256(answer);
    }

}
