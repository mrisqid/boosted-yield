// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BoostedYield} from "../src/BoostedYield.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployBoostedYield is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address admin = vm.addr(deployerKey);
        address rewarder = admin; // or separate address

        vm.startBroadcast(deployerKey);

        // 1. Deploy implementation
        BoostedYield implementation = new BoostedYield();

        // 2. Encode initializer
        bytes memory initData = abi.encodeWithSelector(BoostedYield.initialize.selector, admin, rewarder);

        // 3. Deploy UUPS proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        vm.stopBroadcast();

        console2.log("BoostedYield implementation:", address(implementation));
        console2.log("BoostedYield proxy:", address(proxy));
    }
}
