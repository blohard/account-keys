// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {AccountKeys} from "../src/AccountKeys.sol";
import {Board} from "protocol/src/Board.sol";
import {IBoard} from "protocol/src/IBoard.sol";
import {AuthorKeyBlocklistGate, AuthorKeyGate} from "../src/KeyGates.sol";
import {ListRegistry} from "protocol/src/ListRegistry.sol";
import {ZeroAddress} from "protocol/src/ListGates.sol";

/// Buys keys in one call, replies in the next and sells in the last, all in a single transaction,
/// as a smart account batching them would.
contract BatchingAccount {
    function buyReplySell(AccountKeys keys, Board board, address creator, uint64 parent)
        external
        payable
        returns (uint64 reply)
    {
        uint256 cost = keys.quoteBuy(creator, 1).total;
        keys.buy{value: cost}(creator, 1, cost, block.timestamp);
        reply = board.post(keccak256("batched"), parent, address(0), "");
        keys.sell(creator, 1, 0, block.timestamp);
    }

    receive() external payable {}
}

/// The key gate, exercised through the Board as a real thread would use it.
contract KeyGatesTest is Test {
    Board board;
    AccountKeys keys;
    AuthorKeyGate gate;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address constant NO_GATE = address(0);
    bytes constant NO_DATA = "";

    function setUp() public {
        board = new Board();
        keys = new AccountKeys(makeAddr("dev"));
        gate = new AuthorKeyGate(board, keys);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        vm.prank(alice);
        keys.activate(0, 0, block.timestamp);
    }

    function _post(address who, uint64 parent, address replyGate) internal returns (uint64) {
        vm.prank(who);
        return board.post(
            keccak256(abi.encode(who, parent, replyGate, block.number)), parent, replyGate, NO_DATA
        );
    }

    function _expectRejected(address who, uint64 parent) internal {
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.post(keccak256(abi.encode(who, parent, "rejected")), parent, NO_GATE, NO_DATA);
    }

    function _buy(address who, address creator) internal {
        uint256 cost = keys.quoteBuy(creator, 1).total;
        vm.prank(who);
        keys.buy{value: cost}(creator, 1, cost, block.timestamp);
    }

    function _sell(address who, address creator) internal {
        vm.prank(who);
        keys.sell(creator, 1, 0, block.timestamp);
    }

    function test_rememberBoardAndMarket() public view {
        assertEq(address(gate.BOARD()), address(board));
        assertEq(address(gate.KEYS()), address(keys));
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(ZeroAddress.selector);
        new AuthorKeyGate(IBoard(address(0)), keys);
        vm.expectRevert(ZeroAddress.selector);
        new AuthorKeyGate(board, AccountKeys(address(0)));
    }

    function test_authorGateAdmitsOnlyTheAuthorAndKeyHolders() public {
        vm.prank(alice);
        board.setAuthorGate(address(gate));
        uint64 root = _post(alice, 0, NO_GATE);
        _expectRejected(bob, root);
        _post(alice, root, NO_GATE); // the author needs no key of their own
        _buy(bob, alice);
        _post(bob, root, NO_GATE);
        // Holding someone else's keys does not help.
        vm.prank(bob);
        keys.activate(0, 0, block.timestamp);
        _buy(carol, bob);
        _expectRejected(carol, root);
    }

    function test_sellingTheLastKeyStopsFutureRepliesOnly() public {
        uint64 root = _post(alice, 0, address(gate));
        _buy(bob, alice);
        _buy(bob, alice);
        uint64 kept = _post(bob, root, NO_GATE);
        _sell(bob, alice);
        _post(bob, root, NO_GATE); // one key left is still enough
        _sell(bob, alice);
        _expectRejected(bob, root);
        assertTrue(board.exists(kept), "an accepted reply stands after its author sells");
    }

    function test_transferMovesReplyAccessWithoutRemovingEarlierPosts() public {
        uint64 root = _post(alice, 0, address(gate));
        _buy(bob, alice);
        uint64 kept = _post(bob, root, NO_GATE);
        uint256 fee = keys.quoteTransfer(alice, 1).total;
        vm.prank(bob);
        keys.transfer{value: fee}(alice, carol, 1, fee, block.timestamp);
        _expectRejected(bob, root);
        _post(carol, root, NO_GATE);
        assertFalse(keys.active(carol));
        assertTrue(board.exists(kept));
    }

    function test_perMessageGateResolvesThatMessagesAuthor() public {
        // Carol has no author gate, and one message of hers uses the key gate.
        vm.prank(carol);
        keys.activate(0, 0, block.timestamp);
        uint64 gated = _post(carol, 0, address(gate));
        uint64 open = _post(carol, 0, NO_GATE);
        _buy(bob, alice); // alice's key, not carol's
        _expectRejected(bob, gated);
        _post(bob, open, NO_GATE);
        _buy(bob, carol);
        _post(bob, gated, NO_GATE);
    }

    function test_gateDataIsIgnored() public {
        vm.prank(alice);
        board.setAuthorGate(address(gate));
        uint64 root = _post(alice, 0, NO_GATE);
        bytes memory data = hex"01";
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.checkReply(root, bob, data);
        _buy(bob, alice);
        assertEq(board.checkReply(root, bob, data), address(gate));
    }

    function test_inactiveMarketAdmitsOnlyTheAuthor() public {
        uint64 root = _post(carol, 0, address(gate)); // carol never activated
        _expectRejected(bob, root);
        _post(carol, root, NO_GATE);
    }

    function test_previewMatchesPosting() public {
        uint64 root = _post(alice, 0, address(gate));
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.checkReply(root, bob, NO_DATA);
        assertEq(board.checkReply(root, alice, NO_DATA), address(gate));
        _buy(bob, alice);
        assertEq(board.checkReply(root, bob, NO_DATA), address(gate));
    }

    function test_buyReplyAndSellInOneTransaction() public {
        uint64 root = _post(alice, 0, address(gate));
        BatchingAccount account = new BatchingAccount();
        vm.deal(address(account), 1 ether);
        uint64 reply = account.buyReplySell{value: 0}(keys, board, alice, root);
        assertEq(board.authorOf(reply), address(account));
        assertEq(keys.balanceOf(alice, address(account)), 0);
    }
}

