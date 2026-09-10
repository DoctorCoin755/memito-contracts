// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CityTreasury — the money of MEMELAND CLUB CITY
/// @notice This contract holds the players' money and nothing else. It has no
///         owner, no withdraw button and no upgrade path. Money enters from the
///         frog sale and from the city, and leaves in exactly one way: a player
///         hands in golden frogs and the city tells the treasury to pay them.
///
///         The address of the city is fixed when this contract is born and can
///         never be changed. That is the whole security model: if the address
///         could be changed, whoever changed it would own everyone's money.
///
///         One more thing guards that single door: no more than 1% of what the
///         treasury is worth may leave in any rolling 24 hours. It is not a
///         pause and nobody can trip it — it is arithmetic, and it makes a bank
///         run take a hundred days instead of an afternoon.
contract CityTreasury {
    /// @notice The only contract allowed to order a payout. Immutable.
    address public immutable city;

    /// @notice Where prices come from. Immutable.
    IPriceOracle public immutable oracle;

    /// @notice The five coins the treasury values and pays out in.
    ///         ETH is address(0). Fixed at birth, the list never grows.
    /// @dev The game's own coin is deliberately not among them and is not named
    ///      in this file at all. It arrives here anyway — half of every land
    ///      sale, and every stray-frog buy-out, is paid to this address in
    ///      MEMITO — and it stays here for good: held, never valued, never paid
    ///      out. A bank does not value itself by a number its own customers can
    ///      move, and since this round nobody can price it at all, so the rule
    ///      is the shape of the contract rather than a check at run time.
    address[5] public assets;
    mapping(address => bool) public isAccepted;

    /// @notice Dollars ever paid out to players. Only ever goes up.
    uint256 public paidOutUsd;

    /* ------------------------------------------------------------------ */
    /*  The daily door                                                     */
    /* ------------------------------------------------------------------ */

    /// @notice 1% of the treasury's dollar value, per rolling 24 hours.
    uint256 public constant DAILY_CAP_BP = 100;
    uint256 public constant CAP_WINDOW = 24 hours;

    /// @notice The daily allowance never falls below this many dollars.
    /// @dev Without it the two rules collide and weld the tail of the treasury
    ///      shut for good: the city refuses to pay out less than $20, no more
    ///      than 1% of the treasury may leave in a day, and below $2,000 of
    ///      value no amount satisfies both — with no owner to unstick it. So
    ///      the allowance is floored, and floored a little ABOVE the city's $20
    ///      rather than exactly at it, because the smallest legal cash-out
    ///      lands just over twenty dollars and would otherwise still be one wei
    ///      too big. It only ever binds on a treasury small enough that 1% of
    ///      it is under twenty-five dollars, where the difference between this
    ///      and a strict 1% is measured in cents.
    uint256 public constant MIN_DAILY_CAP_USD = 25e18;

    /// @notice Dollars counted against the current window.
    /// @dev A leaky bucket, not a list of timestamps. The accumulator drains
    ///      linearly to zero over CAP_WINDOW, so a payout stops counting
    ///      gradually over the day after it rather than all at once 24 hours
    ///      later. That is an approximation of a true sliding window, chosen
    ///      because it is O(1) storage and O(1) gas and cannot be made to
    ///      forget faster by splitting a withdrawal into pieces: the bucket
    ///      only ever drains with real time.
    ///
    ///      Stated honestly: the steady-state rate is exactly 1% a day, but the
    ///      very first day can reach about 2% — spend the whole allowance at
    ///      once, then drip at the rate the bucket drains. After that transient
    ///      it settles at 1%. A true sliding window would need a ring of hourly
    ///      buckets and 24 storage reads on every payout; the difference it
    ///      would buy is one day at 2% instead of 1%, on a mechanism whose job
    ///      is to turn an afternoon into a hundred days.
    uint256 public outflowUsd;
    uint64 public outflowUpdatedAt;

    /// @notice The same leaky bucket again, per asset, counted in that asset's
    ///         own units: no more than 1% of what the treasury holds OF THAT
    ///         COIN may leave in a rolling day.
    /// @dev The dollar cap above bounds VALUE, not coins, and the player names
    ///      the coin. So while ETH is a small share of a treasury whose value
    ///      is mostly MEMITO, one payout inside the dollar cap can take every
    ///      wei of ETH the treasury owns, then every USDC tomorrow — the cap is
    ///      satisfied throughout and the hard money is gone in a week, leaving
    ///      golden frogs backed by the game's own token. It also blunts the
    ///      other end of that lever: the dollar cap is computed from
    ///      totalValueUsd(), so pushing the MEMITO average up for one window
    ///      raises the cap with it, and a per-coin ceiling means the extra
    ///      allowance cannot be taken out in real ETH.
    ///
    ///      In aggregate this changes nothing — 1% of each asset is 1% of the
    ///      whole — it only stops the whole day's allowance being taken out of
    ///      one coin.
    mapping(address => uint256) public assetOutflow;
    mapping(address => uint64) public assetOutflowAt;

    event Received(address indexed from, address indexed asset, uint256 amount);
    event Holdings(address indexed asset, uint256 balance);
    event PaidOut(address indexed player, address indexed asset, uint256 amount, uint256 usd);

    error OnlyCity();
    error AssetNotAccepted();
    error NothingToPay();
    error NotEnoughInTreasury();
    error TransferFailed();
    error DuplicateAsset();
    error AssetHasNoCode();
    error AssetNotPriceable();
    error DailyCapReached();
    error AssetCapReached();

    modifier onlyCity() {
        if (msg.sender != city) revert OnlyCity();
        _;
    }

    /// @param city_   address the city contract WILL have — computed before it
    ///                exists, so both sides know each other from birth
    /// @param oracle_ price source
    /// @param assets_ [ETH(0), USDT, USDC, DAI, WBTC]
    /// @dev Every one of these checks guards a mistake that would be permanent:
    ///      there is no setter, no owner and no rescue anywhere in this file.
    ///      A duplicate entry double-counts that balance in totalValueUsd() and
    ///      pays golden frogs out against money that is not there. An asset the
    ///      oracle cannot price, or an address with no code, kills
    ///      totalValueUsd() outright the moment a balance lands on it — and
    ///      totalValueUsd() is what the entire exchange is built on, so that is
    ///      cash-outs frozen in every asset, forever. Ten lines here, checked
    ///      once, instead of a redeployment of all six contracts.
    constructor(address city_, address oracle_, address[5] memory assets_) {
        require(city_ != address(0) && oracle_ != address(0), "zero address");
        city = city_;
        oracle = IPriceOracle(oracle_);

        IPriceOracle o = IPriceOracle(oracle_);
        for (uint256 i = 0; i < 5; i++) {
            address a = assets_[i];
            if (isAccepted[a]) revert DuplicateAsset();
            if (a != address(0) && a.code.length == 0) revert AssetHasNoCode();
            if (!o.supportsAsset(a)) revert AssetNotPriceable();
            assets[i] = a;
            isAccepted[a] = true;
        }
    }

    /* ------------------------------------------------------------------ */
    /*  Money coming in                                                    */
    /* ------------------------------------------------------------------ */

    /// @notice ETH arrives simply by being sent. Tokens arrive by a plain
    ///         transfer to this address — no approval dance, no entry point to
    ///         get wrong.
    receive() external payable {
        emit Received(msg.sender, address(0), msg.value);
    }

    /// @notice Optional: publish what the treasury actually holds of one asset,
    ///         so a token transfer shows up in the log the way ETH does.
    ///         Calling it is not required for the money to count — the treasury
    ///         always reads its real balance.
    /// @dev Still permissionless and it still moves nothing, but the number is
    ///      now MEASURED here instead of being typed in by the caller. The old
    ///      version emitted whatever amount it was handed, so anybody could
    ///      write a million-dollar deposit into the treasury's log for the price
    ///      of the gas, and a coin that skims a fee on transfer would have been
    ///      logged at what was sent rather than at what arrived — USDT has
    ///      carried that switch since 2017 and has never thrown it. The paying
    ///      side already reports what LANDED rather than what was debited; this
    ///      is the same rule on the way in.
    ///
    ///      A balance, not a delta, because a balance needs no bookkeeping to
    ///      stay true: anybody may publish it, nobody can publish a false one,
    ///      and an indexer reading balanceOf gets the same answer. Who called is
    ///      still only who called — this log never proved who paid.
    function noteDeposit(address asset) external {
        if (!isAccepted[asset]) revert AssetNotAccepted();
        emit Holdings(asset, balanceOf(asset));
    }

    /* ------------------------------------------------------------------ */
    /*  What the treasury is worth                                         */
    /* ------------------------------------------------------------------ */

    /// @notice How much of one asset is sitting here, in its own units.
    function balanceOf(address asset) public view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice The whole treasury in dollars, 18 decimals.
    /// @dev This is the number the golden frog rate is built on:
    ///      one golden frog is worth totalValueUsd() / (all golden frogs, floored
    ///      at 12,000,000). Nothing is converted or sold — every coin stays as it
    ///      arrived and is simply valued.
    ///
    ///      A coin the oracle cannot price RIGHT NOW counts as nothing, and only
    ///      that coin: the other five go on being money and go on paying. This
    ///      used to be all or nothing — one late feed, or twelve quiet hours in
    ///      the MEMITO pool, and every cash-out in every coin stopped until
    ///      somebody fixed something, except that there is nobody here to fix
    ///      anything and no button to press. A stranger could arm it for the
    ///      price of the gas by sending in one wei of a coin nobody had chosen
    ///      to hold. Waiting looked like the careful answer and was the
    ///      unbounded one.
    ///
    ///      This function cannot revert on a price. marketAlive() and priceUsd()
    ///      read the same feed against the same limit, so a holding that is
    ///      counted is a holding that can be priced in this same block.
    ///
    ///      What the write-off costs is real and is written down plainly: while
    ///      a feed is silent its coin is worth zero here, so a golden frog
    ///      cashed in during that stretch is paid less than it will be worth an
    ///      hour later. That loss is capped by the same 1%-a-day door as
    ///      everything else, it reverses itself the moment the feed publishes,
    ///      and a write-off can only ever LOWER what a frog is worth — so there
    ///      is nothing in forcing one for anybody.
    ///
    ///      MEMITO is never counted, and it is never named in this file either:
    ///      it is simply not one of the five this loop walks. It is this game's
    ///      own coin, priced out of the one pool this game itself trades in, so
    ///      counting it let anyone set the value of every golden frog by pushing
    ///      that pool, and made the whole treasury depend on a half-hour average
    ///      that only existed while somebody kept poking it. Both are gone by
    ///      subtraction, and since this round nobody can price the coin at all.
    ///      The MEMITO that lands here stays here for good — held, never valued,
    ///      never paid out.
    function totalValueUsd() public view returns (uint256 usd) {
        for (uint256 i = 0; i < 5; i++) {
            address asset = assets[i];
            uint256 bal = balanceOf(asset);
            if (bal == 0) continue;
            if (!oracle.marketAlive(asset)) continue;
            usd += oracle.usdValue(asset, bal);
        }
    }

    /* ------------------------------------------------------------------ */
    /*  The daily cap                                                      */
    /* ------------------------------------------------------------------ */

    /// @dev The accumulator as it stands right now, after draining.
    function _drained(uint256 nowTs) internal view returns (uint256) {
        uint256 acc = outflowUsd;
        if (acc == 0) return 0;
        uint256 elapsed = nowTs - outflowUpdatedAt;
        if (elapsed >= CAP_WINDOW) return 0;
        return acc - (acc * elapsed) / CAP_WINDOW;
    }

    /// @dev The per-asset accumulator as it stands right now, after draining.
    function _drainedAsset(address asset, uint256 nowTs) internal view returns (uint256) {
        uint256 acc = assetOutflow[asset];
        if (acc == 0) return 0;
        uint256 elapsed = nowTs - assetOutflowAt[asset];
        if (elapsed >= CAP_WINDOW) return 0;
        return acc - (acc * elapsed) / CAP_WINDOW;
    }

    /// @notice The most that may leave in a rolling day, in dollars.
    /// @dev Measured against the treasury as it is NOW, so the allowance shrinks
    ///      as the treasury does. That is the point: a run cannot accelerate.
    function dailyCapUsd() public view returns (uint256) {
        uint256 cap = (totalValueUsd() * DAILY_CAP_BP) / 10000;
        return cap < MIN_DAILY_CAP_USD ? MIN_DAILY_CAP_USD : cap;
    }

    /// @notice The most of one coin that may leave in a rolling day, in that
    ///         coin's own units.
    /// @dev Zero for a coin that cannot be priced right now, MEMITO included.
    ///      payOut refuses to pay in one, so nothing of it may leave — that is
    ///      the honest number, and it is also the answer that does not require
    ///      asking a price source which no longer answers what twenty-five
    ///      dollars of its coin comes to.
    function dailyAssetCap(address asset) public view returns (uint256) {
        if (!oracle.marketAlive(asset)) return 0;
        uint256 bal = balanceOf(asset);
        uint256 cap = (bal * DAILY_CAP_BP) / 10000;
        uint256 floorAmount = _floorAmount(bal, totalValueUsd());
        return cap < floorAmount ? floorAmount : cap;
    }

    /// @dev The floor under one coin's daily door, in that coin, worked out
    ///      without ever asking what the coin is worth.
    ///
    ///      The floor is here because two rules would otherwise weld the tail
    ///      of the treasury shut for good: the city refuses to pay out less
    ///      than its minimum, no more than a hundredth of a holding may leave
    ///      in a day, and on a small holding no amount satisfies both — with no
    ///      owner anywhere to unstick it.
    ///
    ///      It used to be MIN_DAILY_CAP_USD converted into coins through the
    ///      oracle, and for MEMITO that conversion WAS the hole: the cheaper
    ///      the pool average was pushed, the more coins twenty-five dollars
    ///      bought, and a thousandfold push made the floor wider than the whole
    ///      holding. MEMITO is out of this contract's books entirely now, but
    ///      the shape of the formula was the better one regardless, so all five
    ///      use it: the floor is `share x price` and the pile is
    ///      `balance x price`, so the price cancels clean out and no price
    ///      appears in the floor at all. Two things follow. A stablecoin in a
    ///      deep depeg no longer opens its own door wider in coins. And this
    ///      value is never larger than the dollar-converted one it replaces,
    ///      because the treasury's stated worth is never less than the one
    ///      holding's own contribution to it — so this is a tightening, never
    ///      a new way out.
    ///
    ///      The denominator is floored at MIN_DAILY_CAP_USD, which does three
    ///      jobs at once: a treasury worth less than one day's allowance cannot
    ///      divide by less than that allowance, the answer can therefore never
    ///      exceed the balance it is a share of, and a treasury whose every
    ///      holding has been written off does not divide by zero.
    function _floorAmount(uint256 bal, uint256 value) internal pure returns (uint256) {
        uint256 denom = value < MIN_DAILY_CAP_USD ? MIN_DAILY_CAP_USD : value;
        return (bal * MIN_DAILY_CAP_USD) / denom;
    }

    /// @notice How much of one coin may still leave in this window.
    /// @dev A shop window, and shop windows do not throw. Everything behind this
    ///      number can fail for reasons that do not stop the treasury: a coin
    ///      whose market is gone is written off above and refused by payOut, a
    ///      price that is merely late closes this coin and not the other four,
    ///      and an address that is not one of the five has no balance to read. In
    ///      every one of those the true answer is "nothing may leave in this coin
    ///      right now" — a number, not a revert. Throwing painted the whole game
    ///      as broken at the exact moment the treasury was working and still
    ///      paying in everything else.
    ///
    ///      dailyAssetCap() and dailyCapUsd() stay strict on purpose: they are
    ///      the arithmetic the payout is built on, and a silent zero there would
    ///      read as "the allowance is spent" rather than "ask again later".
    function remainingDailyAsset(address asset) external view returns (uint256) {
        if (!isAccepted[asset]) return 0;
        try this.dailyAssetCap(asset) returns (uint256 cap) {
            uint256 used = _drainedAsset(asset, block.timestamp);
            return used >= cap ? 0 : cap - used;
        } catch {
            return 0;
        }
    }

    /// @notice How many dollars may still leave in this window.
    /// @dev Quiet for the same reason. If the treasury cannot be valued right
    ///      now then nothing can leave right now, and zero says exactly that.
    function remainingDailyUsd() external view returns (uint256) {
        try this.dailyCapUsd() returns (uint256 cap) {
            uint256 used = _drained(block.timestamp);
            return used >= cap ? 0 : cap - used;
        } catch {
            return 0;
        }
    }

    /* ------------------------------------------------------------------ */
    /*  Money going out — the only door                                    */
    /* ------------------------------------------------------------------ */

    /// @notice Pay a player. Called only by the city, only after it has burned
    ///         the player's golden frogs.
    /// @param player who receives the money
    /// @param asset  which coin the player chose
    /// @param usd    how many dollars they earned, 18 decimals
    /// @return sent  the amount of that coin actually handed over
    ///
    /// @dev The city decides the dollars, the treasury decides the coins. Split
    ///      that way on purpose: the city can never name an asset amount
    ///      directly, and the treasury can never invent a debt.
    ///
    ///      The 1%-a-day cap lives HERE rather than in the city, because this is
    ///      the only place value actually leaves. Whatever the city is or ever
    ///      becomes, it cannot drain the treasury faster than the arithmetic in
    ///      these six lines.
    function payOut(address player, address asset, uint256 usd)
        external
        onlyCity
        returns (uint256 sent)
    {
        if (!isAccepted[asset]) revert AssetNotAccepted();
        if (usd == 0) revert NothingToPay();

        // A coin that cannot be priced right now is counted as nothing above,
        // so it contributes nothing to what a golden frog is worth — and it
        // must therefore not be payable either. The two halves are one rule and
        // they move together; apart, the treasury valued a coin at zero while
        // still handing it out at the last good number, which is free money for
        // whoever asks first at everybody else's expense. This line is also
        // what keeps MEMITO in and never out: marketAlive is false for it
        // always, so it may be held and can never be paid away.
        if (!oracle.marketAlive(asset)) revert AssetNotAccepted();

        // Valued before anything leaves, so the cap is a share of the treasury
        // as it stands at the top of this call. The reading is kept rather than
        // thrown away: MEMITO's per-coin floor below is a share of this very
        // number, and the two doors have to be measured against one treasury.
        uint256 value = totalValueUsd();
        uint256 cap = (value * DAILY_CAP_BP) / 10000;
        if (cap < MIN_DAILY_CAP_USD) cap = MIN_DAILY_CAP_USD;
        uint256 used = _drained(block.timestamp);
        if (used + usd > cap) revert DailyCapReached();
        outflowUsd = used + usd;
        outflowUpdatedAt = uint64(block.timestamp);

        sent = oracle.assetAmount(asset, usd);
        if (sent == 0) revert NothingToPay();

        uint256 bal = balanceOf(asset);
        if (sent > bal) revert NotEnoughInTreasury();

        // And no more than a hundredth of THIS coin in a rolling day, so the
        // dollar allowance cannot be spent entirely out of whichever coin the
        // player finds most useful.
        //
        // The floor under that hundredth is where the one manipulable price in
        // the system used to reach in, so it is written in the coin itself
        // rather than in dollars converted through a price — see _floorAmount().
        {
            uint256 assetCap = (bal * DAILY_CAP_BP) / 10000;
            uint256 floorAmount = _floorAmount(bal, value);
            if (assetCap < floorAmount) assetCap = floorAmount;

            uint256 assetUsed = _drainedAsset(asset, block.timestamp);
            if (assetUsed + sent > assetCap) revert AssetCapReached();
            assetOutflow[asset] = assetUsed + sent;
            assetOutflowAt[asset] = uint64(block.timestamp);
        }

        paidOutUsd += usd;

        // `sent` stops being "debited from here" and becomes "landed over
        // there". The city hands the player's own minAssetOut floor a number to
        // compare against, and a coin that skims a fee on transfer would
        // otherwise let that floor pass while the player received less than it.
        // None of the five does today; USDT has the switch and it is off.
        if (asset == address(0)) {
            (bool ok, ) = payable(player).call{value: sent}("");
            if (!ok) revert TransferFailed();
        } else {
            uint256 before = IERC20(asset).balanceOf(player);
            _safeTransfer(asset, player, sent);
            uint256 landed = IERC20(asset).balanceOf(player) - before;
            if (landed < sent) sent = landed;
        }

        emit PaidOut(player, asset, sent, usd);
    }

    /* ------------------------------------------------------------------ */

    /// @dev USDT on Ethereum returns nothing from transfer instead of a bool.
    ///      A plain `require(token.transfer(...))` breaks on it, which is how a
    ///      lot of hand-written contracts die.
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
