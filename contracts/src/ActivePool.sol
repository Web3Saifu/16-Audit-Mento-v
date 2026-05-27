// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24; // solidity compiler version

// ===== OpenZeppelin Libraries =====

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol"; 
// safer ERC20 operations
// handles non-standard ERC20s safely
// adds:
// - safeTransfer()
// - safeTransferFrom()
// - safeApprove()

import "openzeppelin-contracts/contracts/utils/math/Math.sol"; 
// math utility library
// used here mainly for:
// - ceilDiv()
// normal division rounds down
// ceilDiv rounds UP

// ===== Internal Dependencies =====

import "./Dependencies/Constants.sol"; 
// global protocol constants
// ex:
// - DECIMAL_PRECISION
// - ONE_YEAR

import "./Interfaces/IActivePool.sol"; 
// ActivePool interface

import "./Interfaces/IAddressesRegistry.sol"; 
// registry storing protocol addresses
// helps avoid hardcoding addresses

import "./Interfaces/IBoldToken.sol"; 
// BOLD token interface
// BOLD = protocol debt token

import "./Interfaces/IInterestRouter.sol"; 
// LP reward router interface
// routes protocol yield to liquidity providers

import "./Interfaces/IDefaultPool.sol"; 
// DefaultPool interface
// receives redistributed collateral/debt

import "./Interfaces/ISystemParams.sol"; 
// protocol configuration interface
// stores:
// - CCR
// - MCR
// - fees
// - yield split
// etc.

/*
 * ActivePool = main collateral vault
 *
 * Responsibilities:
 * - holds collateral tokens
 * - tracks aggregate system debt
 * - handles collateral movement
 * - mints aggregate interest
 *
 * Interacts with:
 * - BorrowerOperations
 * - TroveManager  The central accounting + liquidation engine
 * - StabilityPool
 * - DefaultPool
 */

