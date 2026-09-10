// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ICityTreasury {
    function city() external view returns (address);
    function isAccepted(address asset) external view returns (bool);
    function totalValueUsd() external view returns (uint256);
    function payOut(address player, address asset, uint256 usd) external returns (uint256 sent);
}

interface IMemitoFrogs {
    function city() external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @return tokenOwner who holds it
    /// @return mintedAt   when it was born
    /// @return seq        transfer counter
    /// @return production its TRUE rate in basis points, or 0 while sealed
    /// @return revealedAt when its thousand opened, or 0 while sealed
    function frogInfo(uint256 tokenId)
        external
        view
        returns (address tokenOwner, uint40 mintedAt, uint32 seq, uint32 production, uint40 revealedAt);

    /// @notice The second the first thousand revealed. 0 until then.
    function cityOpensAt() external view returns (uint64);

    /// @notice True while this token's thousand has a draw in flight.
    function revealPending(uint256 tokenId) external view returns (bool);

    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title MemelandCity — the rules of the game, on-chain
/// @notice Three things live here and nowhere else:
///
///         1. SILVER. Every frog you own produces silver by the second, at the
///            rate its card says. The clock is capped at ONE WEEK: a player who
///            comes back weekly collects everything, a player who disappears
///            for a month collects one week. A week rather than a day because
///            the daily loop is only cheap while gas is cheap — at 20 gwei a
///            daily collect costs real money, and a weekly cap lets a player
///            wait out a gas storm instead of being punished by it.
///
///            Nothing accrues at all until the CITY OPENS, which is the second
///            the first thousand boxes reveal. Everybody starts together.
///
///         2. GOLDEN FROGS. Exactly 10,000 are minted every day the pot is
///            used — forever, with no halving. Players push silver into the
///            day's pot; when the day closes at 00:00 UTC the 10,000 are split
///            in proportion to what each wallet pushed in. Fighting for a share
///            of a fixed pot is what replaces a difficulty curve.
///
///         3. THE EXCHANGE. A golden frog is worth (everything the treasury
///            holds) divided by (every golden frog that exists, or 12,000,000,
///            whichever is larger). Cashing out BURNS the frogs in full and
///            pays out 98% of their value — the missing 2% stays behind in the
///            treasury. While the 12,000,000 floor is what the rate divides
///            by, that 2% slows the rate's fall rather than lifting it; only
///            once real supply passes the floor does burning lift the rate for
///            everyone left. See exchange().
///
///         There is no owner. There is no admin. There is no function in this
///         file that moves money anywhere except to the player who asked.
contract MemelandCity {
    /* ====================================================================== */
    /*  Wiring — all frozen at birth                                           */
    /* ====================================================================== */

    IMemitoFrogs public immutable frogs;
    ICityTreasury public immutable treasury;

    /// @notice The price source: a published pointer, kept so the whole set can
    ///         be checked from one address, and read by NOTHING in this file
    ///         any more. Land, stray frogs and the exchange all price
    ///         themselves without it; the treasury is the only contract that
    ///         still asks it anything.
    /// @dev Kept deliberately rather than tidied away. Removing it would change
    ///      the shape of the most dangerous transaction this project has — five
    ///      contracts deployed in a row at addresses computed in advance, one
    ///      mistyped argument and nothing is repairable. A dead pointer costs a
    ///      hundred bytes and no risk; a rewritten deploy choreography costs a
    ///      class of mistakes that cannot be fixed afterwards.
    IPriceOracle public immutable oracle;
    address public immutable memito;
    address public immutable ecosystem;

    /// @notice The one token this city sells land for, written in rather than
    ///         taken on trust from whoever sends the deploy transaction.
    /// @dev The NFT, the treasury and the price oracle all hold this address as
    ///      a compile-time constant. The city and the market were the two that
    ///      took it as an argument and checked only that it was not zero and had
    ///      code, which every ERC-20 ever deployed satisfies, including the one
    ///      on the line above ours in a spreadsheet. One mistyped character and
    ///      this city prices land in a token nobody in the game holds and sends
    ///      the treasury half of every sale in a coin it cannot value, silently,
    ///      with no owner to correct it: verifyWiring() looks at the frogs and
    ///      the treasury and would report everything fine. The argument stays,
    ///      so the deploy transaction keeps the exact shape DEPLOY-ORDER.md
    ///      records; it is now checked against this instead of believed.
    address public constant MEMITO = 0xe02AD79732658a2ec2C85Ecd15De5E08A311373C;

    /* ====================================================================== */
    /*  Economy constants                                                      */
    /* ====================================================================== */

    /// @notice The accrual cap. Come back within the week or lose the rest.
    uint256 public constant COLLECT_WINDOW = 7 days;

    /// @dev Production is stored in basis points of the x1 baseline (10,000 =
    ///      x1). One baseline frog is defined to make 1 silver per second, so a
    ///      basis point is 1e18 / 10000 = 1e14 silver per second. Exact
    ///      division, no rounding anywhere in the accrual.
    uint256 public constant SILVER_PER_BP_PER_SECOND = 1e14;

    /// @notice What a still-sealed box produces: the collection average, x2.359.
    /// @dev 6000x1 + 3000x2.5 + 900x7.5 + 90x26 + 10x100 = 23,590 weighted
    ///      points over 10,000 cards. Identical to MemitoFrogs.SEALED_PRODUCTION_BP
    ///      and written here as a constant so the hot loop does not pay for a
    ///      second external call per frog.
    uint256 public constant SEALED_PRODUCTION_BP = 23_590;

    /// @notice 10,000 golden frogs a day. Fixed forever. No halving.
    /// @dev This is the day's FULL pot, minted when the day's deposits add up
    ///      to a full day of the collection's own silver. See COLLECTION_DAY_SILVER.
    uint256 public constant GOLDEN_PER_DAY = 10_000e18;

    /// @notice One day of silver from the whole collection, at the collection
    ///         average: 10,000 cards x 2.359 x 86,400 seconds.
    /// @dev The yardstick the day's emission is measured against, and the fix
    ///      for the cheapest attack in the whole set. The pot used to mint its
    ///      full 10,000 for ANY deposit, so one wallet holding a single $40 box
    ///      could push one wei of silver in every day and walk off with the
    ///      entire day's emission — for ever, at no cost, on a game nobody else
    ///      was playing. Ten thousand golden frogs a day against the 12,000,000
    ///      floor is 0.083% of the treasury a day, so that is roughly 30% of
    ///      everybody's money a year, to one address, for one box.
    ///
    ///      Now the day mints in proportion to how much of the collection's own
    ///      daily output was actually handed in, capped at the full 10,000. One
    ///      frog out of ten thousand deposits a ten-thousandth of a day and
    ///      mints a ten-thousandth of the emission — exactly its share. When
    ///      everybody plays, the day mints the whole 10,000 exactly as promised:
    ///      the agreed number is the day's ceiling, and full participation
    ///      reaches it. Nothing above it is ever minted, so this can only ever
    ///      slow the money leaving, never speed it up.
    uint256 public constant COLLECTION_DAY_SILVER =
        10_000 * SEALED_PRODUCTION_BP * SILVER_PER_BP_PER_SECOND * 1 days;

    /// @notice The floor under the exchange-rate denominator.
    /// @dev Without it the first closed day hands almost the whole treasury to
    ///      whoever was the only depositor: after one day exactly 10,000 golden
    ///      frogs exist, and 10,000 / 10,000 is the entire treasury. The floor
    ///      also sets the payout speed for the first years — 10,000 a day
    ///      against 12,000,000 is 0.083% of the treasury a day, about 30% a
    ///      year — and lifts by itself once real supply passes it, in roughly
    ///      1,200 days of play.
    uint256 public constant GOLDEN_FLOOR = 12_000_000e18;

    /// @notice 2% of every cash-out stays in the treasury.
    uint256 public constant EXCHANGE_FEE_BP = 200;

    /// @notice The smallest cash-out the exchange will process.
    /// @dev Measured on what the player actually RECEIVES, after the 2% fee. A
    ///      $3 withdrawal on mainnet can cost more in gas than it pays out;
    ///      refusing it is kinder than letting someone burn frogs for a net
    ///      loss.
    uint256 public constant MIN_EXCHANGE_USD = 20e18;

    /// @notice What that floor becomes on a treasury too small to pay it: a
    ///         cash-out must take at least a hundredth of everything left.
    /// @dev The same hundredth the treasury's own daily door is cut to, so the
    ///      two rules read as one idea. See _minPayoutUsd().
    uint256 public constant TAIL_EXCHANGE_BP = 100; // 1%

    /// @notice Land: 50% treasury, 50% Ecosystem Wallet.
    uint256 public constant LAND_CITY_BP = 5000;
    /// @notice A referrer takes 15% of the Ecosystem Wallet's half.
    uint256 public constant REFERRAL_BP_OF_ECO = 1500;

    /// @notice The one number every MEMITO price in this file is built from:
    ///         ten million MEMITO.
    ///
    /// @dev This file used to quote land and stray frogs in DOLLARS and let the
    ///      oracle turn dollars into coins. That conversion was the last lever
    ///      in the whole set and it is gone: the prices below are counted in
    ///      MEMITO, and nothing on earth can move a constant.
    ///
    ///      Why this number. On listing day one MEMITO is $0.000004051, so ten
    ///      million of them are $40.51 — the price of a box. Every price here is
    ///      then the same fraction of it the dollar version used: a plot's base
    ///      was $5 and is now an eighth ($5.06), its step was $2.50 and is now a
    ///      sixteenth ($2.53), an average stray frog was $40 and is now the
    ///      whole unit. ONE rounding, +1.28%, applied to all three, chosen so
    ///      the constants read as round numbers of COINS — because coins are the
    ///      unit now, for ever.
    ///
    ///      What floats afterwards is the DOLLAR price, up with the coin and
    ///      down with it. That is the decision, not an oversight: a plot is
    ///      1,875,000 MEMITO on the first day and 1,875,000 MEMITO on the last.
    uint256 public constant AVERAGE_FROG_MEMITO = 10_000_000e18;
    uint256 public constant PLOT_BASE_MEMITO = AVERAGE_FROG_MEMITO / 8; // 1,250,000
    uint256 public constant PLOT_STEP_MEMITO = AVERAGE_FROG_MEMITO / 16; //   625,000

    /// @dev Each plot costs PLOT_BASE + PLOT_STEP * (n+1)^1.7 coins where n is
    ///      how many the wallet ALREADY owns. This is a WHALE TAX and nothing
    ///      more: it makes the tenth plot in one address cost more than the
    ///      first. It is not a consequence of land being non-transferable — the
    ///      ladder resets for a fresh wallet either way, and no contract can
    ///      stop that. Land is non-transferable for its own reasons (there is
    ///      no land market and no land NFT to trade), and the ladder is a price
    ///      curve, not a lock.
    uint256 public constant MAX_PLOTS_PER_TX = 10; // the ^1.7 math is not free
    uint256 public constant MAX_PLOTS_PER_WALLET = 10_000; // keeps the math in range

    /// @notice Land speeds silver up: +2.5% a plot, and it stops at ten plots.
    uint256 public constant LAND_BOOST_BP_PER_PLOT = 250;
    uint256 public constant MAX_BOOSTED_PLOTS = 10;

    uint256 private constant WAD = 1e18;

    /* ====================================================================== */
    /*  State                                                                  */
    /* ====================================================================== */

    /// @notice The second the city opened, cached from the NFT contract once it
    ///         is non-zero. It never changes after that, so one SLOAD replaces
    ///         an external call on every later collect.
    uint64 public cityOpenedAt;

    /// @notice When each frog's silver clock was last reset. 0 means "never
    ///         collected", and the clock then starts at the later of the frog's
    ///         mint time and the city opening.
    /// @dev The clock belongs to the TOKEN, not to the wallet. Sell a frog with
    ///      silver still on it and the buyer collects it. That is deliberate —
    ///      a per-owner clock would need a hook on every transfer, which would
    ///      tax ordinary trading to protect sellers from their own impatience.
    ///      Collect before you list; the one-week cap bounds what is ever at
    ///      stake, and a front end must show the pending silver to both sides.
    mapping(uint256 => uint64) public lastCollect;

    mapping(address => uint256) public silver;
    mapping(address => uint256) public golden;

    /// @notice day number (UTC days since epoch) => RAW silver in that pot.
    /// @dev Raw, and it must stay raw: this is the number the day's emission is
    ///      computed from. The land bonus lives in potWeight instead, at the
    ///      bottom of this block. See deposit().
    mapping(uint256 => uint256) public potSilver;

    /// @notice day => wallet => that wallet's WEIGHTED stake in the day, zeroed
    ///         once claimed. Weighted means after the land bonus, so these add
    ///         up to potWeight rather than to potSilver.
    mapping(uint256 => mapping(address => uint256)) public potShare;

    /// @notice Every golden frog the pot has ever committed to, TODAY INCLUDED.
    /// @dev Kept as a running sum instead of counting days, because a day no
    ///      longer mints a flat 10,000 — it mints in proportion to what went
    ///      into it. Updated by the delta on every deposit, so reading the
    ///      outstanding supply stays one SLOAD and never walks a list of days.
    uint256 public goldenCommitted;

    /// @notice Per closed day, how much of its silver has been claimed against
    ///         and how many golden frogs that has paid out.
    /// @dev The pair exists so the LAST claimant of a day is paid the exact
    ///      remainder rather than a floored share. Without it every claim threw
    ///      away up to a wei of golden, and those wei stayed in the exchange
    ///      denominator for ever: frogs that existed for pricing and could
    ///      never be claimed or burned by anybody.
    mapping(uint256 => uint256) public shareClaimed;
    mapping(uint256 => uint256) public goldenClaimed;

    /// @notice Golden frogs destroyed by the exchange.
    uint256 public goldenBurned;

    mapping(address => uint256) public plotsOf;
    uint256 public totalPlots;
    mapping(address => address) public referrerOf;

    /// @notice day => the sum of every deposit that day AFTER the land bonus.
    /// @dev Two sums, and the split between them IS the safety of the land
    ///      bonus. potSilver above stays RAW and alone decides how many golden
    ///      frogs the day mints; this one decides only how that day is DIVIDED.
    ///      Put the bonus into the first number instead and land would print
    ///      money rather than move it: the day's mint is a straight function of
    ///      deposited silver (see _dayGolden), so a crowd holding land would
    ///      have minted up to a quarter more golden frogs a day out of nowhere,
    ///      against a treasury that does not grow with them. See deposit().
    ///
    ///      Declared at the END of the state block on purpose. Test rigs read
    ///      this contract's storage by slot number; anything inserted higher up
    ///      would move those slots and break them silently.
    mapping(uint256 => uint256) public potWeight;

    uint256 private _lock = 1;

    /* ====================================================================== */
    /*  Events and errors                                                      */
    /* ====================================================================== */

    event CityOpened(uint64 at);
    event SilverCollected(address indexed player, uint256 amount, uint256 frogCount);
    event SilverDeposited(address indexed player, uint256 indexed day, uint256 amount);
    event GoldenClaimed(address indexed player, uint256 indexed day, uint256 amount);
    event GoldenExchanged(
        address indexed player,
        uint256 goldenBurnedNow,
        address indexed asset,
        uint256 usdPaid,
        uint256 assetSent
    );
    /// @dev No dollar figure any more: this path does not know one, and a
    ///      contract that cannot compute a number must not log one.
    event LandBought(
        address indexed player,
        uint256 plots,
        uint256 memitoPaid,
        address indexed referrer,
        uint256 referrerPaid
    );
    event ReferrerSet(address indexed player, address indexed referrer);
    event Swept(address indexed asset, uint256 amount);
    event StrayFrogSold(uint256 indexed tokenId, address indexed buyer, uint256 memitoPaid);

    error Reentrancy();
    error CityClosed();
    error NothingToDo();
    error DayNotClosed();
    error NotEnoughGolden();
    error TooMuchGolden();
    error TooExpensive();
    error TooLittleOut();
    error BelowMinimum();
    error BadPlotCount();
    error PlotLimit();
    error TransferFailed();
    error ZeroAddress();
    error NotAContract();
    error BadWiring();
    error WrongToken();
    error ShortTransfer();
    error AssetNotAccepted();
    error NothingToSweep();
    error NotStray();
    error DrawInFlight();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address frogs_,
        address treasury_,
        address oracle_,
        address memito_,
        address ecosystem_
    ) {
        if (
            frogs_ == address(0) ||
            treasury_ == address(0) ||
            oracle_ == address(0) ||
            memito_ == address(0) ||
            ecosystem_ == address(0)
        ) revert ZeroAddress();

        // Checked before anything else, because this one is decided by a
        // copy-paste in the deploy script and costs a single comparison here.
        // Behind a NotAContract or a BadWiring it would have sent the deployer
        // looking at the wrong line.
        if (memito_ != MEMITO) revert WrongToken();

        // frogs_ is a predicted address and has no code yet — verifyWiring()
        // is what checks that one. The other three exist by now, and every one
        // of them is reached by a low-level call somewhere in this file, where
        // a codeless address would silently succeed and move nothing.
        if (
            treasury_.code.length == 0 ||
            oracle_.code.length == 0 ||
            memito_.code.length == 0
        ) revert NotAContract();

        // The treasury was born one transaction earlier holding a PREDICTED
        // address for this contract. If the deployer's nonce moved even once in
        // between, that prediction is wrong and the treasury would accept every
        // dollar of the sale and be unable to pay a single one back out — the
        // city is the only caller payOut accepts, and neither address can be
        // changed afterwards. Checking it here turns a silent, permanent, total
        // loss into a failed deploy transaction.
        if (ICityTreasury(treasury_).city() != address(this)) revert BadWiring();

        frogs = IMemitoFrogs(frogs_);
        treasury = ICityTreasury(treasury_);
        oracle = IPriceOracle(oracle_);
        memito = memito_;
        ecosystem = ecosystem_;
    }

