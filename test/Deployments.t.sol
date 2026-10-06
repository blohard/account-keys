// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {AccountKeys} from "../src/AccountKeys.sol";
import {AuthorKeyBlocklistGate, AuthorKeyGate} from "../src/KeyGates.sol";

/// Every address in deployments.json is the CREATE2 address of the code in this repository, built
/// on the Board and ListRegistry that the protocol's own deployments.json lists for that chain. So
/// the file cannot go stale: changing a contract without updating it, or the reverse, fails here.
contract DeploymentsTest is Test {
    string json;
    string core;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/deployments.json"));
        core = vm.readFile(string.concat(vm.projectRoot(), "/lib/protocol/deployments.json"));
    }

    function _check(string memory chain) internal view {
        string memory root = string.concat(".", chain);
        address board = vm.parseJsonAddress(core, string.concat(root, ".Board.address"));
        address registry = vm.parseJsonAddress(core, string.concat(root, ".ListRegistry.address"));
        address keys = vm.parseJsonAddress(json, string.concat(root, ".AccountKeys.address"));

        address devFund = vm.parseJsonAddress(json, string.concat(root, ".AccountKeys.devFund"));
        assertEq(
            keys,
            vm.computeCreate2Address(
                keccak256("AccountKeys v1"),
                keccak256(abi.encodePacked(type(AccountKeys).creationCode, abi.encode(devFund)))
            ),
            string.concat(chain, " AccountKeys")
        );

        assertEq(
            vm.parseJsonAddress(json, string.concat(root, ".AuthorKeyGate.address")),
            vm.computeCreate2Address(
                keccak256("AuthorKeyGate v1"),
                keccak256(
                    abi.encodePacked(type(AuthorKeyGate).creationCode, abi.encode(board, keys))
                )
            ),
            string.concat(chain, " AuthorKeyGate")
        );

        string memory list =
            vm.parseJsonString(json, string.concat(root, ".AuthorKeyBlocklistGate.list"));
        assertEq(list, "blocked", string.concat(chain, " AuthorKeyBlocklistGate list"));
        assertEq(
            vm.parseJsonAddress(json, string.concat(root, ".AuthorKeyBlocklistGate.address")),
            vm.computeCreate2Address(
                keccak256("AuthorKeyBlocklistGate v1"),
                keccak256(
                    abi.encodePacked(
                        type(AuthorKeyBlocklistGate).creationCode,
                        abi.encode(board, keys, registry, keccak256(bytes(list)))
                    )
                )
            ),
            string.concat(chain, " AuthorKeyBlocklistGate")
        );
    }

    function test_baseAddressesAreThisCode() public {
        vm.skip(!vm.keyExistsJson(json, ".base"), "not deployed on Base yet");
        assertEq(vm.parseJsonUint(json, ".base.chainId"), 8453);
        _check("base");
    }

    function test_baseSepoliaAddressesAreThisCode() public view {
        assertEq(vm.parseJsonUint(json, ".baseSepolia.chainId"), 84532);
        _check("baseSepolia");
    }
}
