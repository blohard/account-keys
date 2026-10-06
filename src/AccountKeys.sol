// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LowLevelCall} from "@openzeppelin/contracts/utils/LowLevelCall.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title AccountKeys
/// @notice One shared market where every account can open its own keys to trading, priced on a
///         bonding curve. See SPEC.md.
contract AccountKeys is ReentrancyGuardTransient {
    /// @notice The most keys a market can have outstanding.
    uint256 public constant MAX_SUPPLY = type(uint32).max;
    /// @notice A flat amount in every key's price.
    uint256 public constant BASE_PRICE = 0.00001 ether;
    /// @notice Scales the curve. The ETH backing s outstanding keys is
    ///         reserveAt(s) = BASE_PRICE * s + floor(sqrt(RESERVE_SCALE * s^5)).
    uint256 public constant RESERVE_SCALE = 1.6e23;
    /// @notice The creator's fee in basis points (4.5%), charged on every purchase, sale and
    ///         transfer.
    uint256 public constant CREATOR_FEE_BPS = 450;
    /// @notice The dev fund's fee in basis points (0.5%), charged on every purchase, sale and
    ///         transfer.
    uint256 public constant DEV_FEE_BPS = 50;
    /// @notice Receives the development fees. Fixed at deployment.
    address public immutable DEV_FUND;

    /// @notice A trade's price. `total` is what a purchase costs, what a sale pays out, or a
    ///         transfer's fee.
    struct Quote {
        uint256 curveValue;
        uint256 creatorFee;
        uint256 devFee;
        uint256 total;
    }

    /// @notice Whether the creator has activated their market.
    mapping(address creator => bool) public active;
    /// @notice Outstanding keys for each creator.
    mapping(address creator => uint256) public supply;
    /// @notice Keys held by an account in a creator's market.
    mapping(address creator => mapping(address holder => uint256)) public balanceOf;
    /// @notice Fees owed to each recipient.
    mapping(address recipient => uint256) public claimableFees;

    event Activated(address indexed creator);
    event Trade(
        address indexed creator,
        address indexed trader,
        bool isBuy,
        uint256 amount,
        uint256 curveValue,
        uint256 creatorFee,
        uint256 devFee,
        uint256 newSupply
    );
    event KeysTransferred(
        address indexed creator,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 referenceValue,
        uint256 creatorFee,
        uint256 devFee
    );
    event FeesClaimed(address indexed recipient, uint256 amount);

    error ZeroAddress();
    error InvalidRecipient();
    error AlreadyActive();
    error InactiveMarket();
    error InvalidAmount();
    error SupplyLimit();
    error InsufficientKeys();
    error Expired();
    error Slippage();
    error InsufficientPayment();
    error PaymentFailed();

    constructor(address devFund) {
        if (devFund == address(0)) revert ZeroAddress();
        DEV_FUND = devFund;
    }

    /// @notice The ETH, in wei, that backs a market with s outstanding keys.
    function reserveAt(uint256 s) public pure returns (uint256) {
        if (s > MAX_SUPPLY) revert SupplyLimit();
        return BASE_PRICE * s + Math.sqrt(RESERVE_SCALE * s * s * s * s * s);
    }

    /// @notice The price of key n in wei before fees, which is reserveAt(n) - reserveAt(n - 1).
    function price(uint256 n) public pure returns (uint256) {
        if (n == 0) revert SupplyLimit();
        return reserveAt(n) - reserveAt(n - 1);
    }

    /// @notice Quotes buying `amount` keys when `startSupply` are outstanding, for example a
    ///         creator's first keys before activation.
    function quoteAtSupply(uint256 startSupply, uint256 amount)
        public
        pure
        returns (Quote memory q)
    {
        if (amount == 0) revert InvalidAmount();
        if (startSupply > MAX_SUPPLY || amount > MAX_SUPPLY - startSupply) {
            revert SupplyLimit();
        }
        return _quote(reserveAt(startSupply + amount) - reserveAt(startSupply));
    }

    function _quote(uint256 value) private pure returns (Quote memory q) {
        q.curveValue = value;
        q.creatorFee = q.curveValue * CREATOR_FEE_BPS / 10_000;
        q.devFee = q.curveValue * DEV_FEE_BPS / 10_000;
        q.total = q.curveValue + q.creatorFee + q.devFee;
    }

    /// @notice Quotes buying `amount` of the creator's keys now. Reverts if the market is inactive.
    function quoteBuy(address creator, uint256 amount) public view returns (Quote memory) {
        if (!active[creator]) revert InactiveMarket();
        return quoteAtSupply(supply[creator], amount);
    }

    /// @notice Quotes selling `amount` of the creator's keys back to the market now.
    function quoteSell(address creator, uint256 amount) public view returns (Quote memory q) {
        if (!active[creator]) revert InactiveMarket();
        if (amount == 0) revert InvalidAmount();
        uint256 current = supply[creator];
        if (amount > current) revert InsufficientKeys();
        q = quoteAtSupply(current - amount, amount);
        q.total = q.curveValue - q.creatorFee - q.devFee;
    }

    /// @notice Quotes the fee for transferring `amount` keys, 5% of what selling them would pay
    ///         before fees.
    function quoteTransfer(address creator, uint256 amount) public view returns (Quote memory q) {
        if (amount == 0) revert InvalidAmount();
        uint256 current = supply[creator];
        if (amount > current) revert InsufficientKeys();
        q = _quote(reserveAt(current) - reserveAt(current - amount));
        q.total = q.creatorFee + q.devFee;
    }

    /// @notice Moves the caller's keys to `to`, charging the 5% fee and refunding any excess ETH.
    function transfer(address creator, address to, uint256 amount, uint256 maxFee, uint256 deadline)
        external
        payable
        nonReentrant
    {
        _deadline(deadline);
        if (to == address(0)) revert ZeroAddress();
        if (to == msg.sender || to == address(this)) revert InvalidRecipient();
        if (balanceOf[creator][msg.sender] < amount) revert InsufficientKeys();
        Quote memory q = quoteTransfer(creator, amount);
        if (q.total > maxFee) revert Slippage();
        if (msg.value < q.total) revert InsufficientPayment();
        // KeysTransferred below records the change.
        // forge-lint: disable-next-line(missing-events-access-control)
        balanceOf[creator][msg.sender] -= amount;
        balanceOf[creator][to] += amount;
        _accrue(creator, q);
        // The linter mistakes the quote's internal Math.sqrt for an external call.
        // forge-lint: disable-next-line(reentrancy-events)
        emit KeysTransferred(creator, msg.sender, to, amount, q.curveValue, q.creatorFee, q.devFee);
        _pay(msg.sender, msg.value - q.total);
    }

    /// @notice Activates the caller's market, and optionally buys its first keys in the same
    ///         transaction. Activating without keys costs nothing, and any excess ETH is refunded.
    function activate(uint256 initialAmount, uint256 maxTotalCost, uint256 deadline)
        external
        payable
        nonReentrant
    {
        _deadline(deadline);
        if (active[msg.sender]) revert AlreadyActive();
        // The Activated event below records this one-time change.
        // forge-lint: disable-next-line(missing-events-access-control)
        active[msg.sender] = true;
        emit Activated(msg.sender);
        if (initialAmount != 0) {
            _buy(msg.sender, initialAmount, maxTotalCost);
        } else {
            _pay(msg.sender, msg.value);
        }
    }

    /// @notice Buys keys for the caller and refunds any excess ETH.
    function buy(address creator, uint256 amount, uint256 maxTotalCost, uint256 deadline)
        external
        payable
        nonReentrant
    {
        _deadline(deadline);
        _buy(creator, amount, maxTotalCost);
    }

    /// @notice Sells the caller's keys back to the market and pays the proceeds after fees.
    function sell(address creator, uint256 amount, uint256 minNetProceeds, uint256 deadline)
        external
        nonReentrant
    {
        _deadline(deadline);
        Quote memory q = quoteSell(creator, amount);
        if (balanceOf[creator][msg.sender] < amount) revert InsufficientKeys();
        if (q.total < minNetProceeds) revert Slippage();
        // The Trade event below records the change.
        // forge-lint: disable-next-line(missing-events-access-control)
        balanceOf[creator][msg.sender] -= amount;
        supply[creator] -= amount;
        _accrue(creator, q);
        // The linter mistakes the quote's internal Math.sqrt for an external call.
        // forge-lint: disable-start(reentrancy-events)
        emit Trade(
            creator,
            msg.sender,
            false,
            amount,
            q.curveValue,
            q.creatorFee,
            q.devFee,
            supply[creator]
        );
        // forge-lint: disable-end(reentrancy-events)
        _pay(msg.sender, q.total);
    }

    /// @notice Pays `recipient` the fees owed to them. Anyone may call it.
    function claimFees(address recipient) external nonReentrant {
        uint256 amount = claimableFees[recipient];
        if (amount == 0) return;
        claimableFees[recipient] = 0;
        emit FeesClaimed(recipient, amount);
        _pay(recipient, amount);
    }

    function _buy(address creator, uint256 amount, uint256 maxTotalCost) private {
        Quote memory q = quoteBuy(creator, amount);
        if (q.total > maxTotalCost) revert Slippage();
        if (msg.value < q.total) revert InsufficientPayment();
        supply[creator] += amount;
        // The Trade event below records the change.
        // forge-lint: disable-next-line(missing-events-access-control)
        balanceOf[creator][msg.sender] += amount;
        _accrue(creator, q);
        // The linter mistakes the quote's internal Math.sqrt for an external call.
        // forge-lint: disable-start(reentrancy-events)
        emit Trade(
            creator, msg.sender, true, amount, q.curveValue, q.creatorFee, q.devFee, supply[creator]
        );
        // forge-lint: disable-end(reentrancy-events)
        _pay(msg.sender, msg.value - q.total);
    }

    function _accrue(address creator, Quote memory q) private {
        claimableFees[creator] += q.creatorFee;
        claimableFees[DEV_FUND] += q.devFee;
    }

    function _deadline(uint256 deadline) private view {
        // A trader's own deadline, not a source of randomness.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired();
    }

    function _pay(address recipient, uint256 amount) private {
        if (amount == 0) return;
        // Callers hold the reentrancy lock and update balances first. Return data is not copied.
        if (!LowLevelCall.callNoReturn(recipient, amount, "")) revert PaymentFailed();
    }
}
