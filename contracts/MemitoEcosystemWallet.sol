// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Submitted for MEMITO COIN ICO-Sale
 *
 *  ███╗   ███╗ ███████╗ ███╗   ███╗ ██╗ ████████╗ ██████╗
 *  ████╗ ████║ ██╔════╝ ████╗ ████║ ██║ ╚══██╔══╝██╔═══██╗
 *  ██╔████╔██║ █████╗   ██╔████╔██║ ██║    ██║   ██║   ██║
 *  ██║╚██╔╝██║ ██╔══╝   ██║╚██╔╝██║ ██║    ██║   ██║   ██║
 *  ██║ ╚═╝ ██║ ███████╗ ██║ ╚═╝ ██║ ██║    ██║   ╚██████╔╝
 *  ╚═╝     ╚═╝ ╚══════╝ ╚═╝     ╚═╝ ╚═╝    ╚═╝    ╚═════╝
 *
 *  ╔══════════════════════════════════════════════════════════════╗
 *  ║                    MEMITO ECOSYSTEM WALLET                   ║
 *  ║                         MEMITO SAFE                          ║
 *  ╚══════════════════════════════════════════════════════════════╝
 *
 *  MEMITO COIN ($MEMITO) Ecosystem Wallet — Ethereum Mainnet
 *
 *  What this contract does:
 *  - Receives 70% of every MEMITO ICO-Sale purchase, in the coin that was paid
 *    (ETH, USDT, USDC, DAI, WBTC)
 *  - Receives the 15% founder share of MEMITO at startTrade()
 *  - Owner can withdraw ETH or any ERC20 at any time, freely
 *  - Owner holds the only key that can open trading: startMemitoCoinTrade()
 *  - Owner registers the MEMELAND CITY game treasury and the NFT reserve here;
 *    the MEMITO COIN contract reads both of them at startTrade()
 *  - Owner publishes the official MEMELAND CITY and NFT contract addresses
 *    on-chain, so buyers can verify them without trusting a link
 *
 *  IMPORTANT — there is no renounceOwnership() in this contract, on purpose.
 *  This wallet is the only address allowed to call startTrade() on the token.
 *  If ownership were renounced, trading could never be opened, and every token
 *  and every dollar held here would stay locked forever.
 *
 *  ICO-Sale reference:
 *  - Token name: MEMITO COIN
 *  - Symbol: MEMITO
 *  - Network: Ethereum
 *  - Buy with ETH, USDT, USDC, DAI or WBTC
 *  - ICO-Sale start price: 1 MEMITO = $0.00000018585
 *  - Price rises continuously with every purchase, capped at the listing price
 *  - Listing price for automatic LP: 1 MEMITO = $0.0000040510
 *  - 30% of every purchase goes to automatic liquidity (LP tokens are burned)
 *  - 70% of every purchase is forwarded to this Ecosystem Wallet contract
 *  - One-level referral reward is handled by the MEMITO COIN contract
 *  - Game: MEMELAND CITY
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

interface IMemitoCoinTrade {
    function startTrade() external;
}

contract ReentrancyGuard {
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

contract Owned {
    address public owner;
    address public newOwner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "owner is zero");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    /**
     * @dev Two-step handover. With a one-step transfer, a single typo in the
     * address would destroy control of this wallet permanently.
     */
    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "new owner is zero");
        newOwner = _newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == newOwner, "not new owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }

    // renounceOwnership() intentionally does not exist. See the header note.
}

contract MemitoEcosystemWallet is Owned, ReentrancyGuard {
    /// @notice MEMELAND CITY game treasury. Receives 15% of MEMITO at startTrade().
    address public gameTreasury;

    /// @notice NFT reserve. Receives 10% of MEMITO at startTrade().
    address public nftTreasury;

    /// @notice Official MEMELAND CITY game contract, published for verification.
    address public officialGameContract;

    /// @notice Official MEMITO NFT collection, published for verification.
    address public officialNftCollection;

    event ETHReceived(address indexed from, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);
    event MemitoCoinTradeStarted(address indexed memitoCoin);
    event GameTreasurySet(address indexed previous, address indexed current);
    event NftTreasurySet(address indexed previous, address indexed current);
    event OfficialGameContractSet(address indexed previous, address indexed current);
    event OfficialNftCollectionSet(address indexed previous, address indexed current);

    constructor(address walletOwner) Owned(walletOwner == address(0) ? msg.sender : walletOwner) {}

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // Treasury addresses, read by the MEMITO COIN contract at startTrade()
    // ------------------------------------------------------------------

    /**
     * @dev The MEMITO COIN contract renounces its own ownership during
     * deployment, so nothing can be configured there afterwards. These two
     * addresses live here instead, and the token reads them at startTrade().
     * Trading cannot open until both are set, otherwise the game and NFT
     * shares would be burned by mistake and could never be recovered.
     */
    function setGameTreasury(address treasury) external onlyOwner {
        require(treasury != address(0), "treasury is zero");
        emit GameTreasurySet(gameTreasury, treasury);
        gameTreasury = treasury;
    }

    function setNftTreasury(address treasury) external onlyOwner {
        require(treasury != address(0), "treasury is zero");
        emit NftTreasurySet(nftTreasury, treasury);
        nftTreasury = treasury;
    }

    // ------------------------------------------------------------------
    // Public registry — anti-scam
    // ------------------------------------------------------------------

    /**
     * @dev Cloned games and fake NFT collections are the most common way a
     * project's own audience gets robbed. Publishing the real addresses here
     * gives buyers a source of truth on-chain instead of a link in a chat.
     */
    function setOfficialGameContract(address gameContract) external onlyOwner {
        emit OfficialGameContractSet(officialGameContract, gameContract);
        officialGameContract = gameContract;
    }

    function setOfficialNftCollection(address collection) external onlyOwner {
        emit OfficialNftCollectionSet(officialNftCollection, collection);
        officialNftCollection = collection;
    }

    // ------------------------------------------------------------------
    // Withdrawals — free, no time lock
    // ------------------------------------------------------------------

    function withdrawETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "to is zero");
        uint256 balance = address(this).balance;
        uint256 toSend = amount == 0 ? balance : amount;
        require(toSend > 0, "nothing to withdraw");
        require(toSend <= balance, "insufficient ETH");

        (bool success, ) = to.call{value: toSend}("");
        require(success, "ETH withdraw failed");

        emit ETHWithdrawn(to, toSend);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(0), "token is zero");
        require(to != address(0), "to is zero");

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 toSend = amount == 0 ? balance : amount;
        require(toSend > 0, "nothing to withdraw");
        require(toSend <= balance, "insufficient token");

        _safeTransfer(token, to, toSend);

        emit TokenWithdrawn(token, to, toSend);
    }

    /**
     * @dev USDT on Ethereum does not return a bool from transfer(). A plain
     * require(IERC20(token).transfer(...)) reverts on it every single time,
     * which would strand every dollar of USDT this wallet receives. This
     * helper accepts both standard and non-standard tokens.
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "token transfer failed");
    }

    // ------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------

    /**
     * @dev This wallet is the only address allowed to open trading in the
     * MEMITO COIN token contract. One call distributes the founder, game and
     * NFT shares and burns every unsold token, in a single transaction.
     */
    function startMemitoCoinTrade(address memitoCoin) external onlyOwner {
        require(memitoCoin != address(0), "token is zero");
        require(gameTreasury != address(0), "game treasury not set");
        require(nftTreasury != address(0), "nft treasury not set");

        IMemitoCoinTrade(memitoCoin).startTrade();
        emit MemitoCoinTradeStarted(memitoCoin);
    }
}