contract ActivePool is IActivePool {
    using SafeERC20 for IERC20; 
    // extends IERC20 with safe functions

    string public constant NAME = "ActivePool"; 
    // contract identifier

    IERC20 public immutable collToken; 
    // collateral token ex: cUSD

    address public immutable  ; 
    // BorrowerOperations contract
    // user borrow/repay entry point

    address public immutable troveManagerAddress; 
    // liquidation/redemption manager

    address public immutable defaultPoolAddress; 
    // redistribution pool

    ISystemParams public immutable systemParams; 
    // protocol parameters storage

    IBoldToken public immutable boldToken; 
    // protocol debt token

    IInterestRouter public immutable interestRouter; 
    // distributes LP rewards/yield

    IBoldRewardsReceiver public immutable stabilityPool; 
    // StabilityPool reward receiver

    uint256 internal collBalance;
    // internally tracked collateral amount
    // NOT raw token balance

    uint256 public aggRecordedDebt; 
    // total recorded system debt

    uint256 public aggWeightedDebtSum;// সব user debt × interest rate এর total sum
    // total weighted debt
    // formula:
    // debt * interestRate  1000 × 5%= 50

    uint256 public lastAggUpdateTime; 
    // last aggregate interest update

    uint256 public shutdownTime; 
    // 0 = active
    // non-zero = shutdown

    uint256 public aggBatchManagementFees; 
    // total batch management fees

    uint256 public aggWeightedBatchManagementFeeSum; 
    // weighted batch fee sum   aggWeightedDebtSum
    // formula:
    // debt * batchFeeRate 

    uint256 public lastAggBatchManagementFeesUpdateTime; 
    // last batch fee update time

    // ===== Constructor =====

    constructor(
        IAddressesRegistry _addressesRegistry,
        ISystemParams _systemParams
    ) {
        systemParams = _systemParams; 
        // save params contract

        collToken = _addressesRegistry.collToken();//
        // fetch collateral token from registry

        borrowerOperationsAddress =
            address(_addressesRegistry.borrowerOperations()); 
        // fetch BO address

        troveManagerAddress =
            address(_addressesRegistry.troveManager()); 
        // fetch TroveManager address

        stabilityPool =
            IBoldRewardsReceiver(
                _addressesRegistry.stabilityPool()
            ); 
        // fetch StabilityPool

        defaultPoolAddress =
            address(_addressesRegistry.defaultPool()); 
        // fetch DefaultPool address

        interestRouter =
            _addressesRegistry.interestRouter(); 
        // fetch LP reward router

        boldToken =
            _addressesRegistry.boldToken(); 
        // fetch BOLD token

        emit CollTokenAddressChanged(//
            address(collToken)
        ); 
        // emit collateral config event

        emit BorrowerOperationsAddressChanged(
            borrowerOperationsAddress
        ); 
        // emit BO config event

        emit TroveManagerAddressChanged(
            troveManagerAddress
        ); 
        // emit TM config event

        emit StabilityPoolAddressChanged(
            address(stabilityPool)
        ); 
        // emit SP config event

        emit DefaultPoolAddressChanged(
            defaultPoolAddress
        ); 
        // emit DP config event

        collToken.approve(
            defaultPoolAddress,
            type(uint256).max
        ); 
        // infinite approve to DefaultPool
        // allows DefaultPool to pull collateral
        // during liquidation redistribution
    }
} 

    // --- Getters for public variables. Required by IPool interface ---

   
    function getCollBalance() external view override returns (uint256) {//protocol internally যত collateral believe করে তার amount
        return collBalance;
    }

    function calcPendingAggInterest() public view returns (uint256) { //“system কত debt + interest weight ধরে রেখেছে × কত সময় গেছে”  //“শেষ update-এর পর এখন পর্যন্ত system-এ কত interest জমেছে কিন্তু এখনও officially mint/account করা হয়নি?”
        if (shutdownTime != 0) return 0;//👉 last update-এর পর যত নতুন interest জমেছে কিন্তু এখনও officially stored হয়নি।

        return Math.ceilDiv(aggWeightedDebtSum * (block.timestamp - lastAggUpdateTime), ONE_YEAR * DECIMAL_PRECISION);//শেষ update এর পর এখন পর্যন্ত accrued (জমা হওয়া) system interest  //“system কত debt + interest weight ধরে রেখেছে × কত সময় গেছে”
    }

    function calcPendingSPYield() external view returns (uint256) {//pending system interest-এর একটা অংশ Stability Pool (SP)-এ দিচ্ছে
        return calcPendingAggInterest() * systemParams.SP_YIELD_SPLIT() / DECIMAL_PRECISION;//(B) systemParams.SP_YIELD_SPLIT()  SP কত % interest পাবে   50% = 0.5 (বা 0.5e18)
    }//(A) calcPendingAggInterest()  পুরো system-এর এখন পর্যন্ত accrued interest

    function calcPendingAggBatchManagementFee() public view returns (uint256) {//batch managers-এর accrued management fee এখন পর্যন্ত কত জমেছে সেটা calculate করছে
        uint256 periodEnd = shutdownTime != 0 ? shutdownTime : block.timestamp;//0 = default /  এখনও shutdown হয়নি (active)   //shutdownTime = 900  current time = 1000  ,,900 != 0 → TRUE      So:periodEnd = shutdownTime = 900 
        uint256 periodStart = Math.min(lastAggBatchManagementFeesUpdateTime, periodEnd);//fee calculation কখন থেকে শুরু হবে সেটা ঠিক করা হচ্ছে

        return Math.ceilDiv(aggWeightedBatchManagementFeeSum * (periodEnd - periodStart), ONE_YEAR * DECIMAL_PRECISION);//How much batch management fee has accumulated over a time period. // WeightedFeeSum = 100 Time passed = 0.5 year ,,Fee = 100 × 0.5 = 50 50.0001 → becomes 51 (because of ceilDiv)
    }
 
