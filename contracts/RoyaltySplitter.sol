// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

/// @title RoyaltySplitter — the 5% secondary royalty, cut 3/2
/// @notice ERC-2981 lets a collection name exactly ONE royalty receiver. The
///         deal is 3% to the Ecosystem Wallet and 2% to the city treasury, so
///         the named receiver is this contract and it does the cut.
///
/// @dev No owner, no rescue function, no settable shares. Whatever lands here
///      can only leave along the two hardcoded paths. That matters more than it
///      looks: the treasury half is the part players are told backs the golden
///      frog exchange rate, and a splitter with a withdraw button would make
///      that a promise instead of a fact.
///
///      Because there is no rescue, both destinations are checked at birth for
///      the one thing that would make them a black hole: an inability to accept
///      what this contract sends them.
contract RoyaltySplitter {
    /// @notice 3 of the 5 royalty points.
    uint256 public constant ECOSYSTEM_BP = 6000;
    /// @notice 2 of the 5 royalty points. Documentation only — the treasury is
    ///         paid the remainder, so no wei can be stranded by rounding.
    uint256 public constant TREASURY_BP = 4000;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Below this much gas left, an arriving royalty is banked instead
    ///         of split. The split itself costs roughly 60,000; the margin is
    ///         there so that a failed attempt still leaves the outer receive()
    ///         enough gas to return.
    uint256 public constant SPLIT_GAS_FLOOR = 100_000;

    address payable public immutable ecosystem;

    /// @notice The CityTreasury. Named for what it IS, not for the game
    ///         contract: MemelandCity holds no money, accepts no ETH and would
    ///         swallow every royalty ever paid if it were wired in here.
    address payable public immutable treasury;

    uint256 public releasedEth;

    /// @notice What a destination refused to take, held for it until it can.
    /// @dev Both halves used to travel together or not at all: a single
    ///      `if (!ok) revert TransferFailed()` on either leg took the whole
    ///      release down, so a receiver that had come to refuse ETH — a
    ///      multisig mid-upgrade, a contract whose fallback started reverting,
    ///      a gas-hungry receive() — locked up the OTHER destination's money as
    ///      well as its own, for ever, with no owner and no rescue. Now a
    ///      refusal is banked against that one address and the other half is
    ///      paid. Nothing is redirectable: the only two addresses in this file
    ///      are immutable, and withdrawOwed pays them and nobody else.
    ///      keccak(asset, who) => amount, with asset 0 meaning ETH.
    mapping(bytes32 => uint256) public owed;

    /// @notice Total ETH held back for a refusing destination, so `_releaseEth`
    ///         never splits money that already belongs to someone.
    uint256 public owedEthTotal;

    /// @dev Both destinations are contracts that run code on receiving ETH. The
    ///      guard is not protecting a balance (there is nothing to steal here),
    ///      it just keeps a re-entering receiver from splitting the same pot
    ///      twice and leaving the outer call to fail on an empty balance.
    uint256 private _lock = 1;

    event RoyaltyReceived(address indexed from, uint256 amount);
    event Released(address indexed asset, uint256 toEcosystem, uint256 toTreasury);
    event PaymentBanked(address indexed asset, address indexed to, uint256 amount);
    event OwedPaid(address indexed asset, address indexed to, uint256 amount);

    error NothingToRelease();
    error TransferFailed();
    error ZeroAddress();
    error Reentrancy();
    error CannotReceiveEth();
    error NotSelf();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param ecosystem_ the founder wallet, 60% of the royalty
    /// @param treasury_  the CityTreasury, 40% of the royalty
    constructor(address ecosystem_, address treasury_) {
        if (ecosystem_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        ecosystem = payable(ecosystem_);
        treasury = payable(treasury_);

        // A zero-value call with empty calldata reaches receive()/fallback() and
        // reverts on a contract that has neither. Costs nothing here and turns
        // "every ETH royalty is stuck forever" into a failed deployment.
        _requireAcceptsEth(ecosystem_);
        _requireAcceptsEth(treasury_);
    }

    function _requireAcceptsEth(address to) private {
        (bool ok, ) = to.call{value: 0}("");
        if (!ok) revert CannotReceiveEth();
    }

    /// @notice ETH royalties are split and pushed on the way in, in the same
    ///         transaction as the sale that paid them. Nobody has to press
    ///         anything to be paid.
    /// @dev The split is attempted through a self-call so that it CANNOT break
    ///      the payment. Marketplaces pay royalties with a bare transfer, some
    ///      of them on a tight gas stipend; if the split runs out of gas, or a
    ///      destination refuses the call, the catch swallows it and the money
    ///      simply stays here for the permissionless release() below. A royalty
    ///      that arrives is never a royalty that reverts a sale.
    receive() external payable {
        emit RoyaltyReceived(msg.sender, msg.value);
        // Two guards, not one. The gas check is the important one: a sender
        // using the old 2,300-wei stipend has nowhere near enough for a split,
        // and 63/64 of a stipend that small would be consumed by the attempt
        // before the catch could save us. Below the threshold the money simply
        // waits for release(). Above it, try/catch covers a destination that
        // refuses the call for some other reason.
        if (gasleft() > SPLIT_GAS_FLOOR) {
            try this.pushOnReceive() {} catch {}
        }
    }

    /// @notice The split, callable only by this contract from inside receive().
    /// @dev External so that receive() can wrap it in try/catch. It is not a
    ///      hole: it does exactly what release() does, which anyone may call
    ///      anyway, and the two destinations are immutable.
    function pushOnReceive() external nonReentrant returns (uint256 toEcosystem, uint256 toTreasury) {
        if (msg.sender != address(this)) revert NotSelf();
        return _releaseEth();
    }

    /// @notice Push whatever ETH is sitting here to the two destinations.
    /// @dev Kept as a safety valve, not as the normal path: ETH that arrives
    ///      through receive() has already been split. This catches the leftovers
    ///      — a force-fed selfdestruct, a block reward, or a payment whose gas
    ///      was too tight for the automatic split. Anyone may call it.
    function release() external nonReentrant returns (uint256 toEcosystem, uint256 toTreasury) {
        return _releaseEth();
    }

    /// @notice Same for a royalty paid in an ERC-20.
    /// @dev WETH is the common one — Blur settles in it exclusively and every
    ///      Seaport bid does too — and the treasury does NOT accept WETH, so
    ///      forwarding it there would burn the money it was sent to protect.
    ///      It is unwrapped and split as ETH instead.
    ///
    ///      Every other token is split the same way as everything else. There
    ///      used to be a gate here that refused any token the treasury cannot
    ///      value, and in a file with no rescue function that gate was a
    ///      furnace: Seaport lets a seller price an order in ANY ERC-20 and
    ///      pays the 2981 royalty in that same token, so one such sale burned
    ///      the whole royalty for good. The gate protected nobody — the two
    ///      destinations are immutable, and this money never had anywhere else
    ///      to go. The ecosystem wallet can move any ERC-20 it holds; the
    ///      treasury cannot, so its 40% of an unpriceable coin stays put. A
    ///      coin held by its owners still beats a coin held by nobody.
    function releaseToken(address token)
        external
        nonReentrant
        returns (uint256 toEcosystem, uint256 toTreasury)
    {
        if (token == WETH) {
            uint256 wrapped = IERC20(WETH).balanceOf(address(this));
            if (wrapped != 0) IWETH(WETH).withdraw(wrapped);
            return _releaseEth();
        }

        // address(0) is ETH's key in `owed` and _payOrBank reads it as ETH. A
        // token path reaching it would double-count owedEthTotal and underflow
        // _releaseEth for ever. The balanceOf below reverts on the empty
        // extcodesize anyway; this says so out loud rather than leaning on it.
        if (token == address(0)) revert ZeroAddress();

        uint256 held = owed[keccak256(abi.encode(token, ecosystem))] +
            owed[keccak256(abi.encode(token, treasury))];
        // Saturating, not checked. `held` is nominal — it was banked at the
        // size a refused transfer asked for — and now that any ERC-20 can get
        // in here, one that rebases down or burns while held can put the real
        // balance under it. A checked subtraction would panic in the only way
        // out this token has, which is the trap this pass exists to close.
        uint256 raw = IERC20(token).balanceOf(address(this));
        uint256 bal = raw > held ? raw - held : 0;
        if (bal == 0) revert NothingToRelease();

        toEcosystem = (bal * ECOSYSTEM_BP) / 10000;
        toTreasury = bal - toEcosystem;

        // Same rule as ETH: one destination refusing the token does not strand
        // the other's share.
        _payOrBank(token, ecosystem, toEcosystem);
        _payOrBank(token, treasury, toTreasury);

        emit Released(token, toEcosystem, toTreasury);
    }

    function _releaseEth() private returns (uint256 toEcosystem, uint256 toTreasury) {
        uint256 bal = address(this).balance - owedEthTotal;
        if (bal == 0) revert NothingToRelease();

        toEcosystem = (bal * ECOSYSTEM_BP) / 10000;
        toTreasury = bal - toEcosystem; // the remainder, so no wei is ever stranded
        releasedEth += bal;

        _payOrBank(address(0), ecosystem, toEcosystem);
        _payOrBank(address(0), treasury, toTreasury);

        emit Released(address(0), toEcosystem, toTreasury);
    }

    /// @dev Push it; if the destination will not take it, hold it for them.
    function _payOrBank(address asset, address payable to, uint256 amount) private {
        if (amount == 0) return;
        bool ok;
        if (asset == address(0)) {
            (ok, ) = to.call{value: amount, gas: 100_000}("");
        } else {
            (bool sent, bytes memory data) = asset.call(
                abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
            );
            ok = sent && (data.length == 0 || abi.decode(data, (bool)));
        }
        if (ok) return;

        owed[keccak256(abi.encode(asset, to))] += amount;
        if (asset == address(0)) owedEthTotal += amount;
        emit PaymentBanked(asset, to, amount);
    }

    /// @notice Hand a destination what it once refused. Permissionless, because
    ///         it pays nobody but the two immutable addresses in this file, and
    ///         because the party that has to be able to call it may be a
    ///         contract that cannot call anything.
    function withdrawOwed(address asset, address who) external nonReentrant returns (uint256 amount) {
        if (who != ecosystem && who != treasury) revert ZeroAddress();
        bytes32 k = keccak256(abi.encode(asset, who));
        amount = owed[k];
        if (amount == 0) revert NothingToRelease();

        if (asset == address(0)) {
            owed[k] = 0;
            owedEthTotal -= amount;
            (bool ok, ) = payable(who).call{value: amount}("");
            if (!ok) {
                owed[k] = amount;
                owedEthTotal += amount;
                revert TransferFailed();
            }
        } else {
            // The same shrinking balance, at the other end. `amount` was banked
            // nominally, so once the real balance falls under it this transfer
            // reverts on the missing part for ever — while releaseToken counts
            // that same balance as already spoken for and releases nothing.
            // Between the two, every unit of the token is locked in. Hand over
            // what is really here and leave the rest standing, in case the
            // balance comes back.
            uint256 have = IERC20(asset).balanceOf(address(this));
            if (have == 0) revert NothingToRelease();
            if (have < amount) {
                owed[k] = amount - have;
                amount = have;
            } else {
                owed[k] = 0;
            }
            _safeTransfer(asset, who, amount);
        }
        emit OwedPaid(asset, who, amount);
    }

    /// @dev USDT and its clones return nothing at all from transfer. A plain
    ///      require(token.transfer(...)) reverts on them for no reason.
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
