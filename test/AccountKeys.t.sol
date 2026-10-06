// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {AccountKeys} from "../src/AccountKeys.sol";

contract KeyWallet {
    AccountKeys public immutable market;
    bool public reject;
    bytes public attack;
    bool public reentered;
    bytes4 public reentryError;

    constructor(AccountKeys market_) {
        market = market_;
    }

    function configure(bool reject_, bytes memory attack_) external {
        reject = reject_;
        attack = attack_;
        reentered = false;
    }

    function execute(bytes memory data, uint256 value) external returns (bytes memory) {
        (bool ok, bytes memory result) = address(market).call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        return result;
    }

    receive() external payable {
        require(!reject, "reject ETH");
        if (attack.length != 0) {
            (bool ok, bytes memory result) = address(market).call(attack);
            reentered = ok;
            reentryError = result.length >= 4 ? bytes4(result) : bytes4(0);
        }
    }
}

contract ReturnBombRecipient {
    bool public reject;

    function setReject() external {
        reject = true;
    }

    function activate(AccountKeys market) external {
        market.activate(0, 0, block.timestamp);
    }

    receive() external payable {
        // Expanding 1 MiB costs about 2.2M gas. A second copy in the payer exceeds the claim's 3M
        // gas budget, even though this receive succeeds.
        bool rejecting = reject;
        assembly ("memory-safe") {
            let start := mload(0x40)
            if rejecting { revert(start, 0x100000) }
            return(start, 0x100000)
        }
    }
}