//“After this trove change happens, what will be the new approximate average interest rate of the whole system?”
    function getNewApproxAvgInterestRateFromTroveChange(TroveChange calldata _troveChange)  “If this Trove change happens, what will the new average system interest rate become?”
        external
        view
        returns (uint256)//predict new system average interest rate BEFORE actually applying the change
    {
        // We are ignoring the upfront fee when calculating the approx. avg. interest rate.
        // This is a simple way to resolve the circularity in:
        //   fee depends on avg. interest rate -> avg. interest rate is weighted by debt -> debt includes fee -> ...
        assert(_troveChange.upfrontFee == 0);

        if (shutdownTime != 0) return 0;// If shutdown already happened, stop calculation and return 0.


/*Old debt = 10,000

+ 100 interest
+ 50 redistributed debt
+ 500 borrowing
+ 20 fee
- 200 repayment

= 10,470*/

        uint256 newAggRecordedDebt = aggRecordedDebt;//aggRecordedDebt = 10,000 BOLD
        newAggRecordedDebt += calcPendingAggInterest(); //10,000 + 100   Because debt grows over time from interest.
        newAggRecordedDebt += _troveChange.appliedRedistBoldDebtGain;//+50   Some liquidated trove debt got redistributed.
        newAggRecordedDebt += _troveChange.debtIncrease;//User borrowed more: 10,150 + 500  = 10,650  User minted/borrowed 500 more BOLD.
        newAggRecordedDebt += _troveChange.batchAccruedManagementFee;  Batch manager earned 20 BOLD fee.  10,650 + 20    = 10,670
        newAggRecordedDebt -= _troveChange.debtDecrease; User repaid debt:  10,670 - 200    = 10,470

        uint256 newAggWeightedDebtSum = aggWeightedDebtSum; Copy old value. newAggWeightedDebtSum = 1,000
        newAggWeightedDebtSum += _troveChange.newWeightedRecordedDebt;  Add new user value: 1,000 + 180  = 1,180  Because user now has a new debt situation.
        newAggWeightedDebtSum -= _troveChange.oldWeightedRecordedDebt;  Remove old user value: 1,180 - 100   = 1,080

        // Avoid division by 0 if the first ever borrower tries to borrow 0 BOLD
        // Borrowing 0 BOLD is not allowed, but our check of debt >= MIN_DEBT happens _after_ calculating the upfront
        // fee, which involves getting the new approx. avg. interest rate
        return newAggRecordedDebt > 0 ? newAggWeightedDebtSum / newAggRecordedDebt : 0; //If debt is bigger than 0 → calculate average interest rate. 1,080 / 10,470 ≈ 0.103 ≈ 10.3%
    }//New average system interest rate = 10.3%

    // Returns sum of agg.recorded debt plus agg. pending interest. Excludes pending redist. gains.
    function getBoldDebt() external view returns (uint256) {
        return aggRecordedDebt + calcPendingAggInterest() + aggBatchManagementFees + calcPendingAggBatchManagementFee();//100 + 10 + 2 + 1 = 113
    }//

    // --- Pool functionality ---

    function sendColl(address _account, uint256 _amount) external override {//👉 এই function ActivePool vault থেকে collateral বের করে অন্য account/contract-এ পাঠায়।  Alice wants to withdraw:
        _requireCallerIsBOorTroveMorSP();//এই function access control guard। এটা check করে caller protocol-এর trusted contract কিনা। Same single example: Alice deposited 110 collateral and borrowed 100 BOLD.

        _accountForSendColl(_amount);

        collToken.safeTransfer(_account, _amount);
    }
