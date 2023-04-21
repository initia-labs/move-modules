module launch::lock_staking {
    use std::error;
    use std::signer;
    use std::vector;
    use std::option::Option;
    use std::string::String;
    use std::event::{Self, EventHandle};
    use std::type_info::type_name;

    use initia_std::native_uinit::Coin as RewardCoin;
    use initia_std::staking::{Self, Delegation, DelegationResponse};
    use initia_std::block;
    use initia_std::coin::{Self, Coin};
    use initia_std::dex;
    use initia_std::decimal128;

    // Errors

    const ELOCK_STAKING_END: u64 = 1; 
    const ELOCK_STAKING_IN_PROGRESS: u64 = 2;
    const ELS_STORE_NOT_FOUND: u64 = 3;
    const ELS_STORE_ALREADY_EXISTS: u64 = 4;
    const EINVALID_LOCK_TYPE: u64 = 5;
    const EMODULE_OPERATION: u64 = 6;
    const EINVALID_INDEX: u64 = 7;
    const ENOT_RELEASED: u64 = 8;

    struct ModuleStore<phantom BondCoin> has key {
        lock_periods: vector<u64>,
        reward_weights: vector<u64>,
        share_sum: u64,
        // total reward pool
        reward: Coin<RewardCoin>,
        reward_amount: u64,
        end_time: u64,
        lock_events: EventHandle<LockEvent>,
        claim_events: EventHandle<ClaimEvent>,
    }

    struct LSStore<phantom BondCoin> has key {
        entries: vector<LSEntry<BondCoin>>,
        deposit_events: EventHandle<DepositEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
    }

    struct LSEntry<phantom BondCoin> has store {
        delegation: Delegation<BondCoin>,
        release_time: u64,
        // reward share
        share: u64,
    }

    // Events

    struct LockEvent has drop, store {
        coin_type: String,
        bond_amount: u64,
        release_time: u64,
        share: u64,
    }

    struct ClaimEvent has drop, store {
        coin_type: String,
        reward_amount: u64,
        delegation_reward_amount: u64,
        share: u64
    }

    struct DepositEvent has drop, store {
        delegation: DelegationInfo,
        release_time: u64,
        share: u64
    }

    struct WithdrawEvent has drop, store {
        delegation: DelegationInfo,
        release_time: u64,
        share: u64
    }

    // copy structure of DelegationResponse with store
    struct DelegationInfo has drop, store {
        validator: String,
        share: u64,
        unclaimed_reward: u64,
    }

    // Responses

    struct ModuleStoreResponse has drop {
        lock_periods: vector<u64>,
        reward_weights: vector<u64>,
        share_sum: u64,
        reward_amount: u64,
        end_time: u64,
    }

    struct LSEntryResponse has drop {
        delegation: DelegationResponse,
        release_time: u64,
        share: u64,
    }

    public entry fun initialize<BondCoin>(m: &signer, lock_periods: vector<u64>, reward_weights: vector<u64>) {
        move_to(m, ModuleStore<BondCoin> {
            lock_periods,
            reward_weights,
            share_sum: 0,
            reward: coin::zero(),
            reward_amount: 0,
            end_time: 0,
            lock_events: event::new_event_handle<LockEvent>(m),
            claim_events: event::new_event_handle<ClaimEvent>(m),
        });
    }

    // ViewFunctions

    /// util function to convert LSEntry to LSEntryResponse for third party queriers
    public fun get_ls_entry_response_from_ls_entry<BondCoin>(ls_entry: &LSEntry<BondCoin>): LSEntryResponse {
        let delegation_res = staking::get_delegation_response_from_delegation<BondCoin>(&ls_entry.delegation);
        LSEntryResponse {
            delegation: delegation_res,
            release_time: ls_entry.release_time,
            share: ls_entry.share,
        }
    }

    #[view]
    public fun get_module_store<BondCoin>(): ModuleStoreResponse acquires ModuleStore {
        let m_store = borrow_global<ModuleStore<BondCoin>>(@launch);
        ModuleStoreResponse {
            lock_periods: m_store.lock_periods,
            reward_weights: m_store.reward_weights,
            share_sum: m_store.share_sum,
            reward_amount: m_store.reward_amount,
            end_time: m_store.end_time,
        }
    }
    
    #[view]
    public fun get_ls_entries<BondCoin>(addr: address): vector<LSEntryResponse> acquires LSStore {
        if (!exists<LSStore<BondCoin>>(addr)) {
            return vector[]
        };

        let ls_store = borrow_global<LSStore<BondCoin>>(addr);

        let res = vector::empty<LSEntryResponse>();
        let len = vector::length(&ls_store.entries);
        let i = 0;
        while( i < len ) {
            let ls_entry = vector::borrow(&ls_store.entries, i);
            vector::push_back(&mut res, get_ls_entry_response_from_ls_entry(ls_entry));
            i = i + 1;
        };
        
        res
    }

    #[view]
    public fun is_lock_staking_in_progress<BondCoin>(): bool acquires ModuleStore{
        let m_store = borrow_global_mut<ModuleStore<BondCoin>>(@launch);

        // check lock staking end time
        let (_, block_time) = block::get_block_info();
        block_time < m_store.end_time
    }

    // EntryFunctions

    /// Configure end_time with reward coin deposit.
    /// `config` can be executed until lock_staking finished
    /// to add more rewards or to change end_time.
    public entry fun config<BondCoin>(m: &signer, reward_amount: u64, end_time: u64) acquires ModuleStore {
        let account_addr = signer::address_of(m);
        assert!(account_addr == @launch, error::unauthenticated(EMODULE_OPERATION));

        let m_store = borrow_global_mut<ModuleStore<BondCoin>>(account_addr);

        if (reward_amount > 0) {
            // withdarw rewards from module coin store
            let reward = coin::withdraw<RewardCoin>(m, reward_amount);
            
            // deposit coin to module store
            coin::merge(&mut m_store.reward, reward);
            m_store.reward_amount = m_store.reward_amount + reward_amount;
        };

        // adding more rewards or chaning end_time can be changed
        // until lock staking ended.
        let (_, block_time) = block::get_block_info();
        assert!(end_time > block_time, error::unavailable(ELOCK_STAKING_END));
        assert!(m_store.end_time == 0 || m_store.end_time > block_time, error::unavailable(ELOCK_STAKING_END));

        let i = 0;
        let len = vector::length(&m_store.lock_periods);
        while(i < len) {
            assert!(end_time < block_time + *vector::borrow(&m_store.lock_periods, i), error::unavailable(ELOCK_STAKING_END)) ;
            i = i+1;
        };

        m_store.end_time = end_time;
    }

    /// publish LSStore for a user
    public entry fun register<BondCoin>(account: &signer) {
        assert!(!exists<LSStore<BondCoin>>(signer::address_of(account)), error::already_exists(ELS_STORE_ALREADY_EXISTS));
        move_to(account, LSStore<BondCoin>{
            entries: vector::empty(),
            deposit_events: event::new_event_handle<DepositEvent>(account),
            withdraw_events: event::new_event_handle<WithdrawEvent>(account),
        });
    }

    /// Entry function for lock stake
    public entry fun lock_stake_script<BondCoin>(account: &signer, validator: String, lock_type: u64, amount: u64) acquires LSStore, ModuleStore {
        let account_addr = signer::address_of(account);
        if (!exists<LSStore<BondCoin>>(account_addr)) {
            register<BondCoin>(account);
        };

        let lock_coin = coin::withdraw<BondCoin>(account, amount);
        let ls_entry = lock_stake<BondCoin>(validator, lock_type, lock_coin);

        // deposit lock stake to account store
        deposit_lock_stake_entry(account_addr, ls_entry);
    }

    public entry fun provide_lock_stake_script<CoinA, CoinB, BondCoin>(
        account: &signer,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String,
        lock_type: u64,
    ) acquires LSStore, ModuleStore {
        let addr = signer::address_of(account);
        let pool_info = dex::get_pool_info<CoinA, CoinB, BondCoin>();
        let coin_a_amount = dex::get_coin_a_amount_from_pool_info_response(&pool_info);
        let coin_b_amount = dex::get_coin_b_amount_from_pool_info_response(&pool_info);
        let total_share = coin::supply<BondCoin>();

        // calculate the best coin amount
        let (coin_a, coin_b) = if (total_share == 0) {
            (
                coin::withdraw<CoinA>(account, coin_a_amount_in),
                coin::withdraw<CoinB>(account, coin_b_amount_in),
            )
        } else {
            let coin_a_share_ratio = decimal128::from_ratio_u64(coin_a_amount_in, coin_a_amount);
            let coin_b_share_ratio = decimal128::from_ratio_u64(coin_b_amount_in, coin_b_amount);
            if (decimal128::val(&coin_a_share_ratio) > decimal128::val(&coin_b_share_ratio)) {
                coin_a_amount_in = decimal128::mul_u64(&coin_b_share_ratio, coin_a_amount);
            } else {
                coin_b_amount_in = decimal128::mul_u64(&coin_a_share_ratio, coin_b_amount);
            };

            (
                coin::withdraw<CoinA>(account, coin_a_amount_in),
                coin::withdraw<CoinB>(account, coin_b_amount_in),
            )
        };

        let liquidity_token = dex::provide_liquidity<CoinA, CoinB, BondCoin>(
            account,
            coin_a,
            coin_b,
            min_liquidity,
        );

        let liquiidty_amount = coin::value(&liquidity_token);

        if (!coin::is_account_registered<BondCoin>(signer::address_of(account))) {
            coin::register<BondCoin>(account);
        };

        coin::deposit(addr, liquidity_token);
        lock_stake_script<BondCoin>(account, validator, lock_type, liquiidty_amount);
    }

    public entry fun single_asset_provide_lock_stake_script<CoinA, CoinB, BondCoin, ProvideCoin>(
        account: &signer,
        amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String,
        lock_type: u64,
    ) acquires LSStore, ModuleStore {
        let addr = signer::address_of(account);
        let provide_coin = coin::withdraw<ProvideCoin>(account, amount_in);

        let liquidity_token = dex::single_asset_provide_liquidity<CoinA, CoinB, BondCoin, ProvideCoin>(
            account,
            provide_coin,
            min_liquidity,
        );

        let liquiidty_amount = coin::value(&liquidity_token);

        if (!coin::is_account_registered<BondCoin>(signer::address_of(account))) {
            coin::register<BondCoin>(account);
        };

        coin::deposit(addr, liquidity_token);
        lock_stake_script<BondCoin>(account, validator, lock_type, liquiidty_amount);
    }

    public entry fun claim_script<BondCoin>(account: &signer, index: u64) acquires ModuleStore, LSStore {
        let account_addr = signer::address_of(account);
        let ls_entry = withdraw_lock_stake_entry<BondCoin>(account, index);

        // claim delegation with lock staking rewards
        let (delegation, reward) = claim<BondCoin>(ls_entry);

        // register account to staking module
        if (!staking::is_account_registered<BondCoin>(account_addr)) {
            staking::register<BondCoin>(account);
        };

        // deposit delegation to user address
        let d_reward = staking::deposit_delegation<BondCoin>(account_addr, delegation);

        // merge delegation rewards with lock staking rewards
        coin::merge(&mut reward, d_reward);

        // deposit rewards to account coin store
        coin::deposit(account_addr, reward);
    }

    public entry fun staking_reward_claim_script<BondCoin>(account: &signer, index: u64) acquires LSStore {
        let account_addr = signer::address_of(account);

        assert!(exists<LSStore<BondCoin>>(account_addr), error::not_found(ELS_STORE_NOT_FOUND));

        let ls_store = borrow_global_mut<LSStore<BondCoin>>(account_addr);
        assert!(vector::length(&ls_store.entries) > index, error::out_of_range(EINVALID_INDEX));

        let ls_entry = vector::borrow_mut(&mut ls_store.entries, index);
        let reward = staking_reward_claim(ls_entry);
        coin::deposit(account_addr, reward);
    }

    // Public Functions

    /// Execute lock staking and return created LSEntry
    public fun lock_stake<BondCoin>(validator: String, lock_type: u64, lock_coin: Coin<BondCoin>): LSEntry<BondCoin> acquires ModuleStore {
        assert!(lock_type < 4, error::out_of_range(EINVALID_LOCK_TYPE));

        let bond_amount = coin::value(&lock_coin);
        let delegation = staking::delegate<BondCoin>(validator, lock_coin);

        // after delegation, load module store to compute reward share
        let m_store = borrow_global_mut<ModuleStore<BondCoin>>(@launch);

        // check lock staking end time
        let (_, block_time) = block::get_block_info();
        assert!(m_store.end_time > block_time, error::unavailable(ELOCK_STAKING_END));

        let reward_weight = *vector::borrow<u64>(&m_store.reward_weights, lock_type);
        let lock_period = *vector::borrow<u64>(&m_store.lock_periods, lock_type);
        assert!(block_time + lock_period > m_store.end_time, error::unavailable(ELOCK_STAKING_END));

        let share = bond_amount * reward_weight;
        m_store.share_sum = m_store.share_sum + share;

        let (_, block_time) = block::get_block_info();

        // emit events
        event::emit_event<LockEvent>(
            &mut m_store.lock_events,
            LockEvent {
                coin_type: type_name<BondCoin>(),
                bond_amount,
                release_time: block_time + lock_period,
                share,
            }
        );

        LSEntry<BondCoin> {
            delegation,
            release_time: block_time + lock_period,
            share,
        }
    }

    // Deposit LSEntry to user's LSStore
    public fun deposit_lock_stake_entry<BondCoin>(account_addr: address, ls_entry: LSEntry<BondCoin>) acquires LSStore {
        assert!(exists<LSStore<BondCoin>>(account_addr), error::not_found(ELS_STORE_NOT_FOUND));
        
        // copy for event emit
        let delegation_res = staking::get_delegation_response_from_delegation<BondCoin>(&ls_entry.delegation);
        let release_time = ls_entry.release_time;
        let share = ls_entry.share;

        let ls_store = borrow_global_mut<LSStore<BondCoin>>(account_addr);
        vector::push_back(&mut ls_store.entries, ls_entry);

        // emit events
        event::emit_event<DepositEvent>(
            &mut ls_store.deposit_events,
            DepositEvent {
                delegation: delegation_res_to_delegation_info(&delegation_res),
                release_time,
                share,
            }
        );
    }

    /// Withdraw LSEntry of index
    public fun withdraw_lock_stake_entry<BondCoin>(account: &signer, index: u64): LSEntry<BondCoin> acquires LSStore {
        let account_addr = signer::address_of(account);
        assert!(exists<LSStore<BondCoin>>(account_addr), error::not_found(ELS_STORE_NOT_FOUND));

        let ls_store = borrow_global_mut<LSStore<BondCoin>>(account_addr);
        assert!(vector::length(&ls_store.entries) > index, error::out_of_range(EINVALID_INDEX));

        // O(n) cost, but want to keep the order for front UX
        let ls_entry = vector::remove(&mut ls_store.entries, index);

        let delegation_res = staking::get_delegation_response_from_delegation<BondCoin>(&ls_entry.delegation);

        // emit events
        event::emit_event<WithdrawEvent>(
            &mut ls_store.withdraw_events,
            WithdrawEvent {
                delegation: delegation_res_to_delegation_info(&delegation_res),
                release_time: ls_entry.release_time,
                share: ls_entry.share,
            }
        );

        ls_entry
    }

    /// Claim lock staking rewards with Delegation
    public fun claim<BondCoin>(ls_entry: LSEntry<BondCoin>): (Delegation<BondCoin>, Coin<RewardCoin>) acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore<BondCoin>>(@launch);

        // check time constranits
        let (_, block_time) = block::get_block_info();

        assert!(block_time > m_store.end_time, error::unavailable(ELOCK_STAKING_IN_PROGRESS));
        assert!(block_time > ls_entry.release_time, error::unavailable(ENOT_RELEASED));

        // destroy ls_entry
        let LSEntry<BondCoin> {
            delegation,
            release_time: _,
            share,
        } = ls_entry;

        // to prevent overflow
        let reward_amount = ((m_store.reward_amount as u128) * (share as u128) / (m_store.share_sum as u128) as u64);
        let reward = coin::extract(&mut m_store.reward, reward_amount);

        let delegation_res = staking::get_delegation_response_from_delegation<BondCoin>(&delegation);

        event::emit_event<ClaimEvent>(
            &mut m_store.claim_events,
            ClaimEvent {
                coin_type: type_name<BondCoin>(),
                reward_amount,
                delegation_reward_amount: staking::get_unclaimed_reward_from_delegation_response(&delegation_res),
                share,
            }
        );

        (delegation, reward)
    }
    
    public fun staking_reward_claim<BondCoin>(ls_entry: &mut LSEntry<BondCoin>): Coin<RewardCoin> {
        staking::claim_reward(&mut ls_entry.delegation)
    }

    fun delegation_res_to_delegation_info(delegation_res: &DelegationResponse): DelegationInfo {
        DelegationInfo {
            validator: staking::get_validator_from_delegation_response(delegation_res),
            unclaimed_reward: staking::get_unclaimed_reward_from_delegation_response(delegation_res),
            share: staking::get_share_from_delegation_response(delegation_res),
        }
    }

    ///////////////////////////////////////////////////////
    // Test

    #[test_only]
    use std::string;

    #[test_only]
    struct StakeCoin has store {}

    #[test_only]
    struct TestCapabilityStore<phantom CoinType> has key {
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    #[test_only]
    fun test_setup(c: &signer, m: &signer) {
        // coin setup
        coin::init_module_for_test(c);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<RewardCoin>(
            c,
            string::utf8(b"INIT Coin"),
            string::utf8(b"uinit"),
            6,
        );
        move_to(c, TestCapabilityStore<RewardCoin> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<StakeCoin>(
            m,
            string::utf8(b"Bond Coin"),
            string::utf8(b"ubond"),
            6,
        );
        move_to(m, TestCapabilityStore<StakeCoin> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });

        coin::register<RewardCoin>(m);

        // staking setup
        staking::initialize_for_test<StakeCoin>(c);
        staking::set_staking_share_ratio<StakeCoin>(b"val", 1, 1);

        // module setup
        let lock_periods = vector::empty();

        vector::push_back(&mut lock_periods, 60 * 60 * 24 /* a day */);
        vector::push_back(&mut lock_periods, 60 * 60 * 24 * 3 /* three days */);
        vector::push_back(&mut lock_periods, 60 * 60 * 24 * 6 /* six days */);
        vector::push_back(&mut lock_periods, 60 * 60 * 24 * 12 /* twleve days */);

        let reward_weights = vector::empty();
        vector::push_back(&mut reward_weights, 1);
        vector::push_back(&mut reward_weights, 4);
        vector::push_back(&mut reward_weights, 10);
        vector::push_back(&mut reward_weights, 25);

        initialize<StakeCoin>(m, lock_periods, reward_weights);
    }

    #[test_only]
    fun fund_reward(c_addr: address, m_addr: address, amt: u64) acquires TestCapabilityStore {
        let caps = borrow_global<TestCapabilityStore<RewardCoin>>(c_addr);
        let reward = coin::mint<RewardCoin>(amt, &caps.mint_cap);
        coin::deposit<RewardCoin>(m_addr, reward);
    }

    #[test_only]
    fun fund_bond(m_addr: address, u_addr: address, amt: u64) acquires TestCapabilityStore {
        let caps = borrow_global<TestCapabilityStore<StakeCoin>>(m_addr);
        let reward = coin::mint<StakeCoin>(amt, &caps.mint_cap);
        coin::deposit<StakeCoin>(u_addr, reward);
    }

    ////////////////////////////////////////////////////////
    // CONFIG TEST

    #[test(c = @0x1, m = @0x2)]
    fun test_config(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore, TestCapabilityStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 1003600);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // add more fund
        config<StakeCoin>(m, 1000000, 1003600);
        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 2000000, 1);

        // update end time
        config<StakeCoin>(m, 0, 1007200);
        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1007200, 0);
        assert!(res.reward_amount == 2000000, 1);
    }

    #[test(c = @0x1, m = @0x2)]
    #[expected_failure(abort_code = 0x10007, location = coin)]
    fun test_config_insufficient_funds(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore, TestCapabilityStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 1000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 2000000, 2000000);
    }

    #[test(c = @0x1, m = @0x2)]
    #[expected_failure(abort_code = 0xD0001, location = Self)]
    fun test_config_invalid_end_time(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore, TestCapabilityStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 1000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 1000000);
    }

    #[test(c = @0x1, m = @0x2)]
    #[expected_failure(abort_code = 0xD0001, location = Self)]
    fun test_config_invalid_end_time_at_update(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore, TestCapabilityStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 2000000);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 2000000, 0);
        assert!(res.reward_amount == 1000000, 1);

        // update end time to invalid one
        config<StakeCoin>(m, 0, 1000000);
    }

    ////////////////////////////////////////////////////////
    // LockStake TEST
    
    #[test(c = @0x1, m = @0x2, u = @0x3)]
    fun test_lock_stake(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 1003600);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        coin::register<StakeCoin>(u);
        fund_bond(signer::address_of(m), signer::address_of(u), 4000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 0, 1000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 1, 1000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 2, 1000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 3, 1000000);

        // view ls entries
        let m_store = get_module_store<StakeCoin>();
        let ls_entries = get_ls_entries<StakeCoin>(signer::address_of(u));
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 0).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 0), 0);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 1).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 1), 1);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 2).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 2), 2);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 3).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 3), 3);

        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 0).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 0), 0);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 1).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 1), 1);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 2).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 2), 2);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 3).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 3), 3);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x10007, location = coin)]
    fun test_lock_stake_insufficient_funds(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 1003600);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        coin::register<StakeCoin>(u);
        fund_bond(signer::address_of(m), signer::address_of(u), 1000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 0, 1000001);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x20005, location = Self)]
    fun test_lock_stake_invalid_lock_type(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 1003600);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        coin::register<StakeCoin>(u);
        fund_bond(signer::address_of(m), signer::address_of(u), 1000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 5, 1000000);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0xD0001, location = Self)]
    fun test_lock_stake_lock_staking_end(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config<StakeCoin>(m, 1000000, 1003600);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // update block time to end of lock staking
        let m_store = get_module_store<StakeCoin>();
        block::set_block_info(1, m_store.end_time+1);

        // execute lock stake
        coin::register<StakeCoin>(u);
        fund_bond(signer::address_of(m), signer::address_of(u), 1000000);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 0, 1000000);
    }

    ////////////////////////////////////////////////////////
    // Claim TEST

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    fun test_claim(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        coin::register<StakeCoin>(u);
        coin::register<RewardCoin>(u);

        block::set_block_info(1, 1000000);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        let reward_amount = 1000000;
        let end_time = 1003600;
        config<StakeCoin>(m, reward_amount, end_time);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == end_time, 0);
        assert!(res.reward_amount == reward_amount, 1);

        // execute lock stake
        let stake_amount = 1000000;
        fund_bond(signer::address_of(m), signer::address_of(u), 4 * stake_amount);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 0, stake_amount);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 1, stake_amount);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 2, stake_amount);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 3, stake_amount);

        let m_store = get_module_store<StakeCoin>();
        
        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 0) + 1);
        claim_script<StakeCoin>(u, 0);
        
        let claim_amount_0 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 0)) / m_store.share_sum;
        assert!(coin::balance<RewardCoin>(signer::address_of(u)) == claim_amount_0, 0);

        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 1) + 1);
        claim_script<StakeCoin>(u, 0);

        let claim_amount_1 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 1)) / m_store.share_sum;
        assert!(coin::balance<RewardCoin>(signer::address_of(u)) == claim_amount_0 + claim_amount_1, 1);

        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 2) + 1);
        claim_script<StakeCoin>(u, 0);

        let claim_amount_2 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 2)) / m_store.share_sum;
        assert!(coin::balance<RewardCoin>(signer::address_of(u)) == claim_amount_0 + claim_amount_1 + claim_amount_2, 2);

        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 3) + 1);
        claim_script<StakeCoin>(u, 0);
        
        let claim_amount_3 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 3)) / m_store.share_sum;
        assert!(coin::balance<RewardCoin>(signer::address_of(u)) == claim_amount_0 + claim_amount_1 + claim_amount_2 + claim_amount_3, 0);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0xD0002, location = Self)]
    fun test_claim_lock_staking_in_progress(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        coin::register<StakeCoin>(u);
        coin::register<RewardCoin>(u);

        block::set_block_info(1, 1000000);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        let reward_amount = 1000000;
        let end_time = 1003600;
        config<StakeCoin>(m, reward_amount, end_time);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == end_time, 0);
        assert!(res.reward_amount == reward_amount, 1);

        // execute lock stake
        let stake_amount = 1000000;
        fund_bond(signer::address_of(m), signer::address_of(u), 4 * stake_amount);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 0, stake_amount);
        
        block::set_block_info(1, end_time - 1);
        claim_script<StakeCoin>(u, 0);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0xD0008, location = Self)]
    fun test_claim_not_released(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, TestCapabilityStore, LSStore {
        test_setup(c, m);
        coin::register<StakeCoin>(u);
        coin::register<RewardCoin>(u);

        block::set_block_info(1, 1000000);
        fund_reward(signer::address_of(c), signer::address_of(m), 2000000);

        let reward_amount = 1000000;
        let end_time = 1003600;
        config<StakeCoin>(m, reward_amount, end_time);

        let res = get_module_store<StakeCoin>();
        assert!(res.end_time == end_time, 0);
        assert!(res.reward_amount == reward_amount, 1);

        // execute lock stake
        let stake_amount = 1000000;
        fund_bond(signer::address_of(m), signer::address_of(u), 4 * stake_amount);
        lock_stake_script<StakeCoin>(u, string::utf8(b"val"), 0, stake_amount);
        
        let m_store = get_module_store<StakeCoin>();
        
        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 0) - 1);
        claim_script<StakeCoin>(u, 0);
    }
}
