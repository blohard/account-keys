// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AccountKeys} from "../src/AccountKeys.sol";

contract KeysHandler is Test {
    AccountKeys public immutable market;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    uint256 public successfulTrades;

    constructor(AccountKeys market_) {
        market = market_;
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1000 ether);
            vm.prank(actors[i]);
            market.activate(0, 0, block.timestamp);
        }
    }

    function trade(uint256 creatorSeed, uint256 holderSeed, uint256 amountSeed, bool buying)
        external
    {
        address creator = actors[creatorSeed % 3];
        address holder = actors[holderSeed % 3];
        uint256 amount = bound(amountSeed, 1, 5);
        if (buying) {
            if (market.supply(creator) + amount > 100) return;
            AccountKeys.Quote memory q = market.quoteBuy(creator, amount);
            vm.prank(holder);
            market.buy{value: q.total}(creator, amount, q.total, block.timestamp);
        } else {
            uint256 held = market.balanceOf(creator, holder);
            if (held == 0) return;
            amount = bound(amountSeed, 1, held < 5 ? held : 5);
            vm.prank(holder);
            market.sell(creator, amount, 0, block.timestamp);
        }
        ++successfulTrades;
    }

    function move(uint256 creatorSeed, uint256 holderSeed, uint256 amountSeed) external {
        address creator = actors[creatorSeed % 3];
        address holder = actors[holderSeed % 3];
        address recipient = actors[(holderSeed % 3 + 1) % 3];
        uint256 held = market.balanceOf(creator, holder);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        AccountKeys.Quote memory q = market.quoteTransfer(creator, amount);
        vm.prank(holder);
        market.transfer{value: q.total}(creator, recipient, amount, q.total, block.timestamp);
    }

    function claim(uint256 seed) external {
        market.claimFees(seed % 4 == 3 ? market.DEV_FUND() : actors[seed % 4]);
    }
}

contract AccountKeysInvariantTest is StdInvariant, Test {
    AccountKeys market;
    KeysHandler handler;

    function setUp() public {
        market = new AccountKeys(address(0xDEAF));
        handler = new KeysHandler(market);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.move.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_reservesBalancesAndLiabilities() public view {
        uint256 allReserves;
        uint256 allFees = market.claimableFees(market.DEV_FUND());
        for (uint256 i; i < 3; ++i) {
            address creator = handler.actors(i);
            uint256 issued = market.supply(creator);
            uint256 held;
            for (uint256 j; j < 3; ++j) {
                held += market.balanceOf(creator, handler.actors(j));
            }
            assertEq(held, issued);
            uint256 backing;
            for (uint256 n = 1; n <= issued; ++n) {
                backing += market.price(n);
            }
            assertEq(market.reserveAt(issued), backing);
            allReserves += backing;
            allFees += market.claimableFees(creator);
        }
        assertEq(address(market).balance, allReserves + allFees);
    }
}
