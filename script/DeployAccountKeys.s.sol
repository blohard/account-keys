// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {console} from "forge-std/Script.sol";
import {DeterministicDeploy} from "protocol/script/DeterministicDeploy.sol";

import {AccountKeys} from "../src/AccountKeys.sol";

/// @notice Deploys the shared account-key market through the deterministic deployer proxy.
/// @dev The dev fund is part of the market's address and can never change. Run it without
///      --broadcast first and check the printed address against deployments.json.
///
///   ACCOUNT_KEYS_DEV_FUND=0x… forge script script/DeployAccountKeys.s.sol \
///       --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
///
/// Without --broadcast nothing is sent: the script simulates the deployment and prints the market's
/// address.
contract DeployAccountKeys is DeterministicDeploy {
    bytes32 public constant SALT = keccak256("AccountKeys v1");

    /// @notice The market's address for `devFund`, the same on every chain.
    function predictedAddress(address devFund) public pure returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(AccountKeys).creationCode, abi.encode(devFund)));
        return vm.computeCreate2Address(SALT, initCodeHash);
    }

    function run() external returns (AccountKeys market) {
        address devFund = vm.envAddress("ACCOUNT_KEYS_DEV_FUND");
        require(devFund != address(0), "ACCOUNT_KEYS_DEV_FUND is zero");
        console.log("AccountKeys dev fund", devFund);

        market = AccountKeys(
            deploy(
                "AccountKeys",
                SALT,
                abi.encodePacked(type(AccountKeys).creationCode, abi.encode(devFund))
            )
        );
    }
}
