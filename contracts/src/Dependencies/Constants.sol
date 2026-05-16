// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

address constant ZERO_ADDRESS = address(0);//0x0000000000000000000000000000000000000000

uint256 constant MAX_UINT256 = type(uint256).max;//largest possible uint256 value

uint256 constant DECIMAL_PRECISION = 1e18;
uint256 constant _100pct = DECIMAL_PRECISION;//100% = 1e18
uint256 constant _1pct = DECIMAL_PRECISION / 100;//1% = 1e16   1018/100=1016 //?

uint256 constant ONE_MINUTE = 1 minutes;//60 seconds
uint256 constant ONE_YEAR = 365 days;//31536000 seconds

// Interest rate parameters
uint256 constant MAX_ANNUAL_INTEREST_RATE = 250 * _1pct; // 250%
uint128 constant MAX_ANNUAL_BATCH_MANAGEMENT_FEE = uint128(_100pct / 10); // 10%//max batch fee = 10%,, 1e18/10=0.1e18=10%
uint128 constant MIN_INTEREST_RATE_CHANGE_PERIOD = 1 hours;//cannot change interest rate too frequently
uint256 constant UPFRONT_INTEREST_PERIOD = 7 days;//upfront fee simulates 7 days worth of interest  “Open/adjust করার সময় আগে থেকেই 7 days interest charge করবো.”
uint256 constant INTEREST_RATE_ADJ_COOLDOWN = 7 days;//interest rate খুব frequently change করতে পারবে না।

// Batch parameters
uint256 constant MAX_BATCH_SHARES_RATIO = 1e9;//share inflation/extreme ratio distortion //You’ll understand better later in BatchManagerOperations.

// Redemption parameters
uint256 constant URGENT_REDEMPTION_BONUS = 1 * _1pct; // 1% 1% bonus during urgent redemption  receive $1010 collateral That extra $10 is NOT free. System absorbs it somewhere.

// Liquidation parameters
uint256 constant MAX_LIQUIDATION_PENALTY_REDISTRIBUTION = 20 * _1pct; // 20%//যদি liquidation হয়, protocol maximum 20% extra collateral নিতে পারবে penalty হিসেবে।