/// The combined gate: a key is required and a block still wins.
contract KeyBlocklistGateTest is Test {
    Board board;
    AccountKeys keys;
    ListRegistry registry;
    AuthorKeyBlocklistGate gate;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    bytes32 constant BLOCKED = keccak256("blocked");
    address constant NO_GATE = address(0);
    bytes constant NO_DATA = "";

    function setUp() public {
        board = new Board();
        keys = new AccountKeys(makeAddr("dev"));
        registry = new ListRegistry();
        gate = new AuthorKeyBlocklistGate(board, keys, registry, BLOCKED);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        vm.prank(alice);
        keys.activate(0, 0, block.timestamp);
        vm.prank(alice);
        board.setAuthorGate(address(gate));
    }

    function _post(address who, uint64 parent) internal returns (uint64) {
        vm.prank(who);
        return board.post(
            keccak256(abi.encode(who, parent, block.number, gasleft())), parent, NO_GATE, NO_DATA
        );
    }

    function _expectRejected(address who, uint64 parent) internal {
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.post(keccak256(abi.encode(who, parent, "rejected")), parent, NO_GATE, NO_DATA);
    }

    function _buy(address who, address creator) internal {
        uint256 cost = keys.quoteBuy(creator, 1).total;
        vm.prank(who);
        keys.buy{value: cost}(creator, 1, cost, block.timestamp);
    }

    function _block(address owner, address who) internal {
        address[] memory m = new address[](1);
        m[0] = who;
        vm.prank(owner);
        registry.add(owner, BLOCKED, m);
    }

    function test_rememberItsParts() public view {
        assertEq(address(gate.BOARD()), address(board));
        assertEq(address(gate.KEYS()), address(keys));
        assertEq(address(gate.REGISTRY()), address(registry));
        assertEq(gate.LIST_ID(), BLOCKED);
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(ZeroAddress.selector);
        new AuthorKeyBlocklistGate(IBoard(address(0)), keys, registry, BLOCKED);
        vm.expectRevert(ZeroAddress.selector);
        new AuthorKeyBlocklistGate(board, AccountKeys(address(0)), registry, BLOCKED);
        vm.expectRevert(ZeroAddress.selector);
        new AuthorKeyBlocklistGate(board, keys, ListRegistry(address(0)), BLOCKED);
    }

    function test_aKeyIsRequired() public {
        uint64 root = _post(alice, 0);
        _expectRejected(bob, root);
        _buy(bob, alice);
        _post(bob, root);
    }

    function test_aBlockWinsOverAKey() public {
        uint64 root = _post(alice, 0);
        _buy(bob, alice);
        _block(alice, bob);
        _expectRejected(bob, root);
        _buy(carol, alice); // another holder, not blocked, still replies
        _post(carol, root);
    }

    function test_aBlockStillWinsOverAGift() public {
        uint64 root = _post(alice, 0);
        _buy(bob, alice);
        _block(alice, carol);
        uint256 fee = keys.quoteTransfer(alice, 1).total;
        vm.prank(bob);
        keys.transfer{value: fee}(alice, carol, 1, fee, block.timestamp);
        _expectRejected(bob, root);
        _expectRejected(carol, root);
        assertEq(keys.balanceOf(alice, carol), 1);
    }

    function test_unblockingRestoresAHolder() public {
        uint64 root = _post(alice, 0);
        _buy(bob, alice);
        _block(alice, bob);
        _expectRejected(bob, root);
        address[] memory m = new address[](1);
        m[0] = bob;
        vm.prank(alice);
        registry.remove(alice, BLOCKED, m);
        _post(bob, root);
    }

    function test_onlyTheAuthorsOwnListCounts() public {
        uint64 root = _post(alice, 0);
        _buy(bob, alice);
        _block(carol, bob); // carol's list has no say in alice's thread
        _post(bob, root);
    }

    function test_gateDataIsIgnored() public {
        uint64 root = _post(alice, 0);
        bytes memory data = hex"01";
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.checkReply(root, bob, data);
        _buy(bob, alice);
        _block(alice, bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.checkReply(root, bob, data);
    }

    function test_theAuthorAlwaysReplies() public {
        uint64 root = _post(alice, 0);
        _post(alice, root);
    }

    function test_previewMatchesPosting() public {
        uint64 root = _post(alice, 0);
        _buy(bob, alice);
        assertEq(board.checkReply(root, bob, NO_DATA), address(gate));
        _block(alice, bob);
        vm.expectRevert(abi.encodeWithSelector(IBoard.GateRejected.selector, address(gate)));
        board.checkReply(root, bob, NO_DATA);
    }
}