contract AccountKeysTest is Test {
    using stdStorage for StdStorage;
    AccountKeys market;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dev = makeAddr("dev");
    /// Every account that can hold a market or unclaimed fees in a test, each once.
    address[] tracked;

    function setUp() public {
        tracked.push(alice);
        tracked.push(bob);
        tracked.push(dev);
        market = new AccountKeys(dev);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(alice);
        market.activate(0, 0, block.timestamp);
    }

    function test_transferFeesRefundAndConservation() public {
        _buy(alice, alice, 10);
        uint256 heldETH = address(market).balance;
        uint256 senderETH = alice.balance;
        uint256 creatorFees = market.claimableFees(alice);
        uint256 devFees = market.claimableFees(dev);
        AccountKeys.Quote memory q = market.quoteTransfer(alice, 3);
        assertEq(q.curveValue, _reference(10) - _reference(7));
        assertEq(q.creatorFee, q.curveValue * 450 / 10000);
        assertEq(q.devFee, q.curveValue * 50 / 10000);
        assertEq(q.total, q.creatorFee + q.devFee);
        vm.expectEmit(true, true, true, true);
        emit AccountKeys.KeysTransferred(alice, alice, bob, 3, q.curveValue, q.creatorFee, q.devFee);
        vm.prank(alice);
        market.transfer{value: q.total + 123}(alice, bob, 3, q.total, block.timestamp);
        assertEq(alice.balance, senderETH - q.total);
        assertEq(address(market).balance, heldETH + q.total);
        assertEq(market.supply(alice), 10);
        assertEq(market.balanceOf(alice, alice), 7);
        assertEq(market.balanceOf(alice, bob), 3);
        assertFalse(market.active(bob));
        assertEq(market.claimableFees(alice), creatorFees + q.creatorFee);
        assertEq(market.claimableFees(dev), devFees + q.devFee);
        _solvent();
        AccountKeys.Quote memory sale = market.quoteSell(alice, 3);
        vm.prank(bob);
        market.sell(alice, 3, sale.total, block.timestamp);
        _solvent();
    }

    function test_transferRejectsInvalidRequests() public {
        _buy(alice, alice, 2);
        AccountKeys.Quote memory q = market.quoteTransfer(alice, 1);
        vm.startPrank(alice);
        vm.expectRevert(AccountKeys.ZeroAddress.selector);
        market.transfer(alice, address(0), 1, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.InvalidRecipient.selector);
        market.transfer(alice, alice, 1, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.InvalidRecipient.selector);
        market.transfer(alice, address(market), 1, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.InvalidAmount.selector);
        market.transfer(alice, bob, 0, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.InsufficientKeys.selector);
        market.transfer(alice, bob, 3, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.Slippage.selector);
        market.transfer{value: q.total}(alice, bob, 1, q.total - 1, block.timestamp);
        vm.expectRevert(AccountKeys.InsufficientPayment.selector);
        market.transfer{value: q.total - 1}(alice, bob, 1, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.Expired.selector);
        market.transfer(alice, bob, 1, q.total, block.timestamp - 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(AccountKeys.InsufficientKeys.selector);
        market.transfer(alice, alice, 1, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.InsufficientKeys.selector);
        market.quoteTransfer(bob, 1);
        assertEq(market.balanceOf(alice, alice), 2);
        _solvent();
    }

    function test_transferToRejectingWalletDoesNotCallRecipient() public {
        KeyWallet recipient = new KeyWallet(market);
        recipient.configure(true, "");
        _buy(alice, alice, 1);
        AccountKeys.Quote memory q = market.quoteTransfer(alice, 1);
        vm.prank(alice);
        market.transfer{value: q.total}(alice, address(recipient), 1, q.total, block.timestamp);
        assertEq(market.balanceOf(alice, address(recipient)), 1);
        assertEq(market.balanceOf(alice, alice), 0);
        _solvent();
    }

    function test_transferRefundFailureRollsBackAndReentryIsBlocked() public {
        KeyWallet sender = new KeyWallet(market);
        vm.deal(address(sender), 1 ether);
        _buy(alice, address(sender), 2);
        AccountKeys.Quote memory q = market.quoteTransfer(alice, 1);
        bytes memory call =
            abi.encodeCall(market.transfer, (alice, bob, 1, q.total, block.timestamp));
        sender.configure(true, "");
        vm.expectRevert(AccountKeys.PaymentFailed.selector);
        sender.execute(call, q.total + 1);
        assertEq(market.balanceOf(alice, address(sender)), 2);
        assertEq(market.balanceOf(alice, bob), 0);
        _solvent();
        sender.configure(false, call);
        sender.execute(call, q.total + 1);
        assertFalse(sender.reentered());
        assertEq(sender.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(market.balanceOf(alice, bob), 1);
        _solvent();
    }

    function test_transferSupplyBoundary() public {
        uint256 maximum = market.MAX_SUPPLY();
        stdstore.target(address(market))
            .sig("supply(address)")
            .with_key(alice)
            .checked_write(maximum);
        stdstore.target(address(market))
            .sig("balanceOf(address,address)")
            .with_key(alice)
            .with_key(alice)
            .checked_write(maximum);
        // Fund the synthetic market's backing independently of the transfer fee.
        vm.deal(address(market), _reference(maximum));
        AccountKeys.Quote memory q = market.quoteTransfer(alice, maximum);
        assertEq(q.curveValue, _reference(maximum));
        vm.deal(alice, q.total);
        vm.prank(alice);
        market.transfer{value: q.total}(alice, bob, maximum, q.total, block.timestamp);
        assertEq(market.supply(alice), maximum);
        assertEq(market.balanceOf(alice, alice), 0);
        assertEq(market.balanceOf(alice, bob), maximum);
        _solvent();

        q = market.quoteTransfer(alice, 1);
        assertEq(q.curveValue, _reference(maximum) - _reference(maximum - 1));
        vm.deal(bob, q.total);
        vm.prank(bob);
        market.transfer{value: q.total}(alice, alice, 1, q.total, block.timestamp);
        assertEq(market.balanceOf(alice, alice), 1);
        assertEq(market.balanceOf(alice, bob), maximum - 1);
        _solvent();
    }

    function test_transferMinimumFee() public {
        _buy(alice, alice, 1);
        AccountKeys.Quote memory q = market.quoteTransfer(alice, 1);
        assertEq(q.curveValue, 10_400_000_000_000);
        assertEq(q.creatorFee, 468_000_000_000);
        assertEq(q.devFee, 52_000_000_000);
        assertEq(q.total, 520_000_000_000);
    }

    function test_transferFeeIsHalfSellAndRebuyFees() public {
        _buy(alice, alice, 100);
        AccountKeys.Quote memory move = market.quoteTransfer(alice, 100);
        assertEq(move.curveValue, 0.041 ether);
        assertEq(move.total, 0.00205 ether);
        uint256 beforeETH = alice.balance;
        AccountKeys.Quote memory sale = market.quoteSell(alice, 100);
        vm.prank(alice);
        market.sell(alice, 100, sale.total, block.timestamp);
        _buy(alice, alice, 100);
        assertEq(beforeETH - alice.balance, 2 * move.total);
        _solvent();
    }

    function testFuzz_transferMatchesRedemption(uint32 supplySeed, uint32 amountSeed) public {
        uint256 supply = bound(supplySeed, 1, market.MAX_SUPPLY());
        uint256 amount = bound(amountSeed, 1, supply);
        stdstore.target(address(market))
            .sig("supply(address)")
            .with_key(alice)
            .checked_write(supply);
        AccountKeys.Quote memory batch = market.quoteTransfer(alice, amount);
        assertEq(batch.curveValue, _reference(supply) - _reference(supply - amount));
        assertEq(batch.creatorFee, batch.curveValue * 450 / 10000);
        assertEq(batch.devFee, batch.curveValue * 50 / 10000);
        assertEq(batch.total, batch.creatorFee + batch.devFee);
        assertGt(batch.total, 0);
        AccountKeys.Quote memory sale = market.quoteSell(alice, amount);
        AccountKeys.Quote memory rebuy = market.quoteAtSupply(supply - amount, amount);
        assertEq(rebuy.total - sale.total, 2 * batch.total);
    }

    function testFuzz_splittingTransferDoesNotReduceFees(
        uint32 supplySeed,
        uint32 amountSeed,
        uint32 splitSeed
    ) public {
        uint256 supply = bound(supplySeed, 2, market.MAX_SUPPLY());
        uint256 amount = bound(amountSeed, 2, supply);
        uint256 first = bound(splitSeed, 1, amount - 1);
        stdstore.target(address(market))
            .sig("supply(address)")
            .with_key(alice)
            .checked_write(supply);
        // Transfers leave supply unchanged, so both pieces are valued at the same supply.
        AccountKeys.Quote memory batch = market.quoteTransfer(alice, amount);
        AccountKeys.Quote memory a = market.quoteTransfer(alice, first);
        AccountKeys.Quote memory b = market.quoteTransfer(alice, amount - first);
        assertGe(a.curveValue + b.curveValue, batch.curveValue);
        assertGe(a.creatorFee + b.creatorFee, batch.creatorFee);
        assertGe(a.devFee + b.devFee, batch.devFee);
    }

    function _buy(address creator, address holder, uint256 amount) internal {
        AccountKeys.Quote memory q = market.quoteBuy(creator, amount);
        vm.prank(holder);
        market.buy{value: q.total}(creator, amount, q.total, block.timestamp);
    }

    function _track(address account) internal {
        tracked.push(account);
    }

    /// The ETH held equals what the contract owes: each market's reserve plus every unclaimed fee,
    /// derived independently of the trade code.
    function _solvent() internal view {
        uint256 owed;
        for (uint256 i; i < tracked.length; ++i) {
            owed += market.reserveAt(market.supply(tracked[i])) + market.claimableFees(tracked[i]);
        }
        assertEq(address(market).balance, owed);
    }

    // An independent check of reserveAt by binary search, deliberately unlike the contract's square
    // root.
    function _reference(uint256 s) internal pure returns (uint256 lo) {
        uint256 radicand = 1.6e23 * s ** 5;
        uint256 hi = 1e36;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (mid * mid <= radicand) lo = mid;
            else hi = mid;
        }
        lo += 1e13 * s;
    }

    function test_reserveAnchorsAndPriceVectors() public view {
        assertEq(market.reserveAt(0), 0);
        assertEq(market.reserveAt(1), 104e11); // 0.0000104 ETH
        assertEq(market.reserveAt(100), 0.041 ether); // exact
        assertEq(market.reserveAt(10_000), 4000.1 ether); // exact
        assertEq(market.price(1), 10400000000000);
        assertEq(market.price(2), 11862741699796);
        assertEq(market.price(10), 39291106406735);
        assertEq(market.price(100), 1002512515672072);
        assertEq(market.price(2500), 124972502500125016);
        assertEq(market.price(10_000), 999935001250015626);
    }

    function testFuzz_reserveMatchesIndependentOracle(uint32 s) public view {
        assertEq(market.reserveAt(s), _reference(s));
    }

    function testFuzz_pricesRiseAndSumToReserve(uint32 seed) public view {
        uint256 n = bound(seed, 2, market.MAX_SUPPLY());
        assertGt(market.price(n), market.price(n - 1));
        assertEq(market.price(n), market.reserveAt(n) - market.reserveAt(n - 1));
    }

    function testFuzz_batchMatchesSplit(uint32 startSeed, uint16 countSeed) public view {
        uint256 count = bound(countSeed, 1, 300);
        uint256 start = bound(startSeed, 0, market.MAX_SUPPLY() - count);
        AccountKeys.Quote memory q = market.quoteAtSupply(start, count);
        uint256 sum;
        for (uint256 i = 1; i <= count; ++i) {
            sum += market.price(start + i);
        }
        assertEq(q.curveValue, sum);
        assertEq(q.creatorFee, sum * 450 / 10_000);
        assertEq(q.devFee, sum * 50 / 10_000);
        assertEq(q.total, sum + q.creatorFee + q.devFee);
    }

    function test_activationIsOptInAndAtomic() public {
        vm.expectRevert(AccountKeys.InactiveMarket.selector);
        market.buy(bob, 1, 1 ether, block.timestamp);
        AccountKeys.Quote memory q = market.quoteAtSupply(0, 5);
        vm.startPrank(bob);
        vm.expectRevert(AccountKeys.InsufficientPayment.selector);
        market.activate(5, q.total, block.timestamp);
        assertFalse(market.active(bob));
        market.activate{value: q.total}(5, q.total, block.timestamp);
        vm.expectRevert(AccountKeys.AlreadyActive.selector);
        market.activate(0, 0, block.timestamp);
        vm.stopPrank();
        assertTrue(market.active(bob));
        assertEq(market.balanceOf(bob, bob), 5);
        assertEq(market.claimableFees(bob), q.creatorFee);
        assertEq(q.curveValue, market.reserveAt(5));
        assertEq(market.supply(alice), 0);
        _solvent();
    }

    function test_activationSlippageAndRefund() public {
        AccountKeys.Quote memory q = market.quoteAtSupply(0, 3);
        vm.startPrank(bob);
        vm.expectRevert(AccountKeys.Slippage.selector);
        market.activate{value: q.total}(3, q.total - 1, block.timestamp);
        uint256 before = bob.balance;
        market.activate{value: q.total + 1 ether}(3, q.total, block.timestamp);
        vm.stopPrank();
        assertEq(bob.balance, before - q.total, "excess ETH is refunded");
        assertEq(market.balanceOf(bob, bob), 3);
        _solvent();
    }

    function test_inactiveMarketsAndZeroAmounts() public {
        // bob never activated a market.
        vm.expectRevert(AccountKeys.InactiveMarket.selector);
        market.quoteSell(bob, 1);
        vm.expectRevert(AccountKeys.InactiveMarket.selector);
        market.sell(bob, 1, 0, block.timestamp);
        vm.expectRevert(AccountKeys.InvalidAmount.selector);
        market.buy(alice, 0, 1 ether, block.timestamp);
        _buy(alice, bob, 1);
        vm.expectRevert(AccountKeys.InvalidAmount.selector);
        market.quoteSell(alice, 0);
        vm.prank(bob);
        vm.expectRevert(AccountKeys.InvalidAmount.selector);
        market.sell(alice, 0, 0, block.timestamp);
    }

    /// An indexer rebuilds supply, balances and fees from these events, so their fields must be
    /// exact.
    function test_eventsRecordEveryChange() public {
        AccountKeys.Quote memory first = market.quoteAtSupply(0, 2);
        vm.expectEmit(true, false, false, true, address(market));
        emit AccountKeys.Activated(bob);
        vm.expectEmit(true, true, false, true, address(market));
        emit AccountKeys.Trade(
            bob, bob, true, 2, first.curveValue, first.creatorFee, first.devFee, 2
        );
        vm.prank(bob);
        market.activate{value: first.total}(2, first.total, block.timestamp);

        AccountKeys.Quote memory q = market.quoteBuy(alice, 3);
        vm.expectEmit(true, true, false, true, address(market));
        emit AccountKeys.Trade(alice, bob, true, 3, q.curveValue, q.creatorFee, q.devFee, 3);
        vm.prank(bob);
        market.buy{value: q.total}(alice, 3, q.total, block.timestamp);

        AccountKeys.Quote memory s = market.quoteSell(alice, 2);
        vm.expectEmit(true, true, false, true, address(market));
        emit AccountKeys.Trade(alice, bob, false, 2, s.curveValue, s.creatorFee, s.devFee, 1);
        vm.prank(bob);
        market.sell(alice, 2, s.total, block.timestamp);

        // Anyone may claim, and the event names the recipient.
        uint256 owed = market.claimableFees(alice);
        vm.expectEmit(true, false, false, true, address(market));
        emit AccountKeys.FeesClaimed(alice, owed);
        vm.prank(bob);
        market.claimFees(alice);

        // With nothing owed, a claim pays nothing and emits nothing.
        vm.recordLogs();
        market.claimFees(alice);
        assertEq(vm.getRecordedLogs().length, 0);
        _solvent();
    }

    function testFuzz_roundTrip(uint16 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 1000);
        AccountKeys.Quote memory q = market.quoteBuy(alice, amount);
        uint256 beforeBalance = bob.balance;
        _buy(alice, bob, amount);
        AccountKeys.Quote memory sale = market.quoteSell(alice, amount);
        assertEq(sale.curveValue, q.curveValue);
        vm.prank(bob);
        market.sell(alice, amount, sale.total, block.timestamp);
        assertEq(beforeBalance - bob.balance, 2 * (q.creatorFee + q.devFee));
        assertEq(market.supply(alice), 0);
        assertEq(market.balanceOf(alice, bob), 0);
        assertEq(market.claimableFees(alice), 2 * q.creatorFee);
        _solvent();
        market.claimFees(alice);
        market.claimFees(dev);
        assertEq(address(market).balance, 0);
        // A sold-out market remains active and can restart at key 1.
        _buy(alice, bob, 1);
        assertEq(
            address(market).balance,
            market.price(1) + market.claimableFees(alice) + market.claimableFees(dev)
        );
    }

    function test_permissionlessClaimsCannotRedirectFees() public {
        _buy(alice, bob, 10);
        uint256 fees = market.claimableFees(alice);
        uint256 creatorBefore = alice.balance;
        uint256 callerBefore = bob.balance;
        vm.prank(bob);
        market.claimFees(alice);
        assertEq(alice.balance, creatorBefore + fees);
        assertEq(bob.balance, callerBefore);
        assertEq(market.claimableFees(alice), 0);
        market.claimFees(alice);
        market.claimFees(address(0));
        _solvent();
    }

    function test_creatorCanAlsoBeDevFund() public {
        market = new AccountKeys(alice);
        vm.prank(alice);
        market.activate(0, 0, block.timestamp);
        AccountKeys.Quote memory q = market.quoteBuy(alice, 3);
        _buy(alice, alice, 3);
        assertEq(market.claimableFees(alice), q.creatorFee + q.devFee);
        market.claimFees(alice);
        assertEq(market.claimableFees(alice), 0);
        _solvent();
    }

    function test_zeroDevFundRejected() public {
        vm.expectRevert(AccountKeys.ZeroAddress.selector);
        new AccountKeys(address(0));
    }

    function test_limitsAndDeadlines() public {
        uint256 maximum = market.MAX_SUPPLY();
        vm.expectRevert(AccountKeys.SupplyLimit.selector);
        market.price(0);
        vm.expectRevert(AccountKeys.SupplyLimit.selector);
        market.price(maximum + 1);
        vm.expectRevert(AccountKeys.SupplyLimit.selector);
        market.quoteAtSupply(type(uint256).max, 1);
        vm.expectRevert(AccountKeys.SupplyLimit.selector);
        market.quoteAtSupply(maximum, 1);
        market.quoteAtSupply(maximum - 100, 100);
        market.quoteAtSupply(0, maximum);
        vm.expectRevert(AccountKeys.InvalidAmount.selector);
        market.quoteBuy(alice, 0);
        assertEq(market.quoteBuy(alice, 10_000).curveValue, 4000.1 ether);
        vm.expectRevert(AccountKeys.InsufficientKeys.selector);
        market.quoteSell(alice, 1);
        vm.warp(100);
        vm.expectRevert(AccountKeys.Expired.selector);
        market.buy(alice, 1, 1 ether, 99);
        vm.expectRevert(AccountKeys.Expired.selector);
        market.sell(alice, 1, 0, 99);
        vm.prank(bob);
        vm.expectRevert(AccountKeys.Expired.selector);
        market.activate(0, 0, 99);
        assertFalse(market.active(bob));
    }

    function test_slippageBalancesAndRefund() public {
        AccountKeys.Quote memory q = market.quoteBuy(alice, 1);
        vm.startPrank(bob);
        vm.expectRevert(AccountKeys.Slippage.selector);
        market.buy{value: q.total}(alice, 1, q.total - 1, block.timestamp);
        vm.expectRevert(AccountKeys.InsufficientPayment.selector);
        market.buy{value: q.total - 1}(alice, 1, q.total, block.timestamp);
        uint256 beforeBalance = bob.balance;
        market.buy{value: 1 ether}(alice, 1, q.total, block.timestamp);
        assertEq(bob.balance, beforeBalance - q.total);
        AccountKeys.Quote memory sale = market.quoteSell(alice, 1);
        vm.expectRevert(AccountKeys.Slippage.selector);
        market.sell(alice, 1, sale.total + 1, block.timestamp);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(AccountKeys.InsufficientKeys.selector);
        market.sell(alice, 1, 0, block.timestamp);
        _solvent();
    }

    function test_rejectedFeesDoNotBlockTrades() public {
        KeyWallet creator = new KeyWallet(market);
        _track(address(creator));
        creator.execute(abi.encodeCall(market.activate, (0, 0, block.timestamp)), 0);
        creator.configure(true, "");
        _buy(address(creator), bob, 2);
        uint256 owed = market.claimableFees(address(creator));
        vm.expectRevert(AccountKeys.PaymentFailed.selector);
        market.claimFees(address(creator));
        assertEq(market.claimableFees(address(creator)), owed);
        vm.prank(bob);
        market.sell(address(creator), 2, 0, block.timestamp);
        creator.configure(false, "");
        market.claimFees(address(creator));
        assertEq(address(creator).balance, owed * 2);
        _solvent();
    }

    function test_rejectedDevFeesDoNotBlockTrades() public {
        KeyWallet receiver = new KeyWallet(market);
        _track(address(receiver));
        receiver.configure(true, "");
        market = new AccountKeys(address(receiver));
        vm.prank(alice);
        market.activate(0, 0, block.timestamp);
        _buy(alice, bob, 1);
        vm.expectRevert(AccountKeys.PaymentFailed.selector);
        market.claimFees(address(receiver));
        vm.prank(bob);
        market.sell(alice, 1, 0, block.timestamp);
        _solvent();
    }

    function test_rejectedRefundAndSaleRollBack() public {
        KeyWallet holder = new KeyWallet(market);
        vm.deal(address(holder), 1 ether);
        holder.configure(true, "");
        AccountKeys.Quote memory q = market.quoteBuy(alice, 1);
        bytes memory purchase = abi.encodeCall(market.buy, (alice, 1, q.total, block.timestamp));
        vm.expectRevert(AccountKeys.PaymentFailed.selector);
        holder.execute(purchase, q.total + 1);
        assertEq(market.supply(alice), 0);
        assertEq(market.claimableFees(alice) + market.claimableFees(dev), 0);
        holder.execute(purchase, q.total);
        vm.expectRevert(AccountKeys.PaymentFailed.selector);
        holder.execute(abi.encodeCall(market.sell, (alice, 1, 0, block.timestamp)), 0);
        assertEq(market.balanceOf(alice, address(holder)), 1);
        _solvent();
        vm.expectRevert(AccountKeys.PaymentFailed.selector);
        holder.execute(abi.encodeCall(market.activate, (0, 0, block.timestamp)), 1);
        assertFalse(market.active(address(holder)));
    }

    function test_allMutationsRejectReentrancyFromPayouts() public {
        KeyWallet holder = new KeyWallet(market);
        _track(address(holder));
        vm.deal(address(holder), 1 ether);
        holder.execute(abi.encodeCall(market.activate, (0, 0, block.timestamp)), 0);
        bytes[5] memory attacks = [
            abi.encodeCall(market.activate, (0, 0, block.timestamp)),
            abi.encodeCall(market.buy, (alice, 1, 1 ether, block.timestamp)),
            abi.encodeCall(market.sell, (alice, 1, 0, block.timestamp)),
            abi.encodeCall(market.transfer, (alice, bob, 1, 1 ether, block.timestamp)),
            abi.encodeCall(market.claimFees, (dev))
        ];
        for (uint256 i; i < attacks.length; ++i) {
            holder.configure(false, attacks[i]);
            AccountKeys.Quote memory q = market.quoteBuy(alice, 1);
            holder.execute(
                abi.encodeCall(market.buy, (alice, 1, q.total, block.timestamp)), q.total + 1
            );
            assertFalse(holder.reentered());
            assertEq(holder.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            holder.execute(abi.encodeCall(market.sell, (alice, 1, 0, block.timestamp)), 0);
            assertFalse(holder.reentered());
            assertEq(holder.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            _buy(address(holder), bob, 1);
            market.claimFees(address(holder));
            assertFalse(holder.reentered());
            assertEq(holder.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            _solvent();
        }
    }

    function test_unsolicitedETHDoesNotBecomeClaimable() public {
        _buy(alice, bob, 1);
        vm.deal(address(market), address(market).balance + 1 ether);
        market.claimFees(alice);
        market.claimFees(dev);
        vm.prank(bob);
        market.sell(alice, 1, 0, block.timestamp);
        market.claimFees(alice);
        market.claimFees(dev);
        assertEq(address(market).balance, 1 ether);
        assertEq(market.supply(alice), 0);
        assertEq(market.claimableFees(alice) + market.claimableFees(dev), 0);
    }

    function test_largeReturnDataCannotBombPermissionlessClaim() public {
        ReturnBombRecipient creator = new ReturnBombRecipient();
        _track(address(creator));
        creator.activate(market);
        _buy(address(creator), bob, 1);
        uint256 owed = market.claimableFees(address(creator));
        (bool ok,) = address(market).call{gas: 3_000_000}(
            abi.encodeCall(market.claimFees, (address(creator)))
        );
        assertTrue(ok, "recipient return data exhausted the claim budget");
        assertEq(address(creator).balance, owed);
        assertEq(market.claimableFees(address(creator)), 0);
        _solvent();
    }

    function test_largeRevertDataPreservesFeesAndReturnsPaymentFailed() public {
        ReturnBombRecipient creator = new ReturnBombRecipient();
        _track(address(creator));
        creator.activate(market);
        creator.setReject();
        _buy(address(creator), bob, 1);
        uint256 owed = market.claimableFees(address(creator));
        uint256 devOwed = market.claimableFees(dev);
        (bool ok, bytes memory reason) = address(market).call{gas: 3_000_000}(
            abi.encodeCall(market.claimFees, (address(creator)))
        );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AccountKeys.PaymentFailed.selector));
        assertEq(market.claimableFees(address(creator)), owed);
        assertEq(market.claimableFees(dev), devOwed);
        assertEq(address(creator).balance, 0);
        _solvent();
    }

    function test_tradingAtSupplyBoundary() public {
        uint256 maximum = market.MAX_SUPPLY();
        // Set the supply directly instead of buying billions of keys to reach the last mint and
        // burn. The fixture has no earlier holders or reserves. The invariant tests cover the
        // accounting in states that real trades reach.
        stdstore.target(address(market))
            .sig("supply(address)")
            .with_key(alice)
            .checked_write(maximum - 1);
        AccountKeys.Quote memory q = market.quoteBuy(alice, 1);
        assertEq(q.curveValue, _reference(maximum) - _reference(maximum - 1));
        vm.deal(bob, q.total);
        _buy(alice, bob, 1);
        assertEq(market.supply(alice), maximum);
        assertEq(market.balanceOf(alice, bob), 1);
        vm.prank(bob);
        vm.expectRevert(AccountKeys.SupplyLimit.selector);
        market.buy(alice, 1, type(uint256).max, block.timestamp);
        assertEq(market.supply(alice), maximum);
        AccountKeys.Quote memory sale = market.quoteSell(alice, 1);
        assertEq(sale.curveValue, q.curveValue);
        vm.prank(bob);
        market.sell(alice, 1, sale.total, block.timestamp);
        assertEq(market.supply(alice), maximum - 1);
        assertEq(market.balanceOf(alice, bob), 0);
        assertEq(bob.balance, sale.total);
        // The synthetic supply has no real backing, so only fees remain held.
        assertEq(address(market).balance, market.claimableFees(alice) + market.claimableFees(dev));
        // Redemption reopens capacity at the same curve price.
        assertEq(market.quoteBuy(alice, 1).curveValue, q.curveValue);
    }

    /// A trade's gas does not depend on its size: buying one key or a thousand takes the same two
    /// square roots.
    function test_gasIndependentOfTradeSize() public {
        // A first purchase warms up, since it also creates the holder's balance slot.
        vm.deal(bob, 1000 ether);
        _buy(alice, bob, 1);
        AccountKeys.Quote memory one = market.quoteBuy(alice, 1);
        vm.prank(bob);
        uint256 before = gasleft();
        market.buy{value: one.total}(alice, 1, one.total, block.timestamp);
        uint256 small = before - gasleft();
        AccountKeys.Quote memory many = market.quoteBuy(alice, 1000);
        vm.prank(bob);
        before = gasleft();
        market.buy{value: many.total}(alice, 1000, many.total, block.timestamp);
        uint256 large = before - gasleft();
        emit log_named_uint("buy 1 key after a first purchase", small);
        emit log_named_uint("buy 1000 keys", large);
        assertLt(large, small + 1000, "a larger trade must not cost more gas");
        assertLt(large, 90_000);
        vm.prank(bob);
        market.sell(alice, 1002, 0, block.timestamp);
        _solvent();
    }
}