    /// @notice Both neighbours must point back at this exact address. Anyone can
    ///         check it after deploy; if it returns false the nonce prediction
    ///         went wrong and the whole set must be redeployed, not patched.
    function verifyWiring() external view returns (bool frogsOk, bool treasuryOk) {
        frogsOk = frogs.city() == address(this);
        treasuryOk = treasury.city() == address(this);
    }

    /* ====================================================================== */
    /*  0. Opening day                                                         */
    /* ====================================================================== */

    /// @notice The second the city opened, or 0 if it has not.
    /// @dev The city opens when the FIRST thousand boxes reveal — not when the
    ///      sale starts and not when a given box is minted. Before that nothing
    ///      accrues to anybody and the pot does not run, so the buyer of box 1
    ///      and the buyer of box 999 begin in the same second and the earliest
    ///      buyers get no head start for having been early.
    function openedAt() public view returns (uint64) {
        uint64 t = cityOpenedAt;
        if (t != 0) return t;
        return frogs.cityOpensAt();
    }

    function isOpen() public view returns (bool) {
        return openedAt() != 0;
    }

    /// @dev Reads the opening second, caching it the first time it is non-zero.
    function _requireOpen() private returns (uint64 t) {
        t = cityOpenedAt;
        if (t == 0) {
            t = frogs.cityOpensAt();
            if (t == 0) revert CityClosed();
            cityOpenedAt = t;
            emit CityOpened(t);
        }
    }

