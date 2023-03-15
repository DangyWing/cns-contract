// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {LibLinearVRGDA} from "src/lib/LibLinearVRGDA.sol";
import {toDaysWadUnsafe, wadLn, unsafeWadDiv} from "solmate/src/utils/SignedWadMath.sol";

contract MockLinearVRGDA {
    constructor() {}

    struct VRGDAConstants {
        // Target price for a name, to be scaled according to sales pace.
        int256 targetPrice;
        // Percentage price decays per unit of time with no sales, scaled by 1e18.
        int256 priceDecayPercent;
        // Precomputed constant that allows us to rewrite a pow() as an exp().
        int256 decayConstant;
        // The total number of tokens to target selling every full unit of time.
        int256 perTimeUnit;
        // Block timestamp VRGDA initialized in
        int256 startTime;
    }

    mapping(uint256 => VRGDAConstants) public vrgdaData;

    function setupSingleVRGDA(uint256 lengthToSetup, int256 targetPrice, int256 priceDecayPercent, int256 perTimeUnit)
        external
    {
        vrgdaData[lengthToSetup].targetPrice = targetPrice;
        vrgdaData[lengthToSetup].priceDecayPercent = priceDecayPercent;
        vrgdaData[lengthToSetup].decayConstant = wadLn(1e18 - priceDecayPercent);
        vrgdaData[lengthToSetup].perTimeUnit = perTimeUnit;
        vrgdaData[lengthToSetup].startTime = int256(block.timestamp);
    }

    function getTargetSaleTime(int256 sold, uint256 length) public view virtual returns (int256) {
        return unsafeWadDiv(sold, vrgdaData[length].perTimeUnit);
    }
}
