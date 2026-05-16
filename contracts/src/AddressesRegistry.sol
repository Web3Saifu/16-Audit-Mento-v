// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "./Dependencies/Ownable.sol";
import "./Interfaces/IAddressesRegistry.sol";

contract AddressesRegistry is Ownable, IAddressesRegistry {  //এই contract = Protocol Address Directory   “কোন feature কোন contract-এ আছে” — সেই mapping এখানে রাখা
    IERC20Metadata public collToken;  “Loan নেওয়ার জন্য user যেটা lock করে”
    IBorrowerOperations public borrowerOperations; ///👉 Loan open/close controller
    ITroveManager public troveManager; //👉 Core accounting brain
    ITroveNFT public troveNFT;  //👉 Loan ownership NFT 
    IMetadataNFT public metadataNFT;  //👉 NFT metadata handler
    IStabilityPool public stabilityPool;  //👉 Liquidation absorption pool
    IPriceFeed public priceFeed;//“Market price truth source”
    IActivePool public activePool;//👉 Active system funds  ,,“Currently active loans money bucket”  active loans-এর collateral + debt track করে
    IDefaultPool public defaultPool;//👉 Defaulted debt storage    liquidated bad debt temporarily hold করে  redistribution system use করে
    address public gasPoolAddress; //internal protocol gas handling
    ICollSurplusPool public collSurplusPool;///👉 Extra collateral storage  liquidation এর পরে leftover collateral  user claim করতে পারে
    ISortedTroves public sortedTroves;//“Leaderboard of loans (safest → riskiest)”  👉 Ordered loan list
    IInterestRouter public interestRouter;//👉 Interest distribution logic
    IHintHelpers public hintHelpers;//👉 Gas optimization helper
    IMultiTroveGetter public multiTroveGetter;//👉 Batch data reader
    ICollateralRegistry public collateralRegistry;//👉 Allowed collateral manager
    IBoldToken public boldToken;//👉 Protocol stable debt token
    IERC20Metadata public gasToken; // 👉 Gas payment token
    address public liquidityStrategy;//👉 Yield / liquidity optimizer  “Money earning strategy module”

    event CollTokenAddressCh“Money earning strategy module”anged(address _collTokenAddress);
    event BorrowerOperationsAddressChanged(address _borrowerOperationsAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);
    event TroveNFTAddressChanged(address _troveNFTAddress);
    event MetadataNFTAddressChanged(address _metadataNFTAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event PriceFeedAddressChanged(address _priceFeedAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event InterestRouterAddressChanged(address _interestRouterAddress);
    event HintHelpersAddressChanged(address _hintHelpersAddress);
    event MultiTroveGetterAddressChanged(address _multiTroveGetterAddress);
    event CollateralRegistryAddressChanged(address _collateralRegistryAddress);
    event BoldTokenAddressChanged(address _boldTokenAddress);
    event GasTokenAddressChanged(address _gasTokenAddress);
    event LiquidityStrategyAddressChanged(address _liquidityStrategyAddress);

    constructor(address _owner) Ownable(_owner) {}

    function setAddresses(AddressVars memory _vars) external onlyOwner {
        collToken = _vars.collToken;
        borrowerOperations = _vars.borrowerOperations;
        troveManager = _vars.troveManager;
        troveNFT = _vars.troveNFT;
        metadataNFT = _vars.metadataNFT;
        stabilityPool = _vars.stabilityPool;
        priceFeed = _vars.priceFeed;
        activePool = _vars.activePool;
        defaultPool = _vars.defaultPool;
        gasPoolAddress = _vars.gasPoolAddress;
        collSurplusPool = _vars.collSurplusPool;
        sortedTroves = _vars.sortedTroves;
        interestRouter = _vars.interestRouter;
        hintHelpers = _vars.hintHelpers;
        multiTroveGetter = _vars.multiTroveGetter;
        collateralRegistry = _vars.collateralRegistry;
        boldToken = _vars.boldToken;
        gasToken = _vars.gasToken;
        liquidityStrategy = _vars.liquidityStrategy;

        emit CollTokenAddressChanged(address(_vars.collToken));
        emit BorrowerOperationsAddressChanged(address(_vars.borrowerOperations));
        emit TroveManagerAddressChanged(address(_vars.troveManager));
        emit TroveNFTAddressChanged(address(_vars.troveNFT));
        emit MetadataNFTAddressChanged(address(_vars.metadataNFT));
        emit StabilityPoolAddressChanged(address(_vars.stabilityPool));
        emit PriceFeedAddressChanged(address(_vars.priceFeed));
        emit ActivePoolAddressChanged(address(_vars.activePool));
        emit DefaultPoolAddressChanged(address(_vars.defaultPool));
        emit GasPoolAddressChanged(_vars.gasPoolAddress);
        emit CollSurplusPoolAddressChanged(address(_vars.collSurplusPool));
        emit SortedTrovesAddressChanged(address(_vars.sortedTroves));
        emit InterestRouterAddressChanged(address(_vars.interestRouter));
        emit HintHelpersAddressChanged(address(_vars.hintHelpers));
        emit MultiTroveGetterAddressChanged(address(_vars.multiTroveGetter));
        emit CollateralRegistryAddressChanged(address(_vars.collateralRegistry));
        emit BoldTokenAddressChanged(address(_vars.boldToken));
        emit GasTokenAddressChanged(address(_vars.gasToken));
        emit LiquidityStrategyAddressChanged(address(_vars.liquidityStrategy));

        _renounceOwnership();
    }
}