    /* ====================================================================== */
    /*  1. Silver                                                              */
    /* ====================================================================== */

    /// @notice The current UTC day number. Unix time starts at 00:00 UTC, so
    ///         dividing by a day lands the boundary exactly at midnight UTC.
    function today() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice Silver produced over a frog's open window, in TWO segments.
    /// @param from       the second its clock starts from
    /// @param revealedAt the second its thousand opened, or 0 if still sealed
    /// @param production its true rate in basis points, 0 while sealed
    /// @dev This is the whole of change 5 and of EXPLOITS finding 3. A frog's
    ///      clock runs while its box is shut, and the box is worth the
    ///      collection average, x2.359, for exactly that stretch. Only the
    ///      stretch after its own reveal pays the frog's real rate. A single
    ///      rate applied to the whole window would let a Genesis holder sit on a
    ///      sealed box for a week and then cash the whole week at x100.
    function _silverFor(uint256 from, uint40 revealedAt, uint32 production, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        if (nowTs <= from) return 0;

        // The cap is a window, not a budget: only the last COLLECT_WINDOW
        // seconds before now are ever paid for.
        uint256 start = from;
        unchecked {
            if (nowTs - start > COLLECT_WINDOW) start = nowTs - COLLECT_WINDOW;
        }

        uint256 r = revealedAt; // 0 means "never opened"
        uint256 sealedSecs;
        uint256 openSecs;
        if (r == 0 || r >= nowTs) {
            sealedSecs = nowTs - start;
        } else if (r <= start) {
            openSecs = nowTs - start;
        } else {
            sealedSecs = r - start;
            openSecs = nowTs - r;
        }

        return
            (sealedSecs * SEALED_PRODUCTION_BP + openSecs * uint256(production)) *
            SILVER_PER_BP_PER_SECOND;
    }

