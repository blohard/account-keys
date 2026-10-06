// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Board} from "protocol/src/Board.sol";
import {ListRegistry} from "protocol/src/ListRegistry.sol";
import {DeployKeyGates} from "../script/DeployKeyGates.s.sol";
import {AccountKeys} from "../src/AccountKeys.sol";
import {AuthorKeyGate, AuthorKeyBlocklistGate} from "../src/KeyGates.sol";

contract DeployKeyGatesTest is Test {
    function test_keyGateAddressesAndIdempotence() public {
        Board board = new Board();
        ListRegistry registry = new ListRegistry();
        AccountKeys keys = new AccountKeys(makeAddr("devFund"));
        vm.setEnv("BOARD", vm.toString(address(board)));
        vm.setEnv("REGISTRY", vm.toString(address(registry)));
        vm.setEnv("ACCOUNT_KEYS", vm.toString(address(keys)));
        vm.setEnv("LIST_NAME", "blocked");
        DeployKeyGates deployer = new DeployKeyGates();
        (address holders, address combined) = deployer.run();
        assertEq(
            holders,
            vm.computeCreate2Address(
                keccak256("AuthorKeyGate v1"),
                keccak256(
                    abi.encodePacked(type(AuthorKeyGate).creationCode, abi.encode(board, keys))
                )
            )
        );
        assertEq(
            combined,
            vm.computeCreate2Address(
                keccak256("AuthorKeyBlocklistGate v1"),
                keccak256(
                    abi.encodePacked(
                        type(AuthorKeyBlocklistGate).creationCode,
                        abi.encode(board, keys, registry, keccak256("blocked"))
                    )
                )
            )
        );
        (address h2, address c2) = deployer.run();
        assertEq(holders, h2);
        assertEq(combined, c2);
    }
}
