# From 0 to Designing a fully-onchain Uniswap V4 hook line-by-line with assembly level explanation

## Understanding Source Code from SR's perspective

### Introduction

As you might know that Inside V4 , for every pool , there is no separate contract deployed , rather we have one Singleton contract that manages

all the pools and their activitie like swap and add/remove liquidity.

If you are new to Uniswap V4 , Here's a refresher .

#### Refresher :


Uniswap V4 has introduced following features as the main ones compared to it's ancestors V1,V2 & V3 :

##### 1. Hooks :

In General , a hook is a callback to be called before or after a certain action's completion.

In uniswap v4's context, this is custom logic attached to liquidity pools to be executed before or after swaps and liquidity modification operations like add/remove liquidity.

##### 2. Singleton contract :

No More tons of deployments for tons of pools , One contract will manage the operation of all pools.

This has led to :

- Efficient Single source of access
- Drastic Improvement in gas costs ( upto 99% )

##### 3. Flash Accounting System:

- Multicall like paradigm that allows to chain together multiple actions in single transaction , All transactions at the end accrues some debt or clear it , This paradigm 
  check that user has paid all debt at the end of that multicall transaction

- The idea is inspired from flashloans due to the check in the last portion of the transaction which if failed , will revert entire set of transactions.

##### 4. Unlimited Fee Tiers:

- Unlike prior versions of uniswap , this version does not restrict users and pools to operate on specific fee tiers like 0.3% , 0.01% etc.
  Rather it introduces arbitrary fee tiers yo support customized complex strategies for diverse real world trading scenarios.

##### 5. Native ETH Support:

- V4 eliminates the need to convert ETH to Wrapped ETH whenever Eth is intended to be used in the transaction. This reduces a lot of gas 
 and is more intuitive to do . Thank you V4 .


### Architectural Intuition :

If you don't understand these right away , no worries , 
Only thing to note here is how V3 Deploys One more Pool contract for One more Currency Pair like ETH/USDC

And How UniswapV4 introduces single source approach to managing Thousands or Millions of pools .

V3 : https://docs.uniswap.org/assets/images/v3_detailed_architecture-783d0acdac88743c78dd8159ac4783ef.png
V4 : https://docs.uniswap.org/assets/images/v4_detailed_architecture-b3895cdac729e04810fd20fb046c170e.png


### Part 1 - Time for Actual Stuff  ( Protocol Fees)


We know that even in prior versions , uniswap had prtocol fees which could be activated when the governance wanted.

This is also true for Uni V4 , Each pool has some protocol fee to be charged that can vary from 0 to what is set in pool manager 
using `setProtocolFee` method which is defined inside ProtocolFees contract.

The function is defined as follows 

```solidity
    /// @inheritdoc IProtocolFees
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
        if (msg.sender != address(protocolFeeController)) InvalidCaller.selector.revertWith();
        if (!newProtocolFee.isValidProtocolFee()) ProtocolFeeTooLarge.selector.revertWith(newProtocolFee);
        PoolId id = key.toId();
        _getPool(id).setProtocolFee(newProtocolFee);
        emit ProtocolFeeUpdated(id, newProtocolFee);
    }

```
However , only `protocolFeeController` can call this method ( also called access controlled function )

```solidity

    function setProtocolFeeController(IProtocolFeeController controller) external onlyOwner {
        protocolFeeController = controller;
        emit ProtocolFeeControllerUpdated(address(controller));
    }

```
The protocol fee is fetched via an internal function `_fetchProtocolFee` makes a call to `protocolFeeController`
to get the protocol fee and return it .

However there is an important thing to note in its code which is `controllerGasLimit` which is the amount of gas 
this contract will forward to query the protocol fee which is set inside constructor of ProtocolFees contract.


```solidity

      controllerGasLimit = _controllerGasLimit;
    
```

This is important because if during execution , the gas left is not sufficient , its better to fail early than to make a low level call.


Now coming to the code of `_fetchProtocolFee`

