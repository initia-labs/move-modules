module launch::vesting {
    use std::coin::{Self, Coin};
    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{Self, String};
    use std::event::{Self, EventHandle};

    use initia_std::block;
    use initia_std::type_info;

    // Errors

    const EVESTING_STORE_ALREADY_EXISTS: u64 = 1;
    const EINVALID_SCHEDULE: u64 = 2;
    const EVESTING_STORE_NOT_FOUND: u64 = 3;
    const EINVALID_INDEX: u64 = 4;

    struct Schedule<phantom CoinType> has store {
        amount: Coin<CoinType>,
        initial_amount: u64,
        released_amount: u64,

        /// release start time
        start_time: u64,
        /// release end time
        end_time: u64,
        /// claim interval for the released coins
        release_interval: u64,
    }

    struct VestingStore<phantom CoinType> has key {
        schedules: vector<Schedule<CoinType>>,
        release_events: EventHandle<ReleaseEvent>,
    }

    struct ReleaseEvent has drop, store {
        coin_type: String,
        amount: u64,
    }

    struct ScheduleResponse has drop {
        coin_type: String,
        initial_amount: u64,
        released_amount: u64,
        start_time: u64,
        end_time: u64,
        release_interval: u64,
    }

    // View functions

    #[view]
    public fun get_vesting_schedules<CoinType>(addr: address): vector<ScheduleResponse> acquires VestingStore {
        let v_store = borrow_global<VestingStore<CoinType>>(addr);
        let res = vector::empty<ScheduleResponse>();
        let i = 0;
        while (i < vector::length(&v_store.schedules)) {
            let schedule = vector::borrow(&v_store.schedules, i);
            vector::push_back(&mut res, ScheduleResponse {
                coin_type: type_info::type_name<CoinType>(),
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

    public entry fun register<CoinType>(account: &signer) {
        assert!(!exists<VestingStore<CoinType>>(signer::address_of(account)), error::already_exists(EVESTING_STORE_ALREADY_EXISTS));

        move_to(account, VestingStore<CoinType>{
            schedules: vector::empty(),
            release_events: event::new_event_handle<ReleaseEvent>(account),
        });
    }

    public entry fun add_vesting<CoinType>(account: &signer, recipient: address, amount: u64, start_time: u64, end_time: u64, release_interval: u64) acquires VestingStore {
        let vesting_coin = coin::withdraw<CoinType>(account, amount);
        let schedule = new_schedule<CoinType>(vesting_coin, start_time, end_time, release_interval);
        let v_store = borrow_global<VestingStore<CoinType>>(recipient);
        deposit_schedule<CoinType>(recipient, schedule, vector::length(&v_store.schedules));
    }

    public entry fun claim_script<CoinType>(account: &signer, index: u64) acquires VestingStore {
        let account_addr = signer::address_of(account);
        let schedule = withdraw_schedule<CoinType>(account, index);
        let claimed_coin = claim<CoinType>(&mut schedule);

        if (coin::value(&schedule.amount) == 0) {
            // destroy schedule
            let Schedule {
                amount,
                initial_amount: _,
                released_amount: _,
                start_time: _,
                end_time: _,
                release_interval: _,
            } = schedule;
            coin::destroy_zero<CoinType>(amount);
        } else {
            // put back into vesting store
            deposit_schedule<CoinType>(account_addr, schedule, index);
        };

        let claimed_coin_amount = coin::value(&claimed_coin);
        if (claimed_coin_amount == 0) {
            coin::destroy_zero(claimed_coin);
        } else {
            let v_store = borrow_global_mut<VestingStore<CoinType>>(account_addr);
            event::emit_event<ReleaseEvent>(
                &mut v_store.release_events,
                ReleaseEvent {
                    coin_type: type_info::type_name<CoinType>(),
                    amount: claimed_coin_amount,
                },
            );
            coin::deposit(account_addr, claimed_coin);
        };
    }

    // Public functions

    public fun new_schedule<CoinType>(amount: Coin<CoinType>, start_time: u64, end_time: u64, release_interval: u64): Schedule<CoinType> {
        assert!(start_time <= end_time, error::invalid_argument(EINVALID_SCHEDULE));
        let period = end_time - start_time;

        // period must be multiple of interval
        assert!(period == (period / release_interval) * release_interval, error::invalid_argument(EINVALID_SCHEDULE));

        let initial_amount = coin::value(&amount);
        Schedule<CoinType> {
            amount,
            initial_amount,
            released_amount: 0,
            start_time,
            end_time,
            release_interval,
        }
    }

    public fun deposit_schedule<CoinType>(account_addr: address, schedule: Schedule<CoinType>, index: u64) acquires VestingStore {
        assert!(exists<VestingStore<CoinType>>(account_addr), error::not_found(EVESTING_STORE_NOT_FOUND));

        let v_store = borrow_global_mut<VestingStore<CoinType>>(account_addr);
        assert!(vector::length(&v_store.schedules) >= index, error::out_of_range(EINVALID_INDEX));

        vector::insert(&mut v_store.schedules, schedule, index);
    }

    public fun withdraw_schedule<CoinType>(account: &signer, index: u64): Schedule<CoinType> acquires VestingStore {
        let account_addr = signer::address_of(account);
        assert!(exists<VestingStore<CoinType>>(account_addr), error::not_found(EVESTING_STORE_NOT_FOUND));

        let v_store = borrow_global_mut<VestingStore<CoinType>>(account_addr);
        assert!(vector::length(&v_store.schedules) > index, error::out_of_range(EINVALID_INDEX));

        // O(n) cost, but want to keep the order for front UX
        vector::remove(&mut v_store.schedules, index)
    }

    public fun claim<CoinType>(schedule: &mut Schedule<CoinType>): Coin<CoinType> {
        let (_, block_time) = block::get_block_info();

        if (block_time < schedule.start_time || schedule.released_amount == schedule.initial_amount) {
            return coin::zero<CoinType>()
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
        let release_amount = release_unit * passed_intervals - schedule.released_amount;
        if (release_amount == 0) {
            return coin::zero<CoinType>()
        };

        schedule.released_amount = schedule.released_amount + release_amount;
        coin::extract(&mut schedule.amount, release_amount)
    }

    ///////////////////////////////////////////////////////
    // Test

    #[test_only]
    use initia_std::native_uinit::Coin as UinitCoin;

    #[test_only]
    struct CoinCaps<phantom CoinType> has key {
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    #[test_only]
    fun test_setup(c: &signer, m: &signer) {
        // coin setup
        coin::init_module_for_test(c);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<UinitCoin>(
            c,
            string::utf8(b"INIT Coin"),
            string::utf8(b"uinit"),
            6,
        );
        move_to(c, CoinCaps<UinitCoin> {
            burn_cap,
            freeze_cap,
            mint_cap,
        });

        coin::register<UinitCoin>(m);
    }

    #[test_only]
    fun fund_vesting_coin(c_addr: address, m_addr: address, amt: u64) acquires CoinCaps {
        let caps = borrow_global<CoinCaps<UinitCoin>>(c_addr);
        coin::deposit<UinitCoin>(m_addr, coin::mint<UinitCoin>(amt, &caps.mint_cap));
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    fun test_add_vesting(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register<UinitCoin>(u);

        // TODO: add more
        add_vesting<UinitCoin>(m, signer::address_of(u), 1000000, 2000, 3000, 1000);
        let schedules = get_vesting_schedules<UinitCoin>(signer::address_of(u));
        assert!(vector::length(&schedules) == 1, 0)
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x10007, location = coin)]
    fun test_add_vesting_insufficient_amount(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register<UinitCoin>(u);

        add_vesting<UinitCoin>(m, signer::address_of(u), 3000000, 2000, 3000, 1000);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x10002, location = Self)]
    fun test_add_vesting_invalid_schedule(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register<UinitCoin>(u);

        add_vesting<UinitCoin>(m, signer::address_of(u), 1000000, 3000, 2000, 1000);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x10002, location = Self)]
    fun test_add_vesting_invalid_interval(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register<UinitCoin>(u);

        add_vesting<UinitCoin>(m, signer::address_of(u), 1000000, 2000, 3000, 700);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    fun test_claim(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register<UinitCoin>(u);
        add_vesting<UinitCoin>(m, signer::address_of(u), 1000000, 2000, 3000, 1000);

        // TODO: add more
        block::set_block_info(1, 0);
        claim_script<UinitCoin>(u, 0);
        let v_store = borrow_global<VestingStore<UinitCoin>>(signer::address_of(u));
        assert!(vector::borrow(&v_store.schedules, 0).released_amount == 0, 1);
    }

    #[test(c = @0x1, m = @0x2, u = @0x3)]
    #[expected_failure(abort_code = 0x20004, location = Self)]
    fun test_claim_invalid_index(c: &signer, m: &signer, u: &signer) acquires VestingStore, CoinCaps {
        test_setup(c, m);
        fund_vesting_coin(signer::address_of(c), signer::address_of(m), 2000000);
        register<UinitCoin>(u);
        add_vesting<UinitCoin>(m, signer::address_of(u), 1000000, 2000, 3000, 1000);

        block::set_block_info(1, 0);
        claim_script<UinitCoin>(u, 1);        
    }
}