    /// @notice Collect silver from frogs you own right now.
    /// @dev Production is read from the NFT contract, which derives it from the
    ///      sealed deck. Nothing off-chain can change what a frog earns, and
    ///      free starter frogs from the browser game are invisible here — this
    ///      loop can only ever see real ERC-721 tokens, so farming empty wallets
    ///      earns exactly nothing.
    function collect(uint256[] calldata tokenIds) public returns (uint256 gained) {
        uint64 open = _requireOpen();
        uint256 nowTs = block.timestamp;
        uint256 paid; // frogs that actually produced something in this call

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            // A frog that is not yours is skipped rather than reverted. A front
            // end hands in twenty ids at once, and one of them having been sold
            // between the quote and the block would otherwise throw away the
            // whole collection. Nothing is gained by the skip: a frog you do
            // not own pays you nothing either way.
            //
            // A token id that does not exist at all is skipped for the same
            // reason, and it needs the try: frogInfo REVERTS on an unknown id,
            // so a single mistyped or never-minted number used to take the
            // whole call down with it — including the retired slots a thousand
            // leaves behind when it closes early, which look like perfectly
            // ordinary ids from outside.
            address holder;
            uint40 born;
            uint32 production;
            uint40 revealedAt;
            try frogs.frogInfo(id) returns (address h, uint40 b, uint32, uint32 p, uint40 r) {
                (holder, born, production, revealedAt) = (h, b, p, r);
            } catch {
                continue;
            }
            if (holder != msg.sender) continue;

            uint256 from = lastCollect[id];
            if (from == 0) from = born;
            if (from < open) from = open; // nothing accrues before opening day

            uint256 got = _silverFor(from, revealedAt, production, nowTs);
            if (got == 0) continue; // repeated id in the same call: nothing left

            gained += got;
            lastCollect[id] = uint64(nowTs);
            unchecked {
                ++paid; // bounded by tokenIds.length
            }
        }

