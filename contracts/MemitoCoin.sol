// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 *  MEMITO COIN ($MEMITO)
 *
 *  ███╗   ███╗███████╗███╗   ███╗██╗████████╗ ██████╗
 *  ████╗ ████║██╔════╝████╗ ████║██║╚══██╔══╝██╔═══██╗
 *  ██╔████╔██║█████╗  ██╔████╔██║██║   ██║   ██║   ██║
 *  ██║╚██╔╝██║██╔══╝  ██║╚██╔╝██║██║   ██║   ██║   ██║
 *  ██║ ╚═╝ ██║███████╗██║ ╚═╝ ██║██║   ██║   ╚██████╔╝
 *  ╚═╝     ╚═╝╚══════╝╚═╝     ╚═╝╚═╝   ╚═╝    ╚═════╝
 *
 *  ╔══════════════════════════════════════════════════════════════╗
 *  ║                         MEMITO COIN                          ║
 *  ║                           $MEMITO                            ║
 *  ║                   MEMELAND CITY — Ethereum                   ║
 *  ╚══════════════════════════════════════════════════════════════╝
 *
 *  ICO-Sale mechanics:
 *  - Token name: MEMITO COIN
 *  - Symbol: MEMITO
 *  - Network: Ethereum
 *  - Total supply: 420,690,000,000,000 MEMITO
 *  - The entire supply is held by this contract at deployment.
 *    The deployer receives nothing.
 *  - Buy with ETH, USDT, USDC, DAI or WBTC
 *  - ICO-Sale start price: 1 MEMITO = $0.00000018585
 *  - No rounds. The price rises continuously with every purchase and is
 *    capped at the listing price: 1 MEMITO = $0.0000040510
 *  - Minimum purchase: $1 equivalent. Maximum: $10,000 per transaction
 *  - 30% of each purchase becomes liquidity in the MEMITO/ETH pool,
 *    and the LP tokens are sent to the burn address — permanently locked
 *  - 70% of each purchase is forwarded to the Ecosystem Wallet, in the very
 *    coin that was paid
 *  - One-level referral reward: 15% in MEMITO tokens
 *  - Buyers receive their MEMITO immediately, in the same transaction.
 *    They cannot sell it through the pool until startTrade() is called,
 *    but the price is already visible in their wallet from the first purchase.
 *
 *  Distribution at startTrade():
 *  - Whatever left this contract during the sale counts as the buyer share
 *  - For every 60 tokens distributed, 15 go to the founder, 15 to the
 *    MEMELAND CITY game treasury and 10 to the NFT reserve
 *  - Everything still held by this contract after that is burned
 *  - The result is always the same, at any sale volume:
 *    60% buyers / 10% NFT / 15% founder / 15% game
 *
 *  Transparency rules:
 *  - Main contract ownership is renounced during deployment. Nothing here can
 *    ever be changed, paused or re-pointed afterwards.
 *  - Only the Ecosystem Wallet contract can call startTrade()
 *  - The game and NFT treasury addresses are read from the Ecosystem Wallet
 *    at startTrade(), and trading cannot open until both are set
 *  - There is no transfer tax. A transfer of MEMITO is a plain transfer.
 */

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IMemitoEcosystemWallet {
    function gameTreasury() external view returns (address);
    function nftTreasury() external view returns (address);
}

