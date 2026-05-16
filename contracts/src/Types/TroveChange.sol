// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

struct TroveChange {//“What changed in a Trove during an operation?”
    uint256 appliedRedistBoldDebtGain;//redistributed debt added to this Trove
    uint256 appliedRedistCollGain;//redistributed collateral received
    uint256 collIncrease;//user added collateral ,,deposit more ETH
    uint256 collDecrease;//collateral withdrawn/removed
    uint256 debtIncrease;//new debt added
    uint256 debtDecrease;//debt repayment
    uint256 newWeightedRecordedDebt;//new debt × interest rate  ,,1000×0.1=100
    uint256 oldWeightedRecordedDebt;//previous weighted debt before update ,,newTotal = oldTotal + new - old
    uint256 upfrontFee;//immediate borrowing fee charged upfront
    uint256 batchAccruedManagementFee;//“How much management fee has been accumulated in a batch (but not yet applied/settled).”
    uint256 newWeightedRecordedBatchManagementFee;//“The updated weighted management fee value after this operation.”
    uint256 oldWeightedRecordedBatchManagementFee;//“The previous weighted batch management fee before current update.” remove old value  add new value

}