///temporary holding area for redistributed liquidation collateral/debt
    function sendCollToDefaultPool(uint256 _amount) external override {//👉 এই function ActivePool থেকে collateral নিয়ে DefaultPool-এ পাঠায়। Usually liquidation redistribution-এর সময় এটা হয়। Same single example: Alice deposited 110 collateral and borrowed 100 BOLD.
        _requireCallerIsTroveManager();//👉 only TroveManager can trigger this.

        _accountForSendColl(_amount);//Internal Accounting Update

        IDefaultPool(defaultPoolAddress).receiveColl(_amount);
    }

    function _accountForSendColl(uint256 _amount) internal {//👉 এই function collateral OUT যাওয়ার আগে protocol-এর internal accounting update করে। Same single example: Alice deposited 110 collateral and borrowed 100 BOLD.
        uint256 newCollBalance = collBalance - _amount;//collBalance = 110
        collBalance = newCollBalance;//Now protocol wants to send: _amount = 10
        emit ActivePoolCollBalanceUpdated(newCollBalance);
    }

    function receiveColl(uint256 _amount) external {//👉 এই function ActivePool-এর ভিতরে collateral ঢোকায়। Same single example: Alice deposits 110 collateral and borrows 100 BOLD.
        _requireCallerIsBorrowerOperationsOrDefaultPool();//only trusted protocol contracts allowed.

        _accountForReceivedColl(_amount);

        // Pull Coll tokens from sender
        collToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function accountForReceivedColl(uint256 _amount) public {//👉 এই function শুধু ActivePool-এর internal collateral accounting update করে। Real ERC20 token transfer এখানে হয় না। Same single example: Alice deposits 110 collateral and borrows 100 BOLD.
        _requireCallerIsBorrowerOperationsOrDefaultPool();

        _accountForReceivedColl(_amount);
    }

    function _accountForReceivedColl(uint256 _amount) internal {
        uint256 newCollBalance = collBalance + _amount;
        collBalance = newCollBalance;

        emit ActivePoolCollBalanceUpdated(newCollBalance);
    }//*Done

    // --- Aggregate interest operations ---

    // This function is called inside all state-changing user ops: borrower ops, liquidations, redemptions and SP deposits/withdrawals.
    // Some user ops trigger debt changes to Trove(s), in which case _troveDebtChange will be non-zero.
    // The aggregate recorded debt is incremented by the aggregate pending interest, plus the net Trove debt change.
    // The net Trove debt change consists of the sum of a) any debt issued/repaid and b) any redistribution debt gain applied in the encapsulating operation.
    // It does *not* include the Trove's individual accrued interest - this gets accounted for in the aggregate accrued interest.
    // The net Trove debt change could be positive or negative in a repayment (depending on whether its redistribution gain or repayment amount is larger),
    // so this function accepts both the increase and the decrease to avoid using (and converting to/from) signed ints.
    function mintAggInterestAndAccountForTroveChange(TroveChange calldata _troveChange, address _batchAddress)//A user changed trove, now update everything in the system correctly.”
        external
    {
        _requireCallerIsBOorTroveM();//Only BorrowerOperations or TroveManager can call this function.

        // Batch management fees
        if (_batchAddress != address(0)) {
            _mintBatchManagementFeeAndAccountForChange(_troveChange, _batchAddress);
        }

        // Do the arithmetic in 2 steps here to avoid underflow from the decrease
        uint256 newAggRecordedDebt = aggRecordedDebt; // 1 SLOAD
        newAggRecordedDebt += _mintAggInterest(_troveChange.upfrontFee); // adds minted agg. interest + upfront fee
        newAggRecordedDebt += _troveChange.appliedRedistBoldDebtGain;
        newAggRecordedDebt += _troveChange.debtIncrease;
        newAggRecordedDebt -= _troveChange.debtDecrease;
        aggRecordedDebt = newAggRecordedDebt; // 1 SSTORE

        // assert(aggRecordedDebt >= 0) // This should never be negative. If all redistribution gians and all aggregate interest was applied
        // and all Trove debts were repaid, it should become 0.

        // Do the arithmetic in 2 steps here to avoid underflow from the decrease
        uint256 newAggWeightedDebtSum = aggWeightedDebtSum; // 1 SLOAD
        newAggWeightedDebtSum += _troveChange.newWeightedRecordedDebt;
        newAggWeightedDebtSum -= _troveChange.oldWeightedRecordedDebt;
        aggWeightedDebtSum = newAggWeightedDebtSum; // 1 SSTORE
    }

    function mintAggInterest() external override {
        _requireCallerIsBOorSP();
        aggRecordedDebt += _mintAggInterest(0);
    }

    function _mintAggInterest(uint256 _upfrontFee) internal returns (uint256 mintedAmount) {
        mintedAmount = calcPendingAggInterest() + _upfrontFee;

        // Mint part of the BOLD interest to the SP and part to the router for LPs.
        if (mintedAmount > 0) {
            uint256 spYield = systemParams.SP_YIELD_SPLIT() * mintedAmount / DECIMAL_PRECISION;
            uint256 remainderToLPs = mintedAmount - spYield;

            boldToken.mint(address(interestRouter), remainderToLPs);

            if (spYield > 0) {
                boldToken.mint(address(stabilityPool), spYield);
                stabilityPool.triggerBoldRewards(spYield);
            }
        }

        lastAggUpdateTime = block.timestamp;
    }

    function mintBatchManagementFeeAndAccountForChange(TroveChange calldata _troveChange, address _batchAddress)
        external
        override
    {
        _requireCallerIsTroveManager();
        _mintBatchManagementFeeAndAccountForChange(_troveChange, _batchAddress);
    }

    function _mintBatchManagementFeeAndAccountForChange(TroveChange memory _troveChange, address _batchAddress)// 👉 এই function batch manager-এর accrued fee system debt-এ add করে, accounting update করে, তারপর real BOLD mint করে batch manager-কে দেয়। Same single example: Alice deposited 110 collateral and borrowed 100 BOLD. Alice joined a batch manager charging management fee.
    {
        aggRecordedDebt += _troveChange.batchAccruedManagementFee;//— Add Fee Into Total System Debt  aggRecordedDebt += _troveChange.batchAccruedManagementFee; aggRecordedDebt = 100  batchAccruedManagementFee = 5   aggRecordedDebt = 105

        // Do the arithmetic in 2 steps here to avoid underflow from the decrease
        uint256 newAggBatchManagementFees = aggBatchManagementFees; // 👉 load current stored value into memory.  aggBatchManagementFees = 20
        newAggBatchManagementFees += calcPendingAggBatchManagementFee();//Suppose pending new fee: 3   20 + 3 = 23
        newAggBatchManagementFees -= _troveChange.batchAccruedManagementFee;// Suppose accrued fee being settled: 5 23 - 5 = 18      aggBatchManagementFees = 18;
        aggBatchManagementFees = newAggBatchManagementFees; // 1 SSTORE

        // Do the arithmetic in 2 steps here to avoid underflow from the decrease
        uint256 newAggWeightedBatchManagementFeeSum = aggWeightedBatchManagementFeeSum; // 1 SLOAD
        newAggWeightedBatchManagementFeeSum += _troveChange.newWeightedRecordedBatchManagementFee;
        newAggWeightedBatchManagementFeeSum -= _troveChange.oldWeightedRecordedBatchManagementFee;
        aggWeightedBatchManagementFeeSum = newAggWeightedBatchManagementFeeSum; // 1 SSTORE

        // mint fee to batch address
        if (_troveChange.batchAccruedManagementFee > 0) {
            boldToken.mint(_batchAddress, _troveChange.batchAccruedManagementFee);
        }

        lastAggBatchManagementFeesUpdateTime = block.timestamp;
    }

    // --- Shutdown ---

    function setShutdownFlag() external {
        _requireCallerIsTroveManager();
        shutdownTime = block.timestamp;
    }

    function hasBeenShutDown() external view returns (bool) {
        return shutdownTime != 0;
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress || msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool"
        );
    }

    function _requireCallerIsBOorTroveMorSP() internal view {//👉 এই function access control guard। এটা check করে caller protocol-এর trusted contract কিনা। Same single example: Alice deposited 110 collateral and borrowed 100 BOLD.
        require( // @audit haw thay validate who call this fun.
            msg.sender == borrowerOperationsAddress || msg.sender == troveManagerAddress
                || msg.sender == address(stabilityPool),
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool"
        );
    }
    

    function _requireCallerIsBOorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress || msg.sender == address(stabilityPool),
            "ActivePool: Caller is not BorrowerOperations nor StabilityPool"
        );
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == borrowerOperationsAddress || msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager"
        );
    }


    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "ActivePool: Caller is not TroveManager");
    }