        if (gained != 0) silver[msg.sender] += gained;
        // The count is of frogs that PAID, not of ids handed in. Ids that are
        // not the caller's, ids that do not exist and ids repeated inside one
        // call are all skipped and pay nothing, so reporting the array length
        // made every number built on this log a measurement of what the front
        // end happened to batch rather than of the game.
        emit SilverCollected(msg.sender, gained, paid);
    }

    /// @notice What these frogs would pay out if collected this second,
    ///         whoever holds them.
    /// @dev Asks nothing about ownership, which is right for a LISTING page — a
    ///      buyer wants to know what is sitting on the card in front of him —
    ///      and wrong for a wallet page, where it adds a stranger's silver to
    ///      the reader's own and promises a number collect() will never pay. A
    ///      wallet must read pendingSilverOf().
    function pendingSilver(uint256[] calldata tokenIds) external view returns (uint256 total) {
        uint64 open = openedAt();
        if (open == 0) return 0;
        uint256 nowTs = block.timestamp;

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            try frogs.frogInfo(id) returns (address, uint40 born, uint32, uint32 production, uint40 revealedAt) {
                uint256 from = lastCollect[id];
                if (from == 0) from = born;
                if (from < open) from = open;
                total += _silverFor(from, revealedAt, production, nowTs);
            } catch {
                continue; // same rule as collect(): an unknown id is a zero
            }
        }
    }

    /// @notice What collect() would actually pay THIS player this second.
    /// @return total       silver that would land in their balance
    /// @return payingFrogs how many of the ids would pay anything — the same
    ///         number the SilverCollected event reports afterwards
    /// @dev The mirror of collect(), down to skipping ids that do not exist and
    ///      ids with nothing left on them. Without it a front end had only the
    ///      ownerless sum above, and a wallet screen built on that shows silver
    ///      the viewer cannot collect and will never receive: a frog they have
    ///      already sold, a frog they are only looking at, a whole page of
    ///      somebody else's money counted as theirs.
    ///
    ///      The wallet is NAMED rather than read from msg.sender, because this
    ///      is called through eth_call, where the sender is routinely unset — a
    ///      msg.sender check would answer zero for everybody instead, which is
    ///      the same lie from the other side.
    ///
    ///      Hand it DISTINCT ids. A view writes no clock, so an id repeated in
    ///      the list is counted every time it appears, where collect() pays it
    ///      once; the natural list — the ids a wallet holds — has no repeats.
    function pendingSilverOf(address player, uint256[] calldata tokenIds)
        external
        view
        returns (uint256 total, uint256 payingFrogs)
    {
        uint64 open = openedAt();
        if (open == 0) return (0, 0);
        uint256 nowTs = block.timestamp;

        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            try frogs.frogInfo(id) returns (
                address holder,
                uint40 born,
                uint32,
                uint32 production,
                uint40 revealedAt
            ) {
                if (holder != player) continue;
                uint256 from = lastCollect[id];
                if (from == 0) from = born;
                if (from < open) from = open;
                uint256 got = _silverFor(from, revealedAt, production, nowTs);
                if (got == 0) continue;
                total += got;
                unchecked {
                    ++payingFrogs; // bounded by tokenIds.length
                }
            } catch {
                continue; // same rule as collect(): an unknown id is a zero
            }
        }
    }

    /* ====================================================================== */
    /*  2. The daily pot                                                       */
    /* ====================================================================== */

    /// @notice The rate this wallet's deposits count at, in basis points:
    ///         10,000 is x1 and 12,500 is the ceiling.
    /// @dev SAY IT PLAINLY, because it is the whole economics of land: silver
    ///      is a SHARE of a fixed daily pot of golden frogs, so a bonus to one
    ///      player is ALWAYS taken out of the others. It is never printed. The
    ///      day mints exactly what it would have minted with no land in the
    ///      world (see deposit()), and land does not pay for itself either: at
    ///      a $200,000 treasury the entire daily pot is worth about $167 across
    ///      every player alive, and an ordinary wallet's share of the bonus is
    ///      pennies a day against $586 of land. Land buys a bigger slice and a
    ///      place in the city. It is not an income.
    ///
    ///      Why ten. Ten plots is MAX_PLOTS_PER_TX, so the whole bonus is one
    ///      transaction, once, for ever; it costs 144,613,624 MEMITO — about
    ///      $586 on listing day — which is the same order of money as the
    ///      twenty boxes a wallet is allowed to mint at all ($800). A ceiling
    ///      any committed player can reach makes the bonus fade to nothing as
    ///      people take it; a ceiling only a whale could reach would entrench
    ///      him for ever. Plots beyond the tenth still cost more and add
    ///      nothing, and that must be shown on the buying screen.
    ///
    ///      It cannot be bought cheaply by breaking the coin either. Land costs
    ///      a fixed number of MEMITO, so a crashed coin does make it cheaper in
    ///      dollars — but the prize is bounded by a CONSTANT, not by a price:
    ///      even land given away free adds at most a quarter to one wallet's
    ///      weight, the day still mints the same frogs, and the treasury is not
    ///      touched at all. A wallet already holding half of every deposit
    ///      takes 55.6% of the pot instead of 50% — about $9 a day, out of the
    ///      other players and out of nobody's vault.
    ///
    ///      Land cannot be sold, given away or unbought: plotsOf only ever
    ///      grows and no function moves it between wallets. The bonus belongs
    ///      to the wallet that paid for it and cannot be rented or lent.
    function silverBoostBp(address player) public view returns (uint256) {
        uint256 p = plotsOf[player];
        if (p > MAX_BOOSTED_PLOTS) p = MAX_BOOSTED_PLOTS;
        return 10000 + p * LAND_BOOST_BP_PER_PLOT;
    }

    /// @notice Push silver into today's pot. It is spent the moment it goes in;
    ///         there is no taking it back out.
    function deposit(uint256 amount) public {
        if (amount == 0) revert NothingToDo();
        _requireOpen();
        silver[msg.sender] -= amount; // underflow reverts, which is the check

        uint256 d = today();
        // What the day mints is a function of what is in it, so the running
        // total moves by the difference this deposit makes and nothing else.
        // A day nobody plays still mints nothing; a day one wallet plays with
        // one frog now mints one frog's worth instead of all ten thousand.
        uint256 pot = potSilver[d];
        uint256 grown = pot + amount;
        potSilver[d] = grown;
        goldenCommitted += _dayGolden(grown) - _dayGolden(pot);

        // Land speeds up the DIVISION of the day, never its size. The three
        // lines above are untouched by it on purpose: what the day MINTS is a
        // function of raw silver and nothing else, so a day everybody plays
        // with land mints the same ten thousand it always did.
        //
        // The bonus is read HERE, at the moment silver is spent, and NOT at
        // collect(). Read the next paragraph before assuming that buys any
        // safety, because an earlier draft of this comment claimed one it does
        // not have.
        //
        // WHAT THIS DOES NOT STOP. Borrowing frogs for a block still works:
        // the borrower calls collect() and deposit() himself, in one
        // transaction, so the silver lands on HIS balance and is spent at HIS
        // rate wherever the bonus is read. Measured: twenty borrowed frogs
        // deposited by a ten-plot wallet weigh 2,160,000 instead of 1,728,000
        // — the same +25% — and a full collect window is 3,024,000 of weight
        // moved in one transaction. Nor does spending-time reading stop a
        // wallet from earning a week of silver with no land at all and then
        // buying land immediately before the deposit. Both are the same act
        // seen twice, and no placement of this multiplication prevents either.
        //
        // WHY IT IS STILL HERE, AND WHY IT IS LEFT ALONE. All of that moves
        // SHARES between players inside one day; it mints nothing. The day's
        // ten thousand is a function of raw silver, which the bonus never
        // touches, so the treasury is not reachable through any of it. The
        // only real cure is per-frog weekly bookkeeping — permanent storage
        // and gas on every collect, in a contract nobody can ever repair, to
        // stop one wallet from taking a slightly larger slice of a pie whose
        // size does not change. The trade is not worth it. What matters is
        // that the comment says so instead of promising a guard that is not
        // in the code.
        uint256 weight = (amount * silverBoostBp(msg.sender)) / 10000;
        potWeight[d] += weight;
        potShare[d][msg.sender] += weight;

        // The RAW amount is logged: it is what left the wallet. A front end
        // that wants the weighted figure multiplies by silverBoostBp itself.
        emit SilverDeposited(msg.sender, d, amount);
    }

    /// @notice How many golden frogs a day mints, given the silver in its pot.
    function dayGolden(uint256 day) public view returns (uint256) {
        return _dayGolden(potSilver[day]);
    }

    /// @notice The same curve, for any pot size. For front ends and for proofs.
    function dayGoldenFor(uint256 pot) external pure returns (uint256) {
        return _dayGolden(pot);
    }

    function _dayGolden(uint256 pot) internal pure returns (uint256) {
        if (pot >= COLLECTION_DAY_SILVER) return GOLDEN_PER_DAY;
        return (GOLDEN_PER_DAY * pot) / COLLECTION_DAY_SILVER;
    }

    function collectAndDeposit(uint256[] calldata tokenIds) external returns (uint256 gained) {
        gained = collect(tokenIds);
        if (gained != 0) deposit(gained);
    }

    /// @notice Take your share of a closed day's golden frogs.
    /// @dev Paid out of the REMAINDER, not by flooring a fresh fraction each
    ///      time. Same share to the wei for everyone, and the last claimant of
    ///      a day takes exactly what is left, so a day never leaves behind
    ///      golden frogs that count in the exchange denominator and can never
    ///      be claimed or burned by anyone.
    function claim(uint256 day) public returns (uint256 amount) {
        if (day >= today()) revert DayNotClosed();
        uint256 share = potShare[day][msg.sender];
        if (share == 0) revert NothingToDo();
        potShare[day][msg.sender] = 0;

        uint256 claimedShare = shareClaimed[day];
        // Weights, not raw silver: every potShare written that day was written
        // weighted, and they add up to potWeight exactly as they used to add up
        // to potSilver — so the last claimant still takes the exact remainder
        // and a day never leaves an unclaimable wei of golden behind.
        uint256 remainingShare = potWeight[day] - claimedShare;
        uint256 remainingGolden = _dayGolden(potSilver[day]) - goldenClaimed[day];

        amount = (remainingGolden * share) / remainingShare;

        shareClaimed[day] = claimedShare + share;
        goldenClaimed[day] += amount;
        golden[msg.sender] += amount;
        emit GoldenClaimed(msg.sender, day, amount);
    }

    /// @notice Claim several closed days at once.
    /// @dev Days you have nothing in are skipped rather than reverted. A player
    ///      handing in a list built by a front end should not lose the whole
    ///      batch because one day in it was already claimed. A day that has not
    ///      closed yet is still a hard error — that is a mistake, not a
    ///      duplicate.
    function claimMany(uint256[] calldata days_) external returns (uint256 amount) {
        for (uint256 i = 0; i < days_.length; ++i) {
            uint256 day = days_[i];
            if (day >= today()) revert DayNotClosed();
            if (potShare[day][msg.sender] == 0) continue;
            amount += claim(day);
        }
        if (amount == 0) revert NothingToDo();
    }

    /// @notice Every golden frog that exists by right, claimed or not.
    /// @dev Counting unclaimed frogs is deliberate. If the rate were computed
    ///      only against claimed frogs, whoever cashed out first would drain a
    ///      share that belonged to players who had not pressed claim yet. Here
    ///      claiming changes nothing about the rate — only burning does.
    function totalGoldenOutstanding() public view returns (uint256) {
        // Today's pot is committed but has not closed, so its share is not real
        // yet and is taken back out of the running total.
        return goldenCommitted - _dayGolden(potSilver[today()]) - goldenBurned;
    }

    /// @notice The number the exchange actually divides by: outstanding golden
    ///         frogs, but never less than the floor.
    function goldenDenominator() public view returns (uint256) {
        uint256 outstanding = totalGoldenOutstanding();
        return outstanding < GOLDEN_FLOOR ? GOLDEN_FLOOR : outstanding;
    }

    /// @notice What one golden frog is worth right now, in USD (18 decimals).
    function goldenPriceUsd() public view returns (uint256) {
        return (treasury.totalValueUsd() * WAD) / goldenDenominator();
    }

    /* ====================================================================== */
    /*  3. The exchange — the only door money leaves by                        */
    /* ====================================================================== */

    /// @param amount      how many golden frogs to destroy
    /// @param asset       which coin to be paid in (address(0) = ETH)
    /// @param minAssetOut the least of that coin the player will accept. This
    ///        is the only door money leaves by, and the frogs are burned in
    ///        full whatever comes back, so it is the one place a moving price
    ///        cannot be undone. Every other value-moving function in the set
    ///        already takes a cap; this takes a floor for the same reason.
    ///        Pass 0 to accept anything.
    ///
    /// @dev Two guards beyond the price itself. The 12,000,000 floor under the
    ///      denominator stops the first closed day being worth the whole
    ///      treasury; the treasury's own 1%-a-day cap stops a bank run, and it
    ///      is enforced inside payOut, so it cannot be routed around from here.
    function exchange(uint256 amount, address asset, uint256 minAssetOut)
        external
        nonReentrant
        returns (uint256 usdPaid, uint256 assetSent)
    {
        if (amount == 0) revert NothingToDo();

        uint256 outstanding = totalGoldenOutstanding();
        if (amount > outstanding) revert TooMuchGolden();
        if (golden[msg.sender] < amount) revert NotEnoughGolden();

        uint256 denom = outstanding < GOLDEN_FLOOR ? GOLDEN_FLOOR : outstanding;
        uint256 treasuryUsd = treasury.totalValueUsd();
        uint256 usd = (treasuryUsd * amount) / denom;
        usdPaid = (usd * (10000 - EXCHANGE_FEE_BP)) / 10000;

        // The floor SCALES with the treasury instead of switching off below
        // twenty dollars. See _minPayoutUsd() for why, and for what it costs.
        if (usdPaid < _minPayoutUsd(treasuryUsd)) revert BelowMinimum();
        if (usdPaid == 0) revert NothingToDo();

        // Burn first, pay second. The frogs are destroyed in full while only
        // 98% of their value leaves.
        //
        // What that buys depends on which side of the floor the supply is on,
        // and the honest version is worth writing down because the marketing
        // copy gets taken from here. ABOVE the floor the denominator is the
        // real supply, burning shrinks it, and the rate for everyone left
        // genuinely ticks upward: p'/p = (N - 0.98g)/(N - g) > 1. UNDER the
        // floor the denominator is the constant 12,000,000, so burning does
        // not shrink it and the rate falls with the treasury — the fee makes
        // it fall 2% more slowly than a free withdrawal would, and no more
        // than that. The floor is expected to bind for roughly the first
        // 1,200 days, so for those years the fee is a brake, not a dividend.
        unchecked {
            golden[msg.sender] -= amount;
        }
        goldenBurned += amount;

        assetSent = treasury.payOut(msg.sender, asset, usdPaid);
        if (assetSent < minAssetOut) revert TooLittleOut();

        emit GoldenExchanged(msg.sender, amount, asset, usdPaid, assetSent);
    }

    /// @notice The smallest payout the exchange will process against a treasury
    ///         worth `treasuryUsd`.
    ///
    /// @dev The $20 floor is there so that nobody burns frogs for less than the
    ///      gas costs. It used to be switched OFF entirely once the treasury was
    ///      worth less than $20, because below that line no cash-out can reach
    ///      $20 and the last dollars would be welded in with no owner to unstick
    ///      them. Switching it off went too far. totalValueUsd() counts only
    ///      what can be PRICED, and a coin whose price source has ceased to
    ///      exist is written off and counted as nothing while its balance sits
    ///      in the treasury untouched — so one retired Chainlink feed is enough
    ///      to make a treasury holding two hundred thousand dollars read as
    ///      twelve, and with the floor gone entirely, one-wei cash-outs pay
    ///      fractions of a cent for a mainnet transaction. That is the exact
    ///      trade the floor was written to refuse, and it was open to everybody,
    ///      permanently, with nobody able to close it again.
    ///
    ///      So the floor stops being a fixed number of dollars and becomes a
    ///      fixed SHARE of what is left. Above $20 of countable value it is the
    ///      same $20 as before, to the wei, so nothing that ever bound has
    ///      moved. Below it, a cash-out must be worth at least a hundredth of
    ///      the whole treasury: dust never is, and a genuine last-days
    ///      withdrawal always is. Nothing can be welded in by this, because the
    ///      bar is a fraction of the money it guards — it falls as the treasury
    ///      falls and reaches zero with it, which is what the flat $20 could
    ///      never do.
    ///
    ///      The hundredth is not a new number: it is the treasury's own daily
    ///      door. And below $20 that door is floored at $25, which is more than
    ///      the whole treasury, so nothing this rule admits can be turned away
    ///      by the daily cap on the way out.
    function _minPayoutUsd(uint256 treasuryUsd) internal pure returns (uint256) {
        if (treasuryUsd >= MIN_EXCHANGE_USD) return MIN_EXCHANGE_USD;
        return (treasuryUsd * TAIL_EXCHANGE_BP) / 10000;
    }

    /// @notice The smallest number of golden frogs the exchange will take right
    ///         now. Front ends should quote this instead of guessing.
    /// @dev Quotes the floor that actually applies, the scaled one included.
    ///      Quoting a flat $20 against a spent treasury would send every player
    ///      an amount the exchange no longer asks for and the treasury could
    ///      never pay.
    ///
    ///      Both divisions are undone in the order exchange() does them and
    ///      rounded UP, because exchange() rounds down twice: once turning
    ///      frogs into dollars and once taking the fee. Inverting it in one
    ///      step, through a rate that had already been floored, quoted an
    ///      amount one wei of a dollar short of the floor — a quote the
    ///      exchange then refused, which is the one thing a quote must never
    ///      do.
    function minGoldenForExchange() external view returns (uint256) {
        uint256 treasuryUsd = treasury.totalValueUsd();
        if (treasuryUsd == 0) return type(uint256).max;

        // A wei is the target when the scaled floor rounds away to nothing:
        // exchange() refuses a payout of zero whatever the floor says.
        uint256 target = _minPayoutUsd(treasuryUsd);
        if (target == 0) target = 1;

        uint256 gross = (target * 10000 + (10000 - EXCHANGE_FEE_BP) - 1) / (10000 - EXCHANGE_FEE_BP);
        return (gross * goldenDenominator() + treasuryUsd - 1) / treasuryUsd;
    }

    /* ====================================================================== */
    /*  4. Land                                                                */
    /* ====================================================================== */

    /// @notice Price of the plot after `owned` plots, IN MEMITO (18 decimals).
    /// @dev Renamed from plotPrice() on purpose: it returns coins now, and a
    ///      front end still calling the old name must break loudly rather than
    ///      quietly draw a number wrong by a factor of a quarter of a million.
    function plotPriceMemito(uint256 owned) public pure returns (uint256) {
        uint256 x = (owned + 1) * WAD;
        uint256 p = _pow17(x); // x^1.7
        return PLOT_BASE_MEMITO + (p * PLOT_STEP_MEMITO) / WAD;
    }

    /// @notice What the next `count` plots would cost this wallet, in MEMITO.
    function landQuoteMemito(address buyer, uint256 count) public view returns (uint256 memitoDue) {
        uint256 owned = plotsOf[buyer];
        for (uint256 i = 0; i < count; ++i) memitoDue += plotPriceMemito(owned + i);
    }

    /// @param plots     how many to buy, up to MAX_PLOTS_PER_TX in one go
    /// @param referrer  only used the first time; ignored afterwards
    /// @param maxMemito the buyer's own cap. It no longer guards against a
    ///        moving oracle — there is none in this path — but it still guards
    ///        against a real race: a second purchase of your own, landing
    ///        first, moves you up the ladder.
    function buyLand(uint256 plots, address referrer, uint256 maxMemito)
        external
        nonReentrant
        returns (uint256 memitoPaid)
    {
        if (plots == 0 || plots > MAX_PLOTS_PER_TX) revert BadPlotCount();
        uint256 owned = plotsOf[msg.sender];
        if (owned + plots > MAX_PLOTS_PER_WALLET) revert PlotLimit();

        // The whole price, straight off the ladder: no oracle, no conversion,
        // and nothing anybody can move between the quote and the block. The
        // old zero-check is gone with it — the base of a plot is a non-zero
        // constant, so this sum cannot be zero.
        for (uint256 i = 0; i < plots; ++i) memitoPaid += plotPriceMemito(owned + i);
        if (memitoPaid > maxMemito) revert TooExpensive();

        _setReferrer(msg.sender, referrer);

        // ---- effects before any token moves ----
        plotsOf[msg.sender] = owned + plots;
        totalPlots += plots;

        uint256 toCity = (memitoPaid * LAND_CITY_BP) / 10000;
        uint256 toEco = memitoPaid - toCity;

        address ref = referrerOf[msg.sender];
        uint256 toRef = ref == address(0) ? 0 : (toEco * REFERRAL_BP_OF_ECO) / 10000;

        // Paid in the same transaction, straight from the buyer. Nothing is ever
        // parked in this contract, so there is no balance to go missing and
        // nobody has a claim button to press.
        _pull(address(treasury), toCity);
        if (toRef != 0) _pull(ref, toRef);
        _pull(ecosystem, toEco - toRef);

        emit LandBought(msg.sender, plots, memitoPaid, ref, toRef);
    }

    /// @dev Recorded once and never again. Rewriting it later would let anyone
    ///      re-point an existing player's rewards at themselves.
    function _setReferrer(address player, address referrer) private {
        if (referrer == address(0)) return;
        if (referrer == player) return; // self-referral is silently ignored
        if (referrerOf[player] != address(0)) return;
        referrerOf[player] = referrer;
        emit ReferrerSet(player, referrer);
    }

    /// @dev Measured, not assumed. The treasury already counts what LANDS on a
    ///      player rather than what it debited itself, and the way in has to
    ///      hold to the same standard. If the token ever skimmed a fee in
    ///      transit — USDT has carried that switch since 2017 and has never
    ///      thrown it — the treasury would receive less than half of every land
    ///      sale while the event, and every dashboard built on it, reported the
    ///      full amount. The players' half is what the golden frog rate is built
    ///      on, so that shortfall would price the game on money that is not
    ///      there, quietly, on every sale, with no owner to notice it later. A
    ///      purchase that fails is better than a split that lies.
    ///
    ///      A destination that is the payer itself is skipped rather than
    ///      measured: a self-transfer moves no balance, so there is no delta to
    ///      read and nothing that could have been skimmed.
    function _pull(address to, uint256 amount) private {
        if (amount == 0) return;
        bool measure = to != msg.sender;
        uint256 held = measure ? IERC20(memito).balanceOf(to) : 0;

        (bool ok, bytes memory data) = memito.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();

        if (measure && IERC20(memito).balanceOf(to) < held + amount) revert ShortTransfer();
    }

    /* ====================================================================== */
    /*  5. Things that landed here by mistake                                  */
    /* ====================================================================== */

    /// @notice Push a stray balance sitting on this contract into the treasury,
    ///         where it becomes part of what backs a golden frog. Anyone may
    ///         call it.
    /// @param asset one of the six the treasury takes; address(0) for ETH
    ///
    /// @dev Nothing is ever supposed to be held here. Land money is pulled out
    ///      of the buyer's wallet straight to its three destinations inside one
    ///      call, a cash-out is paid by the treasury straight to the player, and
    ///      silver and golden are numbers in mappings rather than balances. Not
    ///      one function in this file is payable either, so ETH can only arrive
    ///      by force — a selfdestruct or a block reward. Whatever is found here
    ///      is therefore somebody's misdirected transfer, there is no legitimate
    ///      holding for this to touch by accident, and this contract's address
    ///      is the one players read off the screen every day.
    ///
    ///      A rescue, not a withdrawal, and the difference is that there is
    ///      nothing here to decide: the destination is not an argument, there is
    ///      exactly one of it, it belongs to nobody, and the caller is paid
    ///      NOTHING. That last part is what keeps this from becoming the door
    ///      the audit warned about. A finder's fee would turn "send it to the
    ///      city contract to stake it" into a trade with a profit in it, aimed
    ///      at the one address every player already has in front of them; with
    ///      no fee the rescue is worth exactly the gas it costs and there is
    ///      nobody worth luring.
    ///
    ///      Only coins the treasury actually takes can be moved. A foreign token
    ///      is every bit as stuck in the treasury as it is here — totalValueUsd
    ///      walks the six and nothing else — so sweeping one would carry it from
    ///      one graveyard to another while letting any passer-by make this
    ///      contract call an address of their choosing.
    function sweepToTreasury(address asset) external nonReentrant returns (uint256 amount) {
        // MEMITO is not one of the treasury's five, because nobody can price
        // it, and that is exactly why this clause has to be here. The treasury
        // is where land money already goes and where the game's coin is meant
        // to end up; a coin nobody can value is no more stuck there than it is
        // here, with the one difference that HERE it sits on the address
        // players hand tokens to every day. Without this line a fumbled
        // transfer would be lost for good, and there is nobody who could ever
        // unstick it.
        if (asset != memito && !treasury.isAccepted(asset)) revert AssetNotAccepted();
        address to = address(treasury);

        if (asset == address(0)) {
            amount = address(this).balance;
            if (amount == 0) revert NothingToSweep();
            (bool sent, ) = payable(to).call{value: amount}("");
            if (!sent) revert TransferFailed();
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            if (amount == 0) revert NothingToSweep();
            (bool ok, bytes memory data) = asset.call(
                abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
            );
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }

        emit Swept(asset, amount);
    }

    /// @notice What a frog stranded on this contract costs to buy out, IN
    ///         MEMITO. Renamed from strayFrogPriceUsd for the same reason
    ///         plotPrice was: the unit changed, so the name must too.
    function strayFrogPriceMemito(uint256 tokenId) external view returns (uint256) {
        (, , , uint32 production, ) = frogs.frogInfo(tokenId);
        return _strayPriceMemito(production);
    }

    /// @dev The unit price scaled by what the card produces, so an average card
    ///      costs exactly one box and a Genesis — a hundred times the baseline
    ///      against a collection average of 2.359 — is not sold for one. A card
    ///      still inside a sealed thousand is priced at the sealed average,
    ///      which is precisely what it earns. Both numbers are constants and
    ///      there is nobody who can tune either.
    function _strayPriceMemito(uint32 production) private pure returns (uint256) {
        uint256 bp = production == 0 ? SEALED_PRODUCTION_BP : uint256(production);
        return (AVERAGE_FROG_MEMITO * bp) / SEALED_PRODUCTION_BP;
    }

    /// @notice Buy a frog that was transferred onto this contract by mistake.
    ///         The whole price goes to the treasury — but see below: the
    ///         treasury cannot value MEMITO, so this is a burn, not a payment.
    /// @dev BE PRECISE ABOUT WHERE THIS MONEY GOES. An earlier version of this
    ///      line said the players are paid for the frog. They are not. The
    ///      price is denominated in MEMITO, and MEMITO is deliberately absent
    ///      from the treasury's five assets: it is this project's own coin,
    ///      its price would have to come from a pool anyone can shove, and one
    ///      manipulable number in the backing put the whole vault within reach
    ///      of rented capital. So MEMITO arriving here is counted at zero,
    ///      cannot be paid out, and cannot be swept — nobody, including the
    ///      founder, has a function that moves it. Every coin spent on a
    ///      stranded frog leaves circulation for good. That is a burn that
    ///      lifts the coin for everyone holding it, and it is a fair thing to
    ///      do with an accident, but it is not backing and must never be sold
    ///      as backing.
    /// @param maxMemito the buyer's own slippage cap, exactly as buyLand takes
    ///
    /// @dev A frog can only land here by a plain transferFrom: this contract
    ///      never asks for one, is never approved for one, and a safe transfer
    ///      already reverts because there is no receiver hook to answer it. Once
    ///      it has landed it is worse off than burned — it stays alive and keeps
    ///      making silver by the second, and no wallet on earth can collect that
    ///      silver or move the card again.
    ///
    ///      It is SOLD rather than handed to whoever asks first, and that is the
    ///      whole of the design. A free rescue reads as generous and is not: it
    ///      turns every fumbled transfer into a race won by the fastest bot and
    ///      hands a Genesis to whoever watches the mempool hardest. A price paid
    ///      to the treasury makes it a purchase instead — the person who fumbled
    ///      can buy their own card back at the price everybody else must pay,
    ///      and whoever ends up with it, the players were paid for it. If the
    ///      price suits nobody the frog simply stays where it is, which is the
    ///      outcome without this function at all: a rescue nobody takes leaves
    ///      nobody worse off than no rescue.
    ///
    ///      No branch of this can reach a frog that is not already sitting on
    ///      this contract, so it is not a door onto anybody's collection.
    ///
    ///      Frozen while that thousand has a draw in flight, for the same reason
    ///      the market is frozen then: for those few blocks the random word sits
    ///      in the public mempool and anyone can work out which sealed card is
    ///      the Genesis, so the sealed-average price would be a gift.
    function buyStrayFrog(uint256 tokenId, uint256 maxMemito)
        external
        nonReentrant
        returns (uint256 memitoPaid)
    {
        (address holder, , , uint32 production, ) = frogs.frogInfo(tokenId);
        if (holder != address(this)) revert NotStray();
        if (frogs.revealPending(tokenId)) revert DrawInFlight();

        memitoPaid = _strayPriceMemito(production);
        if (memitoPaid > maxMemito) revert TooExpensive();

        _pull(address(treasury), memitoPaid);
        frogs.transferFrom(address(this), msg.sender, tokenId);

        emit StrayFrogSold(tokenId, msg.sender, memitoPaid);
    }

    /* ====================================================================== */
    /*  Fixed-point powers, built from square roots only                       */
    /* ====================================================================== */

    /// @dev x^1.7 = x * x^0.7, both in 1e18 fixed point.
    function _pow17(uint256 x) internal pure returns (uint256) {
        return (x * _pow07(x)) / WAD;
    }

    /// @dev 0.7 written as a binary fraction with 32 bits: round(0.7 * 2^32).
    ///      0.7 in binary is 0.1011001100110011..., which is why this is a
    ///      constant and not a division.
    uint256 private constant FRAC_07_Q32 = 3_006_477_107;

    /// @dev x^0.7 with no logarithm tables and no magic polynomial constants.
    ///      x^(1/2^i) is just i square roots of x, so raising to a binary
    ///      fraction is: take the square root, and multiply in whenever the
    ///      corresponding bit of the exponent is set. Every line of this is
    ///      checkable by hand, which is the point — a mispasted PRBMath
    ///      constant would silently reprice the entire land ladder.
    function _pow07(uint256 x) internal pure returns (uint256 r) {
        r = WAD;
        uint256 s = x;
        for (uint256 i = 1; i <= 32; ++i) {
            s = _sqrtWad(s); // s = x^(1/2^i)
            if (((FRAC_07_Q32 >> (32 - i)) & 1) == 1) {
                r = (r * s) / WAD;
            }
            if (s == WAD) break; // converged to 1.0; every later factor is 1.0
        }
    }

    function _sqrtWad(uint256 a) internal pure returns (uint256) {
        return _sqrt(a * WAD);
    }

    /// @dev Integer square root, floored. Newton from a power-of-two estimate;
    ///      seven iterations always suffice for a uint256.
    function _sqrt(uint256 a) internal pure returns (uint256 z) {
        if (a == 0) return 0;

        uint256 xx = a;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x4) {
            r <<= 1;
        }

        unchecked {
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            r = (r + a / r) >> 1;
            uint256 r1 = a / r;
            z = r < r1 ? r : r1;
        }
    }
}