```solidity
 function _fetchProtocolFee(PoolKey memory key) internal returns (bool success, uint24 protocolFee) {
        if (address(protocolFeeController) != address(0)) {
            // note that EIP-150 mandates that calls requesting more than 63/64ths of remaining gas
            // will be allotted no more than this amount, so controllerGasLimit must be set with this
            // in mind.
            if (gasleft() < controllerGasLimit) ProtocolFeeCannotBeFetched.selector.revertWith();

            uint256 gasLimit = controllerGasLimit;
            address toAddress = address(protocolFeeController);

            bytes memory data = abi.encodeCall(IProtocolFeeController.protocolFeeForPool, (key));
            uint256 returnData;
            assembly ("memory-safe") {
                success := call(gasLimit, toAddress, 0, add(data, 0x20), mload(data), 0, 0)

                // success if return data size is 32 bytes
                // only load the return value if it is 32 bytes to prevent gas griefing
                success := and(success, eq(returndatasize(), 32))

                // load the return data if success is true
                if success {
                    let fmp := mload(0x40)
                    returndatacopy(fmp, 0, returndatasize())
                    returnData := mload(fmp)
                    mstore(fmp, 0)
                }
            }

            // Ensure return data does not overflow a uint24 and that the underlying fees are within bounds.
            (success, protocolFee) = success && (returnData == uint24(returnData))
                && uint24(returnData).isValidProtocolFee() ? (true, uint24(returnData)) : (false, 0);
        }
    }
```

This is how it works :

- `protocolFeeController` is not set , it returns 0 as protocol fee.
- If `protocolFeeController` is set , it does following 
  - Check if the gas left in the transaction is sufficient in amount `if (gasleft() < controllerGasLimit)`
  - For the passed Pool key identifier as argument, it makes a function call to `protocolFeeController` contract's  `protocolFeeForPool` method which returns the protocol fee by making a low-level assembly language function call for gas efficiency and other optimization and safety reasons.
  
  - At the end of the execution , it checks if the call was successful and if the protocol fee is valid.
    Remember a protocol fee is valid only if following two cases are met :

    If the swap direction  dictated by `ZeroForOne` is `True` ( means we are selling token0 to buy token1) ,
    Or `ZeroForOne` is `False` , then for both cases , we have fee thresholds
    ```solidity
    uint24 internal constant FEE_0_THRESHOLD = 1001;
    uint24 internal constant FEE_1_THRESHOLD = 1001 << 12;

    ```
    Following conditions need to be hold 

    ```solidity
    assembly ("memory-safe") {
            let isZeroForOneFeeOk := lt(and(self, 0xfff), FEE_0_THRESHOLD)
            let isOneForZeroFeeOk := lt(and(self, 0xfff000), FEE_1_THRESHOLD)
            valid := and(isZeroForOneFeeOk, isOneForZeroFeeOk)
        }
    ```

    Don't worry about this scary inline assembly , it just cheks that 
      - If token0 is being sold , the fee MUST be less than `FEE_0_THRESHOLD`
      - If token1 is being sold , the fee MUST be less than `FEE_1_THRESHOLD`
      
       the `MUST be less than` part comes from assembly's `lt` operation which literally means `whether the first argument passed to it is less than the second one ` . i.e if a=1 , b=2 , `lt(a,b)` will return `True` and else otherwise .
      
       And the valid decision comes from `valid := and(isZeroForOneFeeOk, isOneForZeroFeeOk)` which checks if both conditions are met , then only is this fee valid otherwise it isn't .


    - After the fee has been validated , the protocol fee is returned from `_fetchProtocolFee`
     which is later used in other critical functions like `PoolManager#initalize` method to initalize the pool with protocol fee

     ```solidity
        (, uint24 protocolFee) = _fetchProtocolFee(key);

        tick = _pools[id].initialize(sqrtPriceX96, protocolFee, lpFee);
     ```

phewww !!

And that was all we needed to understand about ProtocolFees contract .

It was important to understand because our rockstar `PoolManager` contract inherits and uses it's above functions

So , as you Now have a deep low-level understanding of how protocol fees work , let's understand how Pool Manager contract works

### Part 2 :

Let's dive into PoolManager contract now .

Reminder that pool manager is the single contract that is used for 

- initialization
- Makings swaps
- Addition and removal of liquidity 

for and across different Pools .

#### Inheritance 

Pool Manager inherits from multiple base contracts , one of them being `ProtocolFees`
which we have discussed in the last part.

