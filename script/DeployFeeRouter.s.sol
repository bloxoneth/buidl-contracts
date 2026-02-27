// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {FeeRouter} from "src/FeeRouter.sol";

/// @notice Deploy FeeRouter for BuildNFT liquidityReceiver routing.
/// Required env:
/// - PRIVATE_KEY
/// - BLOX_ADDRESS
/// - WETH_ADDRESS
/// - SWAP_ROUTER_ADDRESS (Uniswap v3 router)
/// - EMISSIONS_RECEIVER (Distributor or emissions pool)
/// Optional:
/// - FEE_ROUTER_POOL_FEE (defaults 3000)
contract DeployFeeRouter is Script {
    function run() external returns (FeeRouter feeRouter) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address blox = vm.envAddress("BLOX_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address emissionsReceiver = vm.envAddress("EMISSIONS_RECEIVER");
        uint24 poolFee = uint24(vm.envOr("FEE_ROUTER_POOL_FEE", uint256(3000)));

        vm.startBroadcast(pk);
        feeRouter =
            new FeeRouter(blox, weth, swapRouter, emissionsReceiver, poolFee, deployer);
        vm.stopBroadcast();
    }
}

