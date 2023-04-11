module launch::vesting {
    use std::coin::{Self, Coin};
    use std::error;
    use std::signer;
    use std::vector;
    
    use initia_std::block;

    const EVESTING_STORE_ALREADY_EXISTS: u64 = 1;
    const EINVALID_SCHEDULE: u64 = 2;

    struct Schedule<phantom CoinType> has store {
        amount: Coin<CoinType>,
        initial_amount: u64,
        release_amount: u64,

        /// release start time
        start_time: u64,
        /// release end time
        end_time: u64,
        /// claim interval for the released coins
        release_interval: u64,
    }

    struct VestingStore<phantom CoinType> has key {
        schedules: vector<Schedule<CoinType>>,
    }

    public entry fun register<CoinType>(account: &signer) {
        assert!(!exists<VestingStore<CoinType>>(signer::address_of(account)), error::already_exists(EVESTING_STORE_ALREADY_EXISTS));

        move_to(account, VestingStore<CoinType>{
            schedules: vector::empty(),
        });
    }

    public entry fun add_vesting<CoinType>(account: &signer, recipient: address, amount: u64, start_time: u64, end_time: u64, release_interval: u64) acquires VestingStore {
        let vesting_coin = coin::withdraw<CoinType>(account, amount);
        let schedule = new_schedule<CoinType>(vesting_coin, start_time, end_time, release_interval);
        deposit_schedule<CoinType>(recipient, schedule);
    }

    public fun new_schedule<CoinType>(amount: Coin<CoinType>, start_time: u64, end_time: u64, release_interval: u64): Schedule<CoinType> {
        assert!(start_time <= end_time, error::invalid_argument(EINVALID_SCHEDULE));
        let period = end_time - start_time;

        // period must be multiple of interval
        assert!(period == (period / release_interval) * release_interval, error::invalid_argument(EINVALID_SCHEDULE));

        let initial_amount = coin::value(&amount);
        Schedule<CoinType> {
            amount,
            initial_amount,
            release_amount: 0,
            start_time,
            end_time,
            release_interval,
        }
    }

    public fun deposit_schedule<CoinType>(account_addr: address, schedule: Schedule<CoinType>) acquires VestingStore {
        let v_store = borrow_global_mut<VestingStore<CoinType>>(account_addr);
        vector::push_back(&mut v_store.schedules, schedule);
    }

    public fun withdraw_schedule<CoinType>(account: &signer, index: u64): Schedule<CoinType> acquires VestingStore {
        let v_store = borrow_global_mut<VestingStore<CoinType>>(signer::address_of(account));
        
        // O(n) cost, but want to keep the order for front UX
        vector::remove(&mut v_store.schedules, index)
    }

    public fun claim<CoinType>(schedule: &mut Schedule<CoinType>): Coin<CoinType> {
        let (_, block_time) = block::get_block_info();
        
        
        if (block_time < schedule.start_time || schedule.release_amount == schedule.initial_amount) {
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
        let release_amount = release_unit * passed_intervals - schedule.release_amount;
        if (release_amount == 0) {
            return coin::zero<CoinType>()
        };

        schedule.release_amount = schedule.release_amount + release_amount;
        coin::extract(&mut schedule.amount, release_amount)
    }
}