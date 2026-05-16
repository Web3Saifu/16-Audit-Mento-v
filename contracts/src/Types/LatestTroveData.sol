// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;


/*This struct contains:

debt
collateral
redistribution gains
interest
fee state
timestamps

for a single Trove.


LatestTroveData  → one Trove
LatestBatchData  → group of Troves*/

struct LatestTroveData { // “Latest financial/accounting snapshot of ONE Trove”
    uint256 entireDebt; // total current Trove debt
    uint256 entireColl;  //total collateral currently owned by Trove
    uint256 redistBoldDebtGain; //  extra debt received from liquidated Troves  its debt gets distributed to surviving Troves
    uint256 redistCollGain; //  extra collateral received from liquidations
    uint256 accruedInterest;//  interest accumulated over time    but not yet permanently recorded
    uint256 recordedDebt; // principal + already-accounted interest  entireDebt≈recordedDebt+accruedInterest+redistributedDebt
    uint256 annualInterestRate;  //interest rate applied to this Trove  5% APR
    uint256 weightedRecordedDebt;  //weightedDebt=recordedDebt×interestRate   system-wide average interest rate
    uint256 accruedBatchManagementFee;//  management fee accumulated for this Trove
    uint256 lastInterestRateAdjTime;   //last time Trove interest rate was changed
}
