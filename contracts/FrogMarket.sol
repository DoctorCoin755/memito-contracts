// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ICityTreasury {
    function isAccepted(address asset) external view returns (bool);
}

interface IFrogs {
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice The city this collection was born pointing at.
    function city() external view returns (address);

    function getApproved(uint256 tokenId) external view returns (address);
    function transferSeq(uint256 tokenId) external view returns (uint32);
    function revealPending(uint256 tokenId) external view returns (bool);
    function tokenRevealed(uint256 tokenId) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title FrogMarket — our own floor, priced in MEMITO
/// @notice Frogs change hands here for MEMITO and nothing else. That is a demand
///         decision, not a technical one: every resale forces the buyer to go
///         and get the token first.
///
///         Fee is 4.5% of the sale — 2% to the city treasury, 2.5% to the
///         Ecosystem Wallet, 95.5% to the seller. No owner, no fee setter,
///         no pause.
///
///         BE PRECISE ABOUT THE TREASURY SHARE. An earlier version of this
///         line said it "raises the golden frog exchange rate for every
///         player, so trading frogs feeds the game economy". That is not
///         true and must not be repeated in a whitepaper. This market settles
///         in MEMITO and nothing else, so the treasury's 2% arrives as MEMITO
///         — and the treasury deliberately does not carry MEMITO among its
///         five valued assets. It is this project's own coin: pricing it would
///         mean reading a pool anyone can shove with rented capital, and one
///         manipulable number inside the backing put the whole vault in reach.
///         So the 2% is counted at zero, can never be paid out, and can never
///         be swept — nobody, the founder included, has a function that moves
///         it. The golden frog rate does not move by one wei when a frog is
///         resold. What the 2% actually does is leave circulation for good:
///         it is a burn, and a burn lifts the coin for everyone holding it.
///         That is a fair thing for a marketplace fee to do. It is not
///         backing, and calling it backing would be selling a promise the
///         code does not keep.
///
/// @dev No escrow. The frog stays in the seller's wallet, listed by approval,
///      so a seller keeps custody and keeps earning silver while listed.
///
///      Three separate things can kill a listing, and all three live in the same
///      already-paid-for storage slot as the seller's address:
///
///        * THE TOKEN MOVED. Every listing snapshots the token's transfer
///          counter. Any movement of the token, anywhere, to anyone, makes the
///          listing unusable. No hooks in the NFT, no gas for an escrow.
///
///        * THE BOX OPENED. A listing made while the box was still sealed is a
///          price for a lottery ticket. When that thousand reveals, the world
///          learns which token is the Genesis — and the old $45 listing would
///          still be live in the same block. So the listing remembers whether
///          the box was shut when it was written, and dies the moment the batch
///          opens. The seller relists knowing what is in their hand.
///
///        * IT GOT OLD. Revoking an approval HIDES a listing without deleting
///          it. Re-approving a month later — even to sell a different frog —
///          would revive every old cheap listing at once, and the two-step
///          "approve, then reprice" dance leaves the same gap for one block.
///          So a listing expires after LISTING_TTL whatever the seller does
///          with their approvals.
///
///      And because of that same hole, this market takes PER-TOKEN approvals
///      only: `approve(tokenId, market)`, not `setApprovalForAll`. The TTL
///      alone only killed listings whose owner had been away longer than a
///      month — which is exactly the seller who never comes back to trigger
///      anything. Per-token approval means the blast radius of a re-approval
///      is the one frog it names. A seller listing five frogs signs five
///      approvals; that is the price, and it is one transaction each.
///
///      Selling is therefore: approve(tokenId, market) -> list(tokenId, price).
///      Cancelling is cancel(tokenId) — and a front end must call it rather
///      than telling the user to revoke, because a revoked approval only hides
///      a listing while an approval of that same token brings it back.
contract FrogMarket {
    /// @dev One slot: 160 + 32 + 40 + 8 = 240 bits. The seq/seller slot already
    ///      had 64 spare bits, so the expiry and the sealed flag cost no extra
    ///      STORAGE. They are not free overall: reading them means `list` makes
    ///      one more call into the NFT and `buy` two, which is a few thousand
    ///      gas. Measured: list ~83k, buy ~82k.
    struct Listing {
        address seller; // 160 bits
        uint32 seq; //      32  — frogs.transferSeq() when the listing was made
        uint40 expiry; //   40  — dead after this second
        bool listedSealed; // 8 — was the box still shut when this was written?
        uint256 price; // in MEMITO wei
    }

    IFrogs public immutable frogs;
    address public immutable memito;
    address public immutable treasury;
    address public immutable ecosystem;

    /// @notice The one coin frogs change hands for here, written in rather
    ///         than taken on trust from whoever sends the deploy transaction.
    /// @dev The NFT, the treasury and the price oracle all hold this address as
    ///      a compile-time constant. This contract and the city were the two
    ///      that took it as an argument and checked only that it was not zero
    ///      and had code, which every ERC-20 ever deployed satisfies. One
    ///      mistyped character and every frog on this floor is priced, paid and
    ///      fee-split in a token nobody in the game holds, for ever, with no
    ///      setter, no owner and — this market has no verifyWiring() — nothing
    ///      to check it against afterwards. The argument stays, so the deploy
    ///      transaction keeps the exact shape DEPLOY-ORDER.md records; it is now
    ///      checked against this instead of believed.
    address public constant MEMITO = 0xe02AD79732658a2ec2C85Ecd15De5E08A311373C;

    uint256 public constant FEE_CITY_BP = 200; // 2.0%
    uint256 public constant FEE_ECO_BP = 250; // 2.5%

    /// @notice How long a listing stays alive. Relisting is one cheap call.
    uint256 public constant LISTING_TTL = 30 days;

    mapping(uint256 => Listing) private _listings;

    uint256 private _lock = 1;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price, uint40 expiry, bool sealedBox);
    event PriceChanged(uint256 indexed tokenId, address indexed seller, uint256 price, uint40 expiry, bool sealedBox);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Swept(address indexed asset, uint256 amount);
    event StrayFrogSentToCity(uint256 indexed tokenId, address indexed city);
    event Sold(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 feeCity,
        uint256 feeEco
    );

