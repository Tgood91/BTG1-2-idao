// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../BushidoRoomsGauge.sol";

/// @title DeployRoomsGauge
/// @notice Deploys BushidoRoomsGauge owned by the BushidoGovernanceV1_1 timelock. Dry-run it first (no --broadcast).
///
/// Environment variables:
///   WRUNES_ADDRESS  required  the WrappedRunesVotes (WRunes) token invokers vote with
///   GAUGE_OWNER     required  the V1.1 TimelockController (rooms are then added by governance proposals)
///   REWARD_TOKEN    optional  the token rewards are paid in (default: Runes on Base)
contract DeployRoomsGauge is Script {
    address public constant RUNES = 0x68E63f682AB383A9132317349125fF7618C96e01;

    function run() external returns (BushidoRoomsGauge gauge) {
        address token = vm.envAddress("WRUNES_ADDRESS");
        address owner = vm.envAddress("GAUGE_OWNER");
        address reward = vm.envOr("REWARD_TOKEN", RUNES);
        require(owner.code.length != 0, "GAUGE_OWNER should be the V1.1 timelock contract");

        vm.startBroadcast();
        gauge = new BushidoRoomsGauge(IVotes(token), IERC20(reward), owner);
        vm.stopBroadcast();

        console.log("BushidoRoomsGauge:", address(gauge));
        console.log("Owner (timelock): ", owner);
        console.log("Reward token:     ", reward);
        console.log("Epoch 0 starts at:", gauge.genesis());
    }
}
