// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@std/Script.sol";
import "../src/CantoNameService.sol";
import { VRGDAPricer } from "../src/VRGDAPricer.sol";

contract MyScript is Script {
  function run() external {
    // uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    uint256 deployerPrivateKey = vm.envUint("PROD_PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    int256 oneTargetPrice = 6e18;
    int256 twoTargetPrice = 5e18;
    int256 threeTargetPrice = 4e18;
    int256 fourTargetPrice = 3e18;
    int256 fiveTargetPrice = 2e18;
    int256 longTargetPrice = 1e18;

    int256 decayPercent = 0.20e18;
    int256 perTimeUnit = 1e18;

    VRGDAPricer pricerLevelOne = new VRGDAPricer(
      oneTargetPrice,
      decayPercent,
      perTimeUnit
    );

    VRGDAPricer pricerLevelTwo = new VRGDAPricer(
      twoTargetPrice,
      decayPercent,
      perTimeUnit
    );

    VRGDAPricer pricerLevelThree = new VRGDAPricer(
      threeTargetPrice,
      decayPercent,
      perTimeUnit
    );

    VRGDAPricer pricerLevelFour = new VRGDAPricer(
      fourTargetPrice,
      decayPercent,
      perTimeUnit
    );

    VRGDAPricer pricerLevelFive = new VRGDAPricer(
      fiveTargetPrice,
      decayPercent,
      perTimeUnit
    );

    VRGDAPricer pricerLevelLong = new VRGDAPricer(
      longTargetPrice,
      decayPercent,
      perTimeUnit
    );

    address vrgdaOneAddress = address(pricerLevelOne);
    address vrgdaTwoAddress = address(pricerLevelTwo);
    address vrgdaThreeAddress = address(pricerLevelThree);
    address vrgdaFourAddress = address(pricerLevelFour);
    address vrgdaFiveAddress = address(pricerLevelFive);
    address vrgdaLongAddress = address(pricerLevelLong);

    // new CantoNameService(
    //   vrgdaOneAddress,
    //   vrgdaTwoAddress,
    //   vrgdaThreeAddress,
    //   vrgdaFourAddress,
    //   vrgdaFiveAddress,
    //   vrgdaLongAddress
    // );

    vm.stopBroadcast();
  }
}
