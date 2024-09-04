// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionConfig} from "v4-periphery/src/libraries/PositionConfig.sol";
import {ProtocolFeeControllerTest} from "v4-core/src/test/ProtocolFeeControllerTest.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
//
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {InitializeHook} from "../src/InitializeHook.sol";

contract InitializeHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    InitializeHook hook;
    PoolId poolId;
    PositionConfig config;

    function setUp() public {}
    function test_InitializeHooks() external {
        // Declaration of Conracts we need on the way

        // Pool manager is our main contact for initialization of pools
        IPoolManager manager_;
        // Initialize Hook is Our Custom hook that contains the different logic based on the callback
        // In our example , this custom hook implements BeforeInitalize and AfterInitalize Hooks
        // And currently it just increments a global mapping so that it becomes evident that some custom logic is executed
        // and any additional logic can be added
        InitializeHook initializeHook;
        // remember in the previous part of the tutorial , we discussed how uniswap controls the protocol fees
        // using a protocolFeeController insie Pool Manager.
        // Here we are declaring that protocol fee controller
        ProtocolFeeControllerTest feeController_;

        // Deploy All the required contracts

        // Initalize the Pool Manager with initial 500k Gas for controller to suffice for making queries to protocol fees controller for protocol fees
        manager_ = new PoolManager(500000);
        feeController_ = new ProtocolFeeControllerTest();
        // Set protocol fee controller
        manager_.setProtocolFeeController(feeController);

        // Now we need to deploy 2 currencies , we will name them as USDC and AAVE
        //  Note : We are not considering the changed behaviours in them and just think of them as standard ERC20 tokens
        MockERC20 USDC = new MockERC20("USDC", "USDC", 18);
        MockERC20 AAVE = new MockERC20("AAVE", "AAVE", 18);

        // But we don't have any tokens yet . that's why we will mint some .
        // For initalize Hook , we can skip this but this will be used later when we want to add liquidity ,
        // then we will need tokens
        uint totalSupply = 10e20 ether; // time to get rich
        USDC.mint(address(this), totalSupply);
        AAVE.mint(address(this), totalSupply);

        // Time to sort tokens numerically
        // Additionally we are using a wrapper Currency on type address which does not do anything fancy
        // But provides some helper function like equals,greaterThan,lessThan instead of specifying the operators
        // Additionally it also supports the native methods like transfer
        // You can see different functions defined in v4-core/types/Currency.sol for more depth
        Currency token0;
        Currency token1;

        // Currency has a wrap fuction that takes an address as argument and returns a Currency type variable
        // that is composed of that given address
        if (USDC > AAVE) {
            token0 = Currency.wrap(address(AAVE));
            token1 = Currency.wrap(address(USDC));
        } else {
            token0 = Currency.wrap(address(USDC));
            token1 = Currency.wrap(address(AAVE));
        }

        // Deploy the hook to an address with the correct flags

        // Since Our initializeHook is based on only two Hooks , BeforeInitalize and Afterinitialiaze
        // We will make our hook with those corresponding hook type flags.
        // Where | can be considered as the concatenation opeator ( Actually a bit-wise OR )
        //  Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG means our hook contains both hook flags

        // Now , we need to convert it into address that will be used to detect which hooks are supported

        //  Remeber , a hook address is determined by the hook flags it is designed for
        // Through the concatenation of those hook flags , we generate the hook address
        // Now whenever the verification is needed ,the hook address itself can be used to check if it is composed of correct flags.

        // Remember Our discussion about Hooks ,  inside hooks.sol
        //  uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
        //  uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;
        // etc.
        // 1<<13 in its binary represenation is 10 0000 0000 0000 ,
        // 1 << 10 in its binary represenation is 100 0000 0000
        /// For example, a hooks contract deployed to address: 0x0000000000000000000000000000000000002400
        /// has the RIGHTMOST bits '10 0100 0000 0000' which would cause the 'before initialize' and 'after add liquidity' hooks to be used.

        address flags = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG)
        );
        bytes memory constructorArgs = abi.encode(manager_); //Add all the necessary constructor arguments from the hook
        deployCodeTo(
            "InitializeHook.sol:InitializeHook",
            constructorArgs,
            flags
        );
        initializeHook = InitializeHook(flags);

        // Create the pool
        key = PoolKey(token0, token1, 3000, 60, IHooks(initializeHook));
        poolId = key.toId();
        manager_.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide full-range liquidity to the pool
        config = PositionConfig({
            poolKey: key,
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing)
        });
        assertEq(initializeHook.beforeInitializeCalled(), true);
        assertEq(initializeHook.afterInitializeCalled(), true);

    }
}





        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        // 2. Then, the caller must approve POSM as a spender of permit2.
        // IPositionManager posm_;
        // IAllowanceTransfer permit2_;
        // permit2_ = IAllowanceTransfer(deployPermit2());
        // posm_ = IPositionManager(new PositionManager(manager_, permit2_));

        // IERC20(Currency.unwrap(token0)).approve(
        //     address(permit2_),
        //     type(uint256).max
        // );
        // permit2_.approve(
        //     Currency.unwrap(token0),
        //     address(posm_),
        //     type(uint160).max,
        //     type(uint48).max
        // );
        // IERC20(Currency.unwrap(token1)).approve(
        //     address(permit2_),
        //     type(uint256).max
        // );
        // permit2_.approve(
        //     Currency.unwrap(token1),
        //     address(posm_),
        //     type(uint160).max,
        //     type(uint48).max
        // );

        // /// mint is defined in easyposm.sol
        // (tokenId, ) = posm_.mint(
        //     config,
        //     10_000e18,
        //     MAX_SLIPPAGE_ADD_LIQUIDITY,
        //     MAX_SLIPPAGE_ADD_LIQUIDITY,
        //     address(this),
        //     block.timestamp,
        //     ZERO_BYTES
        // );