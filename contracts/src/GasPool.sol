// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ITroveManager.sol";

/**
 * 🧠 Global Mental Model (same story again)

Alice collateral = 110 COLL
Alice debt = 100 BOLD

👉 When Alice opens a trove, protocol also takes a small extra fee in WETH (gas compensation).
👉 That WETH is NOT part of collateral/debt.
👉 It is just “reward money for liquidators / refunds”.

So it is stored in a separate contract:GasPool

GasPool = storage for WETH used to pay gas compensation during liquidation or refunds

🌱 Why does this exist?

When Alice does actions:

1. Open trove
Alice pays extra WETH
→ goes into GasPool
2. Close trove
GasPool returns WETH back to Alice
3. Liquidation
liquidator receives WETH reward from GasPool

 * The purpose of this contract is to hold WETH tokens for gas compensation:
 * https://github.com/liquity/bold/?tab=readme-ov-file#liquidation-gas-compensation
 * When a borrower opens a trove, an additional amount of WETH is pulled,
 * and sent to this contract.
 * When a borrower closes their active trove, this gas compensation is refunded
 * When a trove is liquidated, this gas compensation is paid to liquidator
 */
contract GasPool {
    constructor(IAddressesRegistry _addressesRegistry) {//we fetch system contracts (no hardcoding)
        IERC20Metadata gasToken = _addressesRegistry.gasToken();
        IBorrowerOperations borrowerOperations = _addressesRegistry.borrowerOperations();
        ITroveManager troveManager = _addressesRegistry.troveManager();

        // Allow BorrowerOperations to refund gas compensation
        gasToken.approve(address(borrowerOperations), type(uint256).max);//BorrowerOperations can move WETH from GasPool anytime   ,,refund gas compensation when user closes trove
        // Allow TroveManager to pay gas compensation to liquidator
        gasToken.approve(address(troveManager), type(uint256).max);///TroveManager can move WETH from GasPool anytime  pay liquidators during liquidation
    }
}
