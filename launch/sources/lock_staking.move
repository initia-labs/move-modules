module launch::lock_staking {
    use std::error;
    use std::signer;
    use std::vector;
    use std::option::Option;
    use std::string::String;
    use std::event;

    use initia_std::staking::{Self, Delegation, DelegationResponse};
    use initia_std::block;
    use initia_std::coin;
    use initia_std::dex;
    use initia_std::primary_fungible_store;
    use initia_std::object::{Self, ExtendRef, Object};
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};

    // Errors

    const ELOCK_STAKING_END: u64 = 1; 
    const ELOCK_STAKING_IN_PROGRESS: u64 = 2;
    const ELS_STORE_NOT_FOUND: u64 = 3;
    const ELS_STORE_ALREADY_EXISTS: u64 = 4;
    const EINVALID_LOCK_TYPE: u64 = 5;
    const EMODULE_OPERATION: u64 = 6;
    const EINVALID_INDEX: u64 = 7;
    const ENOT_RELEASED: u64 = 8;

    struct ModuleStore has key {
        lock_periods: vector<u64>,
        reward_weights: vector<u64>,
        bond_coin_metadata: Object<Metadata>,
        reward_coin_metadata: Object<Metadata>,
        share_sum: u64,
        // total reward pool
        reward_store_extend_ref: ExtendRef,
        reward_amount: u64,
        end_time: u64,
    }

    struct LSStore has key {
        entries: vector<LSEntry>,
    }

    struct LSEntry has store {
        delegation: Delegation,
        release_time: u64,
        // reward share
        share: u64,
    }

    // Events

    struct LockEvent has drop, store {
        coin_metadata: address,
        bond_amount: u64,
        release_time: u64,
        share: u64,
    }

    struct ClaimEvent has drop, store {
        coin_metadata: address,
        reward_amount: u64,
        delegation_reward_amount: u64,
        share: u64
    }

    struct DepositEvent has drop, store {
        addr: address,
        delegation: DelegationInfo,
        release_time: u64,
        share: u64
    }

    struct WithdrawEvent has drop, store {
        addr: address,
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

    public entry fun initialize(m: &signer, bond_coin_metadata: Object<Metadata>, reward_coin_metadata: Object<Metadata>, lock_periods: vector<u64>, reward_weights: vector<u64>) {
        let reward_constructor_ref = object::create_object(@initia_std);
        let reward_store_extend_ref = object::generate_extend_ref(&reward_constructor_ref);

        move_to(m, ModuleStore {
            lock_periods,
            reward_weights,
            bond_coin_metadata,
            reward_coin_metadata,
            share_sum: 0,
            reward_store_extend_ref,
            reward_amount: 0,
            end_time: 0,
        });
    }

    // ViewFunctions

    /// util function to convert LSEntry to LSEntryResponse for third party queriers
    public fun get_ls_entry_response_from_ls_entry(ls_entry: &LSEntry): LSEntryResponse {
        let delegation_res = staking::get_delegation_response_from_delegation(&ls_entry.delegation);
        LSEntryResponse {
            delegation: delegation_res,
            release_time: ls_entry.release_time,
            share: ls_entry.share,
        }
    }

    #[view]
    public fun get_module_store(): ModuleStoreResponse acquires ModuleStore {
        let m_store = borrow_global<ModuleStore>(@launch);
        ModuleStoreResponse {
            lock_periods: m_store.lock_periods,
            reward_weights: m_store.reward_weights,
            share_sum: m_store.share_sum,
            reward_amount: m_store.reward_amount,
            end_time: m_store.end_time,
        }
    }
    
    #[view]
    public fun get_ls_entries(addr: address): vector<LSEntryResponse> acquires LSStore {
        if (!exists<LSStore>(addr)) {
            return vector[]
        };

        let ls_store = borrow_global<LSStore>(addr);

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
    public fun is_lock_staking_in_progress(): bool acquires ModuleStore{
        let m_store = borrow_global_mut<ModuleStore>(@launch);

        // check lock staking end time
        let (_, block_time) = block::get_block_info();
        block_time < m_store.end_time
    }

    // EntryFunctions

    /// Configure end_time with reward coin deposit.
    /// `config` can be executed until lock_staking finished
    /// to add more rewards or to change end_time.
    public entry fun config(m: &signer, reward_amount: u64, end_time: u64) acquires ModuleStore {
        let account_addr = signer::address_of(m);
        assert!(account_addr == @launch, error::unauthenticated(EMODULE_OPERATION));

        let m_store = borrow_global_mut<ModuleStore>(@launch);

        if (reward_amount > 0) {
            // withdarw rewards from module coin store
            let reward = primary_fungible_store::withdraw(m, m_store.reward_coin_metadata, reward_amount);

            // deposit coin to module store
            primary_fungible_store::deposit(object::address_from_extend_ref(&m_store.reward_store_extend_ref), reward);
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
    public entry fun register(account: &signer) {
        assert!(!exists<LSStore>(signer::address_of(account)), error::already_exists(ELS_STORE_ALREADY_EXISTS));
        move_to(account, LSStore{
            entries: vector::empty(),
        });
    }

    /// Entry function for lock stake
    public entry fun lock_stake_script(account: &signer, validator: String, lock_type: u64, amount: u64) acquires LSStore, ModuleStore {
        let account_addr = signer::address_of(account);
        if (!exists<LSStore>(account_addr)) {
            register(account);
        };

        let m_store = borrow_global_mut<ModuleStore>(@launch);

        let lock_coin = primary_fungible_store::withdraw(account, m_store.bond_coin_metadata, amount);
        let ls_entry = lock_stake(validator, lock_type, lock_coin);

        // deposit lock stake to account store
        deposit_lock_stake_entry(account_addr, ls_entry);
    }

    public entry fun provide_lock_stake_script(
        account: &signer,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        pair: Object<dex::Config>,
        min_liquidity: Option<u64>,
        validator: String,
        lock_type: u64,
    ) acquires LSStore, ModuleStore {
        let (_, _, liquidity_amount) = dex::provide_liquidity_from_coin_store(
            account,
            coin_a_amount_in,
            coin_b_amount_in,
            pair,
            min_liquidity,
        );

        lock_stake_script(account, validator, lock_type, liquidity_amount);
    }

    public entry fun single_asset_provide_lock_stake_script(
        account: &signer,
        provide_coin_metadata: Object<Metadata>,
        amount_in: u64,
        pair: Object<dex::Config>,
        min_liquidity: Option<u64>,
        validator: String,
        lock_type: u64,
    ) acquires LSStore, ModuleStore {
        let addr = signer::address_of(account);
        let m_store = borrow_global_mut<ModuleStore>(@launch);
        let provide_coin = primary_fungible_store::withdraw(account, provide_coin_metadata, amount_in);

        let liquidity_token = dex::single_asset_provide_liquidity(
            account,
            pair,
            provide_coin,
            min_liquidity,
        );

        let liquiidty_amount = fungible_asset::amount(&liquidity_token);

        primary_fungible_store::deposit(addr, liquidity_token);
        lock_stake_script(account, validator, lock_type, liquiidty_amount);
    }

    public entry fun claim_script(account: &signer, index: u64) acquires ModuleStore, LSStore {
        let account_addr = signer::address_of(account);
        let ls_entry = withdraw_lock_stake_entry(account, index);

        // claim delegation with lock staking rewards
        let (delegation, reward) = claim(ls_entry);

        // register account to staking module
        if (!staking::is_account_registered(account_addr)) {
            staking::register(account);
        };

        // deposit delegation to user address
        let d_reward = staking::deposit_delegation(account_addr, delegation);

        // merge delegation rewards with lock staking rewards
        fungible_asset::merge(&mut reward, d_reward);

        // deposit rewards to account coin store
        primary_fungible_store::deposit(account_addr, reward);
    }

    public entry fun staking_reward_claim_script(account: &signer, index: u64) acquires LSStore {
        let account_addr = signer::address_of(account);

        assert!(exists<LSStore>(account_addr), error::not_found(ELS_STORE_NOT_FOUND));

        let ls_store = borrow_global_mut<LSStore>(account_addr);
        assert!(vector::length(&ls_store.entries) > index, error::out_of_range(EINVALID_INDEX));

        let ls_entry = vector::borrow_mut(&mut ls_store.entries, index);
        let reward = staking_reward_claim(ls_entry);
        coin::deposit(account_addr, reward);
    }

    // Public Functions

    /// Execute lock staking and return created LSEntry
    public fun lock_stake(validator: String, lock_type: u64, lock_coin: FungibleAsset): LSEntry acquires ModuleStore {
        assert!(lock_type < 4, error::out_of_range(EINVALID_LOCK_TYPE));

        let bond_amount = fungible_asset::amount(&lock_coin);
        let coin_metadata = object::object_address(fungible_asset::asset_metadata(&lock_coin));
        let delegation = staking::delegate(validator, lock_coin);

        // after delegation, load module store to compute reward share
        let m_store = borrow_global_mut<ModuleStore>(@launch);

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
        event::emit(
            LockEvent {
                coin_metadata,
                bond_amount,
                release_time: block_time + lock_period,
                share,
            }
        );

        LSEntry {
            delegation,
            release_time: block_time + lock_period,
            share,
        }
    }

    // Deposit LSEntry to user's LSStore
    public fun deposit_lock_stake_entry(account_addr: address, ls_entry: LSEntry) acquires LSStore {
        assert!(exists<LSStore>(account_addr), error::not_found(ELS_STORE_NOT_FOUND));
        
        // copy for event emit
        let delegation_res = staking::get_delegation_response_from_delegation(&ls_entry.delegation);
        let release_time = ls_entry.release_time;
        let share = ls_entry.share;

        let ls_store = borrow_global_mut<LSStore>(account_addr);
        vector::push_back(&mut ls_store.entries, ls_entry);

        // emit events
        event::emit(
            DepositEvent {
                addr: account_addr,
                delegation: delegation_res_to_delegation_info(&delegation_res),
                release_time,
                share,
            }
        );
    }

    /// Withdraw LSEntry of index
    public fun withdraw_lock_stake_entry(account: &signer, index: u64): LSEntry acquires LSStore {
        let account_addr = signer::address_of(account);
        assert!(exists<LSStore>(account_addr), error::not_found(ELS_STORE_NOT_FOUND));

        let ls_store = borrow_global_mut<LSStore>(account_addr);
        assert!(vector::length(&ls_store.entries) > index, error::out_of_range(EINVALID_INDEX));

        // O(n) cost, but want to keep the order for front UX
        let ls_entry = vector::remove(&mut ls_store.entries, index);

        let delegation_res = staking::get_delegation_response_from_delegation(&ls_entry.delegation);

        // emit events
        event::emit<WithdrawEvent>(
            WithdrawEvent {
                addr: account_addr,
                delegation: delegation_res_to_delegation_info(&delegation_res),
                release_time: ls_entry.release_time,
                share: ls_entry.share,
            }
        );

        ls_entry
    }

    /// Claim lock staking rewards with Delegation
    public fun claim(ls_entry: LSEntry): (Delegation, FungibleAsset) acquires ModuleStore {
        let m_store = borrow_global_mut<ModuleStore>(@launch);

        // check time constranits
        let (_, block_time) = block::get_block_info();

        assert!(block_time > m_store.end_time, error::unavailable(ELOCK_STAKING_IN_PROGRESS));
        assert!(block_time > ls_entry.release_time, error::unavailable(ENOT_RELEASED));

        // destroy ls_entry
        let LSEntry {
            delegation,
            release_time: _,
            share,
        } = ls_entry;

        // to prevent overflow
        let reward_amount = ((m_store.reward_amount as u128) * (share as u128) / (m_store.share_sum as u128) as u64);
        let reward_store_signer = object::generate_signer_for_extending(&m_store.reward_store_extend_ref);
        let reward = primary_fungible_store::withdraw(&reward_store_signer, m_store.reward_coin_metadata, reward_amount);

        let delegation_res = staking::get_delegation_response_from_delegation(&delegation);

        event::emit<ClaimEvent>(
            ClaimEvent {
                coin_metadata: object::object_address(m_store.reward_coin_metadata),
                reward_amount,
                delegation_reward_amount: staking::get_unclaimed_reward_from_delegation_response(&delegation_res),
                share,
            }
        );

        (delegation, reward)
    }
    
    public fun staking_reward_claim(ls_entry: &mut LSEntry): FungibleAsset {
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
    fun test_setup(c: &signer, m: &signer) {
        // staking setup
        staking::test_setup(c);
        let bond_metadata = staking::staking_metadata_for_test();
        let reward_metadata = coin::metadata(signer::address_of(c), string::utf8(b"uinit"));
        staking::set_staking_share_ratio(b"val", &bond_metadata, 1, 1);

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

        initialize(m, bond_metadata, reward_metadata, lock_periods, reward_weights);
    }

    #[test_only]
    fun fund_bond(c: &signer, u_addr: address, amt: u64) {
        let coin = primary_fungible_store::withdraw(c, staking::staking_metadata_for_test(), amt);
        primary_fungible_store::deposit(u_addr, coin);
    }

    ////////////////////////////////////////////////////////
    // CONFIG TEST

    #[test(c = @0x1, m = @0x2)]
    fun test_config(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);
        block::set_block_info(1, 1000000);

        config(m, 1000000, 1003600);
        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // add more fund
        config(m, 1000000, 1003600);
        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 2000000, 1);

        // update end time
        config(m, 0, 1007200);
        let res = get_module_store();
        assert!(res.end_time == 1007200, 0);
        assert!(res.reward_amount == 2000000, 1);
    }

    #[test(c = @0x1, m = @0x2)]
    #[expected_failure(abort_code = 0x10004, location = fungible_asset)]
    fun test_config_insufficient_funds(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 1000000);

        block::set_block_info(1, 1000000);

        config(m, 2000000, 2000000);
    }

    #[test(c = @0x1, m = @0x2)]
    #[expected_failure(abort_code = 0xD0001, location = Self)]
    fun test_config_invalid_end_time(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 1000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 1000000);
    }

    #[test(c = @0x1, m = @0x2)]
    #[expected_failure(abort_code = 0xD0001, location = Self)]
    fun test_config_invalid_end_time_at_update(
        c: &signer,
        m: &signer,
    ) acquires ModuleStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 2000000);

        let res = get_module_store();
        assert!(res.end_time == 2000000, 0);
        assert!(res.reward_amount == 1000000, 1);

        // update end time to invalid one
        config(m, 0, 1000000);
    }

    ////////////////////////////////////////////////////////
    // LockStake TEST
    
    #[test(c = @0x1, m = @0x2, u = @0x3)]
    fun test_lock_stake(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 1003600);

        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        fund_bond(c, signer::address_of(u), 4000000);
        lock_stake_script(u, string::utf8(b"val"), 0, 1000000);
        lock_stake_script(u, string::utf8(b"val"), 1, 1000000);
        lock_stake_script(u, string::utf8(b"val"), 2, 1000000);
        lock_stake_script(u, string::utf8(b"val"), 3, 1000000);

        // view ls entries
        let m_store = get_module_store();
        let ls_entries = get_ls_entries(signer::address_of(u));
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 0).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 0), 0);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 1).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 1), 1);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 2).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 2), 2);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 3).share == 1000000 * *vector::borrow<u64>(&m_store.reward_weights, 3), 3);

        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 0).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 0), 0);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 1).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 1), 1);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 2).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 2), 2);
        assert!(vector::borrow<LSEntryResponse>(&ls_entries, 3).release_time == 1000000 + *vector::borrow<u64>(&m_store.lock_periods, 3), 3);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3, relayer = @0x3d18d54532fc42e567090852db6eb21fa528f952)]
    fun test_staking_reward_claim(
        c: &signer,
        m: &signer,
        u: &signer,
        relayer: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 1003600);

        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        fund_bond(c, signer::address_of(u), 4000000);
        lock_stake_script(u, string::utf8(b"val"), 0, 1000000);
        lock_stake_script(u, string::utf8(b"val"), 1, 1000000);
        lock_stake_script(u, string::utf8(b"val"), 2, 1000000);
        lock_stake_script(u, string::utf8(b"val"), 3, 1000000);

        staking::fund_reward_coin(c, signer::address_of(relayer), 4000000);
        staking::deposit_reward_for_chain(c, staking::staking_metadata_for_test(), vector[string::utf8(b"val")], vector[4000000]);
        staking_reward_claim_script(u, 0);
        let m_store = borrow_global<ModuleStore>(@launch);
        assert!(primary_fungible_store::balance(signer::address_of(u), m_store.reward_coin_metadata) == 1000000, 2);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x10004, location = fungible_asset)]
    fun test_lock_stake_insufficient_funds(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 1003600);

        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        fund_bond(c, signer::address_of(u), 1000000);
        lock_stake_script(u, string::utf8(b"val"), 0, 1000001);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x20005, location = Self)]
    fun test_lock_stake_invalid_lock_type(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 1003600);

        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // execute lock stake
        fund_bond(c, signer::address_of(u), 1000000);
        lock_stake_script(u, string::utf8(b"val"), 5, 1000000);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0xD0001, location = Self)]
    fun test_lock_stake_lock_staking_end(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        block::set_block_info(1, 1000000);

        config(m, 1000000, 1003600);

        let res = get_module_store();
        assert!(res.end_time == 1003600, 0);
        assert!(res.reward_amount == 1000000, 1);

        // update block time to end of lock staking
        let m_store = get_module_store();
        block::set_block_info(1, m_store.end_time+1);

        // execute lock stake
        fund_bond(c, signer::address_of(u), 1000000);
        lock_stake_script(u, string::utf8(b"val"), 0, 1000000);
    }

    ////////////////////////////////////////////////////////
    // Claim TEST

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    fun test_claim(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);

        block::set_block_info(1, 1000000);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        let reward_amount = 1000000;
        let end_time = 1003600;
        config(m, reward_amount, end_time);

        let res = get_module_store();
        assert!(res.end_time == end_time, 0);
        assert!(res.reward_amount == reward_amount, 1);

        // execute lock stake
        let stake_amount = 1000000;
        fund_bond(c, signer::address_of(u), 4 * stake_amount);
        lock_stake_script(u, string::utf8(b"val"), 0, stake_amount);
        lock_stake_script(u, string::utf8(b"val"), 1, stake_amount);
        lock_stake_script(u, string::utf8(b"val"), 2, stake_amount);
        lock_stake_script(u, string::utf8(b"val"), 3, stake_amount);

        let m_store = get_module_store();
        
        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 0) + 1);
        claim_script(u, 0);
        
        let claim_amount_0 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 0)) / m_store.share_sum;
        assert!(primary_fungible_store::balance(signer::address_of(u), reward_coin_metadata()) == claim_amount_0, 0);

        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 1) + 1);
        claim_script(u, 0);

        let claim_amount_1 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 1)) / m_store.share_sum;
        assert!(coin::balance(signer::address_of(u), reward_coin_metadata()) == claim_amount_0 + claim_amount_1, 1);

        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 2) + 1);
        claim_script(u, 0);

        let claim_amount_2 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 2)) / m_store.share_sum;
        assert!(coin::balance(signer::address_of(u), reward_coin_metadata()) == claim_amount_0 + claim_amount_1 + claim_amount_2, 2);

        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 3) + 1);
        claim_script(u, 0);
        
        let claim_amount_3 = reward_amount * (stake_amount * *vector::borrow(&m_store.reward_weights, 3)) / m_store.share_sum;
        assert!(coin::balance(signer::address_of(u), reward_coin_metadata()) == claim_amount_0 + claim_amount_1 + claim_amount_2 + claim_amount_3, 0);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0xD0002, location = Self)]
    fun test_claim_lock_staking_in_progress(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);

        block::set_block_info(1, 1000000);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        let reward_amount = 1000000;
        let end_time = 1003600;
        config(m, reward_amount, end_time);

        let res = get_module_store();
        assert!(res.end_time == end_time, 0);
        assert!(res.reward_amount == reward_amount, 1);

        // execute lock stake
        let stake_amount = 1000000;
        fund_bond(c, signer::address_of(u), 4 * stake_amount);
        lock_stake_script(u, string::utf8(b"val"), 0, stake_amount);
        
        block::set_block_info(1, end_time - 1);
        claim_script(u, 0);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0xD0008, location = Self)]
    fun test_claim_not_released(
        c: &signer,
        m: &signer,
        u: &signer,
    ) acquires ModuleStore, LSStore {
        test_setup(c, m);

        block::set_block_info(1, 1000000);
        staking::fund_reward_coin(c, signer::address_of(m), 2000000);

        let reward_amount = 1000000;
        let end_time = 1003600;
        config(m, reward_amount, end_time);

        let res = get_module_store();
        assert!(res.end_time == end_time, 0);
        assert!(res.reward_amount == reward_amount, 1);

        // execute lock stake
        let stake_amount = 1000000;
        fund_bond(c, signer::address_of(u), 4 * stake_amount);
        lock_stake_script(u, string::utf8(b"val"), 0, stake_amount);
        
        let m_store = get_module_store();
        
        block::set_block_info(1, 1000000 + *vector::borrow(&m_store.lock_periods, 0) - 1);
        claim_script(u, 0);
    }

    #[test_only]
    fun reward_coin_metadata(): Object<Metadata> {
        coin::metadata(@initia_std, string::utf8(b"uinit"))
    }
}
