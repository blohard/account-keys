// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {AccountKeys} from "../src/AccountKeys.sol";

/// Gas ceilings for transfers, measured as the call alone: a transaction's base cost and rollup
/// data fees come on top. Setup runs separately, so each measured call starts with cold storage. A
/// transfer to a new holder measures about 114.4k gas and one to an existing holder about 97.3k.
/// The ceilings sit about fifteen percent above.
contract AccountKeysGasTest is Test {
    AccountKeys market;
    address creator = makeAddr("creator");
    address sender = makeAddr("sender");
    address recipient = makeAddr("recipient");
    address dev = makeAddr("dev");
    uint256 fee;

    function setUp() public {
        market = new AccountKeys(dev);
        vm.deal(creator, 1 ether);
        vm.deal(sender, 1 ether);
        uint256 initial = market.quoteAtSupply(0, 1).total;
        vm.prank(creator);
        market.activate{value: initial}(1, initial, block.timestamp);
        uint256 cost = market.quoteBuy(creator, 10).total;
        vm.prank(sender);
        market.buy{value: cost}(creator, 10, cost, block.timestamp);
        // Claiming empties both fee balances, so the measured transfers pay for writing them from
        // zero, the most expensive case.
        market.claimFees(creator);
        market.claimFees(dev);
        fee = market.quoteTransfer(creator, 1).total;
    }

    function _measure(address to, uint256 ceiling) internal {
        AccountKeys target = market;
        address author = creator;
        uint256 payment = fee;
        vm.prank(sender);
        uint256 before = gasleft();
        target.transfer{value: payment}(author, to, 1, payment, block.timestamp);
        uint256 used = before - gasleft();
        emit log_named_uint("transfer call gas", used);
        assertLt(used, ceiling);
        assertEq(market.balanceOf(creator, sender), 9);
    }

    function test_gas_transferToNewHolder() public {
        _measure(recipient, 130_000);
    }

    function test_gas_transferToExistingHolder() public {
        _measure(creator, 112_000);
    }
}
