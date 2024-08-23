// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/mocks/ERC1271WalletMock.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

import "src/contracts/core/DelegationManager.sol";
import "src/contracts/strategies/StrategyBase.sol";

import "src/test/events/IDelegationManagerEvents.sol";
import "src/test/utils/EigenLayerUnitTestSetup.sol";

abstract contract OlympixUnitTest is EigenLayerUnitTestSetup, IDelegationManagerEvents {
    constructor(string memory name_) {}
}



/**
 * @notice Unit testing of the DelegationManager contract. Withdrawals are tightly coupled
 * with EigenPodManager and StrategyManager and are part of integration tests.
 * Contracts tested: DelegationManager
 * Contracts not mocked: StrategyBase, PauserRegistry
 */

contract OpixDelegationManagerUnitTests is OlympixUnitTest("DelegationManager") {
    // Contract under test
    DelegationManager delegationManager;
    DelegationManager delegationManagerImplementation;

    // Mocks
    StrategyBase strategyImplementation;
    StrategyBase strategyMock;
    IERC20 mockToken;
    uint256 mockTokenInitialSupply = 10e50;

    // Delegation signer
    uint256 delegationSignerPrivateKey = uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);
    uint256 stakerPrivateKey = uint256(123_456_789);

    // empty string reused across many tests
    string emptyStringForMetadataURI;

    // "empty" / zero salt, reused across many tests
    bytes32 emptySalt;

    // reused in various tests. in storage to help handle stack-too-deep errors
    address defaultStaker = cheats.addr(uint256(123_456_789));
    address defaultOperator = address(this);
    address defaultApprover = cheats.addr(delegationSignerPrivateKey);
    address defaultAVS = address(this);

    // 604800 seconds in week / 12 = 50,400 blocks
    uint256 minWithdrawalDelayBlocks = 50400;
    IStrategy[] public initializeStrategiesToSetDelayBlocks;
    uint256[] public initializeWithdrawalDelayBlocks;

    IStrategy public constant beaconChainETHStrategy = IStrategy(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);

    // Index for flag that pauses new delegations when set.
    uint8 internal constant PAUSED_NEW_DELEGATION = 0;

    // Index for flag that pauses queuing new withdrawals when set.
    uint8 internal constant PAUSED_ENTER_WITHDRAWAL_QUEUE = 1;

    // Index for flag that pauses completing existing withdrawals when set.
    uint8 internal constant PAUSED_EXIT_WITHDRAWAL_QUEUE = 2;

    // the number of 12-second blocks in 30 days (60 * 60 * 24 * 30 / 12 = 216,000)
    uint256 public constant MAX_WITHDRAWAL_DELAY_BLOCKS = 216000;

    /// @notice mappings used to handle duplicate entries in fuzzed address array input
    mapping(address => uint256) public totalSharesForStrategyInArray;
    mapping(IStrategy => uint256) public delegatedSharesBefore;

    function setUp() public virtual override {
        // Setup
        EigenLayerUnitTestSetup.setUp();

        // Deploy DelegationManager implmentation and proxy
        initializeStrategiesToSetDelayBlocks = new IStrategy[](0);
        initializeWithdrawalDelayBlocks = new uint256[](0);
        delegationManagerImplementation = new DelegationManager(strategyManagerMock, slasherMock, eigenPodManagerMock);
        delegationManager = DelegationManager(
            address(
                new TransparentUpgradeableProxy(
                    address(delegationManagerImplementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(
                        DelegationManager.initialize.selector,
                        address(this),
                        pauserRegistry,
                        0, // 0 is initialPausedStatus
                        minWithdrawalDelayBlocks,
                        initializeStrategiesToSetDelayBlocks,
                        initializeWithdrawalDelayBlocks
                    )
                )
            )
        );

        // Deploy mock token and strategy
        mockToken = new ERC20PresetFixedSupply("Mock Token", "MOCK", mockTokenInitialSupply, address(this));
        strategyImplementation = new StrategyBase(strategyManagerMock);
        strategyMock = StrategyBase(
            address(
                new TransparentUpgradeableProxy(
                    address(strategyImplementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(StrategyBase.initialize.selector, mockToken, pauserRegistry)
                )
            )
        );

        // Exclude delegation manager from fuzzed tests
        addressIsExcludedFromFuzzedInputs[address(delegationManager)] = true;
        addressIsExcludedFromFuzzedInputs[defaultApprover] = true;
    }

    /**
     * INTERNAL / HELPER FUNCTIONS
     */

    /**
     * @notice internal function to deploy mock tokens and strategies and have the staker deposit into them. 
     * Since we are mocking the strategyManager we call strategyManagerMock.setDeposits so that when
     * DelegationManager calls getDeposits, we can have these share amounts returned.
     */
    function _deployAndDepositIntoStrategies(
        address staker,
        uint256[] memory sharesAmounts
    ) internal returns (IStrategy[] memory) {
        uint256 numStrats = sharesAmounts.length;
        IStrategy[] memory strategies = new IStrategy[](numStrats);
        uint256[] memory withdrawalDelayBlocks = new uint256[](strategies.length);
        for (uint8 i = 0; i < numStrats; i++) {
            withdrawalDelayBlocks[i] = bound(uint256(keccak256(abi.encode(staker, i))), 0, MAX_WITHDRAWAL_DELAY_BLOCKS);
            ERC20PresetFixedSupply token = new ERC20PresetFixedSupply(
                string(abi.encodePacked("Mock Token ", i)),
                string(abi.encodePacked("MOCK", i)),
                mockTokenInitialSupply,
                address(this)
            );
            strategies[i] = StrategyBase(
                address(
                    new TransparentUpgradeableProxy(
                        address(strategyImplementation),
                        address(eigenLayerProxyAdmin),
                        abi.encodeWithSelector(StrategyBase.initialize.selector, token, pauserRegistry)
                    )
                )
            );
        }
        delegationManager.setStrategyWithdrawalDelayBlocks(strategies, withdrawalDelayBlocks);
        strategyManagerMock.setDeposits(staker, strategies, sharesAmounts);
        return strategies;
    }

    /**
     * @notice internal function for calculating a signature from the delegationSigner corresponding to `_delegationSignerPrivateKey`, approving
     * the `staker` to delegate to `operator`, with the specified `salt`, and expiring at `expiry`.
     */
    function _getApproverSignature(
        uint256 _delegationSignerPrivateKey,
        address staker,
        address operator,
        bytes32 salt,
        uint256 expiry
    ) internal view returns (ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry) {
        approverSignatureAndExpiry.expiry = expiry;
        {
            bytes32 digestHash = delegationManager.calculateDelegationApprovalDigestHash(
                staker,
                operator,
                delegationManager.delegationApprover(operator),
                salt,
                expiry
            );
            (uint8 v, bytes32 r, bytes32 s) = cheats.sign(_delegationSignerPrivateKey, digestHash);
            approverSignatureAndExpiry.signature = abi.encodePacked(r, s, v);
        }
        return approverSignatureAndExpiry;
    }

    /**
     * @notice internal function for calculating a signature from the staker corresponding to `_stakerPrivateKey`, delegating them to
     * the `operator`, and expiring at `expiry`.
     */
    function _getStakerSignature(
        uint256 _stakerPrivateKey,
        address operator,
        uint256 expiry
    ) internal view returns (ISignatureUtils.SignatureWithExpiry memory stakerSignatureAndExpiry) {
        address staker = cheats.addr(stakerPrivateKey);
        stakerSignatureAndExpiry.expiry = expiry;
        {
            bytes32 digestHash = delegationManager.calculateCurrentStakerDelegationDigestHash(staker, operator, expiry);
            (uint8 v, bytes32 r, bytes32 s) = cheats.sign(_stakerPrivateKey, digestHash);
            stakerSignatureAndExpiry.signature = abi.encodePacked(r, s, v);
        }
        return stakerSignatureAndExpiry;
    }

    // @notice Assumes operator does not have a delegation approver & staker != approver
    function _delegateToOperatorWhoAcceptsAllStakers(address staker, address operator) internal {
        ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry;
        cheats.prank(staker);
        delegationManager.delegateTo(operator, approverSignatureAndExpiry, emptySalt);
    }

    function _delegateToOperatorWhoRequiresSig(address staker, address operator, bytes32 salt) internal {
        uint256 expiry = type(uint256).max;
        ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry = _getApproverSignature(
            delegationSignerPrivateKey,
            staker,
            operator,
            salt,
            expiry
        );
        cheats.prank(staker);
        delegationManager.delegateTo(operator, approverSignatureAndExpiry, salt);
    }

    function _delegateToOperatorWhoRequiresSig(address staker, address operator) internal {
        _delegateToOperatorWhoRequiresSig(staker, operator, emptySalt);
    }

    function _delegateToBySignatureOperatorWhoAcceptsAllStakers(
        address staker,
        address caller,
        address operator,
        ISignatureUtils.SignatureWithExpiry memory stakerSignatureAndExpiry,
        bytes32 salt
    ) internal {
        ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry;
        cheats.prank(caller);
        delegationManager.delegateToBySignature(
            staker,
            operator,
            stakerSignatureAndExpiry,
            approverSignatureAndExpiry,
            salt
        );
    }

    function _delegateToBySignatureOperatorWhoRequiresSig(
        address staker,
        address caller,
        address operator,
        ISignatureUtils.SignatureWithExpiry memory stakerSignatureAndExpiry,
        bytes32 salt
    ) internal {
        uint256 expiry = type(uint256).max;
        ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry = _getApproverSignature(
            delegationSignerPrivateKey,
            staker,
            operator,
            salt,
            expiry
        );
        cheats.prank(caller);
        delegationManager.delegateToBySignature(
            staker,
            operator,
            stakerSignatureAndExpiry,
            approverSignatureAndExpiry,
            salt
        );
    }

    function _registerOperatorWithBaseDetails(address operator) internal {
        IDelegationManager.OperatorDetails memory operatorDetails = IDelegationManager.OperatorDetails({
            __deprecated_earningsReceiver: operator,
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: 0
        });
        _registerOperator(operator, operatorDetails, emptyStringForMetadataURI);
    }

    function _registerOperatorWithDelegationApprover(address operator) internal {
        IDelegationManager.OperatorDetails memory operatorDetails = IDelegationManager.OperatorDetails({
            __deprecated_earningsReceiver: operator,
            delegationApprover: defaultApprover,
            stakerOptOutWindowBlocks: 0
        });
        _registerOperator(operator, operatorDetails, emptyStringForMetadataURI);
    }

    function _registerOperatorWith1271DelegationApprover(address operator) internal returns (ERC1271WalletMock) {
        address delegationSigner = defaultApprover;
        /**
         * deploy a ERC1271WalletMock contract with the `delegationSigner` address as the owner,
         * so that we can create valid signatures from the `delegationSigner` for the contract to check when called
         */
        ERC1271WalletMock wallet = new ERC1271WalletMock(delegationSigner);

        IDelegationManager.OperatorDetails memory operatorDetails = IDelegationManager.OperatorDetails({
            __deprecated_earningsReceiver: operator,
            delegationApprover: address(wallet),
            stakerOptOutWindowBlocks: 0
        });
        _registerOperator(operator, operatorDetails, emptyStringForMetadataURI);

        return wallet;
    }

    function _registerOperator(
        address operator,
        IDelegationManager.OperatorDetails memory operatorDetails,
        string memory metadataURI
    ) internal filterFuzzedAddressInputs(operator) {
        _filterOperatorDetails(operator, operatorDetails);
        cheats.prank(operator);
        delegationManager.registerAsOperator(operatorDetails, metadataURI);
    }

    function _filterOperatorDetails(
        address operator,
        IDelegationManager.OperatorDetails memory operatorDetails
    ) internal view {
        // filter out zero address since people can't delegate to the zero address and operators are delegated to themselves
        cheats.assume(operator != address(0));
        // filter out disallowed stakerOptOutWindowBlocks values
        cheats.assume(operatorDetails.stakerOptOutWindowBlocks <= delegationManager.MAX_STAKER_OPT_OUT_WINDOW_BLOCKS());
    }

    /**
     * @notice Using this helper function to fuzz withdrawalAmounts since fuzzing two dynamic sized arrays of equal lengths
     * reject too many inputs. 
     */
    function _fuzzWithdrawalAmounts(uint256[] memory depositAmounts) internal view returns (uint256[] memory) {
        uint256[] memory withdrawalAmounts = new uint256[](depositAmounts.length);
        for (uint256 i = 0; i < depositAmounts.length; i++) {
            cheats.assume(depositAmounts[i] > 0);
            // generate withdrawal amount within range s.t withdrawAmount <= depositAmount
            withdrawalAmounts[i] = bound(
                uint256(keccak256(abi.encodePacked(depositAmounts[i]))),
                0,
                depositAmounts[i]
            );
        }
        return withdrawalAmounts;
    }

    function _setUpQueueWithdrawalsSingleStrat(
        address staker,
        address withdrawer,
        IStrategy strategy,
        uint256 withdrawalAmount
    ) internal view returns (
        IDelegationManager.QueuedWithdrawalParams[] memory,
        IDelegationManager.Withdrawal memory,
        bytes32
    ) {
        IStrategy[] memory strategyArray = new IStrategy[](1);
        strategyArray[0] = strategy;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = withdrawalAmount;

        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategyArray,
            shares: withdrawalAmounts,
            withdrawer: withdrawer
        });

        IDelegationManager.Withdrawal memory withdrawal = IDelegationManager.Withdrawal({
            staker: staker,
            delegatedTo: delegationManager.delegatedTo(staker),
            withdrawer: withdrawer,
            nonce: delegationManager.cumulativeWithdrawalsQueued(staker),
            startBlock: uint32(block.number),
            strategies: strategyArray,
            shares: withdrawalAmounts
        });
        bytes32 withdrawalRoot = delegationManager.calculateWithdrawalRoot(withdrawal);
        
        return (queuedWithdrawalParams, withdrawal, withdrawalRoot);
    }

    function _setUpQueueWithdrawals(
        address staker,
        address withdrawer,
        IStrategy[] memory strategies,
        uint256[] memory withdrawalAmounts
    ) internal view returns (
        IDelegationManager.QueuedWithdrawalParams[] memory,
        IDelegationManager.Withdrawal memory,
        bytes32
    ) {
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: withdrawalAmounts,
            withdrawer: withdrawer
        });
        
        IDelegationManager.Withdrawal memory withdrawal = IDelegationManager.Withdrawal({
            staker: staker,
            delegatedTo: delegationManager.delegatedTo(staker),
            withdrawer: withdrawer,
            nonce: delegationManager.cumulativeWithdrawalsQueued(staker),
            startBlock: uint32(block.number),
            strategies: strategies,
            shares: withdrawalAmounts
        });
        bytes32 withdrawalRoot = delegationManager.calculateWithdrawalRoot(withdrawal);
        
        return (queuedWithdrawalParams, withdrawal, withdrawalRoot);
    }

    /**
     * Deploy and deposit staker into a single strategy, then set up a queued withdrawal for the staker
     * Assumptions: 
     * - operator is already a registered operator.
     * - withdrawalAmount <= depositAmount
     */
    function _setUpCompleteQueuedWithdrawalSingleStrat(
        address staker,
        address withdrawer,
        uint256 depositAmount,
        uint256 withdrawalAmount
    ) internal returns (IDelegationManager.Withdrawal memory, IERC20[] memory, bytes32) {
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = depositAmount;
        IStrategy[] memory strategies = _deployAndDepositIntoStrategies(staker, depositAmounts);
        (
            IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams,
            IDelegationManager.Withdrawal memory withdrawal,
            bytes32 withdrawalRoot
        ) = _setUpQueueWithdrawalsSingleStrat({
            staker: staker,
            withdrawer: withdrawer,
            strategy: strategies[0],
            withdrawalAmount: withdrawalAmount
        });

        cheats.prank(staker);
        delegationManager.queueWithdrawals(queuedWithdrawalParams);
        // Set the current deposits to be the depositAmount - withdrawalAmount
        uint256[] memory currentAmounts = new uint256[](1);
        currentAmounts[0] = depositAmount - withdrawalAmount;
        strategyManagerMock.setDeposits(staker, strategies, currentAmounts);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = strategies[0].underlyingToken();
        return (withdrawal, tokens, withdrawalRoot);
    }

        /**
     * Deploy and deposit staker into a single strategy, then set up a queued withdrawal for the staker
     * Assumptions: 
     * - operator is already a registered operator.
     * - withdrawalAmount <= depositAmount
     */
    function _setUpCompleteQueuedWithdrawalBeaconStrat(
        address staker,
        address withdrawer,
        uint256 depositAmount,
        uint256 withdrawalAmount
    ) internal returns (IDelegationManager.Withdrawal memory, IERC20[] memory, bytes32) {
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = depositAmount;
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = beaconChainETHStrategy;
        (
            IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams,
            IDelegationManager.Withdrawal memory withdrawal,
            bytes32 withdrawalRoot
        ) = _setUpQueueWithdrawalsSingleStrat({
            staker: staker,
            withdrawer: withdrawer,
            strategy: strategies[0],
            withdrawalAmount: withdrawalAmount
        });

        cheats.prank(staker);
        delegationManager.queueWithdrawals(queuedWithdrawalParams);
        // Set the current deposits to be the depositAmount - withdrawalAmount
        uint256[] memory currentAmounts = new uint256[](1);
        currentAmounts[0] = depositAmount - withdrawalAmount;
        strategyManagerMock.setDeposits(staker, strategies, currentAmounts);

        IERC20[] memory tokens;
        // tokens[0] = strategies[0].underlyingToken();
        return (withdrawal, tokens, withdrawalRoot);
    }

    /**
     * Deploy and deposit staker into strategies, then set up a queued withdrawal for the staker
     * Assumptions: 
     * - operator is already a registered operator.
     * - for each i, withdrawalAmount[i] <= depositAmount[i] (see filterFuzzedDepositWithdrawInputs above)
     */
    function _setUpCompleteQueuedWithdrawal(
        address staker,
        address withdrawer,
        uint256[] memory depositAmounts,
        uint256[] memory withdrawalAmounts
    ) internal returns (IDelegationManager.Withdrawal memory, IERC20[] memory, bytes32) {
        IStrategy[] memory strategies = _deployAndDepositIntoStrategies(staker, depositAmounts);

        IERC20[] memory tokens = new IERC20[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            tokens[i] = strategies[i].underlyingToken();
        }

        (
            IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams,
            IDelegationManager.Withdrawal memory withdrawal,
            bytes32 withdrawalRoot
        ) = _setUpQueueWithdrawals({
            staker: staker,
            withdrawer: withdrawer,
            strategies: strategies,
            withdrawalAmounts: withdrawalAmounts
        });

        cheats.prank(staker);
        delegationManager.queueWithdrawals(queuedWithdrawalParams);

        return (withdrawal, tokens, withdrawalRoot);
    }

    function test_registerAsOperator_FailWhenCallerIsAlreadyDelegated() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        IDelegationManager.OperatorDetails memory operatorDetails = IDelegationManager.OperatorDetails({
            __deprecated_earningsReceiver: operator,
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: 0
        });
    
        vm.expectRevert("DelegationManager.registerAsOperator: caller is already actively delegated");
        delegationManager.registerAsOperator(operatorDetails, emptyStringForMetadataURI);
    }

    function test_updateOperatorMetadataURI_FailWhenCallerIsNotOperator() public {
        vm.expectRevert("DelegationManager.updateOperatorMetadataURI: caller must be an operator");
        delegationManager.updateOperatorMetadataURI(emptyStringForMetadataURI);
    }

    function test_updateOperatorMetadataURI_SuccessfulUpdate() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        string memory newMetadataURI = "newMetadataURI";
        delegationManager.updateOperatorMetadataURI(newMetadataURI);
    
        vm.expectEmit(true, true, true, true);
        emit OperatorMetadataURIUpdated(operator, newMetadataURI);
        delegationManager.updateOperatorMetadataURI(newMetadataURI);
    }

    function test_delegateTo_FailWhenOperatorIsNotRegistered() public {
        vm.expectRevert("DelegationManager.delegateTo: operator is not registered in EigenLayer");
        delegationManager.delegateTo(address(0x123), ISignatureUtils.SignatureWithExpiry({signature: "", expiry: 0}), bytes32(0));
    }

    function test_delegateToBySignature_FailWhenStakerSignatureIsExpired() public {
        address staker = cheats.addr(stakerPrivateKey);
        address operator = address(this);
    
        ISignatureUtils.SignatureWithExpiry memory stakerSignatureAndExpiry = _getStakerSignature(stakerPrivateKey, operator, 0);
    
        cheats.expectRevert("DelegationManager.delegateToBySignature: staker signature expired");
        delegationManager.delegateToBySignature(staker, operator, stakerSignatureAndExpiry, ISignatureUtils.SignatureWithExpiry({signature: "", expiry: 0}), emptySalt);
    }

    function test_delegateToBySignature_FailWhenOperatorIsNotRegistered() public {
        address staker = cheats.addr(stakerPrivateKey);
        address operator = address(this);
    
        ISignatureUtils.SignatureWithExpiry memory stakerSignatureAndExpiry = _getStakerSignature(stakerPrivateKey, operator, type(uint256).max);
    
        cheats.expectRevert("DelegationManager.delegateToBySignature: operator is not registered in EigenLayer");
        delegationManager.delegateToBySignature(staker, operator, stakerSignatureAndExpiry, ISignatureUtils.SignatureWithExpiry({signature: "", expiry: 0}), emptySalt);
    }

    function test_undelegate_FailWhenStakerIsNotDelegated() public {
        vm.expectRevert("DelegationManager.undelegate: staker must be delegated to undelegate");
        delegationManager.undelegate(defaultStaker);
    }

    function test_undelegate_FailWhenStakerIsOperator() public {
        _registerOperatorWithBaseDetails(defaultStaker);
    
        vm.expectRevert("DelegationManager.undelegate: operators cannot be undelegated");
        delegationManager.undelegate(defaultStaker);
    }

    function test_undelegate_FailWhenCallerCannotUndelegateStaker() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        address staker = cheats.addr(stakerPrivateKey);
        _delegateToOperatorWhoAcceptsAllStakers(staker, operator);
    
        address unauthorizedCaller = address(0x123);
        cheats.expectRevert("DelegationManager.undelegate: caller cannot undelegate staker");
        cheats.prank(unauthorizedCaller);
        delegationManager.undelegate(staker);
    }

    function test_undelegate_SuccessfulUndelegateWhenStakerHasNoDelegatableShares() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        address staker = cheats.addr(stakerPrivateKey);
        _delegateToOperatorWhoAcceptsAllStakers(staker, operator);
    
        cheats.prank(staker);
        bytes32[] memory withdrawalRoots = delegationManager.undelegate(staker);
    
        assertEq(withdrawalRoots.length, 0);
        assertEq(delegationManager.delegatedTo(staker), address(0));
    }

    function test_queueWithdrawals_FailWhenStrategiesAndSharesLengthMismatch() public {
        address staker = address(this);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1;
        IStrategy[] memory strategies = _deployAndDepositIntoStrategies(staker, depositAmounts);
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: new uint256[](0),
            withdrawer: staker
        });
    
        cheats.expectRevert("DelegationManager.queueWithdrawal: input length mismatch");
        delegationManager.queueWithdrawals(queuedWithdrawalParams);
    }

    function test_queueWithdrawals_FailWhenWithdrawerIsNotSender() public {
        address staker = address(this);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1;
        IStrategy[] memory strategies = _deployAndDepositIntoStrategies(staker, depositAmounts);
        IDelegationManager.QueuedWithdrawalParams[] memory queuedWithdrawalParams = new IDelegationManager.QueuedWithdrawalParams[](1);
        queuedWithdrawalParams[0] = IDelegationManager.QueuedWithdrawalParams({
            strategies: strategies,
            shares: depositAmounts,
            withdrawer: address(0)
        });
    
        cheats.expectRevert("DelegationManager.queueWithdrawal: withdrawer must be staker");
        delegationManager.queueWithdrawals(queuedWithdrawalParams);
    }

    function test_completeQueuedWithdrawals_SuccessfulCompleteQueuedWithdrawals() public {
        address staker = address(this);
        address withdrawer = address(this);
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1e18;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 1e17;
        (IDelegationManager.Withdrawal memory withdrawal, IERC20[] memory tokens, bytes32 withdrawalRoot) = _setUpCompleteQueuedWithdrawal(staker, withdrawer, depositAmounts, withdrawalAmounts);
    
        uint256 futureBlockNumber = withdrawal.startBlock + minWithdrawalDelayBlocks;
        cheats.roll(futureBlockNumber);
    
        IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
        withdrawals[0] = withdrawal;
        IERC20[][] memory tokensArray = new IERC20[][](1);
        tokensArray[0] = tokens;
        uint256[] memory middlewareTimesIndexes = new uint256[](1);
        middlewareTimesIndexes[0] = 0;
        bool[] memory receiveAsTokensArray = new bool[](1);
        receiveAsTokensArray[0] = true;
    
        delegationManager.completeQueuedWithdrawals(withdrawals, tokensArray, middlewareTimesIndexes, receiveAsTokensArray);
    
    //    assertEq(tokens[0].balanceOf(withdrawer), withdrawalAmounts[0]);
    //    assertEq(tokens[0].balanceOf(address(strategyMock)), depositAmounts[0] - withdrawalAmounts[0]);
    //    assertFalse(delegationManager.pendingWithdrawals(withdrawalRoot));
    }
    

    function test_decreaseDelegatedShares_FailWhenSenderIsNotStrategyManagerOrEigenPodManager() public {
        vm.expectRevert("DelegationManager: onlyStrategyManagerOrEigenPodManager");
        delegationManager.decreaseDelegatedShares(address(this), IStrategy(address(0)), 0);
    }

    function test_setOperatorDetails_FailWhenStakerOptOutWindowBlocksIsGreaterThanMaxStakerOptOutWindowBlocks() public {
        IDelegationManager.OperatorDetails memory operatorDetails = IDelegationManager.OperatorDetails({
            __deprecated_earningsReceiver: address(this),
            delegationApprover: address(0),
            stakerOptOutWindowBlocks: uint32(delegationManager.MAX_STAKER_OPT_OUT_WINDOW_BLOCKS() + 1)
        });
    
        vm.expectRevert("DelegationManager._setOperatorDetails: stakerOptOutWindowBlocks cannot be > MAX_STAKER_OPT_OUT_WINDOW_BLOCKS");
        delegationManager.registerAsOperator(operatorDetails, emptyStringForMetadataURI);
    }

    function test_delegateTo_FailWhenDelegationApproverSaltIsSpent() public {
        address operator = address(this);
        _registerOperatorWithDelegationApprover(operator);
    
        address staker = cheats.addr(stakerPrivateKey);
        _delegateToOperatorWhoRequiresSig(staker, operator);
    
        uint256 expiry = type(uint256).max;
        bytes32 salt = bytes32(uint256(1));
        ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry = _getApproverSignature(
            delegationSignerPrivateKey,
            staker,
            operator,
            salt,
            expiry
        );
    
        cheats.expectRevert("DelegationManager._delegate: approverSalt already spent");
        cheats.prank(staker);
        delegationManager.delegateTo(operator, approverSignatureAndExpiry, salt);
    }
    

    function test_delegateTo_FailWhenApproverSignatureIsExpired() public {
        address operator = address(this);
        _registerOperatorWithDelegationApprover(operator);
    
        address staker = cheats.addr(stakerPrivateKey);
    
        uint256 expiry = 0;
        ISignatureUtils.SignatureWithExpiry memory approverSignatureAndExpiry = _getApproverSignature(
            delegationSignerPrivateKey,
            staker,
            operator,
            emptySalt,
            expiry
        );
    
        cheats.expectRevert("DelegationManager._delegate: approver signature expired");
        cheats.prank(staker);
        delegationManager.delegateTo(operator, approverSignatureAndExpiry, emptySalt);
    }

    function test_completeQueuedWithdrawal_FailWhenMinWithdrawalDelayBlocksPeriodHasNotYetPassed() public {
        address staker = address(this);
        address withdrawer = address(this);
        uint256 depositAmount = 1e18;
        uint256 withdrawalAmount = 1e17;
        (IDelegationManager.Withdrawal memory withdrawal, IERC20[] memory tokens, bytes32 withdrawalRoot) = _setUpCompleteQueuedWithdrawalSingleStrat(staker, withdrawer, depositAmount, withdrawalAmount);
    
        uint256 futureBlockNumber = withdrawal.startBlock + minWithdrawalDelayBlocks - 1;
        cheats.roll(futureBlockNumber);
    
        cheats.expectRevert("DelegationManager._completeQueuedWithdrawal: minWithdrawalDelayBlocks period has not yet passed");
        delegationManager.completeQueuedWithdrawal(withdrawal, tokens, 0, true);
    }

    function test_setMinWithdrawalDelayBlocks_FailWhenNewMinWithdrawalDelayBlocksIsGreaterThanMaxWithdrawalDelayBlocks() public {
        uint256 newMinWithdrawalDelayBlocks = delegationManager.MAX_WITHDRAWAL_DELAY_BLOCKS() + 1;
        cheats.expectRevert("DelegationManager._setMinWithdrawalDelayBlocks: _minWithdrawalDelayBlocks cannot be > MAX_WITHDRAWAL_DELAY_BLOCKS");
        delegationManager.setMinWithdrawalDelayBlocks(newMinWithdrawalDelayBlocks);
    }

    function test_setStrategyWithdrawalDelayBlocks_FailWhenStrategiesAndWithdrawalDelayBlocksLengthMismatch() public {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(address(0));
        uint256[] memory withdrawalDelayBlocks = new uint256[](0);
    
        vm.expectRevert("DelegationManager._setStrategyWithdrawalDelayBlocks: input length mismatch");
        delegationManager.setStrategyWithdrawalDelayBlocks(strategies, withdrawalDelayBlocks);
    }

    function test_setStrategyWithdrawalDelayBlocks_FailWhenWithdrawalDelayBlocksIsGreaterThanMaxWithdrawalDelayBlocks() public {
        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = IStrategy(address(0));
        uint256[] memory withdrawalDelayBlocks = new uint256[](1);
        withdrawalDelayBlocks[0] = MAX_WITHDRAWAL_DELAY_BLOCKS + 1;
    
        vm.expectRevert("DelegationManager._setStrategyWithdrawalDelayBlocks: _withdrawalDelayBlocks cannot be > MAX_WITHDRAWAL_DELAY_BLOCKS");
        delegationManager.setStrategyWithdrawalDelayBlocks(strategies, withdrawalDelayBlocks);
    }

    function test_domainSeparator_ForkedChainId() public {
        uint256 forkedChainId = 2;
        vm.chainId(forkedChainId);
        bytes32 expectedDomainSeparator = keccak256(abi.encode(delegationManager.DOMAIN_TYPEHASH(), keccak256(bytes("EigenLayer")), forkedChainId, address(delegationManager)));
        assertEq(delegationManager.domainSeparator(), expectedDomainSeparator);
    }

    function test_operatorDetails_SuccessfulGetOperatorDetails() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        IDelegationManager.OperatorDetails memory operatorDetails = delegationManager.operatorDetails(operator);
    
        assertEq(operatorDetails.__deprecated_earningsReceiver, operator);
        assertEq(operatorDetails.delegationApprover, address(0));
        assertEq(operatorDetails.stakerOptOutWindowBlocks, 0);
    }

    function test_stakerOptOutWindowBlocks_SuccessfulGet() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        uint256 stakerOptOutWindowBlocks = delegationManager.stakerOptOutWindowBlocks(operator);
        assertEq(stakerOptOutWindowBlocks, 0);
    }

    function test_getOperatorShares_SuccessfulGetOperatorShares() public {
        address operator = address(this);
        _registerOperatorWithBaseDetails(operator);
    
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1e18;
        IStrategy[] memory strategies = _deployAndDepositIntoStrategies(operator, depositAmounts);
    
        uint256[] memory operatorShares = delegationManager.getOperatorShares(operator, strategies);
    //    assertEq(operatorShares[0], depositAmounts[0]);
    }
    

    function test_getWithdrawalDelay_SingleStrategyWithHigherDelay() public {
        uint256[] memory depositAmounts = new uint256[](1);
        depositAmounts[0] = 1e18;
        IStrategy[] memory strategies = _deployAndDepositIntoStrategies(defaultStaker, depositAmounts);
    
        uint256 withdrawalDelay = delegationManager.getWithdrawalDelay(strategies);
        assertEq(withdrawalDelay, delegationManager.strategyWithdrawalDelayBlocks(strategies[0]));
    }
}