ProtocolFees helps Pool manager to get the updated fee data of the protocol using `_fetchProtocolFee`.

#### State Variables

```solidity
    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;

    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    mapping(PoolId id => Pool.State) internal _pools;

```
`MAX_TICK_SPACING` and `MIN_TICK_SPACING` are the boundries of ticks across which a pool can be initialized.

##### Ticks

If you are new to tick maths , Please refer Jeiwan's awesome UniswapV3Development Books's [Tick Maths](https://uniswapv3book.com/milestone_2/introduction.html) section.

However , in short , Uniswap V3 ( and V4 ) allows liquidity providers to provide their assets in a certain price range they want their assets to be traded in .

Instead of price ranges being `[a,b]` where `a` can be 0 and `b` being any valid price  let's say 100k$

the entire price range is now split in mutltiple small portions , each point being called a tick.

Feel free to have a refresher from above link .

Now a Tickspacing is the factor of usable ticks .

Let's say i have following tick range
```
__|___________|_________________|_
-1000         0              10000
```
and the individual ticks would look like 

```
_____|___|___|__|___|___|__|__|__|__|__|__|__|____
... -6  -5  -4 -3  -2  -1  0  1  2  3  4  5  6 .......

```

iF the tick factor is 1 , it means every one of the ticks are usable for the pool.

```
_____|___|___|__|___|___|__|__|__|__|__|__|__|____
... -6  -5  -4 -3  -2  -1  0  1  2  3  4  5  6 .......

```
If the tick space is 2 , it means every second tick is usable.

```
_____|_______|______|______|_____|_____|_____|____
... -6  -5  -4 -3  -2  -1  0  1  2  3  4  5  6 .......

```

If the tick space is 3 , it means every third tick is usable.

```
_____|__________|__________|________|________|___
... -6  -5  -4 -3  -2  -1  0  1  2  3  4  5  6 .......

```
In General , a tickspacing of N means every Nth tickspace on both sides of 0 because Tickspacing is Integer and not just an Unsigned Integer.

Now , as we know , what ticks are , there has to be certain upper and lower range in which liquidity is considered valid.

The max and minimum range is those two variables `MAX_TICK_SPACING` and `MIN_TICK_SPACING` which are nothing but 

the boundries of what are the valid tickspaces for uniswap v4 pools.

Now , the third state variable is following 

```solidity
    mapping(PoolId id => Pool.State) internal _pools;
```

`_pools` is an `internal` mapping that maps pool ids to their information strucure `Pool.State`.

First of all , `Why Internal visibility?` Uniswap V4 developers only allow the `_pools` information to be available to current smart contract and its child contracts and no other contract should be able to access it .

I believe that's what was on their mind because inside soldity `Internal state variables can be accessed only internally from the current contract or contract deriving from it (using inheritance) `

Now , What is `PoolId ` , well If we check the definition inside `types/PoolId.sol`,
Its nothing but an alias of `bytes32`

```solidity
type PoolId is bytes32;
```

with an additional function available to it that is used `for computing the ID of a pool`

```solidity
    function toId(PoolKey memory poolKey) internal pure returns (PoolId poolId) {
        assembly ("memory-safe") {
            poolId := keccak256(poolKey, mul(32, 5))
        }
    }
```

Each pool has following information 

- currency0;
- currency1;
- fee;
- tickSpacing;
- hooks;

In our contract , this infomation is encompassed into PoolKey struct , which is hashed inside `toId` method to determine the `Pool id`

```solidity
/// @notice Returns the key for identifying a pool
struct PoolKey {

    /// @notice The lower currency of the pool, sorted numerically
    Currency currency0;
    /// @notice The higher currency of the pool, sorted numerically
    Currency currency1;
    /// @notice The pool swap fee, capped at 1_000_000. If the highest bit is 1, the pool has a dynamic fee and must be exactly equal to 0x800000
    uint24 fee;
    /// @notice Ticks that involve positions must be a multiple of tick spacing
    int24 tickSpacing;
    /// @notice The hooks of the pool
    IHooks hooks;

|}
```
Now if we check the way `keccak256` hash function is used inside the assembly block :

```solidity
    poolId := keccak256(poolKey, mul(32, 5))
```
The `first argument is the struct reference` and `second argument is  number of bytes`
since there are 5 entries and each size at max can be 32 byes long , we are giving number of bytes to be 32*5.
Here i thought well about packing variables but i beleive that does not happen in struct declaration rather it happens in declaring state variables hence we are giving the size of pool key to be each 32 bytes or 256 Bits long and there are 5 entries so `mul(32,5)`

I hope it makes sense.

Now let's jump out from this .

We see we were in the state variable exploration of `Pool Manager`.

Now we understand that following mapping will map Pool's calculated Unique Identifier to it's state 

```solidity
mapping(PoolId id => Pool.State) internal _pools;
```

Where `Pool.State` contains critical changing information about the pools like current slot0 price, liquidity ,ticks,positions etc.

```solidity
    /// @dev The state of a pool
    struct State {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 => TickInfo) ticks;
        mapping(int16 => uint256) tickBitmap;
        mapping(bytes32 => Position.Info) positions;
    }
```
Okey , so after state variables , we have got modifiers.

Inside Pool Manager , we have only one modifier

```solidity
    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!Lock.isUnlocked()) ManagerLocked.selector.revertWith();
        _;
    }

```
Which is intended to let the execution happen only if the contract is Not Locked.

##### Lock

Now , what is meant by lock ?
Inside PoolManager , Uniswap has launched a special lock mechanism that restricts the arbitrary actions and any 
critical action needs to first acquire lock before performing any series of actions.

Following actions use this modifier ( These actions are performed only if contratc is unlocked )

- Modify Liquidity
- Swap
- Donate
- Take
- Settle
- Clear
- Mint
- Burn

Later we shall see each action in detail.

But how this lock mechanism works at the code level , good point.
This is acheieved by `unlock` function inside PoolManager.

```solidity
/// @notice All interactions on the contract that account deltas require unlocking. A caller that calls `unlock` must implement
/// `IUnlockCallback(msg.sender).unlockCallback(data)`, where they interact with the remaining functions on this contract.
/// @dev The only functions callable without an unlocking are `initialize` and `updateDynamicLPFee`
/// @param data Any data to pass to the callback, via `IUnlockCallback(msg.sender).unlockCallback(data)`
/// @return The data returned by the call to `IUnlockCallback(msg.sender).unlockCallback(data)`

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();

        Lock.unlock();

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
        Lock.lock();
    }
```
Now what is function does ? as stated by Natspec and i will paraphrase it :

- Any action that requires the change in account's assets ( addition or subtraction ) is effectively a change in account's delta.
- Any action that requies change in delta must first acquire the lock by calling `unlock` method.
- Inside one set of transaction , a lock can notb be acquired more than once

```solidity
        if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();
```

- Inside this function,the user is given the lock 

```solidity
        Lock.unlock();
```
- Now , The caller , must implement `unlockCallback` function which Pool manager calls and hands over its 
  immediate execution to the caller. Now that `unlockCallback` will look like a similar function to what we already write i.e

```solidity

function unlockCallback(bytes data)external{
    // Series of PoolManager's state changing transactions i.e swap , modifyLiquidity,mint,burn,settle,take
}

```
- Now inside the callback , the user or caller will perform certain state-changing or account's detla changing actions that when are executed , the execution flow will come back to the `unlock` method's following line 

```solidity
        if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
        Lock.lock();
```
The unlock function now will check if all the debt accrued during the transactions to the caller has been paid by the caller. If debt has been paid what was supposed to , `NonzeroDeltaCount` will be `0` , otherwise it will be `!=0` which means something bad happen or caller has tried to game the protocol by not paying sufficient debt 
and the transactino will revert.

If the delta count is zero , the contract will be locked again and transaction will be successful again.

#### Functions 

Now its time to explore functinos :

```solidity
    constructor(uint256 controllerGasLimit) ProtocolFees(controllerGasLimit) {}
```

Recall from previous part on `ProtocolFees`, Here we set the minimum Controller gas limit that we declare is considered sufficient to make a call to `protocolFeeController` and fetch the `protocol fee`.

Now it's time to analyze critical functions.

##### Initialize

```solidity
 function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        noDelegateCall
        returns (int24 tick)
    
```

The function expects following params :

- Pool key , which if you remember , is calculated by hashing all the information of pool like currencies , fees etc.
- sqrtPriceX96 , which is the square root of actual price multiplied 2**96 to deal with floating point precision because solidity inherently does not support float numbers
- hookData is the data that will be passed to the hooks .
  Now see hooks are the new feature introduced by V4 using which you can embed custom logic during the state changing action of the pool . For example , you can build a hook that is executed during the swap that decides whether you should continue your swap or close it when the price is not in your favor . Hooks allows much more than that and we will see them in the next lessons . But here inside initialize method , we have two hooks 

  - BeforeInitializeHook
  - AfterInitializeHook
  
  These hooks are called as shown by their name before and after the initialization of the poool.
  This data is passed down to those hooks 

  ```solidity
        key.hooks.beforeInitialize(key, sqrtPriceX96, hookData);
        // rest of the code
        key.hooks.afterInitialize(key, sqrtPriceX96, tick, hookData);
  ```

This function has a modifer `nonDelegateCall` which prevents delegatecall to itself from some other contract .
While the purpose of this prevention is not clear to me but i beleive there are some future considerations that
devs have considered which maybe revealed later.

Now , time to dig deep into the implementation

###### The pre-conditions :

```solidity
        // see TickBitmap.sol for overflow conditions that can arise from tick spacing being too large
        if (key.tickSpacing > MAX_TICK_SPACING) TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) TickSpacingTooSmall.selector.revertWith(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }
        if (!key.hooks.isValidHookAddress(key.fee)) Hooks.HookAddressNotValid.selector.revertWith(address(key.hooks));

```

The `initialization` of the pool is valid if

- key tickspacing is in valid range 
- Currencies are sorted ( smaller one first and larger one later when sorted in ascending order )
- The hook address must be valid.
###### Hooks and its types
The validation of a hook address is an interesting part and we will explore more in depth when creating one for ourself but for now . There are multiple types of hooks :


* **BeforeInitialize:** Invoked before a pool is initialized.
* **AfterInitialize:** Invoked after a pool is initialized.
* **BeforeAddLiquidity:** Invoked before liquidity is added to a pool.
* **AfterAddLiquidity:** Invoked after liquidity is added to a pool.
* **BeforeRemoveLiquidity:** Invoked before liquidity is removed from a pool.
* **AfterRemoveLiquidity:** Invoked after liquidity is removed from a pool.
* **BeforeSwap:** Invoked before a swap occurs in a pool.
* **AfterSwap:** Invoked after a swap occurs in a pool.
* **BeforeDonate:** Invoked before tokens are donated to a pool.
* **AfterDonate:** Invoked after tokens are donated to a pool.

Remember that `Each hook address is generated through adding the very corresponing flags that hook has been designed for`. 

For example , if a hook is made for `BeforeSwap`, and has some address like 0xabcd.... , then when it is converted to binary from its current hex representation ,  at its `128th position` , the entry  must be `1` instead of 0.

as dictated by following variable in `Hooks.sol`

```solidity
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
```

You can see the requirements for other hooks in Hooks.sol as well

```solidity
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;

    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;

    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;

    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;

    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;

    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0;

```
So now coming back to validation of the hook , the `isValidHookAddress` checks if the address contains valid hooks 
by doing complex bit shift operations and checking if the element at that position is 1 or not .

```solidity
    function isValidHookAddress(IHooks self, uint24 fee) internal pure returns (bool) {
        // The hook can only have a flag to return a hook delta on an action if it also has the corresponding action flag
        if (!self.hasPermission(BEFORE_SWAP_FLAG) && self.hasPermission(BEFORE_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (!self.hasPermission(AFTER_SWAP_FLAG) && self.hasPermission(AFTER_SWAP_RETURNS_DELTA_FLAG)) return false;
        if (!self.hasPermission(AFTER_ADD_LIQUIDITY_FLAG) && self.hasPermission(AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG))
        {
            return false;
        }
        if (
            !self.hasPermission(AFTER_REMOVE_LIQUIDITY_FLAG)
                && self.hasPermission(AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) return false;

        // If there is no hook contract set, then fee cannot be dynamic
        // If a hook contract is set, it must have at least 1 flag set, or have a dynamic fee
        return address(self) == address(0)
            ? !fee.isDynamicFee()
            : (uint160(address(self)) & ALL_HOOK_MASK > 0 || fee.isDynamicFee());
    }
```

We will visit this in detail later but this is more than enough for understanding now .

###### Core Logic

Coming back to `Initialize` method of `Pool Manager`

```solidity
        uint24 lpFee = key.fee.getInitialLPFee();

        key.hooks.beforeInitialize(key, sqrtPriceX96, hookData);

        PoolId id = key.toId();
        (, uint24 protocolFee) = _fetchProtocolFee(key);

        tick = _pools[id].initialize(sqrtPriceX96, protocolFee, lpFee);

        key.hooks.afterInitialize(key, sqrtPriceX96, tick, hookData);

        // emit all details of a pool key. poolkeys are not saved in storage and must always be provided by the caller
        // the key's fee may be a static fee or a sentinel to denote a dynamic fee.
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick);

```


The function does following tasks 

- Get the Liquidity provider fee 
- Call `beforeInitialize` hook with current data and on-chain conditions to do some pre-processing or execute some custom logic 
- Get protocol fee.
- Using Pool's id , initalize the pool with all the needed information
- Call the `afterInitialize` to do some post-processing with custom logic.
- Emit `Initialize` event so that off-chain services can see the critical changes and might update their services accordingly .


And pheww !!!

That was it , You have understood the very low-level details source code upto Pool initalization function .


## Writing your Hook 

### Setup BoilerPlate using V4-template
Well , if you've made till now , writing your First hook will feel like a breeze to you .

For speeding things up , we will use [Uniswap foundation's V4-Template](https://github.com/uniswapfoundation/v4-template) that will setup all the boiler plater stuff for us like 
creating foundry project , installing v4 contractsetc.

Follow following steps 

- Install foundry 
- Clone the V4 template repo using 

```bash
git clone https://github.com/uniswapfoundation/v4-template
```
- Run `cd v4-template` in the same terminal 
- Run 

```bash
forge build
```
- And later run tests to see if everything is working 

```bash
forge test
``` 

#### Writing your Hook contract

Now its time to write our custom hook contract.
For simplicity , we will develop a very simple Hook contract for following hooks

- beforeInitialize
- afterAinitialize

that if you remember are called inside the `initialize` function of pool manager.

Our hook contract will not do anything fancy here rather it will just update a storage mapping with a value increment which can be verified later to see that this hook was really executed.

Now if you remember , the available hooks are follows :

* **beforeInitialize:** Invoked before a pool is initialized.
* **afterInitialize:** Invoked after a pool is initialized.
* **beforeAddLiquidity:** Invoked before liquidity is added to a pool.
* **afterAddLiquidity:** Invoked after liquidity is added to a pool.
* **beforeRemoveLiquidity:** Invoked before liquidity is removed from a pool.
* **afterRemoveLiquidity:** Invoked after liquidity is removed from a pool.
* **beforeSwap:** Invoked before a swap occurs in a pool.
* **afterSwap:** Invoked after a swap occurs in a pool.
* **beforeDonate:** Invoked before tokens are donated to a pool.
* **afterDonate:** Invoked after tokens are donated to a pool.

We will use the same naming convention when writing our hook callbacks needed for hooks to  to be called .

for example , to make a hook contract have ability to be called on `beforeInitialize` and `afterInitialize` ,

we will use the same naming convention to implement our callbacks 

```solidity
function beforeInitialize(args){
    //code
}
function afterInitialize(args){
    //code
}

```

remember that the return values ,arguments and implementation can be different.

To really see what interface our hook functions must really adhere to ,

headover to `v4-periphery/src/base/hooks/BaseHook.sol` and shall see

```solidity
    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }


```

Recall the `virtual` functions are used to implement `Polymorphism` where the functions defined inside the Parent contract can be implemented and behave differently inside the child contract . [Check this article on Polymorphism](https://www.geeksforgeeks.org/cpp-polymorphism/) for better understanding.

Now , here's our Hook contract inside `src/InitializeHook.sol`


```solidity

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

contract InitializeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    bool public beforeInitializeCalled;
    bool public afterInitializeCalled;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override returns (bytes4) {
        beforeInitializeCalled=true;
        return (BaseHook.beforeInitialize.selector);
    }
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata
    ) external override returns (bytes4) {
        afterInitializeCalled=true;
        return (BaseHook.afterInitialize.selector);
    }
}


```

We start off with some needed imports 

```solidity
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

```

Then we inherit our Hook contract from `BaseHook` to have access to all the hook definitions

Then we are using the `PoolIdLibrary` to get access to the different functions we might need.

```solidity
    using PoolIdLibrary for PoolKey;
```

Inside `constructor` , we are doing nothing but adjacent to that , we are initalizing our contract as `baseHook` 

with the parameter as `PoolManager` address 
```solidity
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}
```

Remember BaseHook functions only are allowed to be called by specified `PoolManager`

```solidity
// Inside BaseHook

    constructor(IPoolManager _manager) SafeCallback(_manager) {
        validateHookAddress(this);
    }


// Inside SafeCallback.sol
    modifier onlyByPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

```


Now , we have , for our custom hook , two variables are there just to signal if our hook callbacks are called

```solidity
    bool public beforeInitializeCalled;
    bool public afterInitializeCalled;

```

We have a main function that actually dictates if our hook is getting deployed with correct permissions or not 

```solidity
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

```

This is our bread and butter - the very core function that decides if our hook gets even deployed in the first place.

See inside this function , for our hook contract , we allowed only two hooks to be used and those are 
- beforeInitialize
- afterInitialize

These are set to True and rest are false.

Now , since we are inheriting from `BaseHook`, inside the constructor of baseHook

```solidity
    constructor(IPoolManager _manager) SafeCallback(_manager) {
        validateHookAddress(this);
    }
```
we call `validateHookAddress(this)` which does following 

```solidity
    // this function is virtual so that we can override it during testing,
    // which allows us to deploy an implementation to any address
    // and then etch the bytecode into the correct address
    function validateHookAddress(BaseHook _this) internal pure virtual {
        Hooks.validateHookPermissions(_this, getHookPermissions());
    }

```

It fetches the permissions , decode the address and compare it with allowed permissions to see if the hook address actually contains those hooks bits as 1 or invalid hook is being deployed .

I've written a great explanation of how hook flags and hook addresses work in the test section , let me add it here too 

```solidity
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

```

Now , coming back , `getHookPermissions` is our one of very core methods to validate our hooks implementation.


Then here are our callbacks 

```solidity
// -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override returns (bytes4) {
        beforeInitializeCalled=true;
        return (BaseHook.beforeInitialize.selector);
    }
    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24,
        bytes calldata
    ) external override returns (bytes4) {
        afterInitializeCalled=true;
        return (BaseHook.afterInitialize.selector);
    }
    
```

In our first hook , all they do is update a state variable and return the Basehook's selector for the particular hook they were called for .

And that's it for writing our first hook.


####  Last Step : Writing Tests for your Hook Contract

Now all you need to do is make a test file named `InitializeHook.t.sol` in `test` directory.

```solidity
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

    uint256 tokenId;
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

```

We start off with needed imports ,and use some libraries for our contract :

```solidity
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

```

We then have some state variables that will be useful later.

```solidity

    InitializeHook hook;
    PoolId poolId;
    PositionConfig config;
```
Our `setup` function is empty . Most tests you're gonna see has some pre-requisites to be done.
Those things are done in the `setup1 function of each Test file in foundry.

However , we don't essentially need it

```solidity
    function setUp() public {}
```
## InitializeHooks Test :

Our Main function is following 

```solidity
    function test_InitializeHooks() external 
```

This function contains very detailed implementation from 0 to hero.

This function is highly commented so that we don't have much on text level .

However , here's a summary of it ( I've used AI for that ) :


* **Contracts Deployed:**
    * Pool Manager (`manager_`)
    * ProtocolFeeControllerTest (`feeController_`) - Controls protocol fees
    * MockERC20 tokens (USDC, AAVE) - Simulate ERC20 tokens
    * InitializeHook (`initializeHook`) - Custom hook with BeforeInitialize and AfterInitialize logic

* **Token Setup:**
    * `USDC` and `AAVE` tokens are minted with a total supply of 10e20.
    * Tokens are sorted numerically (`token0`, `token1`).

* **InitializeHook Configuration:**
    * Deployed with flags for `beforeInitialize` and `afterInitialize` hooks.
    * Flags are used to determine which hooks the contract supports.

* **Pool Creation:**
    * Pool key is created with tokens (`token0`, `token1`), fee tier (3000), and IHook (`initializeHook`).
    * Pool is initialized by the Pool Manager.

* **Liquidity Provision:**
    * Full-range liquidity is provided to the pool using `positionConfig`.

* **Assertions:**
    * Verifies that both `beforeInitialize` and `afterInitialize` functions of the hook were called.

But the code comments are better i would say . Keep an eye on them.

Feel free to read each comment and go through the process.

When you are done reviewing the code , and has implemented on your end , 

It's time to run your first Hook based test using our favorite `forge`

```bash
forge test --mt test_InitializeHooks --via-ir -vvvvv
```

`--mt` to match and run only our target test `test_InitializeHooks`
`-vvvvv` for 5th level verbosity or details


If everything was implemented successfully , you should see a trace like this 

```bash
### very long trace behind
###  .........
    ├─ [57102] PoolManager::initialize(PoolKey({ currency0: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, currency1: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, fee: 3000, tickSpacing: 60, hooks: 0x0000000000000000000000000000000000003000 }), 79228162514264337593543950336 [7.922e28], 0x)
    │   ├─ [22990] 0x0000000000000000000000000000000000003000::beforeInitialize(InitializeHookTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], PoolKey({ currency0: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, currency1: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, fee: 3000, tickSpacing: 60, hooks: 0x0000000000000000000000000000000000003000 }), 79228162514264337593543950336 [7.922e28], 0x)
    │   │   └─ ← [Return] 0x3440d82000000000000000000000000000000000000000000000000000000000
    │   ├─ [1104] 0x0000000000000000000000000000000000003000::afterInitialize(InitializeHookTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], PoolKey({ currency0: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, currency1: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, fee: 3000, tickSpacing: 60, hooks: 0x0000000000000000000000000000000000003000 }), 79228162514264337593543950336 [7.922e28], 0, 0x)
    │   │   └─ ← [Return] 0xa910f80f00000000000000000000000000000000000000000000000000000000
    │   ├─ emit Initialize(id: 0x3028868e330056d8b8eb33861acc05f54f6cc1d2f217f4f0dc9490a9deb5f917, currency0: MockERC20: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], currency1: MockERC20: [0xF62849F9A0B5Bf2913b396098F7c7019b51A820a], fee: 3000, tickSpacing: 60, hooks: 0x0000000000000000000000000000000000003000, sqrtPriceX96: 79228162514264337593543950336 [7.922e28], tick: 0)
    │   └─ ← [Return] 0
    ├─ [397] 0x0000000000000000000000000000000000003000::beforeInitializeCalled() [staticcall]
    │   └─ ← [Return] true
    ├─ [0] VM::assertEq(true, true) [staticcall]
    │   └─ ← [Return] 
    ├─ [363] 0x0000000000000000000000000000000000003000::afterInitializeCalled() [staticcall]
    │   └─ ← [Return] true
    ├─ [0] VM::assertEq(true, true) [staticcall]
    │   └─ ← [Return] 
    └─ ← [Stop] 
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 25.81ms (9.29ms CPU time)

Ran 1 test suite in 2.46s (25.81ms CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```

Aaaand That's it ...

**Congratulations, Master**

You've just leveled up your blockchain game. By building your very own Uniswap v4 hook, you've become part of an elite crew that truly *gets* the nuts and bolts of this new paradigm .

**Diving deep into the v4-core source code and even exploring assembly-level details?** That's next-level stuff. You're not just a developer; you're a blockchain Ninja.

**Not only have you learned how Uniswap v4 works, but you've also gained the power to bend it to your will.** Your custom hook is a testament to your skill and dedication.

**So, pat yourself on the back.** You've earned it. Your hard work and dedication have paid off, and you're now a force to be reckoned with in the world of decentralized finance.

And here's the koala that is here to thank you for putting in that work man .