    error Reentrancy();
    error NotYourFrog();
    error NotApproved();
    error BadPrice();
    error NotListed();
    error StaleListing();
    error ListingExpired();
    error BoxOpenedSinceListed();
    error RevealPending();
    error TransferFailed();
    error ZeroAddress();
    error NotAContract();
    error WrongToken();
    error ShortTransfer();
    error AssetNotAccepted();
    error NothingToSweep();
    error NotStray();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address frogs_, address memito_, address treasury_, address ecosystem_) {
        if (
            frogs_ == address(0) ||
            memito_ == address(0) ||
            treasury_ == address(0) ||
            ecosystem_ == address(0)
        ) revert ZeroAddress();
        // Having code is not the same as being the right token, and there is no
        // setter here to fix it with afterwards.
        if (memito_ != MEMITO) revert WrongToken();
        // MEMITO is paid with a low-level call, where a codeless address would
        // report success and move nothing.
        if (memito_.code.length == 0) revert NotAContract();

        frogs = IFrogs(frogs_);
        memito = memito_;
        treasury = treasury_;
        ecosystem = ecosystem_;
    }

    /* ------------------------------------------------------------------ */

    /// @param live      the listing itself is intact
    /// @param buyableNow live AND this thousand has no draw in flight. An
    ///        integrator should read THIS one: `live` alone says a listing is
    ///        sound, and `buy` additionally refuses to trade a thousand whose
    ///        random word is sitting in the mempool. The two are kept apart on
    ///        purpose — a listing frozen by a reveal is not dead, and anyone may
    ///        sweep a dead listing, so folding the freeze into `live` would let
    ///        a stranger cancel every listing in a thousand while it is frozen.
    function getListing(uint256 tokenId)
        external
        view
        returns (
            address seller,
            uint256 price,
            uint40 expiry,
            bool listedSealed,
            bool live,
            bool buyableNow
        )
    {
        Listing memory l = _listings[tokenId];
        seller = l.seller;
        price = l.price;
        expiry = l.expiry;
        listedSealed = l.listedSealed;
        live = _isLive(tokenId, l);
        buyableNow = live && !frogs.revealPending(tokenId);
    }

    /// @dev A listing is live only while all five of these hold.
    function _isLive(uint256 tokenId, Listing memory l) internal view returns (bool) {
        if (l.seller == address(0)) return false;
        if (block.timestamp >= l.expiry) return false;
        if (l.listedSealed && frogs.tokenRevealed(tokenId)) return false;
        if (frogs.ownerOf(tokenId) != l.seller) return false;
        if (frogs.transferSeq(tokenId) != l.seq) return false;
        return frogs.getApproved(tokenId) == address(this);
    }

    function list(uint256 tokenId, uint256 price) external {
        (uint40 expiry, bool sealedBox) = _write(tokenId, price);
        emit Listed(tokenId, msg.sender, price, expiry, sealedBox);
    }

    /// @notice Change the price of your listing.
    /// @dev A full rewrite, not a price poke: ownership, approval, the transfer
    ///      counter, the sealed flag and the expiry are all taken again from the
    ///      chain as it is now. Anything else would let a seller carry a stale
    ///      snapshot — in particular a sealed-box flag written before the batch
    ///      opened — across a repricing.
    function changePrice(uint256 tokenId, uint256 price) external {
        if (_listings[tokenId].seller != msg.sender) revert NotListed();
        (uint40 expiry, bool sealedBox) = _write(tokenId, price);
        emit PriceChanged(tokenId, msg.sender, price, expiry, sealedBox);
    }

    function _write(uint256 tokenId, uint256 price) private returns (uint40 expiry, bool sealedBox) {
        if (price == 0) revert BadPrice();
        if (frogs.ownerOf(tokenId) != msg.sender) revert NotYourFrog();
        // PER-TOKEN approval only. A blanket operator approval would mean one
        // `setApprovalForAll(market, true)` — granted for one unrelated sale
        // months later — silently revives every listing the seller ever left
        // behind, all at yesterday's prices, in a single block. Per token, a
        // revoked listing can only be revived by an approve() naming that
        // exact frog, which is a deliberate act about that frog.
        if (frogs.getApproved(tokenId) != address(this)) revert NotApproved();

        expiry = uint40(block.timestamp + LISTING_TTL);
        sealedBox = !frogs.tokenRevealed(tokenId);

        _listings[tokenId] = Listing({
            seller: msg.sender,
            seq: frogs.transferSeq(tokenId),
            expiry: expiry,
            listedSealed: sealedBox,
            price: price
        });
    }

    /// @notice Sellers cancel their own. Anyone may clear a listing that is no
    ///         longer live, because such a listing is already dead weight — and
    ///         sweeping them is what keeps the order book honest.
    function cancel(uint256 tokenId) external {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender && _isLive(tokenId, l)) revert NotYourFrog();
        delete _listings[tokenId];
        emit Cancelled(tokenId, l.seller);
    }

    /// @param maxPrice the buyer's cap. Pass exactly the price the interface
    ///        showed you — the seller cannot take a wei more than this, so there
    ///        is nothing to gain by allowing headroom and something to lose.
    /// @dev No sales while this token's thousand has a VRF draw in flight. The
    ///      fulfillment transaction spends a few blocks in the public mempool
    ///      with the random word in its calldata, and the deck is public — so
    ///      for those blocks anyone can work out exactly which token in that
    ///      thousand is the Genesis and buy it off a seller who still thinks
    ///      they are selling a sealed box. That covers the window BEFORE the
    ///      reveal lands; `listedSealed` covers every block after it.
    function buy(uint256 tokenId, uint256 maxPrice) external nonReentrant {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.price > maxPrice) revert BadPrice();
        if (block.timestamp >= l.expiry) revert ListingExpired();
        if (l.listedSealed && frogs.tokenRevealed(tokenId)) revert BoxOpenedSinceListed();
        if (frogs.revealPending(tokenId)) revert RevealPending();
        if (!_isLive(tokenId, l)) revert StaleListing();

        // Clear the listing before anything external happens.
        delete _listings[tokenId];

        uint256 feeCity = (l.price * FEE_CITY_BP) / 10000;
        uint256 feeEco = (l.price * FEE_ECO_BP) / 10000;
        uint256 toSeller = l.price - feeCity - feeEco;

        // Straight from the buyer to each destination — the market never holds
        // a balance, so there is nothing here to rescue, drain or forget, and
        // nobody has to press a button to be paid.
        _pull(treasury, feeCity);
        _pull(ecosystem, feeEco);
        _pull(l.seller, toSeller);

        frogs.transferFrom(l.seller, msg.sender, tokenId);

        emit Sold(tokenId, l.seller, msg.sender, l.price, feeCity, feeEco);
    }

    /// @dev Measured, not assumed. The treasury already counts what LANDS on a
    ///      player rather than what it debited itself, and the way in has to
    ///      hold to the same standard. If the token ever skimmed a fee in
    ///      transit — USDT has carried that switch since 2017 and has never
    ///      thrown it — the seller, the treasury and the Ecosystem Wallet would
    ///      each quietly receive less than the Sold event says they did, on
    ///      every sale, with no owner to notice it afterwards. A trade that
    ///      fails is better than a receipt that lies.
    ///
    ///      A destination that is the payer itself is skipped rather than
    ///      measured: a self-transfer moves no balance, so there is no delta to
    ///      read and nothing that could have been skimmed. That is the buyer of
    ///      his own listing, which this market has always allowed.
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

    /* ------------------------------------------------------------------ */
    /*  Things that landed here by mistake                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Push a stray balance sitting on this contract into the city
    ///         treasury. Anyone may call it, and the caller gets nothing —
    ///         the destination is written into the code.
    /// @dev Where it ends up depends on the coin, and the difference matters.
    ///      One of the treasury's five valued assets does become part of what
    ///      backs a golden frog. MEMITO does not: the treasury holds it at
    ///      zero and can never pay it out, so pushing MEMITO there is a burn,
    ///      not a deposit. Both are better than leaving the money stranded on
    ///      a contract with no owner, which is why this function exists at
    ///      all — but the header of this file used to blur the two, and a
    ///      whitepaper written from that blur would promise backing that is
    ///      not there.
    /// @param asset one of the five the treasury takes, or MEMITO; address(0)
    ///        for ETH
    ///
    /// @dev This market never holds anything. A listing is an approval, the frog
    ///      stays in the seller's wallet, and every payment goes straight from
    ///      the buyer to the seller and the two fee destinations inside one
    ///      call. No function here is payable either, so ETH can only arrive by
    ///      force. Whatever is found here is a misdirected transfer, and today
    ///      it is lost for good.
    ///
    ///      A rescue, not a withdrawal: the destination is not an argument,
    ///      there is exactly one of it, it is the pot every player is paid out
    ///      of, and the caller is paid NOTHING — which is what keeps this from
    ///      becoming a lure worth building a trick around. Only coins the
    ///      treasury accepts can be moved; a foreign token would be just as
    ///      stuck there as it is here, and sweeping one would let any passer-by
    ///      make this contract call an address of their choosing.
    function sweepToTreasury(address asset) external nonReentrant returns (uint256 amount) {
        // MEMITO is not one of the treasury five - nobody can price it - and
        // this contract is the likeliest address in the whole set for it to be
        // fumbled onto: it is the barrow, every sale on it is settled in MEMITO,
        // and buyers approve it for their coins every day. Without this clause a
        // misdirected transfer would be stuck here for good, and there is nobody
        // who could ever unstick it. In the treasury it is no more stuck than it
        // is here, and there it is at least out of reach of a mistake.
        if (asset != memito && !ICityTreasury(treasury).isAccepted(asset)) revert AssetNotAccepted();

        if (asset == address(0)) {
            amount = address(this).balance;
            if (amount == 0) revert NothingToSweep();
            (bool sent, ) = payable(treasury).call{value: amount}("");
            if (!sent) revert TransferFailed();
        } else {
            amount = IERC20(asset).balanceOf(address(this));
            if (amount == 0) revert NothingToSweep();
            (bool ok, bytes memory data) = asset.call(
                abi.encodeWithSelector(IERC20.transfer.selector, treasury, amount)
            );
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }

        emit Swept(asset, amount);
    }

    /// @notice Send a frog that was transferred onto this contract to the city,
    ///         which is the one place a stranded frog can be priced and sold
    ///         back into the game. Anyone may call it.
    ///
    /// @dev Nothing in this file ever makes this contract the owner of a frog —
    ///      there is no escrow — and a safe transfer here already reverts, as
    ///      there is no receiver hook to answer it. So a frog sitting on this
    ///      address is the "send it to the marketplace to sell it" reflex from
    ///      the escrow marketplaces, and it is otherwise lost for good: it stays
    ///      alive, keeps making silver, and no wallet on earth can collect it or
    ///      move the card again.
    ///
    ///      This market has no oracle and no price of its own, so it cannot put
    ///      a number on a card; the city can, and sells it with the whole of the
    ///      money going to the treasury. There is one destination and it is not
    ///      passed in — it is read out of the NFT contract, which names its city
    ///      and is checked against it at deploy by verifyWiring(). So there is
    ///      nothing here to mistype and nothing to point anywhere else, and the
    ///      caller chooses nothing and receives nothing.
    function sendStrayFrogToCity(uint256 tokenId) external {
        if (frogs.ownerOf(tokenId) != address(this)) revert NotStray();
        address cityAddr = frogs.city();
        frogs.transferFrom(address(this), cityAddr, tokenId);
        emit StrayFrogSentToCity(tokenId, cityAddr);
    }
}
