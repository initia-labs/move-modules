module launch::vesting {
    use std::coin;
    use std::error;
    use std::signer;
    use std::vector;
    use std::string;
    use std::event;

    use initia_std::block;
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::primary_fungible_store;
    use initia_std::object::{Self, Object};

    use launch::coin_wrapper::{Self, WrappedCoin};

    // Errors

    const EVESTING_STORE_ALREADY_EXISTS: u64 = 1;
    const EVESTING_STORE_NOT_FOUND: u64 = 2;
    const EINVALID_SCHEDULE: u64 = 3;
    const EINVALID_INDEX: u64 = 4;

    struct Schedule has store {
        vesting_coin: WrappedCoin,
        initial_amount: u64,
        released_amount: u64,

        /// release start time
        start_time: u64,
        /// release end time
        end_time: u64,
        /// claim interval for the released coins
        release_interval: u64,
    }

    struct VestingStore has key {
        schedules: vector<Schedule>,
    }

    struct DepositEvent has drop, store {
        addr: address,
        coin_metadata: address,
        initial_amount: u64,
        released_amount: u64,
        start_time: u64,
        end_time: u64,
        release_interval: u64,
    }

    struct WithdrawEvent has drop, store {
        addr: address,
        coin_metadata: address,
        initial_amount: u64,
        released_amount: u64,
        start_time: u64,
        end_time: u64,
        release_interval: u64,
    }

    struct ClaimEvent has drop, store {
        addr: address,
        coin_metadata: address,
        amount: u64,
    }

    struct ScheduleResponse has drop {
        coin_metadata: address,
        initial_amount: u64,
        released_amount: u64,
        start_time: u64,
        end_time: u64,
        release_interval: u64,
    }

    // View functions

    #[view]
    public fun get_vesting_schedules(addr: address): vector<ScheduleResponse> acquires VestingStore {
        let v_store = borrow_global<VestingStore>(addr);
        let res = vector::empty<ScheduleResponse>();
        let i = 0;
        while (i < vector::length(&v_store.schedules)) {
            let schedule = vector::borrow(&v_store.schedules, i);
            vector::push_back(&mut res, ScheduleResponse {
                coin_metadata: wrapped_coin_metadata_address(&schedule.vesting_coin),
                initial_amount: schedule.initial_amount,
                released_amount: schedule.released_amount,
                start_time: schedule.start_time,
                end_time: schedule.end_time,
                release_interval: schedule.release_interval,
            });
            i = i + 1;
        };

        res
    }

    // Entry functions

    public entry fun register(account: &signer) {
        assert!(!exists<VestingStore>(signer::address_of(account)), error::already_exists(EVESTING_STORE_ALREADY_EXISTS));

        move_to(account, VestingStore{
            schedules: vector::empty(),
        });
    }

    public entry fun add_vesting(
        account: &signer,
        recipient: address,
        metadata: Object<Metadata>,
        amount: u64,
        start_time: u64,
        end_time: u64,
        release_interval: u64,
    ) acquires VestingStore {
        let vesting_fa = primary_fungible_store::withdraw(account, metadata, amount);
        let vesting_coin = coin_wrapper::wrap(vesting_fa);
        let schedule = new_schedule(vesting_coin, start_time, end_time, release_interval);
        deposit_schedule(recipient, schedule);
    }

    public entry fun claim_script(account: &signer, index: u64) acquires VestingStore {
        let account_addr = signer::address_of(account);
        assert!(exists<VestingStore>(account_addr), error::not_found(EVESTING_STORE_NOT_FOUND));

        let v_store = borrow_global_mut<VestingStore>(account_addr);
        assert!(vector::length(&v_store.schedules) > index, error::out_of_range(EINVALID_INDEX));

        let schedule = vector::borrow_mut<Schedule>(&mut v_store.schedules, index);
        let claimed_coin = claim(schedule);
        let coin_metadata = wrapped_coin_metadata_address(&schedule.vesting_coin);

        if (coin_wrapper::amount(&schedule.vesting_coin) == 0) {
            destroy_schedule(withdraw_schedule(account, index));
        };

        let claimed_coin_amount = fungible_asset::amount(&claimed_coin);
        if (claimed_coin_amount == 0) {
            fungible_asset::destroy_zero(claimed_coin);
        } else {
            event::emit<ClaimEvent>(
                ClaimEvent {
                    addr: account_addr,
                    coin_metadata,
                    amount: claimed_coin_amount,
                },
            );
            coin::deposit(account_addr, claimed_coin);
        };
    }

    // Public functions

    public fun new_schedule(vesting_coin: WrappedCoin, start_time: u64, end_time: u64, release_interval: u64): Schedule {
        assert!(start_time <= end_time, error::invalid_argument(EINVALID_SCHEDULE));
        let period = end_time - start_time;

        // period must be multiple of interval
        assert!(period == (period / release_interval) * release_interval, error::invalid_argument(EINVALID_SCHEDULE));

        let initial_amount = coin_wrapper::amount(&vesting_coin);
        Schedule {
            vesting_coin,
            initial_amount,
            released_amount: 0,
            start_time,
            end_time,
            release_interval,
        }
    }

    public fun deposit_schedule(account_addr: address, schedule: Schedule) acquires VestingStore {
        assert!(exists<VestingStore>(account_addr), error::not_found(EVESTING_STORE_NOT_FOUND));

        let v_store = borrow_global_mut<VestingStore>(account_addr);
        event::emit<DepositEvent>(
            DepositEvent {
                addr: account_addr,
                coin_metadata: wrapped_coin_metadata_address(&schedule.vesting_coin),
                initial_amount: schedule.initial_amount,
                released_amount: schedule.released_amount,
                start_time: schedule.start_time,
                end_time: schedule.end_time,
                release_interval: schedule.release_interval,
            },
        );
        vector::push_back(&mut v_store.schedules, schedule);
    }

    public fun withdraw_schedule(account: &signer, index: u64): Schedule acquires VestingStore {
        let account_addr = signer::address_of(account);
        assert!(exists<VestingStore>(account_addr), error::not_found(EVESTING_STORE_NOT_FOUND));

        let v_store = borrow_global_mut<VestingStore>(account_addr);
        assert!(vector::length(&v_store.schedules) > index, error::out_of_range(EINVALID_INDEX));

        // O(n) cost, but want to keep the order for front UX
        let schedule = vector::remove(&mut v_store.schedules, index);
        event::emit<WithdrawEvent>(
            WithdrawEvent {
                addr: account_addr,
                coin_metadata: wrapped_coin_metadata_address(&schedule.vesting_coin),
                initial_amount: schedule.initial_amount,
                released_amount: schedule.released_amount,
                start_time: schedule.start_time,
                end_time: schedule.end_time,
                release_interval: schedule.release_interval,
            },
        );

        schedule
    }

    public fun claim(schedule: &mut Schedule): FungibleAsset {
        let (_, block_time) = block::get_block_info();

        if (block_time < schedule.start_time || schedule.released_amount == schedule.initial_amount) {
            return fungible_asset::zero(coin_wrapper::metadata(&schedule.vesting_coin))
        };

        let period = schedule.end_time - schedule.start_time;
        let time_diff = if (block_time > schedule.end_time) {
            schedule.end_time - schedule.start_time
        } else {
            block_time - schedule.start_time
        };

        let total_intervals = period / schedule.release_interval + 1;
        let passed_intervals = time_diff / schedule.release_interval + 1;

        let release_unit = schedule.initial_amount / total_intervals;
        let release_amount = if (passed_intervals == total_intervals) {
            schedule.initial_amount - schedule.released_amount
        } else {
            release_unit * passed_intervals - schedule.released_amount
        };
        if (release_amount == 0) {
            return fungible_asset::zero(coin_wrapper::metadata(&schedule.vesting_coin))
        };

        schedule.released_amount = schedule.released_amount + release_amount;
        let claimed_coin = coin_wrapper::extract(&mut schedule.vesting_coin, release_amount);
        coin_wrapper::unwrap(claimed_coin)
    }

    public fun destroy_schedule(schedule: Schedule) {
        let Schedule {
            vesting_coin,
            initial_amount: _,
            released_amount: _,
            start_time: _,
            end_time: _,
            release_interval: _,
        } = schedule;

        coin_wrapper::destroy_zero(vesting_coin);
    }

    fun wrapped_coin_metadata_address(wrapped_coin: &WrappedCoin): address {
        object::object_address(coin_wrapper::metadata(wrapped_coin))
    }

    ///////////////////////////////////////////////////////
    // Test

    #[test_only]
    struct CoinCaps has key {
        burn_cap: coin::BurnCapability,
        freeze_cap: coin::FreezeCapability,
        mint_cap: coin::MintCapability,
    }

    #[test_only]
    fun test_setup(c: &signer, m: &signer) {
        primary_fungible_store::init_module_for_test(c);
        coin_wrapper::init_module_for_test(m);
        let (mint_cap, burn_cap, freeze_cap) = coin::initialize(
            c,
            std::option::none(),
            string::utf8(b"INIT Coin"),
            string::utf8(b"uinit"),
            6,
            string::utf8(b""),
            string::utf8(b""),
        );
        move_to(c, CoinCaps {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test_only]
    fun vesting_coin_metadata(creator: address): Object<Metadata> {
        coin::metadata(creator, string::utf8(b"uinit"))
    }

    #[test_only]
    fun fund_vesting_coin(c_addr: address, m_addr: address, amt: u64) acquires CoinCaps {
        let caps = borrow_global<CoinCaps>(c_addr);
        coin::deposit(m_addr, coin::mint(&caps.mint_cap, amt));
    }

    #[test(c = @0x1, m = @launch, u = @0x3)]
    fun test_add_vesting(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        register(u);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        let c_addr = signer::address_of(c);
        let metadata = vesting_coin_metadata(c_addr);
        let coin_metadata = object::object_address(metadata);
        add_vesting(m, signer::address_of(u), metadata, 200000, 0, 1000, 1000);
        add_vesting(m, signer::address_of(u), metadata, 300000, 1000, 2000, 500);
        add_vesting(m, signer::address_of(u), metadata, 400000, 2000, 3000, 250);
        add_vesting(m, signer::address_of(u), metadata, 500000, 3000, 4000, 200);

        let schedules = get_vesting_schedules(signer::address_of(u));
        assert!(
            schedules == vector[
                ScheduleResponse {
                    coin_metadata,
                    initial_amount: 200000,
                    released_amount: 0,
                    start_time: 0,
                    end_time: 1000,
                    release_interval: 1000,
                },
                ScheduleResponse {
                    coin_metadata,
                    initial_amount: 300000,
                    released_amount: 0,
                    start_time: 1000,
                    end_time: 2000,
                    release_interval: 500,
                },
                ScheduleResponse {
                    coin_metadata,
                    initial_amount: 400000,
                    released_amount: 0,
                    start_time: 2000,
                    end_time: 3000,
                    release_interval: 250,
                },
                ScheduleResponse {
                    coin_metadata,
                    initial_amount: 500000,
                    released_amount: 0,
                    start_time: 3000,
                    end_time: 4000,
                    release_interval: 200,
                },
            ],
            0
        );
    }

    #[test(c = @0x1, m = @launch, u = @0x3)]
    #[expected_failure(abort_code = 0x10004, location = fungible_asset)]
    fun test_add_vesting_insufficient_amount(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register(u);
        let c_addr = signer::address_of(c);
        let metadata = vesting_coin_metadata(c_addr);

        add_vesting(m, signer::address_of(u), metadata, 3000000, 2000, 3000, 1000);
    }

    #[test(c = @0x1, m = @launch, u = @0x3)]
    #[expected_failure(abort_code = 0x10003, location = Self)]
    fun test_add_vesting_invalid_schedule(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register(u);
        let c_addr = signer::address_of(c);
        let metadata = vesting_coin_metadata(c_addr);

        add_vesting(m, signer::address_of(u), metadata, 1000000, 3000, 2000, 1000);
    }

    #[test(c = @0x1, m = @launch, u = @0x3)]
    #[expected_failure(abort_code = 0x10003, location = Self)]
    fun test_add_vesting_invalid_interval(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register(u);
        let c_addr = signer::address_of(c);
        let metadata = vesting_coin_metadata(c_addr);

        add_vesting(m, signer::address_of(u), metadata, 1000000, 2000, 3000, 700);
    }

    #[test(c = @0x1, m = @launch, u = @0x3)]
    fun test_claim(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        register(u);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        let c_addr = signer::address_of(c);
        let metadata = vesting_coin_metadata(c_addr);

        add_vesting(m, signer::address_of(u), metadata, 1000000, 1000, 2000, 500);
        add_vesting(m, signer::address_of(u), metadata, 1000000, 3000, 4000, 200);

        block::set_block_info(1, 0);
        claim_script(u, 0);
        let v_store = borrow_global<VestingStore>(signer::address_of(u));
        assert!(vector::borrow(&v_store.schedules, 0).released_amount == 0, 0);
        // check preserved order after claim
        assert!(vector::borrow(&v_store.schedules, 1).start_time == 3000, 1);

        block::set_block_info(2, 1000);
        claim_script(u, 0);
        let v_store = borrow_global<VestingStore>(signer::address_of(u));
        assert!(vector::borrow(&v_store.schedules, 0).released_amount == 333333, 2);

        block::set_block_info(3, 1500);
        claim_script(u, 0);
        let v_store = borrow_global<VestingStore>(signer::address_of(u));
        assert!(vector::borrow(&v_store.schedules, 0).released_amount == 666666, 3);

        block::set_block_info(4, 2000);
        claim_script(u, 0);
        let v_store = borrow_global<VestingStore>(signer::address_of(u));
        // check vesting finished
        assert!(vector::borrow(&v_store.schedules, 0).release_interval == 200, 4);
        assert!(coin::balance(signer::address_of(u), metadata) == 1000000, 5);
    }

    #[test(c = @0x1, m = @launch, u = @0x3)]
    #[expected_failure(abort_code = 0x20004, location = Self)]
    fun test_claim_invalid_index(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register(u);
        let c_addr = signer::address_of(c);
        let metadata = vesting_coin_metadata(c_addr);

        add_vesting(m, signer::address_of(u), metadata, 1000000, 2000, 3000, 1000);

        block::set_block_info(1, 0);
        claim_script(u, 1);        
    }
}
