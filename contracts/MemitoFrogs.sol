// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";
import {SSTORE2} from "./SSTORE2.sol";
import {Base64} from "./Base64.sol";

/* -------------------------------------------------------------------------- */
/*  Minimal external interfaces, written out so the file flattens cleanly       */
/* -------------------------------------------------------------------------- */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Chainlink VRF v2.5 **direct funding** wrapper. The caller pays for the
///      randomness in ETH, in the same transaction, and there is no
///      subscription for anyone to keep topped up or to close.
interface IVRFV2PlusWrapper {
    /// @notice What one request costs right now, paid in native ETH. Depends on
    ///         tx.gasprice, so it must be read inside the paying transaction.
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords)
        external
        view
        returns (uint256);

    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/* -------------------------------------------------------------------------- */

/// @title MemitoFrogs — MEMELAND CLUB CITY, 10,000 sealed boxes
/// @notice An ERC-721 whose metadata is not hosted anywhere. The name, the tier,
///         the production rate and the edition number of every frog are computed
///         by this contract from two frozen tables, and handed back as a data:
///         URI. Only the pictures live off-chain, on IPFS, addressed by content
///         hash — so nobody, including us, can swap a dragon for a plain frog.
///
///         What is sold is a box, not a picture. The shuffled deck is published
///         (its hash is baked in at deploy) before a single box is sold, and the
///         link between a token number and a deck position is a random offset
///         drawn from Chainlink VRF, one draw per thousand boxes. Until a
///         thousand is closed and its offset is drawn, nobody — buyer, bot or
///         deployer — can tell what is inside any box in it.
///
/// @dev THERE IS NO OWNER. Not a renounced one, not a zero one: the concept does
///      not appear in this file. Everything an admin would once have done is a
///      permissionless function whose CONDITION is checked in code:
///
///        * loadDeck / loadDesigns — anyone may call them, and they only accept
///          bytes whose keccak256 matches the commit frozen at deploy. Wrong
///          data is rejected on the spot, so there is nothing to grief.
///        * seal() — anyone may call it. It re-checks both commits against what
///          was actually stored and then validates the CONTENT of both tables.
///        * the sale opens by itself at `saleStart`, a timestamp fixed at
///          deploy. There is no pause and no close button: the sale ends when
///          the last box is sold.
///        * requestReveal(batch) — anyone may call it, and the caller pays
///          Chainlink in ETH in that same transaction. A batch is revealable
///          when it is FULL, or when it has gone long enough WITHOUT ONE OF
///          ITS BOXES SELLING — a stretch priced by how many boxes closing it
///          would strike off — or a year after its first box whatever the
///          trickle. Nobody can fire it early and nobody can block it. And a
///          revealed thousand can never be sold out of again, because its
///          remaining cards would be face up.
///        * armFallbackReveal / fallbackReveal — if a request was actually put
///          to Chainlink and thirty days later there is still no answer,
///          anyone may draw the offset from sixteen future block hashes, ONE
///          BIT each, instead. It opens on a recorded failure and never on a
///          date, and it is the only thing standing between a dead VRF wrapper
///          and a treasury that can never be opened.
contract MemitoFrogs {

    /* ====================================================================== */
    /*  Collection shape                                                       */
    /* ====================================================================== */

    string public constant name = "MEMELAND CLUB CITY";
    string public constant symbol = "FROG";

    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant BATCH_SIZE = 1_000;
    uint256 public constant BATCHES = 10;
    uint256 public constant DESIGN_COUNT = 150;

    /// @notice Twenty boxes, per wallet, forever.
    /// @dev Per ADDRESS, which is the only thing a contract can count. It
    ///      spreads the collection and stops one transaction taking a whole
    ///      batch; it does not stop a determined buyer from using twenty
    ///      wallets, and nothing on-chain can.
    uint256 public constant MAX_PER_WALLET = 20;

    /// @notice One price for the whole sale, the same in every coin: $40, paid
    ///         in ETH, USDT, USDC, DAI or WBTC.
    /// @dev MEMITO is not a way to pay for a box any more, and the door is shut
    ///      by a single question mint() already asked — oracle.supportsAsset —
    ///      rather than by a new rule here. Its price came out of the one
    ///      Uniswap pool this game trades in, and rented money holding that pool
    ///      for half an hour bought the ENTIRE sale for a fifteenth of the
    ///      sticker; three rounds of repairs each broke from a new side.
    ///
    ///      Nothing is lost at the till. The MEMITO discount was already gone,
    ///      and paying in MEMITO was measured as the WORST door anyway
    ///      ($806.71 against $800 in USDC), because the buyer first has to buy
    ///      the coin on the pool and pay its 0.3% fee and his own slippage.
    ///      MEMITO keeps its own demand, and a harder one: land can be bought
    ///      with nothing else.
    uint256 public constant PRICE_USD = 40e18;

    /// @notice Half of every box to the city treasury.
    uint256 public constant BP_TREASURY = 5000;

    /// @dev Documentation only. The ecosystem is paid the REMAINDER of the sale
    ///      after the treasury, so rounding dust rides along with it instead of
    ///      being stranded in this contract.
    uint256 public constant BP_ECOSYSTEM = 5000;

    uint96 public constant ROYALTY_BP = 500; // 5% secondary, split 3/2 downstream

    address public constant MEMITO = 0xe02AD79732658a2ec2C85Ecd15De5E08A311373C;

    /// @notice IPFS folder holding 001.jpg .. 150.jpg
    string public constant IMAGE_CID = "bafybeiezpqkgemb6md3kkhrbc2ostzj4eo2hjesx5qdebdcqu6gcromy64";

    /// @notice The picture every unrevealed box shows.
    string public constant SEALED_CID = "bafybeictddri5qlyybszq7fwf3dsen3tiwfq2r7jepaf5hwnrgzg77vav4";

    /* ---- print runs and production, indexed by tier 0..4 ---------------- */
    /*  60 common x100, 50 rare x60, 30 legendary x30, 9 mythic x10,
        1 genesis x10  ->  6000+3000+900+90+10 = exactly 10,000            */

    function _printRun(uint8 tier) internal pure returns (uint256) {
        if (tier == 0) return 100;
        if (tier == 1) return 60;
        if (tier == 2) return 30;
        return 10; // mythic and genesis are both printed 10 times
    }

    /// @notice Silver production, in basis points of the x1 baseline.
    function _productionBp(uint8 tier) internal pure returns (uint32) {
        if (tier == 0) return 10_000; // x1
        if (tier == 1) return 25_000; // x2.5
        if (tier == 2) return 75_000; // x7.5
        if (tier == 3) return 260_000; // x26
        return 1_000_000; // x100
    }

    /// @notice What a box produces while it is still sealed: the COLLECTION
    ///         AVERAGE, x2.359.
    /// @dev 6000x1 + 3000x2.5 + 900x7.5 + 90x26 + 10x100 = 23,590 weighted
    ///      points across 10,000 cards, so the average card is x2.359 and the
    ///      collection produces exactly the same total whether it is open or
    ///      shut. A sealed box therefore neither subsidises nor is subsidised
    ///      by the revealed ones, and stalling a reveal gains nothing.
    ///
    ///      The city pays this rate for the SEALED stretch of a frog's clock and
    ///      the frog's true rate for the stretch after its own reveal — two
    ///      segments, never one rate applied backwards. That is what stops
    ///      silver being banked while sealed and cashed at a Genesis rate later.
    uint32 public constant SEALED_PRODUCTION_BP = 23_590;

    function _tierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return "Common";
        if (tier == 1) return "Rare";
        if (tier == 2) return "Legendary";
        if (tier == 3) return "Mythic";
        return "Genesis";
    }

    function _productionLabel(uint8 tier) internal pure returns (string memory) {
        if (tier == 0) return "x1";
        if (tier == 1) return "x2.5";
        if (tier == 2) return "x7.5";
        if (tier == 3) return "x26";
        return "x100";
    }

    /* ====================================================================== */
    /*  Frozen wiring                                                          */
    /* ====================================================================== */

    address payable public immutable treasury; // CityTreasury
    address public immutable city; // MemelandCity, kept so the pairing is checkable
    address payable public immutable ecosystem; // founder wallet
    IPriceOracle public immutable oracle;
    address public immutable royaltyReceiver; // RoyaltySplitter

    /// @notice Chainlink VRF v2.5 direct-funding wrapper. No subscription.
    address public immutable vrfWrapper;

    /// @notice The second the sale opens itself. Fixed at deploy, and the only
    ///         schedule this contract has: after it, boxes sell until the last
    ///         one is gone.
    uint64 public immutable saleStart;

    uint32 public constant VRF_CALLBACK_GAS = 200_000;

    /// @notice The most this contract will ever pay Chainlink for one draw.
    /// @dev Not a budget — a refusal detector. A wrapper that answers "one
    ///      thousand ether" to the price question has refused the request in a
    ///      way no revert would show, and without a ceiling nobody could ever
    ///      pay it, so nothing would go on record and the rescue would have no
    ///      door. Four thousand gwei of gas price is far past anything the
    ///      chain has seen, so no honest quote is ever refused by this.
    uint256 public constant VRF_SANE_PRICE = 2 ether;
    uint16 public constant VRF_CONFIRMATIONS = 3;

    /// @notice keccak256 of the exact 10,000-byte deck. Published before the
    ///         sale opened; loadDeck refuses anything else.
    bytes32 public immutable deckCommit;

    /// @notice keccak256 of the 150 x 32-byte design table.
    bytes32 public immutable designsCommit;

    /* ====================================================================== */
    /*  Storage                                                                */
    /* ====================================================================== */

    /// @dev One slot per token holds three things that are written together on
    ///      every transfer anyway, so packing them is free:
    ///        bits   0..159  owner
    ///        bits 160..199  mint timestamp (uint40, good until year 36812)
    ///        bits 200..231  transfer counter (uint32)
    ///      The mint timestamp is what lets the city start a frog's silver clock
    ///      at the second it was born instead of handing every new frog a free
    ///      week. The counter is what lets the marketplace tell a live listing
    ///      from one whose token has moved since.
    mapping(uint256 => uint256) private _packed;

    uint256 private constant OWNER_MASK = (1 << 160) - 1;
    uint256 private constant TIME_SHIFT = 160;
    uint256 private constant TIME_MASK = (1 << 40) - 1;
    uint256 private constant SEQ_SHIFT = 200;
    uint256 private constant SEQ_MASK = (1 << 32) - 1;

    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApproval;
    mapping(address => mapping(address => bool)) private _operatorApproval;

    /// @notice The sale cursor: how many box slots have been used up. A slot is
    ///         used either by being SOLD or by being RETIRED with its thousand.
    /// @dev Boxes come out strictly in order, so this doubles as "the id of the
    ///      last box handed out". It stopped being the same thing as the supply
    ///      the moment a thousand could close with boxes still on its shelf —
    ///      see _retireBatch. Use totalSupply() for how many frogs exist.
    uint256 public totalMinted;

    /// @notice How many boxes were actually sold. Never counts a retired slot.
    uint256 public boxesSold;

    /// @notice Slots of a thousand that were never sold because the thousand
    ///         closed early. Written once, when the thousand's draw starts.
    mapping(uint256 => uint256) public batchRetired;

    mapping(address => uint256) public boxesBought;

    /* ---- the deck and the design table ---------------------------------- */

    uint256 public constant DESIGN_RECORD_BYTES = 32; // 1 tier byte + 31 name bytes
    uint256 public constant DESIGNS_BYTES = DESIGN_COUNT * DESIGN_RECORD_BYTES; // 4,800

    /// @notice The whole 10,000-byte deck, stored as the code of one tiny
    ///         contract (SSTORE2). 10,001 bytes of runtime code, comfortably
    ///         under the 24,576-byte limit.
    address public deckPtr;
    address public designsPtr;
    bool public dataSealed;

    /* ---- reveal ---------------------------------------------------------- */

    /// @dev offset + 1, so that 0 unambiguously means "not revealed yet".
    mapping(uint256 => uint256) private _batchOffsetPlus1;

    /// @notice When the first box of each thousand was sold.
    mapping(uint256 => uint64) public batchOpenedAt;

    /// @notice When the LAST box of each thousand was sold. The quiet
    ///         deadline counts from here, not from the batch's first box.
    /// @dev Counting from the FIRST box was the worst hole in the previous
    ///      revision. A thousand that had not sold out in seven days revealed
    ///      anyway while its remaining boxes were still on the shelf — and a
    ///      published offset plus the public deck turns every unsold box in
    ///      that thousand into a card whose face is known before it is bought.
    ///      Counting from the last sale means the deadline can only fire on a
    ///      thousand that nobody is buying from any more, which is the only
    ///      case it was ever written for.
    mapping(uint256 => uint64) public batchLastSaleAt;

    /// @notice When each thousand actually revealed. The city splits accrual at
    ///         this second; the marketplace kills sealed-era listings past it.
    mapping(uint256 => uint64) public batchRevealedAt;

    mapping(uint256 => uint256) public batchRequestedAt;

    /// @notice The second Chainlink first gave this thousand trouble: either
    ///         the second a request was first put to it, or the second it was
    ///         first caught refusing to take one. Zero means it has never been
    ///         asked. This is the ONLY clock the last-resort draw runs on.
    /// @dev It is written once and never rewound. That is the whole of it:
    ///      the old gates counted from the thousand's LAST SALE, and a last
    ///      sale is a thing anybody can rewrite for the price of one box, so
    ///      one box a month held the rescue shut for ever — city closed,
    ///      treasury door closed, nothing to press and nobody to press it.
    ///      Re-requesting cannot rewind it either, which was the other way to
    ///      hold the door: ask again every few weeks for a couple of dollars
    ///      and the "asked and ignored" clock never finished. Nothing resets
    ///      it and nobody can set it early — the only way to start it is to
    ///      actually put a request to Chainlink, and a healthy Chainlink
    ///      answers that in minutes and reveals the thousand honestly.
    mapping(uint256 => uint64) public vrfTroubleAt;

    /// @dev requestId => (second it was asked for << 16) | (batch + 1). The
    ///      timestamp rides along because a fulfilment has to be able to tell
    ///      how old its own request is: past REREQUEST_DELAY the market has
    ///      already been let go, so an answer arriving then must be dropped
    ///      rather than allowed to open a thousand that is trading freely.
    mapping(uint256 => uint256) private _requestBatchPlus1;

    /// @notice The floor of the quiet clock: what a thousand with nothing left
    ///         on its shelf must go without a sale before it may be closed.
    /// @dev A flat week was the most expensive number in this file. Waves of
    ///      sales with pauses longer than a week are what a launch looks like,
    ///      not what a dead sale looks like — and the button that closes a
    ///      thousand STRIKES OFF its unsold shelf, for ever, with no owner
    ///      anywhere to undo it. On a seven-day clock a passer-by needed no
    ///      boxes of his own: buyers open each thousand for him, and one press
    ///      a week ends the lot of them. Up to 9,900 boxes that were going to
    ///      be sold, for the price of ten gas fees.
    uint256 public constant REVEAL_QUIET_MIN = 14 days;

    /// @notice The ceiling of the same clock: what a thousand that is almost
    ///         entirely unsold must go without a sale instead.
    /// @dev The wait is priced by what closing the thousand would destroy, and
    ///      that is what keeps the two requirements from fighting. A thousand
    ///      nobody has bought from in a month and a half is a dead sale by any
    ///      reading. A thousand with fifty boxes left is one a fortnight of
    ///      silence already settles — and the nearly-finished thousands are
    ///      exactly the ones people are waiting on, because everything
    ///      downstream hangs off batch zero opening. See revealQuietPeriod.
    uint256 public constant REVEAL_QUIET_MAX = 45 days;

    /// @notice The outer bound. However the boxes trickle, a thousand may be
    ///         revealed once this long has passed since its first box was sold.
    /// @dev A year, not ninety days. The quiet clock above is restarted by
    ///      every sale, so this exists only to stop one wallet holding a
    ///      thousand — and, for batch zero, the city and the treasury door —
    ///      shut for ever by buying a single box now and then. Ninety days was
    ///      too short for that job: it fired on thousands that were still
    ///      selling briskly and struck off whatever was left of them, which is
    ///      the same wound the quiet clock had. A year cannot fire on a sale
    ///      that is really moving — a thousand boxes take less than that, or
    ///      the sale goes quiet and the clock above settles it.
    uint256 public constant REVEAL_HARD_DEADLINE = 365 days;

    /// @notice If VRF never answers, anyone may ask again after this long.
    /// @dev Long, on purpose. Chainlink answers in minutes. The only thing a
    ///      short delay buys is two live requests at once — and then two
    ///      different valid offsets exist at the same time and whichever
    ///      fulfillment lands first wins, which is an ordering a block builder
    ///      can be paid for.
    uint256 public constant REREQUEST_DELAY = 24 hours;

    /// @notice If VRF has been silent this long on a batch that is ready to be
    ///         revealed, a fallback draw opens up. See armFallbackReveal.
    /// @dev The one thing direct funding cannot rule out: a wrapper that is
    ///      retired, paused or simply never answers. Without a way out, batch 0
    ///      never reveals, the city never opens, and every dollar the players
    ///      paid sits in the treasury with no door — no owner, no rescue, and
    ///      nothing to press. Thirty days is far longer than any real Chainlink
    ///      outage and short enough that the money is not gone.
    uint256 public constant VRF_GIVEUP = 30 days;

    /// @notice How many future blocks the fallback draw is built from, ONE
    ///         BIT EACH. See fallbackReveal for why the width of a block's
    ///         contribution is the whole of this design.
    /// @dev Sixteen bits, and sixteen blocks, because a block's proposer can
    ///      write his own block's hash to order — the header carries 32 free
    ///      bytes and rewriting them costs him nothing — so whatever he is
    ///      allowed to contribute, he contributes deliberately. Chaining the
    ///      hashes handed the LAST proposer the entire answer: he saw the
    ///      first fifteen, ground his own header until the result was the one
    ///      he wanted, and that took a few thousand tries off chain. One bit
    ///      each caps him at a choice between two outcomes, and the man who
    ///      holds j of the last consecutive slots at 2^j. Sixteen bits is
    ///      65,536 seeds, which mod a thousand is uniform to a part in a
    ///      thousand, and the wait is the same three minutes it was.
    uint256 public constant FALLBACK_BLOCKS = 16;

    /// @notice How long an armed fallback stays usable, in blocks. Must stay
    ///         well inside the 256-block window BLOCKHASH can see.
    /// @dev Sixty-four, not two hundred. From block seventeen the offset is
    ///      plain arithmetic over public block hashes, while our own
    ///      marketplace and the box sale are honestly shut and every other
    ///      venue goes on trading that frog at the price of a sealed box. Two
    ///      hundred blocks meant up to 184 of them — some thirty-seven
    ///      minutes — of a card that is face up everywhere except here; sixty-
    ///      four meant forty-eight. Forty means twenty-four, under five
    ///      minutes, and still leaves sixteen paid blocks for a stranger to
    ///      collect the bounty in. The oldest hash the draw needs is then
    ///      thirty-nine blocks old against a limit of two hundred and fifty-six.
    uint256 public constant FALLBACK_WINDOW = 40;

    /// @notice Blocks after arming during which finishing pays no finder's fee.
    /// @dev The bounty was a tax on the honest rescuer, not only a fine on the
    ///      grinder. fallbackReveal takes one number, keeps no secret and is
    ///      computable by anybody from block seventeen, so an armer's own
    ///      finishing transaction was copied out of the mempool and resubmitted
    ///      at a higher tip: the bot took a quarter of a stake it had done
    ///      nothing to earn, and an honest arming cost 0.0125 ETH instead of
    ///      gas. Inside this stretch the fee is zero, so there is nothing to
    ///      snipe and the armer finishes his own draw for gas. Past it the
    ///      bounty is back in full, which is all the anti-grinding argument
    ///      ever needed: abandoning a draw still means censoring every
    ///      remaining block of the window against anybody who wants the money.
    uint256 public constant FALLBACK_GRACE = 24;

    /// @notice The stake an arming caller puts up, and gets back by finishing.
    /// @dev The whole point of the bond is that walking away from a started
    ///      draw has a price. See armFallbackReveal for why grinding is dead
    ///      even without it, and why the bond is nonetheless here.
    uint256 public constant FALLBACK_BOND = 0.05 ether;

    /// @dev Each abandoned attempt on a batch doubles the next bond, capped at
    ///      sixteen times the base. Capped because an uncapped ladder is itself
    ///      an attack: burn a few bonds, and the price of the next honest
    ///      attempt climbs past what anyone will pay, which locks the treasury
    ///      exactly as surely as no fallback at all.
    uint256 public constant FALLBACK_MAX_DOUBLINGS = 4;

    /// @notice The share of the bond paid to whoever WRITES the offset, when
    ///         that is not the armer who posted it.
    /// @dev This is the answer to grinding, and it is the only one that works.
    ///      Reading the drawn offset is free and public, so "throw this roll
    ///      away" never cost an attacker a transaction — it cost him silence,
    ///      and silence was free because the contract paid nobody to spend gas
    ///      finishing another man's draw. It climbs with the ladder, so the
    ///      more a grinder re-arms the more he pays the people who stop him.
    ///
    ///      HALF, not a quarter, and the reason is arithmetic rather than
    ///      taste. Writing the offset costs about 121,000 gas, so a quarter of
    ///      the base bond stopped covering it at roughly 100 gwei — and gas
    ///      above 100 gwei is an ordinary bad hour on this chain, not a freak
    ///      event. In that hour nobody finishes an abandoned draw, and a free
    ///      re-roll is exactly what the bond was bought to prevent. Half moves
    ///      that line past 200 gwei. It costs the honest armer nothing, because
    ///      FALLBACK_GRACE leaves him alone to finish his own draw for gas; the
    ///      only man who ever pays it is the one who armed a draw and then
    ///      would not write down what it said.
    uint256 public constant FALLBACK_FINDER_BP = 5000;

    /// @notice The state of a batch's fallback draw. One slot.
    /// @param armer       who armed it and who gets the bond back
    /// @param armedBlock  the block it was armed in, 0 if not armed
    /// @param forfeits    abandoned attempts on this batch so far
    struct Fallback {
        address armer; //     160
        uint64 armedBlock; //  64
        uint8 forfeits; //      8
    }

    mapping(uint256 => Fallback) public fallbacks;



    /* ---- reentrancy ------------------------------------------------------ */

    uint256 private _lock = 1;

    /* ====================================================================== */
    /*  Events and errors                                                      */
    /* ====================================================================== */

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event BoxesBought(
        address indexed buyer,
        uint256 quantity,
        address indexed asset,
        uint256 paid,
        uint256 firstTokenId
    );
    event BatchOpened(uint256 indexed batch, uint256 firstTokenId, uint64 at);
    event RevealRequested(uint256 indexed batch, uint256 requestId, address indexed payer, uint256 feePaid);
    event BatchRevealed(uint256 indexed batch, uint256 offset, uint256 requestId);
    event FallbackArmed(uint256 indexed batch, address indexed armer, uint256 armedAtBlock, uint256 bond);
    event VrfRefused(uint256 indexed batch, address indexed by);
    event FallbackForfeited(uint256 indexed batch, address indexed armer, uint256 bond);
    event FallbackRevealed(uint256 indexed batch, uint256 offset);
    event FallbackFinderPaid(uint256 indexed batch, address indexed finder, uint256 amount);
    event ForfeitSwept(uint256 amount);
    event BatchRetired(uint256 indexed batch, uint256 boxesSoldInBatch);
    event DeckLoaded(address pointer);
    event DesignsLoaded(address pointer);
    event DataSealed(bytes32 deckHash, bytes32 designsHash);

    error Reentrancy();
    error SaleNotOpen();
    error NotSealed();
    error AlreadySealed();
    error AlreadyLoaded();
    error NotLoaded();
    error BadQuantity();
    error SoldOut();
    error WalletLimit();
    error AssetNotAccepted();
    error TooExpensive();
    error NotEnoughEth();
    error NoEthExpected();
    error TransferFailed();
    error NoToken();
    error NotAuthorized();
    error WrongRecipient();
    error ZeroAddress();
    error BadBatch();
    error BatchNotOpen();
    error BatchNotClosed();
    error AlreadyRevealed();
    error BatchAlreadyOpened();
    error FallbackNotDue();
    error FallbackNotArmed();
    error FallbackNotRipe();
    error FallbackExpired();
    error TooSoon();
    error RevealInFlight();
    error NothingToSweep();
    error NotEnoughGas();
    error CommitMismatch();
    error OnlyWrapper();
    error BadDeck();
    error BadDesigns();
    error CannotReceiveEth();

    /// @dev Guards the functions that move money and hand tokens in or out.
    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /* ====================================================================== */

    /// @param saleStart_ unix second the sale opens itself. No pause, no close.
    constructor(
        address treasury_,
        address city_,
        address ecosystem_,
        address oracle_,
        address royaltyReceiver_,
        address vrfWrapper_,
        uint64 saleStart_,
        bytes32 deckCommit_,
        bytes32 designsCommit_
    ) {
        if (
            treasury_ == address(0) ||
            city_ == address(0) ||
            ecosystem_ == address(0) ||
            oracle_ == address(0) ||
            royaltyReceiver_ == address(0) ||
            vrfWrapper_ == address(0)
        ) revert ZeroAddress();

        treasury = payable(treasury_);
        city = city_;
        ecosystem = payable(ecosystem_);
        oracle = IPriceOracle(oracle_);
        royaltyReceiver = royaltyReceiver_;

        vrfWrapper = vrfWrapper_;
        saleStart = saleStart_;

        deckCommit = deckCommit_;
        designsCommit = designsCommit_;

        // The two addresses an ETH box sale pays. Both are immutable and both
        // are paid with a low-level call that reverts the whole mint if it
        // fails — so one of them being a contract that cannot take ETH would
        // kill every ETH sale permanently, with nothing to change. A zero-value
        // call reaches receive()/fallback() and fails on a contract that has
        // neither, which is exactly the case worth catching. An EOA passes.
        _requireAcceptsEth(treasury_);
        _requireAcceptsEth(ecosystem_);
    }

    function _requireAcceptsEth(address to) private {
        (bool ok, ) = to.call{value: 0}("");
        if (!ok) revert CannotReceiveEth();
    }

    /* ====================================================================== */
    /*  Loading the tables — permissionless, and guarded by the commits        */
    /* ====================================================================== */

    /// @notice Upload the shuffled deck: exactly 10,000 bytes, one design id
    ///         (0..149) per position.
    /// @dev Anyone may call this. There is nothing to trust and nothing to
    ///      grief: the only bytes this function accepts are bytes whose
    ///      keccak256 equals `deckCommit`, which was frozen at deploy and
    ///      published before a box was sold. Wrong data reverts, right data is
    ///      right data whoever sends it.
    ///
    ///      Not a constructor argument because 10,000 bytes plus the contract
    ///      code will not fit comfortably in one deployment. Stored once, as the
    ///      runtime code of a throwaway contract: 200 gas a byte instead of
    ///      20,000 a slot.
    function loadDeck(bytes calldata deck) external {
        if (dataSealed) revert AlreadySealed();
        if (deckPtr != address(0)) revert AlreadyLoaded();
        if (deck.length != MAX_SUPPLY) revert BadDeck();
        if (keccak256(deck) != deckCommit) revert CommitMismatch();
        address p = SSTORE2.write(deck);
        deckPtr = p;
        emit DeckLoaded(p);
    }

    /// @notice Upload the 150 design records: 1 tier byte + 31 name bytes each.
    ///         Same rule — the commit decides, not the caller.
    function loadDesigns(bytes calldata blob) external {
        if (dataSealed) revert AlreadySealed();
        if (designsPtr != address(0)) revert AlreadyLoaded();
        if (blob.length != DESIGNS_BYTES) revert BadDesigns();
        if (keccak256(blob) != designsCommit) revert CommitMismatch();
        address p = SSTORE2.write(blob);
        designsPtr = p;
        emit DesignsLoaded(p);
    }

    /// @notice Check both tables against the hashes baked in at deploy, check
    ///         that what they contain is actually a valid collection, and
    ///         freeze them. Selling cannot start before this succeeds, and
    ///         nothing can be loaded after it. Anyone may call it.
    ///
    /// @dev The hashes prove the tables are UNCHANGED. They prove nothing about
    ///      whether they are CORRECT — a commit is only ever a hash of whatever
    ///      blob the deployer chose. So the contents are checked here too, once.
    ///      Without this a single stray byte would seal cleanly and then
    ///      permanently brick the frog that landed on it: tokenURI reverts, and
    ///      so does the city's collect() for the whole array that token appears
    ///      in. And nothing would tie the advertised rarity to the deck at all.
    ///
    ///      The hashes are re-checked here against what was actually STORED, not
    ///      against what was passed to the loader — cheap, and it proves the
    ///      SSTORE2 round trip.
    function seal() external {
        if (dataSealed) revert AlreadySealed();
        if (deckPtr == address(0) || designsPtr == address(0)) revert NotLoaded();

        bytes memory deck = _deckBytes(MAX_SUPPLY);
        bytes32 dHash = keccak256(deck);
        bytes32 gHash = keccak256(SSTORE2.read(designsPtr, 0, DESIGNS_BYTES));
        if (dHash != deckCommit || gHash != designsCommit) revert CommitMismatch();

        uint8[DESIGN_COUNT] memory tiers = _validateDesigns();
        _validateDeck(deck, tiers);

        dataSealed = true;
        emit DataSealed(dHash, gHash);
    }

    /// @dev Every design record must be readable by _design() and printable by
    ///      tokenURI(), and the 150 designs must be split across the tiers the
    ///      collection advertises.
    function _validateDesigns() private view returns (uint8[DESIGN_COUNT] memory tiers) {
        uint256[5] memory designsPerTier;

        for (uint256 d = 0; d < DESIGN_COUNT; ++d) {
            bytes32 rec = SSTORE2.readWord(designsPtr, d);

            uint8 tier = uint8(rec[0]);
            if (tier > 4) revert BadDesigns();
            if (rec[1] == 0) revert BadDesigns(); // a nameless card renders as "MEMITO - "

            for (uint256 i = 1; i < DESIGN_RECORD_BYTES; ++i) {
                uint8 c = uint8(rec[i]);
                if (c == 0) continue; // NUL padding, and anything after it
                // The name is dropped into the JSON of tokenURI unescaped. A
                // quote or a backslash there produces metadata no marketplace
                // can parse, on every copy of that design, forever.
                if (c < 0x20 || c > 0x7E || c == 0x22 || c == 0x5C) revert BadDesigns();
            }

            tiers[d] = tier;
            unchecked { ++designsPerTier[tier]; }
        }

        // 60 common, 50 rare, 30 legendary, 9 mythic, 1 genesis.
        if (
            designsPerTier[0] != 60 ||
            designsPerTier[1] != 50 ||
            designsPerTier[2] != 30 ||
            designsPerTier[3] != 9 ||
            designsPerTier[4] != 1
        ) revert BadDesigns();
    }

    /// @dev The deck is checked one THOUSAND at a time, and every thousand must
    ///      contain exactly a tenth of every print run: 10 copies of each
    ///      common, 6 of each rare, 3 of each legendary, 1 of each mythic, 1
    ///      Genesis. Each print run divides by ten exactly, so this is the same
    ///      collection either way — it just also fixes the one thing the batch
    ///      reveal cannot hide.
    ///
    ///      A batch draws only from its own slice of the deck, and the deck is
    ///      public from the moment it is loaded. Without this check anyone could
    ///      read off which thousands hold the Genesis and which hold none, and
    ///      since boxes are minted strictly in order, buyers would simply refuse
    ///      the barren thousands and the sale would stall on the first one.
    ///      Same $40 box, publicly unequal odds. Balanced, every thousand is the
    ///      same lottery and the offset is the only unknown — which is exactly
    ///      what the sealed box is sold as.
    ///
    ///      Summing to 10,000 with the right print runs falls out of this for
    ///      free, so it is not checked separately.
    function _validateDeck(bytes memory deck, uint8[DESIGN_COUNT] memory tiers) private pure {
        // How many copies of each design one thousand must hold. Every print
        // run divides by ten exactly, so these are whole numbers: 10 / 6 / 3 / 1.
        uint256[DESIGN_COUNT] memory want;
        for (uint256 d = 0; d < DESIGN_COUNT; ++d) want[d] = _printRun(tiers[d]) / BATCHES;

        uint256[DESIGN_COUNT] memory count;
        uint256 deckPtrMem;
        assembly { deckPtrMem := add(deck, 32) }

        for (uint256 b = 0; b < BATCHES; ++b) {
            for (uint256 d = 0; d < DESIGN_COUNT; ++d) count[d] = 0;

            uint256 start = b * BATCH_SIZE;
            for (uint256 i = 0; i < BATCH_SIZE; ++i) {
                uint256 designId;
                // deck[start + i], without re-checking a bound the loop already
                // guarantees. 10,000 of these run, so it is worth the two lines.
                assembly { designId := byte(0, mload(add(deckPtrMem, add(start, i)))) }
                if (designId >= DESIGN_COUNT) revert BadDeck();
                unchecked { ++count[designId]; }
            }

            for (uint256 d = 0; d < DESIGN_COUNT; ++d) {
                if (count[d] != want[d]) revert BadDeck();
            }
        }
    }

    /* ====================================================================== */
    /*  Buying a box                                                           */
    /* ====================================================================== */

    /// @notice True once the sale has opened itself, and while there is still a
    ///         box that can be sold. Nobody opens it and nobody can hold it shut.
    /// @dev Boxes come out in order, so the only thousand that matters is the
    ///      one the cursor is standing in. It is never a revealed thousand and
    ///      never one with a draw in flight, because starting a draw retires
    ///      the thousand and moves the cursor to the next one — which is how a
    ///      quiet thousand closes WITHOUT closing the collection.
    function saleOpen() public view returns (bool) {
        if (!dataSealed || block.timestamp < saleStart || totalMinted >= MAX_SUPPLY) return false;
        uint256 b = totalMinted / BATCH_SIZE;
        return _batchOffsetPlus1[b] == 0 && !batchDrawInFlight(b);
    }

    /// @notice How many boxes of a thousand were actually sold before it closed.
    function batchSold(uint256 batch) public view returns (uint256) {
        uint256 first = batch * BATCH_SIZE;
        if (totalMinted <= first) return 0;
        uint256 end = totalMinted - first;
        if (end > BATCH_SIZE) end = BATCH_SIZE;
        uint256 retired = batchRetired[batch];
        return end - retired;
    }

    /// @param qty       how many boxes
    /// @param asset     address(0) for ETH, otherwise USDT / USDC / DAI / WBTC
    /// @param maxAmount the most of that coin the buyer will part with. This is
    ///                  the buyer's own guard against the price moving between
    ///                  pressing the button and landing in a block.
    function mint(uint256 qty, address asset, uint256 maxAmount)
        external
        payable
        nonReentrant
        returns (uint256 firstTokenId, uint256 paid)
    {
        if (!dataSealed) revert NotSealed();
        if (block.timestamp < saleStart) revert SaleNotOpen();
        if (qty == 0) revert BadQuantity();
        if (!oracle.supportsAsset(asset)) revert AssetNotAccepted();

        uint256 minted = totalMinted;
        if (minted + qty > MAX_SUPPLY) revert SoldOut();

        uint256 already = boxesBought[msg.sender];
        if (already + qty > MAX_PER_WALLET) revert WalletLimit();

        paid = oracle.assetAmount(asset, PRICE_USD * qty);
        if (paid == 0) revert BadQuantity();
        if (paid > maxAmount) revert TooExpensive();

        // ---- every state change happens before any coin moves --------------
        totalMinted = minted + qty;
        boxesSold += qty;
        boxesBought[msg.sender] = already + qty;
        firstTokenId = minted + 1;

        // Stamp the clocks of every thousand this mint reaches into. qty is at
        // most 20, so this touches one batch or two.
        //
        // A REVEALED thousand is refused here, and that refusal is the whole of
        // the reveal-snipe fix. Once a batch's offset is public, the deck —
        // which has been public since loadDeck — says exactly which card every
        // remaining token of that thousand holds. Selling those tokens as
        // sealed boxes would be selling a face-up card at lottery-ticket
        // prices, and since boxes are minted strictly in order the buyer would
        // simply be whoever is watching. Boxes are only ever sold out of a
        // thousand that is still shut.
        //
        // A thousand with a DRAW IN FLIGHT is refused for the same reason one
        // block later. The fulfilment transaction carries the random word in
        // plain calldata and sits in the public mempool before it lands, and an
        // armed fallback is public from the moment its sixteen blocks are
        // mined; either way somebody knows the offset before the contract does.
        // Selling sealed boxes across that window is selling face-up cards.
        // Both windows are the same predicate, batchDrawInFlight().
        {
            uint256 firstBatch = minted / BATCH_SIZE;
            uint256 lastBatch = (minted + qty - 1) / BATCH_SIZE;
            for (uint256 b = firstBatch; b <= lastBatch; ++b) {
                if (_batchOffsetPlus1[b] != 0) revert BatchAlreadyOpened();
                if (batchDrawInFlight(b)) revert RevealInFlight();
                if (batchOpenedAt[b] == 0) {
                    batchOpenedAt[b] = uint64(block.timestamp);
                    emit BatchOpened(b, b * BATCH_SIZE + 1, uint64(block.timestamp));
                }
                // Restarts that thousand's quiet clock. See revealQuietPeriod.
                batchLastSaleAt[b] = uint64(block.timestamp);
            }
        }

        _balanceOf[msg.sender] += qty;
        uint256 stamp = (block.timestamp & TIME_MASK) << TIME_SHIFT;
        for (uint256 i = 0; i < qty; ++i) {
            uint256 id = firstTokenId + i;
            _packed[id] = uint256(uint160(msg.sender)) | stamp;
            emit Transfer(address(0), msg.sender, id);
        }

        _settle(asset, paid);

        emit BoxesBought(msg.sender, qty, asset, paid, firstTokenId);
    }

    /// @dev Split 50 / 50 and push it straight out. This contract never holds
    ///      sale money for even one block, and neither half waits for anybody to
    ///      press a claim button.
    ///
    ///      There used to be a third slice for liquidity, and paying in MEMITO
    ///      burned it. Both are gone: the MEMITO token already sends 30% of
    ///      every presale purchase to the pool by itself, so the boxes were
    ///      paying for liquidity twice. Every currency now splits the same way.
    function _settle(address asset, uint256 paid) private {
        uint256 toTreasury = (paid * BP_TREASURY) / 10000;
        uint256 toEcosystem = paid - toTreasury; // dust rides along here

        if (asset == address(0)) {
            if (msg.value < paid) revert NotEnoughEth();
            _sendEth(treasury, toTreasury);
            _sendEth(ecosystem, toEcosystem);
            unchecked {
                uint256 refund = msg.value - paid;
                if (refund != 0) _sendEth(payable(msg.sender), refund);
            }
        } else {
            if (msg.value != 0) revert NoEthExpected();
            _pull(asset, treasury, toTreasury);
            _pull(asset, ecosystem, toEcosystem);
        }
    }

    function _sendEth(address payable to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev USDT on Ethereum returns no bool at all. Decoding blindly reverts on
    ///      it, which is the single most common way a hand-written sale dies.
    ///      And an address with NO CODE would answer that call with a plain
    ///      success and move nothing at all, which is a free box. The oracle's
    ///      allow-list already rules that out on mainnet; this is the belt,
    ///      because there is no patch after deploy.
    function _pull(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token.code.length == 0) revert TransferFailed();
        uint256 before = IERC20(token).balanceOf(to);
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        // What ARRIVED, not what the token said it moved — the same
        // measurement the paying side of this set already makes. A coin that
        // keeps a slice of every transfer (USDT has carried that switch,
        // unused, since 2017) would otherwise short the treasury and the
        // ecosystem on every single box while BoxesBought went on reporting the
        // full price: silently, for ever, with no owner to reprice anything and
        // nothing to patch. A box costs forty dollars, and a buyer who
        // delivered thirty-six did not buy one, so this refuses rather than
        // quietly under-fund the frog everybody else already paid for. It
        // refuses only the asset that turned a fee on; ETH and the other five
        // are untouched, so no door closes.
        if (IERC20(token).balanceOf(to) - before < amount) revert TransferFailed();
    }

    /* ====================================================================== */
    /*  Reveal — one VRF draw per thousand, paid for by whoever asks           */
    /* ====================================================================== */

    /// @notice What one reveal request costs right now, in wei.
    /// @dev Chainlink prices a direct-funding request off tx.gasprice, so this
    ///      is only exact inside a transaction sent at the same gas price. Send
    ///      more than this; the surplus comes straight back in the same call.
    function revealFee() public view returns (uint256) {
        return IVRFV2PlusWrapper(vrfWrapper).calculateRequestPriceNative(VRF_CALLBACK_GAS, 1);
    }

    /// @notice True when `batch` may be revealed this second.
    /// @dev Three ways in, and every one of them means the same thing: no more
    ///      boxes of this thousand are going to be sold.
    ///        * FULL — all thousand are gone.
    ///        * QUIET — a stretch with no box of it selling at all, priced
    ///          by what closing it would destroy. See revealQuietPeriod.
    ///        * HARD — a year since its first box, whatever the trickle.
    ///      A thousand that is still selling is never revealed, because the
    ///      first thing either draw does is RETIRE the thousand — its unsold
    ///      slots are struck off and the sale steps to the next thousand. So
    ///      the published offset can never be read off the deck by the next
    ///      buyer, and closing one thousand early no longer closes the sale.
    ///      "Full" below means the cursor has left this thousand, which covers
    ///      both a sell-out and a retirement.
    function revealReady(uint256 batch) public view returns (bool) {
        if (batch >= BATCHES || !dataSealed) return false;
        if (_batchOffsetPlus1[batch] != 0) return false;
        uint256 opened = batchOpenedAt[batch];
        if (opened == 0) return false;
        if (totalMinted >= (batch + 1) * BATCH_SIZE) return true;
        if (block.timestamp >= uint256(batchLastSaleAt[batch]) + revealQuietPeriod(batch)) return true;
        return block.timestamp >= opened + REVEAL_HARD_DEADLINE;
    }

    /// @notice How long this thousand must go without a single sale before its
    ///         unsold remainder may be struck off. A function of the loss, not
    ///         a constant.
    /// @dev A fortnight when there is almost nothing left to destroy, six and a
    ///      half weeks when nine hundred boxes are still on the shelf. That
    ///      shape is what stops the two requirements fighting each other. The
    ///      more of a thousand has been bought, the more people are waiting for
    ///      it to open and the less closing it costs — so the sooner it
    ///      closes; and the emptier it is, the more a stranger's press would
    ///      destroy — so the longer he has to wait to be believed. Nobody can
    ///      shorten this except by BUYING the boxes, which is the sale itself.
    ///
    ///      batchSold() is the right measure on both sides of a closure: while
    ///      the thousand is still selling it counts what has been bought, and
    ///      once it is retired the retired slots are subtracted, so the period
    ///      FREEZES at the value it closed on instead of drifting afterwards.
    function revealQuietPeriod(uint256 batch) public view returns (uint256) {
        uint256 unsold = BATCH_SIZE - batchSold(batch);
        return REVEAL_QUIET_MIN + ((REVEAL_QUIET_MAX - REVEAL_QUIET_MIN) * unsold) / BATCH_SIZE;
    }

    /// @notice Draw the offset of a thousand. Anyone may call it and the caller
    ///         pays Chainlink in ETH in this same transaction.
    ///
    /// @dev There is no subscription behind this. Nobody has a LINK balance to
    ///      keep topped up, nobody can remove this contract from a consumer
    ///      list, and nobody can close the account that pays — so nobody can
    ///      stop a batch from being revealed. And nobody can fire one early:
    ///      the condition is checked here, not granted by an address.
    ///
    ///      Overpay freely. The exact price is read from the wrapper inside this
    ///      call, exactly that much is forwarded, and the rest is sent back to
    ///      the caller before the function returns.
    function requestReveal(uint256 batch)
        external
        payable
        nonReentrant
        returns (uint256 requestId)
    {
        if (batch >= BATCHES) revert BadBatch();
        if (!dataSealed) revert NotSealed();
        if (_batchOffsetPlus1[batch] != 0) revert AlreadyRevealed();

        if (batchOpenedAt[batch] == 0) revert BatchNotOpen();
        // One source of truth for "this thousand is finished". The three flags
        // that used to live here said the same thing in different words, and a
        // contract that can never be patched must not be able to drift.
        if (!revealReady(batch)) revert BatchNotClosed();

        // A fallback draw whose window is still live is not overtaken from
        // here, and this line is what stops a re-roll being bought instead of
        // paid for. From the seventeenth block the drawn offset is public
        // arithmetic, and a paid answer now WINS over an armed draw — so
        // without this, a man who disliked what the sixteen blocks said would
        // simply order a fresh number from Chainlink and take whichever landed
        // first, for a few dollars instead of a forfeited bond. Behind this
        // line his only moves are the two he always had: write it, or abandon
        // it and pay. It fails open: the window is forty blocks, after which a
        // request goes through exactly as before, so nothing here can freeze
        // the honest path. Re-arming to hold this shut costs a doubling bond
        // every eight minutes and is finishable by any passer-by for a bounty.
        uint256 armedAt = fallbacks[batch].armedBlock;
        if (armedAt != 0 && block.number <= armedAt + FALLBACK_WINDOW) revert RevealInFlight();

        uint256 last = batchRequestedAt[batch];
        if (last != 0 && block.timestamp - last < REREQUEST_DELAY) revert TooSoon();

        // The clock the rescue runs on starts HERE, on the first ask, and is
        // never rewound by a later one. See vrfTroubleAt.
        if (vrfTroubleAt[batch] == 0) vrfTroubleAt[batch] = uint64(block.timestamp);

        // A failure is only believed when the wrapper was given room to
        // succeed. Without this a caller could hand the call too little gas,
        // watch it die of starvation and forge himself a dead-Chainlink mark.
        if (gasleft() < 1_400_000) revert NotEnoughGas();

        // From this second on, no more boxes of this thousand are sold. If it
        // was not full, the leftovers are retired and the cursor steps to the
        // next thousand — the sale carries on there instead of ending.
        _retireBatch(batch);

        // Both wrapper calls are raw and gas-capped, and a refusal is WRITTEN
        // DOWN rather than bubbled out. This is what replaced a six-month
        // calendar. A wrapper that is retired, gone, or quoting a price nobody
        // would pay is the catastrophe the last-resort draw exists for, and
        // the old code let that catastrophe revert this function — so nothing
        // could ever be put on record and the only door left was a date. Now
        // the failure itself leaves a dated mark, any passer-by can put it
        // there, and no owner and no calendar is involved. A wrapper whose
        // code is gone answers a plain call with success and no data, which is
        // why the returndata length is checked and not just the success flag.
        (bool okQuote, bytes memory quote) = vrfWrapper.staticcall{gas: 200_000}(
            abi.encodeWithSelector(
                IVRFV2PlusWrapper.calculateRequestPriceNative.selector,
                VRF_CALLBACK_GAS,
                uint32(1)
            )
        );
        uint256 price = (okQuote && quote.length >= 32)
            ? abi.decode(quote, (uint256))
            : type(uint256).max;
        // A quote above the sane ceiling is a refusal wearing a price tag: it
        // cannot be paid, so no request can ever go on record behind it.
        if (price > VRF_SANE_PRICE) {
            emit VrfRefused(batch, msg.sender);
            if (msg.value != 0) _sendEth(payable(msg.sender), msg.value);
            return 0;
        }
        if (msg.value < price) revert NotEnoughEth();

        (bool okAsk, bytes memory ret) = vrfWrapper.call{value: price, gas: 1_000_000}(
            abi.encodeWithSelector(
                IVRFV2PlusWrapper.requestRandomWordsInNative.selector,
                VRF_CALLBACK_GAS,
                VRF_CONFIRMATIONS,
                uint32(1),
                // ExtraArgsV1{ nativePayment: true } — the caller pays in ETH.
                abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)
            )
        );
        if (!okAsk || ret.length < 32) {
            emit VrfRefused(batch, msg.sender);
            if (msg.value != 0) _sendEth(payable(msg.sender), msg.value);
            return 0;
        }
        requestId = abi.decode(ret, (uint256));

        batchRequestedAt[batch] = block.timestamp;
        _requestBatchPlus1[requestId] = (block.timestamp << 16) | (batch + 1);
        emit RevealRequested(batch, requestId, msg.sender, price);

        unchecked {
            uint256 refund = msg.value - price;
            if (refund != 0) _sendEth(payable(msg.sender), refund);
        }
    }

    /// @dev The wrapper's callback. It must never revert: a reverting consumer
    ///      loses the randomness, so unknown or duplicate requests are ignored
    ///      quietly instead. First answer wins, which is why re-requesting is
    ///      harmless — nobody can cancel a pending draw to fish for a nicer one.
    ///
    ///      An answer OLDER than REREQUEST_DELAY is dropped, and that is not a
    ///      nicety. The trading freeze on a thousand fails open at exactly that
    ///      age, so that a wrapper which never answers cannot lock a thousand's
    ///      market for good. Without this check the request stayed alive behind
    ///      the reopened market: a fulfilment landing in hour 25, or a month
    ///      later, would open the pack while its frogs were listed and buyable
    ///      at sealed prices — the very trade the freeze exists to stop. The
    ///      freeze and the request now expire in the same second. Anyone may
    ///      re-request from that second, and a fresh request re-arms both.
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != vrfWrapper) revert OnlyWrapper();

        uint256 packed = _requestBatchPlus1[requestId];
        if (packed == 0) return;
        delete _requestBatchPlus1[requestId];

        uint256 b1 = packed & 0xFFFF;
        if (block.timestamp - (packed >> 16) >= REREQUEST_DELAY) return;

        uint256 batch = b1 - 1;
        if (_batchOffsetPlus1[batch] != 0) return;
        if (randomWords.length == 0) return;

        uint256 offset = randomWords[0] % BATCH_SIZE;
        _batchOffsetPlus1[batch] = offset + 1;
        batchRevealedAt[batch] = uint64(block.timestamp);
        emit BatchRevealed(batch, offset, requestId);

        // A PAID ANSWER BEATS THE CHAIN'S OWN DICE, even one already armed and
        // waiting. It used to be the other way round — an answer landing under
        // a live window was thrown away — because the arming record would
        // otherwise stand over a revealed thousand and the armer's stake would
        // be stranded as abandoned money. So do both at once: write the answer
        // and hand the stake straight back. That is what the old shape could
        // not do, and it cost the man who PAID Chainlink his fee while handing
        // the draw to block hashes; with the rescue clock no longer rewound by
        // a fresh request, that collision is buildable, so it is closed here
        // rather than argued about. Only a LIVE window is refunded: past it the
        // bond is already forfeit and may already have gone to the players, and
        // paying it again would be paying it out of somebody else's stake. The
        // send is gas-capped and unchecked on purpose — this callback must
        // never revert, and a bond nobody will take is swept to the players.
        Fallback memory f = fallbacks[batch];
        if (f.armedBlock != 0 && block.number <= uint256(f.armedBlock) + FALLBACK_WINDOW) {
            delete fallbacks[batch];
            (bool ok, ) = payable(f.armer).call{value: _bondFor(f.forfeits), gas: 30_000}("");
            ok; // deliberately unchecked — see above
        }
    }

    /* ---------------------------------------------------------------------- */
    /*  The way out if Chainlink stops answering                               */
    /* ---------------------------------------------------------------------- */

    /// @notice Retire whatever is left of a thousand whose draw has just begun,
    ///         and step the sale on to the next thousand.
    /// @dev The old code had no such thing, and that was the most expensive
    ///      line in the file: revealing a thousand that had not sold out ended
    ///      the WHOLE collection's sale, permanently, because `mint` refuses a
    ///      revealed thousand and boxes come out in order. One quiet spell on
    ///      batch 0 and a stranger's three dollars of gas closed nine thousand
    ///      unsold boxes forever, with nobody able to reopen them.
    ///
    ///      Now the thousand closes and only the thousand. Its unsold slots are
    ///      retired — those boxes are never minted and their deck positions
    ///      stay empty — and the cursor moves to the first box of the next
    ///      thousand, which sells on exactly as before. Supply ends up smaller
    ///      than 10,000; nothing else changes.
    function _retireBatch(uint256 batch) private {
        uint256 cursor = totalMinted;
        if (cursor / BATCH_SIZE != batch) return; // the sale has already moved on
        uint256 end = (batch + 1) * BATCH_SIZE;
        uint256 unsold = end - cursor;
        if (unsold == 0) return;
        batchRetired[batch] = unsold;
        totalMinted = end;
        emit BatchRetired(batch, cursor - batch * BATCH_SIZE);
    }

    /// @notice True when the last-resort draw may be armed for `batch`.
    /// @dev ONE condition, and it is neither a calendar nor a thing a player
    ///      can move: this thousand was put to Chainlink at least a month ago
    ///      and is still not open. There used to be three doors and every one
    ///      of them was wrong in the same way — they counted from a DATE.
    ///
    ///        * Thirty days from the thousand's last sale, which any buyer
    ///          rewrote for the price of one box: one box a month and the
    ///          rescue never came due, so a dead Chainlink meant the city and
    ///          the treasury were shut for good with nothing to press.
    ///
    ///        * Six months from the last sale asking for no evidence at all,
    ///          which handed the weak draw to anybody patient enough to buy a
    ///          single box of the last thousand and wait, with Chainlink in
    ///          perfect health the whole time.
    ///
    ///      Now the only way in is through an ask that was actually made and
    ///      was not answered. Starting that clock is free and open to anybody,
    ///      it cannot be started early, and it cannot be rewound — but a
    ///      healthy Chainlink answers the ask in minutes and opens the thousand
    ///      honestly long before the month is out, so a working oracle can
    ///      never be routed around. If the wrapper is gone, disabled, or
    ///      quoting a price nobody could pay, requestReveal records the attempt
    ///      anyway instead of reverting, so the door still opens. See
    ///      vrfTroubleAt and requestReveal.
    function fallbackDue(uint256 batch) public view returns (bool) {
        if (!revealReady(batch)) return false;
        uint256 asked = uint256(vrfTroubleAt[batch]);
        return asked != 0 && block.timestamp >= asked + VRF_GIVEUP;
    }

    /// @notice Arm the last-resort draw for a thousand Chainlink has not
    ///         answered for a month. Anyone may call it; it costs a refundable
    ///         bond, and the caller decides nothing about the outcome.
    ///
    /// @dev WHY THIS EXISTS AT ALL. Everything downstream hangs off batch 0's
    ///      reveal: the city opens then, silver starts then, the pot runs then,
    ///      and the treasury's only door — a player burning golden frogs — is
    ///      shut until it does. There is no owner to swap wrappers and no
    ///      rescue function. If the VRF wrapper is retired or simply never
    ///      answers, every dollar the players paid sits in the treasury
    ///      permanently unreachable. That is a total loss, and it is worth a
    ///      weaker last-resort draw to avoid.
    ///
    ///      WHY THE OLD ONE WAS BROKEN, AND WHAT REPLACED IT. The previous
    ///      version armed at block A and let anyone read the offset out of the
    ///      hashes of blocks A+1..A+8. By block A+9 the answer was public — the
    ///      formula is plain keccak and block hashes are plain public data —
    ///      and WRITING it was optional. So the caller looked, and if the
    ///      offset did not put a Genesis on one of their own token numbers they
    ///      simply sent no second transaction, waited out the window and armed
    ///      again. No attempt counter, no bond, no cost. The offset of an
    ///      entire thousand was chosen by whoever was willing to press the
    ///      button a few dozen times.
    ///
    ///      The fix is not a patch on that shape, it is a different shape.
    ///      There are now two moves and neither of them is a choice:
    ///
    ///        1. ARM (this function). The caller posts a bond and NOTHING
    ///           ELSE. He used to hand in a seed of his choosing, and that was
    ///           a mistake even though the seed was committed before the
    ///           deciding blocks existed: a seed can be ground off chain for
    ///           one that makes a favourable answer likelier over the whole
    ///           space of futures, and off-chain grinding is free. The draw
    ///           now takes no input from the man who starts it at all. At this
    ///           second the offset cannot be computed by anybody, because it
    ///           lives entirely in the hashes of the next sixteen blocks.
    ///
    ///        2. DRAW (fallbackReveal). Sixteen blocks later the offset is
    ///           fully determined by data already on chain, and ANYONE may
    ///           write it — the armer holds no key and no secret. There is no
    ///           second discretionary moment to abuse.
    ///
    ///      So the two properties hold together: at the only moment a caller
    ///      chooses anything, the result is unknowable; from the moment the
    ///      result is knowable, the caller cannot stop it being written.
    ///
    ///      The bond covers what is left. Abandoning an armed draw — refusing
    ///      to finish it AND censoring everyone else for the whole window,
    ///      which is the only way to get a second roll — forfeits the bond to
    ///      the city treasury, i.e. to the players, and the next attempt on
    ///      that thousand costs twice as much, up to sixteen times the base.
    ///      Finishing it, whoever finishes it, returns the bond to the armer in
    ///      full, so an honest arming costs nothing but gas. The forfeited
    ///      money is unreachable by the forfeiter: pushing it to the treasury
    ///      is what keeps "try again" from being free the second time round.
    ///
    ///      What remains, honestly stated: a validator holding sixteen
    ///      consecutive slots after an arming block could choose the offset,
    ///      and the proposer of the last of those blocks picks between two
    ///      outcomes for nothing, or buys one further pair of them for the
    ///      price of a block he drops. That is the floor for any
    ///      chain-only randomness. It is unreachable until Chainlink has been
    ///      silent for thirty days, and anyone can pre-empt it with a real VRF
    ///      request that answers in minutes.
    ///
    ///      When this path opens is fallbackDue's business, and it is not a
    ///      calendar at all: it wants a request that was actually put to
    ///      Chainlink and went a month unanswered, and nothing else opens it.
    ///      A wrapper that is GONE used to make that impossible to record —
    ///      the request reverted the whole call — which is why requestReveal
    ///      now writes the refusal down instead of bubbling it out.
    ///
    /// @param batch which thousand
    function armFallbackReveal(uint256 batch) external payable nonReentrant {
        if (batch >= BATCHES) revert BadBatch();
        if (_batchOffsetPlus1[batch] != 0) revert AlreadyRevealed();
        if (!revealReady(batch)) revert BatchNotClosed();
        if (!fallbackDue(batch)) revert FallbackNotDue();

        Fallback memory f = fallbacks[batch];
        uint8 forfeits = f.forfeits;

        if (f.armedBlock != 0) {
            // Re-arming while a live window is still usable would let anyone
            // reset the sixteen-block wait every block and hold the fallback
            // shut for ever.
            if (block.number <= uint256(f.armedBlock) + FALLBACK_WINDOW) revert TooSoon();
            // The previous attempt was abandoned. Its bond is gone to the
            // players, and the next one is dearer.
            emit FallbackForfeited(batch, f.armer, _bondFor(forfeits));
            unchecked {
                if (forfeits < 255) ++forfeits;
            }
        }

        uint256 bond = _bondFor(forfeits);
        if (msg.value < bond) revert NotEnoughEth();

        // The thousand stops selling here, exactly as it does for a VRF
        // request: from this block its offset is being decided, and a sealed
        // box sold across that is a face-up card sold at a lottery price.
        _retireBatch(batch);

        fallbacks[batch] = Fallback({
            armer: msg.sender,
            armedBlock: uint64(block.number),
            forfeits: forfeits
        });
        emit FallbackArmed(batch, msg.sender, block.number, bond);

        // The overpayment goes home BEFORE the sweep, or the sweep would count
        // it as money nobody is coming back for.
        unchecked {
            uint256 refund = msg.value - bond;
            if (refund != 0) _sendEth(payable(msg.sender), refund);
        }
        _sweep();
    }

    /// @notice Write the offset that the armed commitment and the sixteen
    ///         blocks after it have already decided. Anyone may call it, and
    ///         the bond goes back to whoever armed it regardless of who does.
    /// @dev Deliberately open to everybody. The armer having no monopoly on
    ///      this call is the reason there is no second bite: by the time the
    ///      result is knowable it is also unstoppable.
    function fallbackReveal(uint256 batch) external nonReentrant returns (uint256 offset) {
        if (batch >= BATCHES) revert BadBatch();
        if (_batchOffsetPlus1[batch] != 0) revert AlreadyRevealed();

        Fallback memory f = fallbacks[batch];
        if (f.armedBlock == 0) revert FallbackNotArmed();

        uint256 armed = f.armedBlock;
        if (block.number <= armed + FALLBACK_BLOCKS) revert FallbackNotRipe();
        // BLOCKHASH only sees 256 blocks back; past the window the hashes are
        // zero and the draw would be a constant. Arm again instead — with a
        // fresh bond, because this one is now forfeit.
        if (block.number > armed + FALLBACK_WINDOW) revert FallbackExpired();

        // ONE BIT from each block, never the whole hash. Folding the hashes
        // into each other handed the answer to a single man: the proposer of
        // the sixteenth block saw the fifteen before it and reshaped his own
        // header — thirty-two free bytes, a few thousand tries off chain —
        // until the offset put the Genesis on a token of his. He then wrote
        // the result himself, so the bond came back whole, the ladder never
        // moved and the bounty was never paid. Every guard in this file was
        // built against a man who ABANDONS a roll; this one never abandoned
        // anything. A single bit is the whole of what he can dictate now: he
        // chooses between two futures, not among a thousand, and the man who
        // holds j of the last consecutive slots chooses among 2^j. That is the
        // floor for any draw a chain can make of itself, and it is reached
        // only after a month of Chainlink silence.
        uint256 bits;
        for (uint256 i = 1; i <= FALLBACK_BLOCKS; ++i) {
            bits = (bits << 1) | (uint256(blockhash(armed + i)) & 1);
        }
        // The batch number is in here so that two thousands armed in the same
        // block cannot draw the same offset.
        offset = uint256(keccak256(abi.encodePacked(batch, bits))) % BATCH_SIZE;

        _batchOffsetPlus1[batch] = offset + 1;
        batchRevealedAt[batch] = uint64(block.timestamp);
        delete fallbacks[batch];

        emit FallbackRevealed(batch, offset);
        emit BatchRevealed(batch, offset, 0);

        // The bond returns to the armer, less a finder's fee when somebody
        // else did the writing. Nobody was paid for this call before, so
        // refusing a roll you did not like never cost an attacker a
        // transaction: it cost him silence, and silence was free because no
        // stranger burns gas finishing another man's draw for nothing. See
        // FALLBACK_FINDER_BP. An armer who finishes his own draw pays nothing,
        // so an honest arming still costs only gas.
        //
        // A refusal to take either share does NOT revert this call: an armer or
        // a finisher that is a contract with no receive() would otherwise be
        // able to make the only rescue path in the whole set permanently
        // unfinishable, which is the exact failure this rescue exists to
        // prevent. Money left behind is swept to the players.
        uint256 bond = _bondFor(f.forfeits);
        if (msg.sender != f.armer && block.number > armed + FALLBACK_GRACE) {
            uint256 finder = (bond * FALLBACK_FINDER_BP) / 10000;
            unchecked { bond -= finder; }
            (bool okFinder, ) = payable(msg.sender).call{value: finder, gas: 30_000}("");
            okFinder; // deliberately unchecked — see above
            emit FallbackFinderPaid(batch, msg.sender, finder);
        }
        (bool ok, ) = payable(f.armer).call{value: bond, gas: 30_000}("");
        ok; // deliberately unchecked — see above
    }

    /// @notice ETH sitting here that belongs to nobody: bonds of attempts that
    ///         lapsed, a refund a contract refused, or anything force-fed in.
    /// @dev Computed from the balance rather than from a counter, so no path
    ///      can leave a wei behind by forgetting to book it. This contract
    ///      never holds sale money for a block — every mint pays both halves
    ///      out and refunds the rest in the same call — so the only ETH that
    ///      can legitimately be here is a live bond.
    function unclaimedEth() public view returns (uint256) {
        uint256 locked;
        for (uint256 b = 0; b < BATCHES; ++b) {
            Fallback memory f = fallbacks[b];
            if (f.armedBlock != 0 && block.number <= uint256(f.armedBlock) + FALLBACK_WINDOW) {
                locked += _bondFor(f.forfeits);
            }
        }
        uint256 bal = address(this).balance;
        return bal > locked ? bal - locked : 0;
    }

    /// @notice Push that money to the city treasury, where it becomes part of
    ///         what backs a golden frog. Permissionless, and nothing breaks if
    ///         it is never called — arming a fallback sweeps automatically, and
    ///         until then the money simply waits.
    function sweepForfeitedBonds() external nonReentrant {
        if (unclaimedEth() == 0) revert NothingToSweep();
        _sweep();
    }

    function _sweep() private {
        uint256 amount = unclaimedEth();
        if (amount == 0) return;
        (bool ok, ) = treasury.call{value: amount}("");
        if (!ok) return; // it waits here; nothing is lost and anyone may retry
        emit ForfeitSwept(amount);
    }

    /// @notice What arming this batch's fallback costs right now, in wei.
    function fallbackBond(uint256 batch) external view returns (uint256) {
        Fallback memory f = fallbacks[batch];
        uint8 forfeits = f.forfeits;
        if (f.armedBlock != 0 && block.number > uint256(f.armedBlock) + FALLBACK_WINDOW && forfeits < 255) {
            unchecked { ++forfeits; }
        }
        return _bondFor(forfeits);
    }

    function _bondFor(uint8 forfeits) private pure returns (uint256) {
        uint256 n = forfeits > FALLBACK_MAX_DOUBLINGS ? FALLBACK_MAX_DOUBLINGS : forfeits;
        return FALLBACK_BOND << n;
    }


    function isRevealed(uint256 batch) public view returns (bool) {
        return _batchOffsetPlus1[batch] != 0;
    }

    /// @notice Is this particular token's thousand open yet? FrogMarket reads it
    ///         to kill a listing that was written while the box was sealed.
    function tokenRevealed(uint256 tokenId) public view returns (bool) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) return false;
        return _batchOffsetPlus1[(tokenId - 1) / BATCH_SIZE] != 0;
    }

    /// @notice The second the city opened: when the FIRST thousand revealed.
    ///         Zero until then, and nothing accrues to anybody while it is zero.
    /// @dev Everyone starts in the same second. A buyer of box 1 and a buyer of
    ///      box 999 begin earning together, and neither earns anything during
    ///      the sale itself.
    function cityOpensAt() external view returns (uint64) {
        return batchRevealedAt[0];
    }

    /// @notice True while this token's thousand has a draw in flight. FrogMarket
    ///         refuses to sell across it.
    /// @dev The fulfillment transaction carries the random word in plain
    ///      calldata and sits in the public mempool before it lands. The deck is
    ///      public, so `word % 1000` resolves the entire thousand — every
    ///      Genesis and Mythic in it — while its frogs are still listed at
    ///      sealed-box prices.
    ///
    ///      The window is the request's whole life, not a guess at how long a
    ///      draw takes. The previous revision froze the market for a flat 30
    ///      minutes from the request; a fulfillment that ran long — exactly
    ///      what a gas spike produces — reopened our own market with the answer
    ///      still in the mempool, which is the very trade this exists to stop.
    ///      It clears the instant the batch reveals, and it fails open after
    ///      REREQUEST_DELAY so a wrapper that never answers cannot freeze a
    ///      thousand's trading for good. That is also the moment anyone may
    ///      re-request, so a fresh request simply re-arms it.
    function revealPending(uint256 tokenId) public view returns (bool) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY || _packed[tokenId] == 0) return false;
        return batchDrawInFlight((tokenId - 1) / BATCH_SIZE);
    }

    /// @notice True while a thousand's offset is being decided, by EITHER route.
    /// @dev The one predicate every door reads: `mint`, `saleOpen`,
    ///      `revealPending` and through it the marketplace.
    ///
    ///      It used to look at Chainlink requests only. The armed fallback was
    ///      invisible to it — the field was read nowhere outside the two
    ///      fallback functions — and that was a hole big enough to drive the
    ///      whole collection through: for every block a fallback
    ///      stood armed, the offset of that thousand was computable by anybody
    ///      who cared to keccak sixteen public block hashes, while the contract
    ///      went on selling its boxes as sealed and letting them trade on our
    ///      own marketplace at sealed prices. Both routes are one predicate now.
    ///
    ///      Both halves fail open, and on purpose: a Chainlink request that is
    ///      never answered stops counting after REREQUEST_DELAY (and the answer
    ///      stops being accepted in the same second — see
    ///      rawFulfillRandomWords), and an armed fallback stops counting after
    ///      FALLBACK_WINDOW blocks (and stops being drawable in the same
    ///      block). Neither can freeze a thousand's market for good, and
    ///      re-arming either one costs money.
    function batchDrawInFlight(uint256 batch) public view returns (bool) {
        if (_batchOffsetPlus1[batch] != 0) return false;
        uint256 requested = batchRequestedAt[batch];
        if (requested != 0 && block.timestamp - requested < REREQUEST_DELAY) return true;
        uint256 armed = fallbacks[batch].armedBlock;
        return armed != 0 && block.number <= armed + FALLBACK_WINDOW;
    }

    function batchOffset(uint256 batch) public view returns (uint256) {
        uint256 v = _batchOffsetPlus1[batch];
        require(v != 0, "not revealed");
        return v - 1;
    }

    /* ====================================================================== */
    /*  Deck lookups                                                           */
    /* ====================================================================== */

    /// @notice Which card of the shuffled deck this token turned out to be.
    /// @dev Shuffled INSIDE its own thousand, not across the whole deck. That is
    ///      the point: closing a batch reveals only that batch, so a buyer in
    ///      batch 4 learns nothing about batch 5, and the deck slice a batch can
    ///      draw from is fixed before its offset exists.
    function deckPosition(uint256 tokenId) public view returns (uint256) {
        // Existence is `_packed`, not `<= totalMinted`: a thousand that closed
        // early leaves retired slots below the cursor that were never sold.
        if (_packed[tokenId] == 0) revert NoToken();
        uint256 batch = (tokenId - 1) / BATCH_SIZE;
        uint256 offset = batchOffset(batch);
        uint256 indexInBatch = (tokenId - 1) % BATCH_SIZE;
        return ((indexInBatch + offset) % BATCH_SIZE) + batch * BATCH_SIZE;
    }

    /// @notice Design id 0..149 of a revealed token.
    function designOf(uint256 tokenId) public view returns (uint8) {
        return _deckByte(deckPosition(tokenId));
    }

    /// @notice Tier 0..4 of a revealed token.
    function tierOf(uint256 tokenId) public view returns (uint8) {
        return _tierOf(designOf(tokenId));
    }

    /// @notice Silver production in basis points of x1, as it stands right now.
    /// @dev A sealed box produces the collection average, x2.359. It is not a
    ///      placeholder and it is not charity: the collection's total output is
    ///      the same number whether every box is open or every box is shut, so
    ///      nobody gains by stalling a reveal and nobody is punished for a
    ///      reveal they do not control. The city never applies this rate
    ///      backwards over a revealed stretch — see frogInfo.
    function productionOf(uint256 tokenId) public view returns (uint32) {
        if (_packed[tokenId] == 0) revert NoToken();
        uint256 batch = (tokenId - 1) / BATCH_SIZE;
        if (_batchOffsetPlus1[batch] == 0) return SEALED_PRODUCTION_BP;
        // _tierOf, not _design: this is the hottest path in the game — the city
        // calls it once per frog on every collect — and the name _design builds
        // would be allocated and thrown away every time.
        return _productionBp(_tierOf(_deckByte(deckPosition(tokenId))));
    }

    /// @notice Which copy of its design this frog is, counted along the deck.
    /// @dev O(deck position) — up to 10,000 bytes for the last card in the deck.
    ///      A pure view, only ever reached through eth_call: nothing on-chain
    ///      calls it and the city never touches it. Scanned 32 bytes at a time
    ///      rather than one at a time, because at one byte per iteration the
    ///      last batch's tokens cost about 1.8M gas and some public RPC nodes
    ///      cap eth_call well below that.
    function editionOf(uint256 tokenId) public view returns (uint256 edition) {
        uint256 pos = deckPosition(tokenId);
        uint256 want = _deckByte(pos);
        uint256 n = pos + 1;
        bytes memory prefix = _deckBytes(n);

        assembly {
            let p := add(prefix, 32)
            let end := add(p, n)
            let count := 0
            for {} lt(p, end) {
                p := add(p, 32)
            } {
                let word := mload(p)
                // The final word may reach past the array. Memory is zero-filled
                // there, and `lanes` stops us from looking at those bytes.
                let lanes := sub(end, p)
                if gt(lanes, 32) {
                    lanes := 32
                }
                for {
                    let k := 0
                } lt(k, lanes) {
                    k := add(k, 1)
                } {
                    if eq(byte(k, word), want) {
                        count := add(count, 1)
                    }
                }
            }
            edition := count
        }
    }

    /// @notice Everything the city needs about a frog, in one call.
    /// @param production the frog's TRUE rate, or 0 while it is still sealed.
    /// @param revealedAt the second its thousand opened, or 0 while sealed.
    /// @dev Two numbers, not one, because the city has to price a frog's clock
    ///      in TWO segments: the stretch before `revealedAt` at the collection
    ///      average, the stretch after it at `production`. Handing back a single
    ///      "current rate" is exactly what let silver be banked in a sealed box
    ///      and cashed at a Genesis rate the moment it opened.
    function frogInfo(uint256 tokenId)
        external
        view
        returns (address tokenOwner, uint40 born, uint32 seq, uint32 production, uint40 revealedAt)
    {
        uint256 p = _packed[tokenId];
        if (p == 0) revert NoToken();
        tokenOwner = address(uint160(p & OWNER_MASK));
        born = uint40((p >> TIME_SHIFT) & TIME_MASK);
        seq = uint32((p >> SEQ_SHIFT) & SEQ_MASK);

        uint256 batch = (tokenId - 1) / BATCH_SIZE;
        if (_batchOffsetPlus1[batch] != 0) {
            production = _productionBp(_tierOf(_deckByte(deckPosition(tokenId))));
            revealedAt = uint40(batchRevealedAt[batch]);
        }
    }

    /// @notice The token's authorisation counter: it goes up on every transfer
    ///         AND on every approve(). The marketplace snapshots it so a listing
    ///         dies the moment its frog moves or its approval is touched.
    /// @dev Named for what it originally counted; kept so nothing off-chain has
    ///      to be rewired. See approve() for why approvals count too.
    function transferSeq(uint256 tokenId) external view returns (uint32) {
        uint256 p = _packed[tokenId];
        if (p == 0) revert NoToken();
        return uint32((p >> SEQ_SHIFT) & SEQ_MASK);
    }

    function mintedAt(uint256 tokenId) external view returns (uint40) {
        uint256 p = _packed[tokenId];
        if (p == 0) revert NoToken();
        return uint40((p >> TIME_SHIFT) & TIME_MASK);
    }

    function _deckByte(uint256 pos) internal view returns (uint8) {
        return SSTORE2.readByte(deckPtr, pos);
    }

    function _deckBytes(uint256 count) internal view returns (bytes memory) {
        return SSTORE2.read(deckPtr, 0, count);
    }

    /// @dev Just the tier byte, with no name allocated. seal() has already
    ///      proved both bounds hold for every record; the checks stay as a
    ///      belt on a contract that can never be patched.
    function _tierOf(uint256 designId) internal view returns (uint8 tier) {
        require(designId < DESIGN_COUNT, "design id");
        tier = uint8(SSTORE2.readWord(designsPtr, designId)[0]);
        require(tier < 5, "tier");
    }

    /// @dev Design record: byte 0 is the tier, bytes 1..31 the NUL-padded name.
    function _design(uint256 designId) internal view returns (uint8 tier, string memory designName) {
        require(designId < DESIGN_COUNT, "design id");
        bytes32 rec = SSTORE2.readWord(designsPtr, designId);
        tier = uint8(rec[0]);
        require(tier < 5, "tier");

        uint256 len;
        while (len < 31 && rec[len + 1] != 0) ++len;
        bytes memory buf = new bytes(len);
        for (uint256 i = 0; i < len; ++i) buf[i] = rec[i + 1];
        designName = string(buf);
    }

    /* ====================================================================== */
    /*  Metadata, built here and nowhere else                                  */
    /* ====================================================================== */

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_packed[tokenId] == 0) revert NoToken();
        uint256 batch = (tokenId - 1) / BATCH_SIZE;
        if (_batchOffsetPlus1[batch] == 0) return _sealedJson(tokenId, batch);
        return _revealedJson(tokenId);
    }

    function _sealedJson(uint256 tokenId, uint256 batch) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"MEMITO Sealed Box #',
            _toString(tokenId),
            '","description":"A sealed box from MEMELAND CLUB CITY. The deck was shuffled and its hash published before the first box was sold. This box opens when its thousand is sold, or once its thousand has gone quiet, whichever comes first. While sealed it produces the collection average, x2.359 the base rate.","image":"ipfs://',
            SEALED_CID,
            '","attributes":[{"trait_type":"Status","value":"Sealed"},{"trait_type":"Production","value":"x2.359"},{"trait_type":"Batch","display_type":"number","value":',
            _toString(batch + 1),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _revealedJson(uint256 tokenId) internal view returns (string memory) {
        uint256 pos = deckPosition(tokenId);
        uint8 designId = _deckByte(pos);
        (uint8 tier, string memory designName) = _design(designId);

        string memory head = string.concat(
            '{"name":"MEMITO - ',
            designName,
            '","description":"MEMELAND CLUB CITY. Design ',
            _pad3(designId + 1),
            " of 150, tier ",
            _tierName(tier),
            ". Produces silver in the city at ",
            _productionLabel(tier),
            ' the base rate, forever, for whoever holds it.","image":"ipfs://',
            IMAGE_CID,
            "/",
            _pad3(designId + 1),
            '.jpg"'
        );

        string memory attrs = string.concat(
            ',"attributes":[',
            '{"trait_type":"Tier","value":"',
            _tierName(tier),
            '"},',
            '{"trait_type":"Design","value":"',
            _pad3(designId + 1),
            '"},',
            '{"trait_type":"Production","value":"',
            _productionLabel(tier),
            '"},',
            '{"trait_type":"Copies of this design","display_type":"number","value":',
            _toString(_printRun(tier)),
            "},",
            '{"trait_type":"Edition","display_type":"number","value":',
            _toString(editionOf(tokenId)),
            "}]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(head, attrs))));
    }

    function _pad3(uint256 v) internal pure returns (string memory) {
        if (v < 10) return string.concat("00", _toString(v));
        if (v < 100) return string.concat("0", _toString(v));
        return _toString(v);
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 t = v;
        while (t != 0) {
            ++digits;
            t /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            buf[--digits] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(buf);
    }

    /* ====================================================================== */
    /*  ERC-2981                                                               */
    /* ====================================================================== */

    /// @notice 5% of every secondary sale, sent to the splitter, which forwards
    ///         3% to the Ecosystem Wallet and 2% to the city treasury.
    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = royaltyReceiver;
        royaltyAmount = (salePrice * ROYALTY_BP) / 10000;
    }

    /* ====================================================================== */
    /*  ERC-721                                                                */
    /* ====================================================================== */

    function balanceOf(address account) public view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balanceOf[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        uint256 p = _packed[tokenId];
        if (p == 0) revert NoToken();
        return address(uint160(p & OWNER_MASK));
    }

    /// @notice How many frogs exist. Nothing is ever burned, so this is simply
    ///         how many boxes were sold — which is NOT `totalMinted`, the sale
    ///         cursor, once a thousand has closed with boxes still on its shelf.
    function totalSupply() external view returns (uint256) {
        return boxesSold;
    }

    /// @dev Bumps the token's authorisation counter, and that bump is load
    ///      bearing. The marketplace holds no escrow: a listing is alive while
    ///      the market is still approved for that exact frog. Revoking the
    ///      approval therefore HIDES a listing without killing it, and granting
    ///      it again — which is the first half of "reprice", one transaction
    ///      before the new price is written — brought the old cheap listing
    ///      back to life for that gap. Counting approvals as well as transfers
    ///      means any touch of a frog's authorisation retires every listing
    ///      written before it, so a revoked listing can never come back.
    function approve(address spender, uint256 tokenId) external {
        uint256 p = _packed[tokenId];
        if (p == 0) revert NoToken();
        address holder = address(uint160(p & OWNER_MASK));
        if (msg.sender != holder && !_operatorApproval[holder][msg.sender]) revert NotAuthorized();
        _tokenApproval[tokenId] = spender;
        _packed[tokenId] = (p & ~(SEQ_MASK << SEQ_SHIFT)) |
            (((((p >> SEQ_SHIFT) & SEQ_MASK) + 1) & SEQ_MASK) << SEQ_SHIFT);
        emit Approval(holder, spender, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_packed[tokenId] == 0) revert NoToken();
        return _tokenApproval[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApproval[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address holder, address operator) external view returns (bool) {
        return _operatorApproval[holder][operator];
    }

    /// @notice Transfers are never pausable here. A player who bought a frog owns
    ///         it under every condition, including one where we would rather
    ///         they did not move it.
    function transferFrom(address from, address to, uint256 tokenId) public {
        uint256 p = _packed[tokenId];
        if (p == 0) revert NoToken();
        address holder = address(uint160(p & OWNER_MASK));
        if (holder != from) revert NotAuthorized();
        if (to == address(0)) revert ZeroAddress();
        if (
            msg.sender != holder &&
            msg.sender != _tokenApproval[tokenId] &&
            !_operatorApproval[holder][msg.sender]
        ) revert NotAuthorized();

        unchecked {
            _balanceOf[from] -= 1;
            _balanceOf[to] += 1;
        }

        // Keep the mint stamp, bump the transfer counter, swap the owner.
        uint256 newSeq = (((p >> SEQ_SHIFT) & SEQ_MASK) + 1) & SEQ_MASK;
        _packed[tokenId] =
            uint256(uint160(to)) |
            (p & (TIME_MASK << TIME_SHIFT)) |
            (newSeq << SEQ_SHIFT);

        delete _tokenApproval[tokenId];
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            if (
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) !=
                IERC721Receiver.onERC721Received.selector
            ) revert WrongRecipient();
        }
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return
            id == 0x01ffc9a7 || // ERC-165
            id == 0x80ac58cd || // ERC-721
            id == 0x5b5e139f || // ERC-721 Metadata
            id == 0x2a55205a; // ERC-2981
    }
}
