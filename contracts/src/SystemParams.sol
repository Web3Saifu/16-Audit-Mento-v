// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import {ISystemParams} from "./Interfaces/ISystemParams.sol";//ISystemParams.sol file থেকে ISystemParams import করো
import {//constants import করো
    _100pct,
    _1pct,
    MAX_LIQUIDATION_PENALTY_REDISTRIBUTION,
    MAX_ANNUAL_INTEREST_RATE
} from "./Dependencies/Constants.sol";
import "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/*
the entire protocol economic rules
minimum debt
liquidation penalties
collateral ratios
interest constraints
redemption configs
SP configs*/



/**
 * @title System Parameters
 * @author Mento Labs
 * @notice This contract manages the system-wide parameters for the protocol.
 */
contract SystemParams is ISystemParams, Initializable {// protocol configuration storage + validation layer
    /* ========== DEBT PARAMETERS ========== */

    uint256 public immutable MIN_DEBT;

    /* ========== LIQUIDATION PARAMETERS ========== */

    uint256 public immutable LIQUIDATION_PENALTY_SP;//Suppose penalty = 10%. system had to rescue it     Used when:StabilityPool covers debt
    uint256 public immutable LIQUIDATION_PENALTY_REDISTRIBUTION;//But different liquidation mode.      Used when: other borrowers absorb Alice debt

    /* ========== GAS COMPENSATION PARAMETERS ========== */

    uint256 public immutable COLL_GAS_COMPENSATION_DIVISOR;//Someone must press liquidation transaction. That person pays gas fee.    So protocol rewards them.
    uint256 public immutable COLL_GAS_COMPENSATION_CAP; //What if Alice had HUGE collateral? Then liquidator reward becomes too huge.   So protocol sets max limit.
    uint256 public immutable ETH_GAS_COMPENSATION;  //  Protocol also gives fixed ETH reward.   0.01 ETH    Even if collateral reward small,    liquidator still earns fixed ETH. 

    /* ========== COLLATERAL PARAMETERS ========== */

    uint256 public immutable CCR;//CCR triggers Recovery Mode   CCR = protocol emergency alarm   This is about WHOLE protocol.  Critical Collateral Ratio
    uint256 public immutable SCR; //   This is another safety threshold. Protocol wants extra safety before danger happens.”  “Don’t borrow too aggressively.”    So even if liquidation starts at 110%,   opening may require 120%.  Secondary Collateral Ratio
    uint256 public immutable MCR;  //“Below this ratio → liquidation starts”   105% < 110%   Minimum Collateral Ratio
    uint256 public immutable BCR;  //liquidation happens at 110%    but opening loan may require 120%       Borrowing Collateral Ratio

    /* ========== INTEREST PARAMETERS ========== */

    uint256 public immutable MIN_ANNUAL_INTEREST_RATE; //Protocol charges interest on loans.

    /* ========== REDEMPTION PARAMETERS ========== */

    uint256 public immutable REDEMPTION_FEE_FLOOR; // Protocol charges fee.
    uint256 public immutable INITIAL_BASE_RATE;  //Starting redemption fee level.
    uint256 public immutable REDEMPTION_MINUTE_DECAY_FACTOR;  //Redemption fee slowly decreases over time.    Market calm    Fee slowly cools down
    uint256 public immutable REDEMPTION_BETA;  //how aggressively redemption fee changes

    /* ========== STABILITY POOL PARAMETERS ========== */

    uint256 public immutable SP_YIELD_SPLIT;//governance can mutate it anytime   কত StabilityPool users পাবে  কত অন্য জায়গায় যাবে  
    uint256 public immutable MIN_BOLD_IN_SP; // “Stability Pool must always have minimum liquidity.”
    uint256 public immutable MIN_BOLD_AFTER_REBALANCE;  //“After rebalance, do we still have enough BOLD inside SP?”

    /* ========== CONSTRUCTOR ========== */

    constructor(  //they group related configs together.
        bool disableInitializers,
        DebtParams memory _debtParams,//debt-related settings package
        LiquidationParams memory _liquidationParams,  
        GasCompParams memory _gasCompParams,
        CollateralParams memory _collateralParams,
        InterestParams memory _interestParams,
        RedemptionParams memory _redemptionParams,
        StabilityPoolParams memory _poolParams
    ) {
        if (disableInitializers) {
            _disableInitializers();
        }

        // minDebt should be choosen depending on the debt currency
        if (_debtParams.minDebt == 0) revert InvalidMinDebt();

        // Validate liquidation parameters
        // Hardcoded validation bounds: MIN_LIQUIDATION_PENALTY_SP = 5%
        if (_liquidationParams.liquidationPenaltySP < 5 * _1pct) {//“Liquidation penalty cannot be too small.”
            revert SPPenaltyTooLow();
        }
        if (_liquidationParams.liquidationPenaltySP > _liquidationParams.liquidationPenaltyRedistribution) {//“SP liquidation should NOT be harsher than redistribution.”
            revert SPPenaltyGtRedist();
        }

        // Validate gas compensation parameters
        if (_gasCompParams.collGasCompensationDivisor == 0 || _gasCompParams.collGasCompensationDivisor > 1000) { //🔥 division by zero crash.
            revert InvalidGasCompensation();
        }
        if (_gasCompParams.collGasCompensationCap == 0 || _gasCompParams.collGasCompensationCap > 10 ether) {//if (cap == 0 || cap > 10 ether)    reward cap cannot be absurdly huge
            revert InvalidGasCompensation();
        }
        if (_gasCompParams.ethGasCompensation == 0 || _gasCompParams.ethGasCompensation > 1 ether) {// if (ethGasCompensation == 0 || > 1 ether)   cannot be crazy large
            revert InvalidGasCompensation();
        }

        // Validate collateral parameters
        if (_collateralParams.ccr <= _100pct || _collateralParams.ccr >= 2 * _100pct) revert InvalidCCR();//“CCR must stay in reasonable range.”  if (ccr <= 100% || ccr >= 200%)   “CCR must stay between 100% and 200%”
        if (_collateralParams.mcr <= _100pct || _collateralParams.mcr >= 2 * _100pct) revert InvalidMCR();  CCR = emergency mode trigger.
        if (_collateralParams.bcr < 5 * _1pct || _collateralParams.bcr >= 50 * _1pct) revert InvalidBCR();   BCR = borrowing safety buffer.  Users can borrow too aggressively. BCR = 1%     Too huge.   BCR = 90%
        if (_collateralParams.scr <= _100pct || _collateralParams.scr >= 2 * _100pct) revert InvalidSCR();   SCR is another safety threshold.   if (scr <= 100% || scr >= 200%)

        // The redistribution penalty must not exceed the overcollateralization buffer (MCR - 100%)
        if (
            _liquidationParams.liquidationPenaltyRedistribution > MAX_LIQUIDATION_PENALTY_REDISTRIBUTION// redistribution penalty = 20%  But Alice only has: 10% extra collateral  🔥 impossible.
                || _liquidationParams.liquidationPenaltyRedistribution > _collateralParams.mcr - _100pct//Penalty must stay <= extra buffer otherwise revert   liquidate হলে borrower থেকে extra collateral কেটে নেওয়া হয়   //mcr - 100% কী?   110%−100%=10%
        ) {
            revert RedistPenaltyTooHigh();
        }

        // Validate interest parameters
        if (_interestParams.minAnnualInterestRate > MAX_ANNUAL_INTEREST_RATE) {//“minimum interest rate খুব বেশি হয়ে গেলে reject”
            revert MinInterestRateGtMax();
        }

        // Validate redemption parameters
        if (_redemptionParams.redemptionFeeFloor > _100pct) revert InvalidFeeValue();  //fee 100% এর বেশি হতে পারবে না   If redeeming 100 BOLD:fee = 120 BOLD ❌ impossible
        if (_redemptionParams.initialBaseRate > 10 * _100pct) revert InvalidFeeValue();//starting fee too high হলে reject

        // Validate stability pool parameters
        if (_poolParams.spYieldSplit > _100pct) revert InvalidFeeValue();
        if (_poolParams.minBoldAfterRebalance < _poolParams.minBoldInSP) revert InvalidMinBoldInSP();
        if (_poolParams.minBoldInSP < 1e18) revert InvalidMinBoldInSP();

        // Set debt parameters
        MIN_DEBT = _debtParams.minDebt;

        // Set liquidation parameters
        LIQUIDATION_PENALTY_SP = _liquidationParams.liquidationPenaltySP;
        LIQUIDATION_PENALTY_REDISTRIBUTION = _liquidationParams.liquidationPenaltyRedistribution;

        // Set gas compensation parameters
        COLL_GAS_COMPENSATION_DIVISOR = _gasCompParams.collGasCompensationDivisor;
        COLL_GAS_COMPENSATION_CAP = _gasCompParams.collGasCompensationCap;
        ETH_GAS_COMPENSATION = _gasCompParams.ethGasCompensation;

        // Set collateral parameters
        CCR = _collateralParams.ccr;
        SCR = _collateralParams.scr;
        MCR = _collateralParams.mcr;
        BCR = _collateralParams.bcr;

        // Set interest parameters
        MIN_ANNUAL_INTEREST_RATE = _interestParams.minAnnualInterestRate;

        // Set redemption parameters
        REDEMPTION_FEE_FLOOR = _redemptionParams.redemptionFeeFloor;
        INITIAL_BASE_RATE = _redemptionParams.initialBaseRate;
        REDEMPTION_MINUTE_DECAY_FACTOR = _redemptionParams.redemptionMinuteDecayFactor;
        REDEMPTION_BETA = _redemptionParams.redemptionBeta;

        // Set stability pool parameters
        SP_YIELD_SPLIT = _poolParams.spYieldSplit;
        MIN_BOLD_IN_SP = _poolParams.minBoldInSP;
        MIN_BOLD_AFTER_REBALANCE = _poolParams.minBoldAfterRebalance;
    }

    /*
     * Initializes proxy storage
     * All parameters are immutable from constructor. This function
     * only marks initialization complete for proxy pattern.
     */
    function initialize() external initializer {}
}
