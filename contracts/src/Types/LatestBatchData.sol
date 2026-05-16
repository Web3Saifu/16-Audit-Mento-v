// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

struct LatestBatchData {//“Current snapshot of a Batch”  a group of Troves managed together    interest strategy
    uint256 totalDebtShares;//total ownership shares of debt inside batch   their shares represent 10% of batch debt
    uint256 entireDebtWithoutRedistribution;  //batch debt BEFORE redistribution gains
    uint256 entireCollWithoutRedistribution;   //batch collateral BEFORE redistribution gains
    uint256 accruedInterest;  //interest accumulated but not yet fully accounted/minted
    uint256 recordedDebt; //  official stored debt value    principal + previously accounted interest
    uint256 annualInterestRate;  //yearly interest rate for this batch    5% APR    stored in 1e18 precision.
    uint256 weightedRecordedDebt;//  weightedDebt=debt×interestRate   aggregate average interest rate  across the whole protocol.
    uint256 annualManagementFee;//yearly management fee for this batch
    uint256 accruedManagementFee;//   yearly fee charged by batch manager 
    uint256 weightedRecordedBatchManagementFee;//  management fee accumulated over time   but maybe not yet minted/accounted.
    uint256 lastDebtUpdateTime;//Same weighted accounting idea.   debt×managementFeeRate  
    uint256 lastInterestRateAdjTime;//  last time debt/interest accounting updated  time-based interest accrual
}
