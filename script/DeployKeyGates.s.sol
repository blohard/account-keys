// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console} from "forge-std/Script.sol";
import {DeterministicDeploy} from "protocol/script/DeterministicDeploy.sol";
import {AccountKeys} from "../src/AccountKeys.sol";
import {AuthorKeyGate, AuthorKeyBlocklistGate} from "../src/KeyGates.sol";

/// @notice Deploys the shared key gates through the deterministic deployer proxy.
/// @dev BOARD, ACCOUNT_KEYS and REGISTRY must name existing deployments. LIST_NAME names the
///      blocklist the combined gate reads, `blocked` by default. Wrong inputs give other
///      addresses, so run it without --broadcast first and check the printed addresses against
///      deployments.json.
///
///   BOARD=0x… REGISTRY=0x… ACCOUNT_KEYS=0x… forge script script/DeployKeyGates.s.sol \
///       --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
contract DeployKeyGates is DeterministicDeploy {
    function run() external returns (address holders, address combined) {
        address board = vm.envAddress("BOARD");
        address keys = vm.envAddress("ACCOUNT_KEYS");
        address registry = vm.envAddress("REGISTRY");
        require(
            board.code.length > 0 && keys.code.length > 0 && registry.code.length > 0,
            "missing dependency"
        );
        require(AccountKeys(keys).reserveAt(10_000) == 4000.1 ether, "unexpected key curve");

        string memory listName = vm.envOr("LIST_NAME", string("blocked"));
        require(bytes(listName).length > 0, "LIST_NAME is empty");
        console.log("Board", board);
        console.log("AccountKeys", keys);
        console.log("ListRegistry", registry);
        console.log("list name", listName);
        bytes32 list = keccak256(bytes(listName));
        holders = deploy(
            "AuthorKeyGate",
            keccak256("AuthorKeyGate v1"),
            abi.encodePacked(type(AuthorKeyGate).creationCode, abi.encode(board, keys))
        );
        combined = deploy(
            "AuthorKeyBlocklistGate",
            keccak256("AuthorKeyBlocklistGate v1"),
            abi.encodePacked(
                type(AuthorKeyBlocklistGate).creationCode, abi.encode(board, keys, registry, list)
            )
        );
    }
}
