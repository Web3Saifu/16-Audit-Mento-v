// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/ITroveManager.sol";//Imports trove manager interface; example: when user opens a trove, BorrowerOperations calls TroveManager to save trove data.
import "./Interfaces/IBoldToken.sol";//Imports BOLD token interface; example: contract can mint BOLD when user borrows.
import "./Interfaces/ICollSurplusPool.sol";//Imports collateral surplus pool interface; example: after liquidation, extra collateral can later be claimed from this pool.
import "./Interfaces/ISortedTroves.sol";//ISortedTroves → to keep troves sorted
import "./Interfaces/ISystemParams.sol";//Imports system parameter interface; example: contract can read values like MCR or CCR.
import "./Dependencies/LiquityBase.sol";//LiquityBase → to reuse common helper logic
import "./Dependencies/AddRemoveManagers.sol";//Imports manager permission logic; example: owner can allow another address to add/remove collateral.
import "./Types/LatestTroveData.sol";//Imports trove data struct type; example: stores trove info like debt and collateral together.
import "./Types/LatestBatchData.sol";//Imports batch data struct type; example: stores grouped trove batch information.
import "./BatchManagerOperations.sol";//Imports helper contract for batch logic; example: batch interest-rate operations are executed through this helper contract. Alhamdulillah.

