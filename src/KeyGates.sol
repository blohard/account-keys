// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {AccountKeys} from "./AccountKeys.sol";
import {IBoard} from "protocol/src/IBoard.sol";
import {IReplyGate} from "protocol/src/IReplyGate.sol";
import {ZeroAddress} from "protocol/src/ListGates.sol";
import {ListRegistry} from "protocol/src/ListRegistry.sol";

/// @title AuthorKeyGate
/// @notice A reply gate an author can install to limit replies to their key holders. The author
///         can always reply.
contract AuthorKeyGate is IReplyGate {
    IBoard public immutable BOARD;
    AccountKeys public immutable KEYS;

    constructor(IBoard board, AccountKeys keys) {
        if (address(board) == address(0) || address(keys) == address(0)) revert ZeroAddress();
        BOARD = board;
        KEYS = keys;
    }

    /// @inheritdoc IReplyGate
    function canReply(uint64 parentId, address replier, bytes calldata)
        external
        view
        returns (bool)
    {
        address author = BOARD.authorOf(parentId);
        return replier == author || KEYS.balanceOf(author, replier) > 0;
    }
}

/// @title AuthorKeyBlocklistGate
/// @notice Like `AuthorKeyGate`, but also refuses key holders on the author's blocklist.
contract AuthorKeyBlocklistGate is IReplyGate {
    IBoard public immutable BOARD;
    AccountKeys public immutable KEYS;
    ListRegistry public immutable REGISTRY;
    bytes32 public immutable LIST_ID;

    constructor(IBoard board, AccountKeys keys, ListRegistry registry, bytes32 listId) {
        if (
            address(board) == address(0) || address(keys) == address(0)
                || address(registry) == address(0)
        ) revert ZeroAddress();
        BOARD = board;
        KEYS = keys;
        REGISTRY = registry;
        LIST_ID = listId;
    }

    /// @inheritdoc IReplyGate
    function canReply(uint64 parentId, address replier, bytes calldata)
        external
        view
        returns (bool)
    {
        address author = BOARD.authorOf(parentId);
        if (replier == author) return true;
        return KEYS.balanceOf(author, replier) > 0 && !REGISTRY.contains(author, LIST_ID, replier);
    }
}