contract ReentrancyGuardMEMITO {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract MemitoCoin is IERC20, ReentrancyGuardMEMITO {
    string public constant name = "MEMITO COIN";
    string public constant symbol = "MEMITO";
    uint8 public constant decimals = 18;

    uint256 private constant TOKEN_UNIT = 1e18;

    // ------------------------------------------------------------------
    // Supply and distribution
    // ------------------------------------------------------------------

    uint256 public constant TOTAL_SUPPLY = 420_690_000_000_000 * TOKEN_UNIT;

    // Shares of the FINAL supply, i.e. of what is left alive after the burn.
    uint256 public constant BUYER_SHARE = 60;
    uint256 public constant NFT_SHARE = 10;
    uint256 public constant FOUNDER_SHARE = 15;
    uint256 public constant GAME_SHARE = 15;

    // Buyers can never receive more than 60% of the original supply, because
    // at exactly 60% the other three shares consume the remaining 40% and
    // there is nothing left to burn.
    uint256 public constant SALE_CAP = (TOTAL_SUPPLY * BUYER_SHARE) / 100;

    // ------------------------------------------------------------------
    // Price curve — no rounds
    // ------------------------------------------------------------------

    // All USD values in this contract carry 18 decimals: $1 == 1e18.

    /// @notice $0.00000018585 per MEMITO
    uint256 public constant START_PRICE_USD = 185_850_000_000;

    /// @notice $0.0000040510 per MEMITO — listing price and the price ceiling
    uint256 public constant LISTING_PRICE_USD = 4_051_000_000_000;

    /// @notice price = START * (1 + usdRaised / CURVE_STEP_USD)
    uint256 public constant CURVE_STEP_USD = 50_000 * TOKEN_UNIT;

    uint256 public constant MIN_USD_PURCHASE = 1 * TOKEN_UNIT;
    uint256 public constant MAX_USD_PURCHASE = 10_000 * TOKEN_UNIT;

    uint256 public constant LIQ_PERCENT = 30;
    uint256 public constant ECOSYSTEM_PERCENT = 70;
    uint256 public constant REFERRAL_PERCENT = 15;

    // ------------------------------------------------------------------
    // Ethereum mainnet addresses
    // ------------------------------------------------------------------

    address public constant UNISWAP_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 decimals
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals
    address public constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18 decimals
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 decimals

    /// @dev Chainlink feeds. Reading a price straight from a pool would let
    /// anyone move it inside one transaction and buy tokens for almost nothing.
    address public constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    uint256 public constant PRICE_MAX_AGE = 6 hours;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    // Ownership is shown for transparency. It is set to address(0) in the constructor.
    address public owner;
    address public immutable deployerWallet;
    address payable public immutable ecosystemWallet;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    bool public saleStarted;
    uint256 public saleStartBlock;
    uint256 public buyCount;

    /// @notice Total raised so far, in USD with 18 decimals. Drives the price.
    uint256 public usdRaised;

    uint256 public buyerTokensIssued;
    uint256 public referralTokensIssued;
    uint256 public liquidityTokensUsed;

    bool public tradeOpen;
    address public uniswapPairETH; // MEMITO/WETH pair, public for verification

    mapping(address => address) public referrerOf;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SaleStarted(uint256 indexed blockNumber);
    event TokensPurchased(
        address indexed buyer,
        address indexed paymentToken,
        uint256 paidAmount,
        uint256 usdValue,
        uint256 buyerTokens,
        uint256 referralTokens,
        uint256 priceUsd
    );
    event ReferralSet(address indexed user, address indexed referrer);
    event ReferralPaid(address indexed buyer, address indexed referrer, uint256 amount);
    event LiquidityAdded(uint256 ethAmount, uint256 tokenAmount);
    event FundsForwarded(address indexed token, address indexed to, uint256 amount);
    event TradeStarted(
        uint256 indexed blockNumber,
        uint256 founderTokens,
        uint256 gameTokens,
        uint256 nftTokens,
        uint256 burnedTokens
    );

    modifier onlyEcosystemWallet() {
        require(msg.sender == ecosystemWallet, "only ecosystem wallet");
        _;
    }

    constructor(address payable _ecosystemWallet) {
        require(_ecosystemWallet != address(0), "ecosystem is zero");
        require(_ecosystemWallet.code.length > 0, "ecosystem must be contract");

        owner = msg.sender;
        deployerWallet = msg.sender;
        ecosystemWallet = _ecosystemWallet;

        // The whole supply starts inside this contract. The deployer gets nothing.
        _totalSupply = TOTAL_SUPPLY;
        _balances[address(this)] = TOTAL_SUPPLY;

        emit OwnershipTransferred(address(0), msg.sender);
        emit Transfer(address(0), address(this), TOTAL_SUPPLY);

        // Create the MEMITO/WETH pair now, so the first buyer does not have to
        // pay the gas for creating it.
        address factory = IUniswapV2Router02(UNISWAP_ROUTER).factory();
        address pair = IUniswapV2Factory(factory).getPair(address(this), WETH);
        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(address(this), WETH);
        }
        uniswapPairETH = pair;

        // Main contract ownership is removed immediately after deployment.
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    /// @dev Plain ETH transfers are not purchases. They are forwarded onward.
    receive() external payable {
        if (msg.value > 0 && msg.sender != UNISWAP_ROUTER && msg.sender != WETH) {
            _forwardETH(msg.value);
        }
    }

    // ------------------------------------------------------------------
    // ERC20
    // ------------------------------------------------------------------

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address tokenOwner, address spender) public view override returns (uint256) {
        return _allowances[tokenOwner][spender];
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "allowance exceeded");
        _approve(from, msg.sender, currentAllowance - amount);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 currentAllowance = _allowances[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "allowance below zero");
        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }

    // ------------------------------------------------------------------
    // Buying
    // ------------------------------------------------------------------

    function buyWithETH(address refer) external payable nonReentrant returns (bool) {
        require(!tradeOpen, "ICO-Sale closed");
        require(msg.value > 0, "no ETH sent");

        uint256 usdValue = _usdValueOfETH(msg.value);
        uint256 liqETH = (msg.value * LIQ_PERCENT) / 100;

        (uint256 buyerTokens, uint256 referralTokens) = _processPurchase(usdValue, refer);

        _addLiquidity(liqETH, (usdValue * LIQ_PERCENT) / 100);
        _forwardETH(address(this).balance);

        emit TokensPurchased(msg.sender, address(0), msg.value, usdValue, buyerTokens, referralTokens, currentPriceUSD());
        return true;
    }

    function buyWithToken(address token, uint256 amount, address refer) external nonReentrant returns (bool) {
        require(!tradeOpen, "ICO-Sale closed");
        require(_isSupported(token), "token not supported");
        require(amount > 0, "no amount");

        _safeTransferFrom(token, msg.sender, address(this), amount);

        uint256 usdValue = _usdValueOfToken(token, amount);
        uint256 liqAmount = (amount * LIQ_PERCENT) / 100;

        (uint256 buyerTokens, uint256 referralTokens) = _processPurchase(usdValue, refer);

        // Whatever the buyer paid with, the liquidity share becomes ETH, so the
        // whole project keeps one deep MEMITO/ETH pool instead of five thin ones.
        uint256 ethFromSwap = _swapToETH(token, liqAmount);
        _addLiquidity(ethFromSwap, (usdValue * LIQ_PERCENT) / 100);

        // The remaining 70% goes to the Ecosystem Wallet in the coin that was paid.
        _forwardToken(token, amount - liqAmount);
        _forwardETH(address(this).balance);

        emit TokensPurchased(msg.sender, token, amount, usdValue, buyerTokens, referralTokens, currentPriceUSD());
        return true;
    }

    function _processPurchase(uint256 usdValue, address refer)
        internal
        returns (uint256 buyerTokens, uint256 referralTokens)
    {
        require(usdValue >= MIN_USD_PURCHASE, "min $1");
        require(usdValue <= MAX_USD_PURCHASE, "max $10000");

        if (!saleStarted) {
            saleStarted = true;
            saleStartBlock = block.number;
            emit SaleStarted(block.number);
        }

        buyerTokens = _tokensForUSD(usdValue);

        _setReferrer(msg.sender, refer);
        referralTokens = _referralAmount(msg.sender, buyerTokens);

        uint256 liqTokens = _lpTokensForUSD((usdValue * LIQ_PERCENT) / 100);

        require(_balances[address(this)] >= buyerTokens + referralTokens + liqTokens, "not enough MEMITO left");
        require(
            (TOTAL_SUPPLY - _balances[address(this)]) + buyerTokens + referralTokens + liqTokens <= SALE_CAP,
            "sale cap reached"
        );

        usdRaised += usdValue;

        if (referralTokens > 0) {
            address referrer = referrerOf[msg.sender];
            _balances[address(this)] -= referralTokens;
            _balances[referrer] += referralTokens;
            referralTokensIssued += referralTokens;
            emit Transfer(address(this), referrer, referralTokens);
            emit ReferralPaid(msg.sender, referrer, referralTokens);
        }

        _balances[address(this)] -= buyerTokens;
        _balances[msg.sender] += buyerTokens;
        emit Transfer(address(this), msg.sender, buyerTokens);

        buyCount += 1;
        buyerTokensIssued += buyerTokens;
    }

    // ------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------

    /**
     * @dev Opens trading, hands out the founder, game and NFT shares and burns
     * every MEMITO still held by this contract. Callable only by the Ecosystem
     * Wallet, which is also where the treasury addresses live.
     */
    function startTrade() external onlyEcosystemWallet nonReentrant {
        require(!tradeOpen, "trade already open");

        address gameTreasury = IMemitoEcosystemWallet(ecosystemWallet).gameTreasury();
        address nftTreasury = IMemitoEcosystemWallet(ecosystemWallet).nftTreasury();
        require(gameTreasury != address(0), "game treasury not set");
        require(nftTreasury != address(0), "nft treasury not set");

        uint256 held = _balances[address(this)];
        uint256 distributed = TOTAL_SUPPLY - held;

        // For every 60 tokens that went out, 15 to the founder, 15 to the game
        // and 10 to the NFT reserve. The result is exactly 60/10/15/15 of the
        // final supply, whatever the sale volume turned out to be.
        uint256 founderTokens = (distributed * FOUNDER_SHARE) / BUYER_SHARE;
        uint256 gameTokens = (distributed * GAME_SHARE) / BUYER_SHARE;
        uint256 nftTokens = (distributed * NFT_SHARE) / BUYER_SHARE;

        uint256 payout = founderTokens + gameTokens + nftTokens;
        require(held >= payout, "not enough left for shares");

        _balances[address(this)] = held - payout;

        _balances[ecosystemWallet] += founderTokens;
        emit Transfer(address(this), ecosystemWallet, founderTokens);

        _balances[gameTreasury] += gameTokens;
        emit Transfer(address(this), gameTreasury, gameTokens);

        _balances[nftTreasury] += nftTokens;
        emit Transfer(address(this), nftTreasury, nftTokens);

        uint256 burnAmount = _balances[address(this)];
        if (burnAmount > 0) {
            _balances[address(this)] = 0;
            _totalSupply -= burnAmount;
            emit Transfer(address(this), address(0), burnAmount);
        }

        tradeOpen = true;
        emit TradeStarted(block.number, founderTokens, gameTokens, nftTokens, burnAmount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Current sale price of 1 MEMITO in USD, 18 decimals.
    function currentPriceUSD() public view returns (uint256) {
        uint256 price = START_PRICE_USD + (START_PRICE_USD * usdRaised) / CURVE_STEP_USD;
        return price > LISTING_PRICE_USD ? LISTING_PRICE_USD : price;
    }

    function quoteTokensForUSD(uint256 usdAmount) external view returns (uint256) {
        return _tokensForUSD(usdAmount);
    }

    function quoteTokensForETH(uint256 ethAmount) external view returns (uint256) {
        return _tokensForUSD(_usdValueOfETH(ethAmount));
    }

    function quoteTokensForToken(address token, uint256 amount) external view returns (uint256) {
        require(_isSupported(token), "token not supported");
        return _tokensForUSD(_usdValueOfToken(token, amount));
    }

    function viewSale()
        external
        view
        returns (
            bool Started,
            bool TradeOpen,
            uint256 UsdRaised,
            uint256 BuyCount,
            uint256 CurrentPriceUSD,
            uint256 RemainingContractTokens,
            uint256 BuyerTokensIssued,
            uint256 ReferralTokensIssued,
            uint256 LiquidityTokensUsed,
            uint256 SaleCap
        )
    {
        return (
            saleStarted,
            tradeOpen,
            usdRaised,
            buyCount,
            currentPriceUSD(),
            _balances[address(this)],
            buyerTokensIssued,
            referralTokensIssued,
            liquidityTokensUsed,
            SALE_CAP
        );
    }

    // ------------------------------------------------------------------
    // Pricing helpers
    // ------------------------------------------------------------------

    function _tokensForUSD(uint256 usdAmount18) internal view returns (uint256) {
        return (usdAmount18 * TOKEN_UNIT) / currentPriceUSD();
    }

    function _lpTokensForUSD(uint256 usdAmount18) internal pure returns (uint256) {
        return (usdAmount18 * TOKEN_UNIT) / LISTING_PRICE_USD;
    }

    function _isSupported(address token) internal pure returns (bool) {
        return token == USDT || token == USDC || token == DAI || token == WBTC;
    }

    function _feedPrice(address feed) internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = IChainlinkFeed(feed).latestRoundData();
        require(answer > 0, "bad feed price");
        require(block.timestamp - updatedAt <= PRICE_MAX_AGE, "stale feed price");
        return uint256(answer); // 8 decimals
    }

    function _usdValueOfETH(uint256 ethAmount) internal view returns (uint256) {
        return (ethAmount * _feedPrice(ETH_USD_FEED)) / 1e8;
    }

    /**
     * @dev USDT and USDC carry 6 decimals, DAI 18 and WBTC 8. Treating them all
     * as 18 would misprice a purchase by a factor of a trillion, so every coin
     * is normalised explicitly.
     */
    function _usdValueOfToken(address token, uint256 amount) internal view returns (uint256) {
        if (token == USDT || token == USDC) {
            return amount * 1e12; // 6 -> 18 decimals, 1 unit == $1
        }
        if (token == DAI) {
            return amount; // already 18 decimals, 1 unit == $1
        }
        // WBTC: 8 decimals, priced through Chainlink
        return (amount * _feedPrice(BTC_USD_FEED)) * 1e2;
    }

    // ------------------------------------------------------------------
    // Referral
    // ------------------------------------------------------------------

    function _setReferrer(address user, address refer) internal {
        if (referrerOf[user] != address(0)) return;
        if (refer == address(0)) return;
        if (refer == user) return;
        if (refer == address(this)) return;
        if (refer == ecosystemWallet) return;
        if (_balances[refer] == 0) return;

        referrerOf[user] = refer;
        emit ReferralSet(user, refer);
    }

    function _referralAmount(address buyer, uint256 buyerTokens) internal view returns (uint256) {
        if (referrerOf[buyer] == address(0)) return 0;
        return (buyerTokens * REFERRAL_PERCENT) / 100;
    }

    // ------------------------------------------------------------------
    // Liquidity and payouts
    // ------------------------------------------------------------------

    function _swapToETH(address token, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WETH;

        _safeApprove(token, UNISWAP_ROUTER, amount);

        uint256 before = address(this).balance;
        IUniswapV2Router02(UNISWAP_ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 1200
        );
        return address(this).balance - before;
    }

    function _addLiquidity(uint256 ethAmount, uint256 usdForLiq) internal {
        if (ethAmount == 0 || usdForLiq == 0) return;

        uint256 tokenAmount = _lpTokensForUSD(usdForLiq);
        if (tokenAmount == 0 || _balances[address(this)] < tokenAmount) return;

        _approve(address(this), UNISWAP_ROUTER, tokenAmount);

        // LP tokens go to the burn address: the liquidity can never be pulled out.
        IUniswapV2Router02(UNISWAP_ROUTER).addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            BURN_ADDRESS,
            block.timestamp + 1200
        );

        liquidityTokensUsed += tokenAmount;
        emit LiquidityAdded(ethAmount, tokenAmount);
    }

    function _forwardETH(uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = ecosystemWallet.call{value: amount}("");
        require(success, "ecosystem ETH transfer failed");
        emit FundsForwarded(address(0), ecosystemWallet, amount);
    }

    function _forwardToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        _safeTransfer(token, ecosystemWallet, amount);
        emit FundsForwarded(token, ecosystemWallet, amount);
    }

    // ------------------------------------------------------------------
    // Non-standard ERC20 helpers
    // ------------------------------------------------------------------

    /**
     * @dev USDT on Ethereum returns nothing from transfer, transferFrom and
     * approve. A plain require(...transfer(...)) reverts on it every time,
     * which would make buying with USDT impossible. These helpers accept both
     * standard and non-standard tokens.
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token transferFrom failed");
    }

    /// @dev USDT also refuses a non-zero approve over a non-zero allowance.
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok0, ) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        ok0; // some tokens return nothing here, the result is intentionally ignored
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token approve failed");
    }

    // ------------------------------------------------------------------
    // Internal ERC20
    // ------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "from is zero");
        require(to != address(0), "to is zero");

        _checkTradeLock(from, to);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "balance too low");
        _balances[from] = fromBalance - amount;
        _balances[to] += amount;

        emit Transfer(from, to, amount);
    }

    function _approve(address tokenOwner, address spender, uint256 amount) internal {
        require(tokenOwner != address(0), "owner is zero");
        require(spender != address(0), "spender is zero");

        _allowances[tokenOwner][spender] = amount;
        emit Approval(tokenOwner, spender, amount);
    }

    /**
     * @dev Before startTrade() nobody can trade through the pool, but the pool
     * itself already exists and already holds liquidity — so wallets show a
     * price for MEMITO from the very first purchase. Buyers hold real tokens
     * the whole time, not a promise.
     */
    function _checkTradeLock(address from, address to) internal view {
        if (tradeOpen) return;
        if (uniswapPairETH == address(0)) return;

        if (from == uniswapPairETH || to == uniswapPairETH) {
            require(from == address(this) || to == address(this), "trade not started");
        }
    }
}
