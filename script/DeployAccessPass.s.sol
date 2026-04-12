// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BasebloxAccessPass} from "src/BasebloxAccessPass.sol";

contract DeployAccessPass is Script {
    function run() external {
        address blox = vm.envAddress("BLOX_ADDRESS");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        string memory baseTokenURI = vm.envString("ACCESS_PASS_BASE_URI");
        string memory contractURI = vm.envString("ACCESS_PASS_CONTRACT_URI");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        BasebloxAccessPass pass = new BasebloxAccessPass(blox, treasury, baseTokenURI, contractURI);
        vm.stopBroadcast();

        console2.log("BasebloxAccessPass:", address(pass));
    }
}
