// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import {CantoNameService} from "src/CantoNameService.sol";

// forge script ./script/CantoNameService.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

contract CNSScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address cnsSignerPublicAddress = vm.envAddress("CNS_SIGNER_PUBLIC_ADDRESS");
        address delegateCashAddress = 0x00000000000076A84feF008CDAbe6409d2FE638B;

        vm.startBroadcast(deployerPrivateKey);
        CantoNameService cns = new CantoNameService(delegateCashAddress, cnsSignerPublicAddress);

        cns.setBaseURI("https://www.cantonameservice.xyz/api/metadata/");

        int256 baseTargetDecayPercent = 0.42e18;

        int256[] memory tempTargetPrices = new int256[](6);
        int256[] memory tempPriceDecays = new int256[](6);
        int256[] memory tempBasePerTimeUnits = new int256[](6);

        cns.setStatus(1);

        tempTargetPrices[0] = 200e18;
        tempTargetPrices[1] = 100e18;
        tempTargetPrices[2] = 50e18;
        tempTargetPrices[3] = 20e18;
        tempTargetPrices[4] = 15e18;
        tempTargetPrices[5] = 10e18;

        tempBasePerTimeUnits[0] = 0.5e18;
        tempBasePerTimeUnits[1] = 1e18;
        tempBasePerTimeUnits[2] = 3e18;
        tempBasePerTimeUnits[3] = 4e18;
        tempBasePerTimeUnits[4] = 5e18;
        tempBasePerTimeUnits[5] = 100e18;

        for (uint256 i = 0; i < 6; i++) {
            tempPriceDecays[i] = baseTargetDecayPercent;
        }

        cns.setupVRGDAs(tempTargetPrices, tempPriceDecays, tempBasePerTimeUnits, 6);

        vm.stopBroadcast();
    }
}