contract BorrowerOperations is LiquityBase, AddRemoveManagers, IBorrowerOperations {
    using SafeERC20 for IERC20;

    // --- Connected contract declarations ---

    IERC20 internal immutable collToken;
    ITroveManager internal troveManager;//Stores trove data and manages trove states. Example: after opening a trove, BorrowerOperations tells troveManager to save debt and collateral info.
    address internal gasPoolAddress;//Address holding gas compensation reserve. Example: when opening trove, small gas reserve amount is sent here.
    ICollSurplusPool internal collSurplusPool;//Stores extra collateral users can later claim. Example: after liquidation, leftover collateral may stay here for borrower withdrawal.
    IBoldToken internal boldToken;//The stablecoin token contract. Example: when user borrows, this contract mints BOLD tokens to the user.
    // A doubly linked list of Troves, sorted by their collateral ratios
    ISortedTroves internal sortedTroves;//Keeps troves sorted by interest rate/collateral logic using linked list structure. Example: liquidation system can quickly find risky troves from this sorted list.
    // Wrapped ETH for liquidation reserve (gas compensation)
    IERC20Metadata internal immutable gasToken;//Token used for gas compensation reserve. Example: protocol may use WETH as gas token.
    ISystemParams public immutable systemParams;//Stores important protocol configuration values. Example: minimum collateral ratio (MCR), minimum debt, CCR all come from here.
    // Helper contract for batch management operations
    address public batchManagerOperations;//Helper contract handling batch manager logic. Example: one manager can manage interest rate settings for many troves together.

    bool public hasBeenShutDown;//Emergency shutdown flag. Example: if oracle fails or system becomes unsafe, protocol sets this to true and important actions stop. Alhamdulillah.

    /*
     * Mapping from TroveId to individual delegate for interest rate setting.
     *
     * This address then has the ability to update the borrower’s interest rate, but not change its debt or collateral.
     * Useful for instance for cold/hot wallet setups.
     */
    mapping(uint256 => InterestIndividualDelegate) private interestIndividualDelegateOf;//→ Trove #1 → Helper Wallet = 0xABC  একটা Trove এর জন্য আলাদা একজন “helper” সেট করা যায়, যে শুধু interest rate change করতে পারবে।

    /*
     * Mapping from TroveId to granted address for interest rate setting (batch manager).
     *
     * Batch managers set the interest rate for every Trove in the batch. The interest rate is the same for all Troves in the batch.
     */
    mapping(uint256 => address) public interestBatchManagerOf;//→ কোন Trove কোন Batch Manager এর ভিতরে আছে সেটা রাখে।

    // List of registered Interest Batch Managers
    mapping(address => InterestBatchManager) private interestBatchManagers;//এটা protocol এর সব registered batch manager এর information রাখে।

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

    struct OpenTroveVars {//OpenTroveVars = open trove করার সময় দরকারি জিনিসের bag
        ITroveManager troveManager;//এখান থেকে trove save/update করা হবে।
        uint256 troveId;//Trove ID = 25
        TroveChange change;//→ Trove এ কী change হচ্ছে সেটা রাখে। +100 collateral  +50 debt
        LatestBatchData batch;//→ batch related latest information।  Current batch interest rate = 5%
    }

    struct LocalVariables_openTrove {//এটাও open trove এর সময় temporary variables রাখে।
        ITroveManager troveManager;//→ Trove manager reference।
        IActivePool activePool;//→ যেখানে collateral জমা থাকে।
        IBoldToken boldToken;//borrow করলে এখান থেকে BOLD mint হবে।
        uint256 troveId;//→ current trove ID।
        uint256 price;//ETH = $3000
        uint256 avgInterestRate;//→ average interest rate।Average rate = 5%
        uint256 entireDebt;//→ total debt including fee।
        uint256 ICR;//→ Individual Collateral Ratio।→ Individual Collateral Ratio।
        uint256 newTCR;//→ পুরো protocol এর নতুন collateral ratio। মানে তোমার action এর পরে পুরো system কত safe।
        bool newOracleFailureDetected;//→ oracle fail করেছে কিনা।
    }

    struct LocalVariables_adjustTrove {//এটা _adjustTrove() function এর temporary working memory।  Trove adjust করার সময় দরকারি সব temporary data এখানে রাখা হয়।
        IActivePool activePool;//→ collateral যেখানে রাখা হয় সেই pool।
        IBoldToken boldToken;//borrow করলে এখান থেকে BOLD mint হবে।
        LatestTroveData trove;//→ current trove এর latest information। Current debt = 100   Current collateral = 300
        uint256 price;//→ oracle থেকে current collateral price। ETH price = $3000
        bool isBelowCriticalThreshold;//→ protocol dangerous mode এ গেছে কিনা।  System collateral খুব কমে গেলে = true
        uint256 newICR;// → adjustment এর পরে নতুন ICR।  $300 coll / $100 debt = 300%   Borrow আরো 50 করলে:  $300 / $150 = 200%  এই নতুন ratio হলো newICR।
        uint256 newDebt;//→ adjustment এর পরে total debt। Old debt = 100  Borrow = 20  New debt = 120
        uint256 newColl;//  → adjustment এর পরে total collateral। Old collateral = 5 ETH  Withdraw = 1 ETH   New collateral = 4 ETH
        bool newOracleFailureDetected;// → oracle fail detect হয়েছে কিনা।
    }

    error IsShutDown();//Shutdown mode এ borrowing বন্ধ।
    error TCRNotBelowSCR();//→ System collateral ratio এখনও খুব dangerous level এ যায়নি।
    error ZeroAdjustment();//→ কিছুই change করা হয়নি।
    error NotOwnerNorInterestManager();//→ Caller owner না, interest manager ও না।
    error TroveInBatch();//→ Trove already batch এর ভিতরে আছে।
    error TroveNotInBatch();//→ Trove কোনো batch এ নেই।
    error InterestNotInRange();//→ Interest rate allowed range এর বাইরে।
    error BatchInterestRateChangePeriodNotPassed();//→ Batch manager খুব তাড়াতাড়ি আবার rate change করতে চাচ্ছে।
    error DelegateInterestRateChangePeriodNotPassed();//→ Delegate খুব তাড়াতাড়ি আবার rate change করছে।
    error TroveExists();//→ Trove already exists।
    error TroveNotOpen();//→ Trove open অবস্থায় নেই।
    error TroveNotActive();//→ Trove active না।
    error TroveNotZombie();//→ Trove zombie state এ নেই।
    error TroveWithZeroDebt();//→ Trove এর debt = 0।
    error UpfrontFeeTooHigh();//→ upfront fee user allowed limit এর চেয়ে বেশি।
    error ICRBelowMCR();//→ Individual collateral ratio খুব কম।   Required = 110%   Current = 90%
    error ICRBelowMCRPlusBCR();///→ Batch trove এর collateral ratio safe level এর নিচে।
    error RepaymentNotMatchingCollWithdrawal();//→ যথেষ্ট debt repay না করে collateral withdraw করা হচ্ছে।
    error TCRBelowCCR();///→ পুরো protocol এর collateral ratio unsafe হয়ে যাবে।
    error DebtBelowMin();// → Debt minimum required amount এর নিচে।  Minimum debt = 2000   Current debt = 500
    error CollWithdrawalTooHigh();//  → যত collateral আছে তার চেয়ে বেশি withdraw।
    error NotEnoughBoldBalance();// → User এর কাছে repay করার মতো enough BOLD নেই।
    error InterestRateTooLow();//→ Interest rate খুব কম।
    error InterestRateTooHigh();//→ Interest rate খুব বেশি।
    error InterestRateNotNew();//→ পুরানো rate আবার same rate set করা হয়েছে।
    error InvalidInterestBatchManager();//→ Batch manager valid না।
    error BatchManagerExists();//→ Batch manager already registered।
    error BatchManagerNotNew();//→ পুরানো same batch manager আবার set করা হচ্ছে।
    error NewFeeNotLower();//→ নতুন fee আগের fee থেকে কম না।
    error CallerNotTroveManager();//→ Caller troveManager contract না।
    error CallerNotPriceFeed();//→ → Caller priceFeed contract না।
    error CallerNotSelf();//→ Contract নিজে function call করেনি।
    error MinGeMax();//→→ Min value >= Max value। Min = 10   Max = 5
    error AnnualManagementFeeTooHigh();//→ → Management fee খুব বেশি।
    error MinInterestRateChangePeriodTooLow();// Interest rate change cooldown খুব কম।
    error NewOracleFailureDetected();//
    error BatchSharesRatioTooLow();// → Batch share ratio খুব কম হয়ে গেছে। Alhamdulillah.

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event BoldTokenAddressChanged(address _boldTokenAddress);

    event ShutDown(uint256 _tcr);

    constructor(IAddressesRegistry _addressesRegistry, ISystemParams _systemParams)
        AddRemoveManagers(_addressesRegistry)  //
        LiquityBase(_addressesRegistry)//_applyShutdown/
    {
        // This makes impossible to open a trove with zero withdrawn Bold
        assert(_systemParams.MIN_DEBT() > 0);// Check করছে MIN_DEBT zero না।

        systemParams = _systemParams;//System parameter contract save করছে।

        collToken = _addressesRegistry.collToken();//Collateral token address নিচ্ছে। Example: WETH token।

        gasToken = _addressesRegistry.gasToken();//Gas compensation token নিচ্ছে।

        troveManager = _addressesRegistry.troveManager();//TroveManager contract address নিচ্ছে।
        gasPoolAddress = _addressesRegistry.gasPoolAddress();//
        collSurplusPool = _addressesRegistry.collSurplusPool();//
        sortedTroves = _addressesRegistry.sortedTroves();//
        boldToken = _addressesRegistry.boldToken();//
        // We can leave the deployment script as-is by just having BorrowerOperations deploy its
        // own batchManagerOperations contract
        // /!\ If we have to redeploy a BorrowerOps that could need the same batchManagerOps then we
        // would replace this line with some extra param, but that seems unlikely
        batchManagerOperations = address(new BatchManagerOperations(_addressesRegistry, _systemParams));//BorrowerOperations deploys a new BatchManagerOperations contract and stores its address.    BatchManagerOperations x =    new BatchManagerOperations(...);

        emit TroveManagerAddressChanged(address(troveManager));//
        emit GasPoolAddressChanged(gasPoolAddress);//
        emit CollSurplusPoolAddressChanged(address(collSurplusPool));//
        emit SortedTrovesAddressChanged(address(sortedTroves));//
        emit BoldTokenAddressChanged(address(boldToken));//

        // Allow funds movements between Liquity contracts
        collToken.approve(address(activePool), type(uint256).max);//
    }

    function CCR() external view override returns (uint256) {//যদি CCR = 150% হয়, তাহলে পুরো protocol safe থাকতে total collateral ratio কমপক্ষে 150% থাকতে হবে।
        return systemParams.CCR();
    }

    function MCR() external view override returns (uint256) {//যদি MCR = 110% হয়, তাহলে একটি trove এর collateral ratio 110% এর নিচে গেলে liquidation হতে পারে।
        return systemParams.MCR();
    }

    // --- Borrower Trove Operations ---

    function openTrove(//এটা user এর নতুন Trove create করে।
        address _owner,//Trove এর আসল owner কে হবে।
        uint256 _ownerIndex,// Same owner এর multiple trove uniquely identify করার helper value।
        uint256 _collAmount,//10 ETH
        uint256 _boldAmount,//5000 BOLD
        uint256 _upperHint,//SortedTroves list এ fast position খুঁজতে সাহায্য করে।
        uint256 _lowerHint,//are used for gas optimization in SortedTroves.
        uint256 _annualInterestRate,//5%
        uint256 _maxUpfrontFee,//User maximum কত upfront fee accept করবে।  “fee 50 BOLD এর বেশি হলে transaction cancel।”
        address _addManager,//এই address collateral add করতে বা debt repay করতে পারবে।
        address _removeManager,// এটা বেশি powerful permission। এই address collateral withdraw করতে বা new debt নিতে পারবে।
        address _receiver// তোমার another wallet address। মানে removeManager collateral withdraw করলে token এই receiver address এ যাবে। 
    ) external override returns (uint256) {// returned trove ID = 8451 Example: user frontend থেকে trove open করছে। returns (uint256) → শেষে trove ID return করবে।
        _requireValidAnnualInterestRate(_annualInterestRate);//5% allowed range এর মধ্যে আছে কিনা।

        OpenTroveVars memory vars;//Temporary variables রাখার জন্য memory struct তৈরি করছে।

        vars.troveId = _openTrove(//
            _owner,//
            _ownerIndex,//
            _collAmount,//
            _boldAmount,//
            _annualInterestRate,//
            address(0),//
            0,//Batch related debt/fee values।
            0,//কারণ batch use হচ্ছে না, তাই 0 দেওয়া হয়েছে।
            _maxUpfrontFee,//User maximum কত upfront fee accept করবে।
            _addManager,//এই address তোমার trove এ collateral add করতে বা debt repay করতে পারবে।
            _removeManager,//এই address collateral withdraw করতে বা নতুন debt নিতে পারবে।  এটা powerful permission।
            _receiver,//Withdraw করা collateral বা borrowed BOLD কোথায় যাবে।
            vars.change//  trove এ কী কী change হচ্ছে সেগুলো এখানে temporarily save হয়।
        );

        // Set the stored Trove properties and mint the NFT
        troveManager.onOpenTrove(_owner, vars.troveId, vars.change, _annualInterestRate);//  এখন TroveManager permanently trove data save করছে।

        sortedTroves.insert(vars.troveId, _annualInterestRate, _upperHint, _lowerHint);//যখন নতুন trove insert/reinsert হয়, protocol-কে sorted list-এ correct position খুঁজতে হয় (interest rate বা collateral ratio অনুযায়ী)।

        return vars.troveId;//শেষে unique trove ID return করছে।
    }

    function openTroveAndJoinInterestBatchManager(OpenTroveAndJoinInterestBatchManagerParams calldata _params)//এই function নতুন trove open করে এবং একই সাথে একটা Interest Batch Manager এর batch এ join করায়।
        external
        override
        returns (uint256)
    {
        _requireValidInterestBatchManager(_params.interestBatchManager);//registered manager কিনা।

        OpenTroveVars memory vars;//OpenTroveVars type-এর একটি temporary variable vars create করা।
        vfars.troveManager = troveManager;//contract-এর storage variable troveManager কে vars.troveManager এ copy করো।

        vars.batch = vars.troveManager.getLatestBatchData(_params.interestBatchManager);//"এই batch manager (0xABC) এর latest batch data দাও"
        // We set old weighted values here, as it’s only necessary for batches, so we don’t need to pass them to _openTrove func
        vars.change.batchAccruedManagementFee = vars.batch.accruedManagementFee;//Batch এ আগে থেকে যত management fee accumulated হয়েছে সেটা save করছে। ধরো batch already 200 BOLD management fee earn করেছে।
        vars.change.oldWeightedRecordedDebt = vars.batch.weightedRecordedDebt;// batch এ আগে কত debt ছিল এবং কোন interest rate এ ছিল সেটা tracking করার value।   এখন নতুন trove add হওয়ার আগে old value save করছে।
        vars.change.oldWeightedRecordedBatchManagementFee = vars.batch.weightedRecordedBatchManagementFee;//Batch এর পুরানো weighted management fee value save করছে।   management fee calculation এর previous state।
        vars.troveId = _openTrove(//এখন actual trove create হচ্ছে।
            _params.owner,//তোমার wallet।
            _params.ownerIndex,//Unique trove ID generate করার helper value।  vতোমার দ্বিতীয় trove হলে index = 1
            _params.collAmount,/// 10 ETH
            _params.boldAmount,//5000 BOLD 
            vars.batch.annualInterestRate,//Batch এর shared interest rate।batch interest = 5%   batch interest = 5%   এই trove এর own custom interest rate নেই।
            _params.interestBatchManager,//কোন batch manager এর batch এ join করবে।
            vars.batch.entireDebtWithoutRedistribution,//  Batch এর current total debt।  নতুন trove add হওয়ার আগে batch এ already কত debt আছে।
            vars.batch.annualManagementFee,//Batch manager yearly management fee। 1%
            _params.maxUpfrontFee,//“ Maximum upfront fee user accept করবে। 100 BOLD এর বেশি fee হলে revert।”
            _params.addManager,//Collateral add / repay করার permission address।
            _params.removeManager,//Withdraw / borrow করার permission address।
            _params.receiver,//Withdraw করা token কোথায় যাবে।
            vars.change//সব trove change data store করার struct।
        ); 

        interestBatchManagerOf[vars.troveId] = _params.interestBatchManager;//এখানে protocol save করে রাখে যে এই trove কোন batch manager-এর under এ আছে।  তোমার troveId = 15     আর batch manager = 0xABC    trove 15 -> manager 0xABC

        // Set the stored Trove properties and mint the NFT
        vars.troveManager.onOpenTroveAndJoinBatch(//এটা TroveManager-কে inform করে যে:
            _params.owner,//= trove owner address। Example: তোমার wallet।
            vars.troveId,// = নতুন trove এর ID।  Example: 15
            vars.change,//= trove open করার সময় collateral/debt/fee related changed data।  collateral added = 100 USDC    debt added = 50 BOLD
            _params.interestBatchManager,//= কোন batch manager-এর batch এ join করছে। Example: 0xABC
            vars.batch.entireCollWithoutRedistribution,//
            vars.batch.entireDebtWithoutRedistribution//
        );

        sortedTroves.insertIntoBatch(//
            vars.troveId,//
            BatchId.wrap(_params.interestBatchManager),//
            vars.batch.annualInterestRate,//
            _params.upperHint,//
            _params.lowerHint//
        );//

        return vars.troveId;//
    }

    function _openTrove(//
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _boldAmount,
        uint256 _annualInterestRate,
        address _interestBatchManager,
        uint256 _batchEntireDebt,
        uint256 _batchManagementAnnualFee,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver,
        TroveChange memory _change
    ) internal returns (uint256) {
        _requireIsNotShutDown();

        LocalVariables_openTrove memory vars;

        // stack too deep not allowing to reuse troveManager from outer functions
        vars.troveManager = troveManager;//contract-এর storage variable troveManager কে vars.troveManager এ copy করো।
        vars.activePool = activePool;
        vars.boldToken = boldToken;

        vars.price = priceFeed.fetchPrice();//Oracle/price feed থেকে latest collateral price আনো।  

        // --- Checks ---

        vars.troveId = uint256(keccak256(abi.encode(msg.sender, _owner, _ownerIndex)));
        _requireTroveDoesNotExist(vars.troveManager, vars.troveId);

        _change.collIncrease = _collAmount;
        _change.debtIncrease = _boldAmount;

        // For simplicity, we ignore the fee when calculating the approx. interest rate
        _change.newWeightedRecordedDebt = (_batchEntireDebt + _change.debtIncrease) * _annualInterestRate;

        vars.avgInterestRate = vars.activePool.getNewApproxAvgInterestRateFromTroveChange(_change);
        _change.upfrontFee = _calcUpfrontFee(_change.debtIncrease, vars.avgInterestRate);
        _requireUserAcceptsUpfrontFee(_change.upfrontFee, _maxUpfrontFee);

        vars.entireDebt = _change.debtIncrease + _change.upfrontFee;
        _requireAtLeastMinDebt(vars.entireDebt);

        vars.ICR = LiquityMath._computeCR(_collAmount, vars.entireDebt, vars.price);

        // Recalculate newWeightedRecordedDebt, now taking into account the upfront fee, and the batch fee if needed
        if (_interestBatchManager == address(0)) {
            _change.newWeightedRecordedDebt = vars.entireDebt * _annualInterestRate;

            // ICR is based on the requested Bold amount + upfront fee.
            _requireICRisAboveMCR(vars.ICR);
        } else {
            // old values have been set outside, before calling this function
            _change.newWeightedRecordedDebt = (_batchEntireDebt + vars.entireDebt) * _annualInterestRate;
            _change.newWeightedRecordedBatchManagementFee =
                (_batchEntireDebt + vars.entireDebt) * _batchManagementAnnualFee;

            // ICR is based on the requested Bold amount + upfront fee.
            // Troves in a batch have a stronger requirement (MCR+BCR)
            _requireICRisAboveMCRPlusBCR(vars.ICR);
        }

        vars.newTCR = _getNewTCRFromTroveChange(_change, vars.price);
        _requireNewTCRisAboveCCR(vars.newTCR);

        // --- Effects & interactions ---

        // Set add/remove managers
        _setAddManager(vars.troveId, _addManager);
        _setRemoveManagerAndReceiver(vars.troveId, _removeManager, _receiver);

        vars.activePool.mintAggInterestAndAccountForTroveChange(_change, _interestBatchManager);

        // Pull coll tokens from sender and move them to the Active Pool
        _pullCollAndSendToActivePool(vars.activePool, _collAmount);

        // Mint the requested _boldAmount to the borrower and mint the gas comp to the GasPool
        vars.boldToken.mint(msg.sender, _boldAmount);
        gasToken.transferFrom(msg.sender, gasPoolAddress, systemParams.ETH_GAS_COMPENSATION());

        return vars.troveId;
    }

    // Send collateral to a trove
    function addColl(uint256 _troveId, uint256 _collAmount) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.collIncrease = _collAmount;

        _adjustTrove(
            troveManagerCached,
            _troveId,
            troveChange,
            0 // _maxUpfrontFee
        );
    }

    // Withdraw collateral from a trove
    function withdrawColl(uint256 _troveId, uint256 _collWithdrawal) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.collDecrease = _collWithdrawal;

        _adjustTrove(
            troveManagerCached,
            _troveId,
            troveChange,
            0 // _maxUpfrontFee
        );
    }

    // Withdraw Bold tokens from a trove: mint new Bold tokens to the owner, and increase the trove's debt accordingly
    function withdrawBold(uint256 _troveId, uint256 _boldAmount, uint256 _maxUpfrontFee) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.debtIncrease = _boldAmount;
        _adjustTrove(troveManagerCached, _troveId, troveChange, _maxUpfrontFee);
    }

    // Repay Bold tokens to a Trove: Burn the repaid Bold tokens, and reduce the trove's debt accordingly
    function repayBold(uint256 _troveId, uint256 _boldAmount) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        troveChange.debtDecrease = _boldAmount;

        _adjustTrove(
            troveManagerCached,
            _troveId,
            troveChange,
            0 // _maxUpfrontFee
        );
    }

    function _initTroveChange(
        TroveChange memory _troveChange,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease
    ) internal pure {
        if (_isCollIncrease) {
            _troveChange.collIncrease = _collChange;
        } else {
            _troveChange.collDecrease = _collChange;
        }

        if (_isDebtIncrease) {
            _troveChange.debtIncrease = _boldChange;
        } else {
            _troveChange.debtDecrease = _boldChange;
        }
    }

    function adjustTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease,
        uint256 _maxUpfrontFee
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsActive(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        _initTroveChange(troveChange, _collChange, _isCollIncrease, _boldChange, _isDebtIncrease);
        _adjustTrove(troveManagerCached, _troveId, troveChange, _maxUpfrontFee);
    }

    function adjustZombieTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external override {
        ITroveManager troveManagerCached = troveManager;
        _requireTroveIsZombie(troveManagerCached, _troveId);

        TroveChange memory troveChange;
        _initTroveChange(troveChange, _collChange, _isCollIncrease, _boldChange, _isDebtIncrease);
        _adjustTrove(troveManagerCached, _troveId, troveChange, _maxUpfrontFee);

        troveManagerCached.setTroveStatusToActive(_troveId);

        address batchManager = interestBatchManagerOf[_troveId];
        uint256 batchAnnualInterestRate;
        if (batchManager != address(0)) {
            LatestBatchData memory batch = troveManagerCached.getLatestBatchData(batchManager);
            batchAnnualInterestRate = batch.annualInterestRate;
        }
        _reInsertIntoSortedTroves(
            _troveId,
            troveManagerCached.getTroveAnnualInterestRate(_troveId),
            _upperHint,
            _lowerHint,
            batchManager,
            batchAnnualInterestRate
        );
    }

    function adjustTroveInterestRate(
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external {
        _requireIsNotShutDown();

        ITroveManager troveManagerCached = troveManager;

        _requireValidAnnualInterestRate(_newAnnualInterestRate);
        _requireIsNotInBatch(_troveId);
        _requireSenderIsOwnerOrInterestManager(_troveId);
        _requireTroveIsActive(troveManagerCached, _troveId);

        LatestTroveData memory trove = troveManagerCached.getLatestTroveData(_troveId);
        _requireValidDelegateAdjustment(_troveId, trove.lastInterestRateAdjTime, _newAnnualInterestRate);
        _requireAnnualInterestRateIsNew(trove.annualInterestRate, _newAnnualInterestRate);

        uint256 newDebt = trove.entireDebt;

        TroveChange memory troveChange;
        troveChange.appliedRedistBoldDebtGain = trove.redistBoldDebtGain;
        troveChange.appliedRedistCollGain = trove.redistCollGain;
        troveChange.newWeightedRecordedDebt = newDebt * _newAnnualInterestRate;
        troveChange.oldWeightedRecordedDebt = trove.weightedRecordedDebt;

        // Apply upfront fee on premature adjustments. It checks the resulting ICR
        if (block.timestamp < trove.lastInterestRateAdjTime + INTEREST_RATE_ADJ_COOLDOWN) {
            newDebt = _applyUpfrontFee(trove.entireColl, newDebt, troveChange, _maxUpfrontFee, false);
        }

        // Recalculate newWeightedRecordedDebt, now taking into account the upfront fee
        troveChange.newWeightedRecordedDebt = newDebt * _newAnnualInterestRate;

        activePool.mintAggInterestAndAccountForTroveChange(troveChange, address(0));

        sortedTroves.reInsert(_troveId, _newAnnualInterestRate, _upperHint, _lowerHint);
        troveManagerCached.onAdjustTroveInterestRate(
            _troveId, trove.entireColl, newDebt, _newAnnualInterestRate, troveChange
        );
    }

    /*
     * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal.
     */
    function _adjustTrove(
        ITroveManager _troveManager,
        uint256 _troveId,
        TroveChange memory _troveChange,
        uint256 _maxUpfrontFee
    ) internal {
        _requireIsNotShutDown();

        LocalVariables_adjustTrove memory vars;
        vars.activePool = activePool;
        vars.boldToken = boldToken;

        vars.price = priceFeed.fetchPrice();
        vars.isBelowCriticalThreshold = _checkBelowCriticalThreshold(vars.price, systemParams.CCR());

        // --- Checks ---

        _requireTroveIsOpen(_troveManager, _troveId);

        address owner = troveNFT.ownerOf(_troveId);
        address receiver = owner; // If it’s a withdrawal, and remove manager privilege is set, a different receiver can be defined

        if (_troveChange.collDecrease > 0 || _troveChange.debtIncrease > 0) {
            receiver = _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_troveId, owner);
        } else {
            // RemoveManager assumes AddManager, so if the former is set, there's no need to check the latter
            _requireSenderIsOwnerOrAddManager(_troveId, owner);
            // No need to check the type of trove change for two reasons:
            // - If the check above fails, it means sender is not owner, nor AddManager, nor RemoveManager.
            //   An independent 3rd party should not be allowed here.
            // - If it's not collIncrease or debtDecrease, _requireNonZeroAdjustment would revert
        }

        vars.trove = _troveManager.getLatestTroveData(_troveId);

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough Bold
        if (_troveChange.debtDecrease > 0) {
            uint256 maxRepayment =
                vars.trove.entireDebt > systemParams.MIN_DEBT() ? vars.trove.entireDebt - systemParams.MIN_DEBT() : 0;
            if (_troveChange.debtDecrease > maxRepayment) {
                _troveChange.debtDecrease = maxRepayment;
            }
            _requireSufficientBoldBalance(vars.boldToken, msg.sender, _troveChange.debtDecrease);
        }

        _requireNonZeroAdjustment(_troveChange);

        // When the adjustment is a collateral withdrawal, check that it's no more than the Trove's entire collateral
        if (_troveChange.collDecrease > 0) {
            _requireValidCollWithdrawal(vars.trove.entireColl, _troveChange.collDecrease);
        }

        vars.newColl = vars.trove.entireColl + _troveChange.collIncrease - _troveChange.collDecrease;
        vars.newDebt = vars.trove.entireDebt + _troveChange.debtIncrease - _troveChange.debtDecrease;

        address batchManager = interestBatchManagerOf[_troveId];
        bool isTroveInBatch = batchManager != address(0);
        LatestBatchData memory batch;
        uint256 batchFutureDebt;
        if (isTroveInBatch) {
            batch = _troveManager.getLatestBatchData(batchManager);

            batchFutureDebt = batch.entireDebtWithoutRedistribution + vars.trove.redistBoldDebtGain
                + _troveChange.debtIncrease - _troveChange.debtDecrease;

            _troveChange.appliedRedistBoldDebtGain = vars.trove.redistBoldDebtGain;
            _troveChange.appliedRedistCollGain = vars.trove.redistCollGain;
            _troveChange.batchAccruedManagementFee = batch.accruedManagementFee;
            _troveChange.oldWeightedRecordedDebt = batch.weightedRecordedDebt;
            _troveChange.newWeightedRecordedDebt = batchFutureDebt * batch.annualInterestRate;
            _troveChange.oldWeightedRecordedBatchManagementFee = batch.weightedRecordedBatchManagementFee;
            _troveChange.newWeightedRecordedBatchManagementFee = batchFutureDebt * batch.annualManagementFee;
        } else {
            _troveChange.appliedRedistBoldDebtGain = vars.trove.redistBoldDebtGain;
            _troveChange.appliedRedistCollGain = vars.trove.redistCollGain;
            _troveChange.oldWeightedRecordedDebt = vars.trove.weightedRecordedDebt;
            _troveChange.newWeightedRecordedDebt = vars.newDebt * vars.trove.annualInterestRate;
        }

        // Pay an upfront fee on debt increases
        if (_troveChange.debtIncrease > 0) {
            uint256 avgInterestRate = vars.activePool.getNewApproxAvgInterestRateFromTroveChange(_troveChange);
            _troveChange.upfrontFee = _calcUpfrontFee(_troveChange.debtIncrease, avgInterestRate);
            _requireUserAcceptsUpfrontFee(_troveChange.upfrontFee, _maxUpfrontFee);

            vars.newDebt += _troveChange.upfrontFee;
            if (isTroveInBatch) {
                batchFutureDebt += _troveChange.upfrontFee;
                // Recalculate newWeightedRecordedDebt, now taking into account the upfront fee
                _troveChange.newWeightedRecordedDebt = batchFutureDebt * batch.annualInterestRate;
                _troveChange.newWeightedRecordedBatchManagementFee = batchFutureDebt * batch.annualManagementFee;
            } else {
                // Recalculate newWeightedRecordedDebt, now taking into account the upfront fee
                _troveChange.newWeightedRecordedDebt = vars.newDebt * vars.trove.annualInterestRate;
            }
        }

        // Make sure the Trove doesn't end up zombie
        // Now the max repayment is capped to stay above MIN_DEBT, so this only applies to adjustZombieTrove
        _requireAtLeastMinDebt(vars.newDebt);

        vars.newICR = LiquityMath._computeCR(vars.newColl, vars.newDebt, vars.price);

        // Check the adjustment satisfies all conditions for the current system mode
        _requireValidAdjustmentInCurrentMode(_troveChange, vars, isTroveInBatch);

        // --- Effects and interactions ---

        if (isTroveInBatch) {
            _troveManager.onAdjustTroveInsideBatch(
                _troveId,
                vars.newColl,
                vars.newDebt,
                _troveChange,
                batchManager,
                batch.entireCollWithoutRedistribution,
                batch.entireDebtWithoutRedistribution
            );
        } else {
            _troveManager.onAdjustTrove(_troveId, vars.newColl, vars.newDebt, _troveChange);
        }

        vars.activePool.mintAggInterestAndAccountForTroveChange(_troveChange, batchManager);
        _moveTokensFromAdjustment(receiver, _troveChange, vars.boldToken, vars.activePool);
    }

    function closeTrove(uint256 _troveId) external override {
        ITroveManager troveManagerCached = troveManager;
        IActivePool activePoolCached = activePool;
        IBoldToken boldTokenCached = boldToken;

        // --- Checks ---

        address owner = troveNFT.ownerOf(_troveId);
        address receiver = _requireSenderIsOwnerOrRemoveManagerAndGetReceiver(_troveId, owner);
        _requireTroveIsOpen(troveManagerCached, _troveId);

        LatestTroveData memory trove = troveManagerCached.getLatestTroveData(_troveId);

        // The borrower must repay their entire debt including accrued interest, batch fee and redist. gains
        _requireSufficientBoldBalance(boldTokenCached, msg.sender, trove.entireDebt);

        TroveChange memory troveChange;
        troveChange.appliedRedistBoldDebtGain = trove.redistBoldDebtGain;
        troveChange.appliedRedistCollGain = trove.redistCollGain;
        troveChange.collDecrease = trove.entireColl;
        troveChange.debtDecrease = trove.entireDebt;

        address batchManager = interestBatchManagerOf[_troveId];
        LatestBatchData memory batch;
        if (batchManager != address(0)) {
            batch = troveManagerCached.getLatestBatchData(batchManager);
            uint256 batchFutureDebt =
                batch.entireDebtWithoutRedistribution - (trove.entireDebt - trove.redistBoldDebtGain);
            troveChange.batchAccruedManagementFee = batch.accruedManagementFee;
            troveChange.oldWeightedRecordedDebt = batch.weightedRecordedDebt;
            troveChange.newWeightedRecordedDebt = batchFutureDebt * batch.annualInterestRate;
            troveChange.oldWeightedRecordedBatchManagementFee = batch.weightedRecordedBatchManagementFee;
            troveChange.newWeightedRecordedBatchManagementFee = batchFutureDebt * batch.annualManagementFee;
        } else {
            troveChange.oldWeightedRecordedDebt = trove.weightedRecordedDebt;
            // troveChange.newWeightedRecordedDebt = 0;
        }

        uint256 price = priceFeed.fetchPrice();
        uint256 newTCR = _getNewTCRFromTroveChange(troveChange, price);
        if (!hasBeenShutDown) _requireNewTCRisAboveCCR(newTCR);

        troveManagerCached.onCloseTrove(
            _troveId,
            troveChange,
            batchManager,
            batch.entireCollWithoutRedistribution,
            batch.entireDebtWithoutRedistribution
        );

        // If trove is in batch
        if (batchManager != address(0)) {
            // Unlink here in BorrowerOperations
            interestBatchManagerOf[_troveId] = address(0);
        }

        activePoolCached.mintAggInterestAndAccountForTroveChange(troveChange, batchManager);

        // Return ETH gas compensation
        gasToken.transferFrom(gasPoolAddress, receiver, systemParams.ETH_GAS_COMPENSATION());
        // Burn the remainder of the Trove's entire debt from the user
        boldTokenCached.burn(msg.sender, trove.entireDebt);

        // Send the collateral back to the user
        activePoolCached.sendColl(receiver, trove.entireColl);

        _wipeTroveMappings(_troveId);
    }

    function applyPendingDebt(uint256 _troveId, uint256 _lowerHint, uint256 _upperHint) public {
        _requireIsNotShutDown();

        ITroveManager troveManagerCached = troveManager;

        _requireTroveIsOpen(troveManagerCached, _troveId);

        LatestTroveData memory trove = troveManagerCached.getLatestTroveData(_troveId);
        _requireNonZeroDebt(trove.entireDebt);

        TroveChange memory change;
        change.appliedRedistBoldDebtGain = trove.redistBoldDebtGain;
        change.appliedRedistCollGain = trove.redistCollGain;

        address batchManager = interestBatchManagerOf[_troveId];
        LatestBatchData memory batch;

        if (batchManager == address(0)) {
            change.oldWeightedRecordedDebt = trove.weightedRecordedDebt;
            change.newWeightedRecordedDebt = trove.entireDebt * trove.annualInterestRate;
        } else {
            batch = troveManagerCached.getLatestBatchData(batchManager);
            change.batchAccruedManagementFee = batch.accruedManagementFee;
            change.oldWeightedRecordedDebt = batch.weightedRecordedDebt;
            change.newWeightedRecordedDebt =
                (batch.entireDebtWithoutRedistribution + trove.redistBoldDebtGain) * batch.annualInterestRate;
            change.oldWeightedRecordedBatchManagementFee = batch.weightedRecordedBatchManagementFee;
            change.newWeightedRecordedBatchManagementFee =
                (batch.entireDebtWithoutRedistribution + trove.redistBoldDebtGain) * batch.annualManagementFee;
        }

        troveManagerCached.onApplyTroveInterest(
            _troveId,
            trove.entireColl,
            trove.entireDebt,
            batchManager,
            batch.entireCollWithoutRedistribution,
            batch.entireDebtWithoutRedistribution,
            change
        );
        activePool.mintAggInterestAndAccountForTroveChange(change, batchManager);

        // If the trove was zombie, and now it's not anymore, put it back in the list
        if (_checkTroveIsZombie(troveManagerCached, _troveId) && trove.entireDebt >= systemParams.MIN_DEBT()) {
            troveManagerCached.setTroveStatusToActive(_troveId);
            _reInsertIntoSortedTroves(
                _troveId, trove.annualInterestRate, _upperHint, _lowerHint, batchManager, batch.annualInterestRate
            );
        }
    }

    function getInterestIndividualDelegateOf(uint256 _troveId)
        external
        view
        returns (InterestIndividualDelegate memory)
    {
        return interestIndividualDelegateOf[_troveId];
    }

    function setInterestIndividualDelegate(
        uint256 _troveId,
        address _delegate,
        uint128 _minInterestRate,
        uint128 _maxInterestRate,
        // only needed if trove was previously in a batch:
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee,
        uint256 _minInterestRateChangePeriod
    ) external {
        _requireIsNotShutDown();
        _requireTroveIsActive(troveManager, _troveId);
        _requireCallerIsBorrower(_troveId);
        _requireValidAnnualInterestRate(_minInterestRate);
        _requireValidAnnualInterestRate(_maxInterestRate);
        // With the check below, it could only be ==
        _requireOrderedRange(_minInterestRate, _maxInterestRate);

        interestIndividualDelegateOf[_troveId] =
            InterestIndividualDelegate(_delegate, _minInterestRate, _maxInterestRate, _minInterestRateChangePeriod);
        // Can’t have both individual delegation and batch manager
        if (interestBatchManagerOf[_troveId] != address(0)) {
            // Not needed, implicitly checked in removeFromBatch
            //_requireValidAnnualInterestRate(_newAnnualInterestRate);
            removeFromBatch(_troveId, _newAnnualInterestRate, _upperHint, _lowerHint, _maxUpfrontFee);
        }
    }

    function removeInterestIndividualDelegate(uint256 _troveId) external {
        _requireCallerIsBorrower(_troveId);
        delete interestIndividualDelegateOf[_troveId];
    }

    function getInterestBatchManager(address _account) external view returns (InterestBatchManager memory) {
        return interestBatchManagers[_account];
    }

    function registerBatchManager(
        uint128 _minInterestRate,
        uint128 _maxInterestRate,
        uint128 _currentInterestRate,
        uint128 _annualManagementFee,
        uint128 _minInterestRateChangePeriod
    ) external {
        _requireIsNotShutDown();
        _requireNonExistentInterestBatchManager(msg.sender);
        (bool success, bytes memory data) = batchManagerOperations.delegatecall(
            abi.encodeWithSignature(
                "registerBatchManager(uint128,uint128,uint128,uint128,uint128)",
                _minInterestRate,
                _maxInterestRate,
                _currentInterestRate,
                _annualManagementFee,
                _minInterestRateChangePeriod
            )
        );
        _requireDelegateCallSucceeded(success, data);
        interestBatchManagers[msg.sender] =
            InterestBatchManager(_minInterestRate, _maxInterestRate, _minInterestRateChangePeriod);
        troveManager.onRegisterBatchManager(msg.sender, _currentInterestRate, _annualManagementFee);
    }

    function lowerBatchManagementFee(uint256 _newAnnualManagementFee) external {
        _requireIsNotShutDown();
        _requireValidInterestBatchManager(msg.sender);
        (bool success, bytes memory data) = batchManagerOperations.delegatecall(
            abi.encodeWithSignature("lowerBatchManagementFee(uint256)", _newAnnualManagementFee)
        );
        _requireDelegateCallSucceeded(success, data);
    }

    function setBatchManagerAnnualInterestRate(
        uint128 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external {
        _requireIsNotShutDown();
        _requireValidInterestBatchManager(msg.sender);
        _requireInterestRateInBatchManagerRange(msg.sender, _newAnnualInterestRate);
        InterestBatchManager memory interestBatchManager = interestBatchManagers[msg.sender];
        (bool success, bytes memory data) = batchManagerOperations.delegatecall(
            abi.encodeWithSignature(
                "setBatchManagerAnnualInterestRate(uint128,uint256,uint256,uint256,uint256)",
                _newAnnualInterestRate,
                _upperHint,
                _lowerHint,
                _maxUpfrontFee,
                interestBatchManager.minInterestRateChangePeriod
            )
        );
        _requireDelegateCallSucceeded(success, data);
    }

    function setInterestBatchManager(
        uint256 _troveId,
        address _newBatchManager,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) public override {
        _requireIsNotShutDown();
        _requireTroveIsActive(troveManager, _troveId);
        _requireCallerIsBorrower(_troveId);
        _requireValidInterestBatchManager(_newBatchManager);
        _requireIsNotInBatch(_troveId);
        interestBatchManagerOf[_troveId] = _newBatchManager;
        // Can't have both individual delegation and batch manager
        if (interestIndividualDelegateOf[_troveId].account != address(0)) {
            delete interestIndividualDelegateOf[_troveId];
        }

        (bool success, bytes memory data) = batchManagerOperations.delegatecall(
            abi.encodeWithSignature(
                "setInterestBatchManager(uint256,address,uint256,uint256,uint256)",
                _troveId,
                _newBatchManager,
                _upperHint,
                _lowerHint,
                _maxUpfrontFee
            )
        );
        _requireDelegateCallSucceeded(success, data);
    }

    function kickFromBatch(uint256 _troveId, uint256 _upperHint, uint256 _lowerHint) external override {
        _requireIsNotShutDown();
        (bool success, bytes memory data) = batchManagerOperations.delegatecall(
            abi.encodeWithSignature("kickFromBatch(uint256,uint256,uint256)", _troveId, _upperHint, _lowerHint)
        );
        _requireDelegateCallSucceeded(success, data);
        delete interestBatchManagerOf[_troveId];
    }

    function removeFromBatch(
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) public override {
        _requireIsNotShutDown();
        (bool success, bytes memory data) = batchManagerOperations.delegatecall(
            abi.encodeWithSignature(
                "removeFromBatch(uint256,uint256,uint256,uint256,uint256)",
                _troveId,
                _newAnnualInterestRate,
                _upperHint,
                _lowerHint,
                _maxUpfrontFee
            )
        );
        _requireDelegateCallSucceeded(success, data);
        delete interestBatchManagerOf[_troveId];
    }

    function switchBatchManager(
        uint256 _troveId,
        uint256 _removeUpperHint,
        uint256 _removeLowerHint,
        address _newBatchManager,
        uint256 _addUpperHint,
        uint256 _addLowerHint,
        uint256 _maxUpfrontFee
    ) external override {
        address oldBatchManager = _requireIsInBatch(_troveId);
        _requireNewInterestBatchManager(oldBatchManager, _newBatchManager);

        LatestBatchData memory oldBatch = troveManager.getLatestBatchData(oldBatchManager);

        removeFromBatch(_troveId, oldBatch.annualInterestRate, _removeUpperHint, _removeLowerHint, 0);
        setInterestBatchManager(_troveId, _newBatchManager, _addUpperHint, _addLowerHint, _maxUpfrontFee);
    }

    function _applyUpfrontFee(
        uint256 _troveEntireColl,
        uint256 _troveEntireDebt,
        TroveChange memory _troveChange,
        uint256 _maxUpfrontFee,
        bool _isTroveInBatch
    ) internal returns (uint256) {
        uint256 price = priceFeed.fetchPrice();

        uint256 avgInterestRate = activePool.getNewApproxAvgInterestRateFromTroveChange(_troveChange);
        _troveChange.upfrontFee = _calcUpfrontFee(_troveEntireDebt, avgInterestRate);
        _requireUserAcceptsUpfrontFee(_troveChange.upfrontFee, _maxUpfrontFee);

        _troveEntireDebt += _troveChange.upfrontFee;

        // ICR is based on the requested Bold amount + upfront fee.
        uint256 newICR = LiquityMath._computeCR(_troveEntireColl, _troveEntireDebt, price);
        if (_isTroveInBatch) {
            _requireICRisAboveMCRPlusBCR(newICR);
        } else {
            _requireICRisAboveMCR(newICR);
        }

        // Disallow a premature adjustment if it would result in TCR < CCR
        // (which includes the case when TCR is already below CCR before the adjustment).
        uint256 newTCR = _getNewTCRFromTroveChange(_troveChange, price);
        _requireNewTCRisAboveCCR(newTCR);

        return _troveEntireDebt;
    }

    function _calcUpfrontFee(uint256 _debt, uint256 _avgInterestRate) internal pure returns (uint256) {
        return _calcInterest(_debt * _avgInterestRate, UPFRONT_INTEREST_PERIOD);
    }

    // Call from TM to clean state here
    function onLiquidateTrove(uint256 _troveId) external {
        _requireCallerIsTroveManager();

        _wipeTroveMappings(_troveId);
    }

    function _wipeTroveMappings(uint256 _troveId) internal {
        delete interestIndividualDelegateOf[_troveId];
        delete interestBatchManagerOf[_troveId];
        _wipeAddRemoveManagers(_troveId);
    }

    /**
     * Claim remaining collateral from a liquidation with ICR exceeding the liquidation penalty
     */
    function claimCollateral() external override {
        // send coll from CollSurplus Pool to owner
        collSurplusPool.claimColl(msg.sender);
    }

    function shutdown() external {
        if (hasBeenShutDown) revert IsShutDown();

        uint256 totalColl = getEntireBranchColl();
        uint256 totalDebt = getEntireBranchDebt();
        uint256 price = priceFeed.fetchPrice();

        // Otherwise, proceed with the TCR check:
        uint256 TCR = LiquityMath._computeCR(totalColl, totalDebt, price);
        if (TCR >= systemParams.SCR()) revert TCRNotBelowSCR();

        _applyShutdown();

        emit ShutDown(TCR);
    }

    // Not technically a "Borrower op", but seems best placed here given current shutdown logic.
    function shutdownFromOracleFailure() external {
        _requireCallerIsPriceFeed();

        // No-op rather than revert here, so that the outer function call which fetches the price does not revert
        // if the system is already shut down.
        if (hasBeenShutDown) return;

        _applyShutdown();
    }

    function _applyShutdown() internal {
        activePool.mintAggInterest();
        hasBeenShutDown = true;
        troveManager.shutdown();
    }

    // --- Helper functions ---

    function _reInsertIntoSortedTroves(
        uint256 _troveId,
        uint256 _troveAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        address _batchManager,
        uint256 _batchAnnualInterestRate
    ) internal {
        // If it was in a batch, we need to put it back, otherwise we insert it normally
        if (_batchManager == address(0)) {
            sortedTroves.insert(_troveId, _troveAnnualInterestRate, _upperHint, _lowerHint);
        } else {
            sortedTroves.insertIntoBatch(
                _troveId, BatchId.wrap(_batchManager), _batchAnnualInterestRate, _upperHint, _lowerHint
            );
        }
    }

    // This function mints the BOLD corresponding to the borrower's chosen debt increase
    // (it does not mint the accrued interest).
    function _moveTokensFromAdjustment(
        address withdrawalReceiver,
        TroveChange memory _troveChange,
        IBoldToken _boldToken,
        IActivePool _activePool
    ) internal {
        if (_troveChange.debtIncrease > 0) {
            _boldToken.mint(withdrawalReceiver, _troveChange.debtIncrease);
        } else if (_troveChange.debtDecrease > 0) {
            _boldToken.burn(msg.sender, _troveChange.debtDecrease);
        }

        if (_troveChange.collIncrease > 0) {
            // Pull coll tokens from sender and move them to the Active Pool
            _pullCollAndSendToActivePool(_activePool, _troveChange.collIncrease);
        } else if (_troveChange.collDecrease > 0) {
            // Pull Coll from Active Pool and decrease its recorded Coll balance
            _activePool.sendColl(withdrawalReceiver, _troveChange.collDecrease);
        }
    }

    function _pullCollAndSendToActivePool(IActivePool _activePool, uint256 _amount) internal {
        // Send Coll tokens from sender to active pool
        collToken.safeTransferFrom(msg.sender, address(_activePool), _amount);
        // Make sure Active Pool accountancy is right
        _activePool.accountForReceivedColl(_amount);
    }

    function checkBatchManagerExists(address _batchManager) external view returns (bool) {
        return interestBatchManagers[_batchManager].maxInterestRate > 0;
    }

    // --- 'Require' wrapper functions ---

    function _requireIsNotShutDown() internal view {
        if (hasBeenShutDown) {
            revert IsShutDown();
        }
    }

    function _requireNonZeroAdjustment(TroveChange memory _troveChange) internal pure {
        if (
            _troveChange.collIncrease == 0 && _troveChange.collDecrease == 0 && _troveChange.debtIncrease == 0
                && _troveChange.debtDecrease == 0
        ) {
            revert ZeroAdjustment();
        }
    }

    function _requireSenderIsOwnerOrInterestManager(uint256 _troveId) internal view {
        address owner = troveNFT.ownerOf(_troveId);
        if (msg.sender != owner && msg.sender != interestIndividualDelegateOf[_troveId].account) {
            revert NotOwnerNorInterestManager();
        }
    }

    function _requireValidDelegateAdjustment(
        uint256 _troveId,
        uint256 _lastInterestRateAdjTime,
        uint256 _annualInterestRate
    ) internal view {
        InterestIndividualDelegate memory individualDelegate = interestIndividualDelegateOf[_troveId];
        // We have previously checked that sender is either owner or delegate
        // If it’s owner, this restriction doesn’t apply
        if (individualDelegate.account == msg.sender) {
            _requireInterestRateInRange(
                _annualInterestRate, individualDelegate.minInterestRate, individualDelegate.maxInterestRate
            );
            _requireDelegateInterestRateChangePeriodPassed(
                _lastInterestRateAdjTime, individualDelegate.minInterestRateChangePeriod
            );
        }
    }

    function _requireIsNotInBatch(uint256 _troveId) internal view {
        if (interestBatchManagerOf[_troveId] != address(0)) {
            revert TroveInBatch();
        }
    }

    function _requireIsInBatch(uint256 _troveId) internal view returns (address) {
        address batchManager = interestBatchManagerOf[_troveId];
        if (batchManager == address(0)) {
            revert TroveNotInBatch();
        }

        return batchManager;
    }

    function _requireTroveDoesNotExist(ITroveManager _troveManager, uint256 _troveId) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (status != ITroveManager.Status.nonExistent) {
            revert TroveExists();
        }
    }

    function _requireTroveIsOpen(ITroveManager _troveManager, uint256 _troveId) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (status != ITroveManager.Status.active && status != ITroveManager.Status.zombie) {
            revert TroveNotOpen();
        }
    }

    function _requireTroveIsActive(ITroveManager _troveManager, uint256 _troveId) internal view {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        if (status != ITroveManager.Status.active) {
            revert TroveNotActive();
        }
    }

    function _requireTroveIsZombie(ITroveManager _troveManager, uint256 _troveId) internal view {
        if (!_checkTroveIsZombie(_troveManager, _troveId)) {
            revert TroveNotZombie();
        }
    }

    function _checkTroveIsZombie(ITroveManager _troveManager, uint256 _troveId) internal view returns (bool) {
        ITroveManager.Status status = _troveManager.getTroveStatus(_troveId);
        return status == ITroveManager.Status.zombie;
    }

    function _requireNonZeroDebt(uint256 _troveDebt) internal pure {
        if (_troveDebt == 0) {
            revert TroveWithZeroDebt();
        }
    }

    function _requireUserAcceptsUpfrontFee(uint256 _fee, uint256 _maxFee) internal pure {
        if (_fee > _maxFee) {
            revert UpfrontFeeTooHigh();
        }
    }

    function _requireValidAdjustmentInCurrentMode(
        TroveChange memory _troveChange,
        LocalVariables_adjustTrove memory _vars,
        bool _isTroveInBatch
    ) internal view {
        /*
         * Below Critical Threshold, it is not permitted:
         *
         * - Borrowing, unless it brings TCR up to CCR again
         * - Collateral withdrawal except accompanied by a debt repayment of at least the same value
         *
         * In Normal Mode, ensure:
         *
         * - The adjustment won't pull the TCR below CCR
         *
         * In Both cases:
         * - The new ICR is above MCR, or MCR+BCR if a batched trove
         */

        if (_isTroveInBatch) {
            _requireICRisAboveMCRPlusBCR(_vars.newICR);
        } else {
            _requireICRisAboveMCR(_vars.newICR);
        }

        uint256 newTCR = _getNewTCRFromTroveChange(_troveChange, _vars.price);
        if (_vars.isBelowCriticalThreshold) {
            _requireNoBorrowingUnlessNewTCRisAboveCCR(_troveChange.debtIncrease, newTCR);
            _requireDebtRepaymentGeCollWithdrawal(_troveChange, _vars.price);
        } else {
            // if Normal Mode
            _requireNewTCRisAboveCCR(newTCR);
        }
    }

    function _requireICRisAboveMCR(uint256 _newICR) internal view {
        if (_newICR < systemParams.MCR()) {
            revert ICRBelowMCR();
        }
    }

    function _requireICRisAboveMCRPlusBCR(uint256 _newICR) internal view {
        if (_newICR < systemParams.MCR() + systemParams.BCR()) {
            revert ICRBelowMCRPlusBCR();
        }
    }

    function _requireNoBorrowingUnlessNewTCRisAboveCCR(uint256 _debtIncrease, uint256 _newTCR) internal view {
        if (_debtIncrease > 0 && _newTCR < systemParams.CCR()) {
            revert TCRBelowCCR();
        }
    }

    function _requireDebtRepaymentGeCollWithdrawal(TroveChange memory _troveChange, uint256 _price) internal pure {
        if ((_troveChange.debtDecrease * DECIMAL_PRECISION < _troveChange.collDecrease * _price)) {
            revert RepaymentNotMatchingCollWithdrawal();
        }
    }

    function _requireNewTCRisAboveCCR(uint256 _newTCR) internal view {
        if (_newTCR < systemParams.CCR()) {
            revert TCRBelowCCR();
        }
    }

    function _requireAtLeastMinDebt(uint256 _debt) internal view {
        if (_debt < systemParams.MIN_DEBT()) {
            revert DebtBelowMin();
        }
    }

    function _requireValidCollWithdrawal(uint256 _currentColl, uint256 _collWithdrawal) internal pure {
        if (_collWithdrawal > _currentColl) {
            revert CollWithdrawalTooHigh();
        }
    }

    function _requireSufficientBoldBalance(IBoldToken _boldToken, address _borrower, uint256 _debtRepayment)
        internal
        view
    {
        if (_boldToken.balanceOf(_borrower) < _debtRepayment) {
            revert NotEnoughBoldBalance();
        }
    }

    function _requireValidAnnualInterestRate(uint256 _annualInterestRate) internal view { //“Make sure user-provided interest rate is not too low and not too high.”
        if (_annualInterestRate < systemParams.MIN_ANNUAL_INTEREST_RATE()) {//
            revert InterestRateTooLow();
        }
        if (_annualInterestRate > MAX_ANNUAL_INTEREST_RATE) {//
            revert InterestRateTooHigh();
        }
    }//*Done

    function _requireAnnualInterestRateIsNew(uint256 _oldAnnualInterestRate, uint256 _newAnnualInterestRate)
        internal
        pure
    {
        if (_oldAnnualInterestRate == _newAnnualInterestRate) {
            revert InterestRateNotNew();
        }
    }

    function _requireOrderedRange(uint256 _minInterestRate, uint256 _maxInterestRate) internal pure {
        if (_minInterestRate >= _maxInterestRate) revert MinGeMax();
    }

    function _requireInterestRateInBatchManagerRange(address _interestBatchManagerAddress, uint256 _annualInterestRate)
        internal
        view
    {
        InterestBatchManager memory interestBatchManager = interestBatchManagers[_interestBatchManagerAddress];
        _requireInterestRateInRange(
            _annualInterestRate, interestBatchManager.minInterestRate, interestBatchManager.maxInterestRate
        );
    }

    function _requireInterestRateInRange(
        uint256 _annualInterestRate,
        uint256 _minInterestRate,
        uint256 _maxInterestRate
    ) internal pure {
        if (_minInterestRate > _annualInterestRate || _annualInterestRate > _maxInterestRate) {
            revert InterestNotInRange();
        }
    }

    function _requireDelegateInterestRateChangePeriodPassed(
        uint256 _lastInterestRateAdjTime,
        uint256 _minInterestRateChangePeriod
    ) internal view {
        if (block.timestamp < _lastInterestRateAdjTime + _minInterestRateChangePeriod) {
            revert DelegateInterestRateChangePeriodNotPassed();
        }
    }

    function _requireValidInterestBatchManager(address _interestBatchManagerAddress) internal view { //“Batch manager valid/registered কিনা check করা”
        if (interestBatchManagers[_interestBatchManagerAddress].maxInterestRate == 0) {
            revert InvalidInterestBatchManager();
        }
    }//*Done

    function _requireNonExistentInterestBatchManager(address _interestBatchManagerAddress) internal view {
        if (interestBatchManagers[_interestBatchManagerAddress].maxInterestRate > 0) {
            revert BatchManagerExists();
        }
    }

    function _requireNewInterestBatchManager(address _oldBatchManagerAddress, address _newBatchManagerAddress)
        internal
        pure
    {
        if (_oldBatchManagerAddress == _newBatchManagerAddress) {
            revert BatchManagerNotNew();
        }
    }

    function _requireCallerIsTroveManager() internal view {
        if (msg.sender != address(troveManager)) {
            revert CallerNotTroveManager();
        }
    }

    function _requireCallerIsPriceFeed() internal view {
        if (msg.sender != address(priceFeed)) {
            revert CallerNotPriceFeed();
        }
    }

    function _requireDelegateCallSucceeded(bool success, bytes memory data) internal pure {
        if (!success) {
            assembly {
                revert(add(0x20, data), mload(data))
            }
        }
    }

    // --- ICR and TCR getters ---

    function _getNewTCRFromTroveChange(TroveChange memory _troveChange, uint256 _price)
        internal
        view
        returns (uint256 newTCR)
    {
        uint256 totalColl = getEntireBranchColl();
        totalColl += _troveChange.collIncrease;
        totalColl -= _troveChange.collDecrease;

        uint256 totalDebt = getEntireBranchDebt();
        totalDebt += _troveChange.debtIncrease;
        totalDebt += _troveChange.upfrontFee;
        totalDebt -= _troveChange.debtDecrease;

        newTCR = LiquityMath._computeCR(totalColl, totalDebt, _price);
    }
}
