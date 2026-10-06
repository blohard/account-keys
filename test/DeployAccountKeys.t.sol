// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {AccountKeys} from "../src/AccountKeys.sol";
import {DeployAccountKeys} from "../script/DeployAccountKeys.s.sol";

contract DeployAccountKeysTest is Test {
    // Every change to the environment stays in this one test, since tests run in parallel and share
    // the process environment.
    function test_deployPredictionAndIdempotence() public {
        DeployAccountKeys script = new DeployAccountKeys();
        address dev = address(0xDEAF);
        assertEq(script.SALT(), keccak256("AccountKeys v1"));
        address predicted = script.predictedAddress(dev);
        assertTrue(
            script.predictedAddress(address(0xBEEF)) != predicted,
            "the dev fund is part of the address"
        );
        vm.setEnv("ACCOUNT_KEYS_DEV_FUND", vm.toString(dev));
        AccountKeys market = script.run();
        assertEq(address(market), predicted);
        assertEq(market.DEV_FUND(), dev);
        assertEq(address(script.run()), predicted, "a rerun finds the same market");
        vm.setEnv("ACCOUNT_KEYS_DEV_FUND", vm.toString(address(0)));
        vm.expectRevert(bytes("ACCOUNT_KEYS_DEV_FUND is zero"));
        script.run();
        vm.setEnv("ACCOUNT_KEYS_DEV_FUND", vm.toString(dev));
    }
}
