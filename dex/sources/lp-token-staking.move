module dex_util::staking {
    use std::vector;
    use std::error;
    use std::signer;

    use initia_std::block::get_block_info;
    use initia_std::coin::{Self, Coin};

    use dex::decimal::{Self, Decimal};

    // Errors
    const EUNAUTHORIZED: u64 = 0;
    const EWORNG_LEN: u64 = 1;
    const EPAST_TIME: u64 = 2;

    struct StakingInfo<phantom Reward, phantom LpToken> has key {
        schedules: vector<Schedule>,
        reward: Coin<Reward>,
        total_staked: u128,
        last_update: u64,
        reward_per_staked_index: Decimal,
    }

    struct StakingToken<phantom Reward, phantom LpToken> has key {
        staked: Coin<LpToken>,
        reward_per_staked_index: Decimal,
    }

    struct Schedule has store {
        start_time: u64,
        end_time: u64,
        amount: u64,
    }

    ///
    /// Query entry functions
    ///
    
    public entry fun claimable_amount<Reward, LpToken>(
        addr: address
    ): u64 acquires StakingInfo, StakingToken {
        let (_block, timestamp) = get_block_info();
        let info = borrow_global<StakingInfo<Reward, LpToken>>(@dex_util);
        let release_amount = get_release_amount(info, timestamp);

        let increase_per_staking = decimal::from_ratio(release_amount, info.total_staked);

        let reward_per_staked_index = decimal::add(&info.reward_per_staked_index, &increase_per_staking);

        let staking_token = borrow_global<StakingToken<Reward, LpToken>>(addr);

        let diff = decimal::sub(&reward_per_staked_index, &staking_token.reward_per_staked_index);
        let staked_amount = (coin::value(&staking_token.staked) as u128);
        let claim_amount = decimal::mul(&diff, staked_amount);

        (claim_amount as u64)
    }

    ///
    /// Execute entry functions
    ///

    public entry fun register_staking<Reward, LpToken>(
        account: &signer,
        timestamps: vector<u64>,
        amounts: vector<u64>,
    ) {
        assert!(@dex_util == signer::address_of(account), error::permission_denied(EUNAUTHORIZED));

        assert!(vector::length(&amounts) + 1 == vector::length(&timestamps), error::invalid_argument(EWORNG_LEN));

        let total_amount = 0;
        let index = 0;
        let schedules: vector<Schedule> = vector[];
        let (_block, timestamp) = get_block_info();

        assert!(*vector::borrow(&timestamps, index) > timestamp, error::invalid_argument(EPAST_TIME));
        while (index < vector::length(&amounts)) {
            let amount = *vector::borrow(&amounts, index);
            total_amount = total_amount + amount;
            vector::push_back(
                &mut schedules,
                Schedule {
                    start_time: *vector::borrow(&timestamps, index),
                    end_time: *vector::borrow(&timestamps, index + 1),
                    amount,
                }
            );

            index = index + 1;
        };

        let reward = coin::withdraw<Reward>(account, total_amount);

        move_to(account, StakingInfo<Reward, LpToken> {
            schedules,
            reward,
            total_staked: 0,
            last_update: timestamp,
            reward_per_staked_index: decimal::zero(),
        });
    }

    public entry fun update_reward<Reward, LpToken>(
        _account: &signer,
    ) acquires StakingInfo {
        let info = borrow_global_mut<StakingInfo<Reward, LpToken>>(@dex_util);
        let (_block, timestamp) = get_block_info();

        if (info.total_staked != 0) {
            let release_amount = get_release_amount(info, timestamp);
            let increase_per_staking = decimal::from_ratio(release_amount, info.total_staked);

            info.reward_per_staked_index = decimal::add(&info.reward_per_staked_index, &increase_per_staking);
        };

        info.last_update = timestamp;
    }

    public entry fun claim<Reward, LpToken>(account: &signer) acquires StakingInfo, StakingToken {
        let addr = signer::address_of(account);

        update_reward<Reward, LpToken>(account);

        if (exists<StakingToken<Reward, LpToken>>(addr)) {
            let info = borrow_global_mut<StakingInfo<Reward, LpToken>>(@dex_util);
            let staking_token = borrow_global_mut<StakingToken<Reward, LpToken>>(addr);

            let diff = decimal::sub(&info.reward_per_staked_index, &staking_token.reward_per_staked_index);
            let staked_amount = (coin::value(&staking_token.staked) as u128);
            let claim_amount = decimal::mul(&diff, staked_amount);

            staking_token.reward_per_staked_index = info.reward_per_staked_index;

            let reward = coin::extract(&mut info.reward, (claim_amount as u64));
            coin::deposit(addr, reward);
        }
    }

    public entry fun staking<Reward, LpToken>(account: &signer, amount: u64) acquires StakingInfo, StakingToken {
        claim<Reward, LpToken>(account);

        let addr = signer::address_of(account);
        let lp_token = coin::withdraw<LpToken>(account, amount);
        let info = borrow_global_mut<StakingInfo<Reward, LpToken>>(@dex_util);

        if (!exists<StakingToken<Reward, LpToken>>(addr)) {
            move_to(
                account,
                StakingToken<Reward, LpToken> {
                    staked: coin::zero(),
                    reward_per_staked_index: info.reward_per_staked_index,
                },
            )
        };

        let staking_token = borrow_global_mut<StakingToken<Reward, LpToken>>(addr);

        coin::merge(&mut staking_token.staked, lp_token);

        info.total_staked = info.total_staked + (amount as u128);
    }

    public entry fun withdraw<Reward, LpToken>(account: &signer, amount: u64) acquires StakingInfo, StakingToken {
        claim<Reward, LpToken>(account);

        let addr = signer::address_of(account);

        let staking_token = borrow_global_mut<StakingToken<Reward, LpToken>>(addr);
        let withdraw_coin = coin::extract(&mut staking_token.staked, amount);

        coin::deposit(addr, withdraw_coin);

        let info = borrow_global_mut<StakingInfo<Reward, LpToken>>(@dex_util);
        info.total_staked = info.total_staked - (amount as u128);
    }

    fun get_release_amount<Reward, LpToken>(info: &StakingInfo<Reward, LpToken>, timestamp: u64): u128 {
        let release_amount = 0;
        let last_update = info.last_update;
        let index = 0;
        while (index < vector::length(&info.schedules)) {
            let schedule = vector::borrow(&info.schedules, index);
            last_update = max(schedule.start_time, last_update);
            if (schedule.end_time > last_update && schedule.start_time < timestamp) {
                let interval = (schedule.end_time - schedule.start_time as u128);
                if (schedule.end_time <= timestamp) {
                    let valid_time = (schedule.end_time - last_update as u128);
                    last_update = schedule.end_time;
                    release_amount = release_amount 
                        + decimal::mul(&decimal::from_ratio(valid_time, interval), (schedule.amount as u128));
                } else {
                    let valid_time = (timestamp - last_update as u128);
                    release_amount = release_amount 
                        + decimal::mul(&decimal::from_ratio(valid_time, interval), (schedule.amount as u128));
                    break
                };
            };

            index = index + 1;
        };

        release_amount
    }

    fun max(a: u64, b: u64): u64 {
        if (a > b) {
            a
        } else {
            b
        }
    }

    #[test_only]
    struct RewardCoin { }

    #[test_only]
    struct LpToken { }

    #[test_only]
    struct CoinCaps<phantom CoinType> has key { 
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    #[test_only]
    fun initialized_coin<CoinType>(
        account: &signer
    ): (coin::BurnCapability<CoinType>, coin::FreezeCapability<CoinType>, coin::MintCapability<CoinType>) {
        coin::initialize<CoinType>(
            account,
            std::string::utf8(b"name"),
            std::string::utf8(b"SYMBOL"),
            6,
        )
    }

    #[test_only]
    use std::unit_test::set_block_info_for_testing;

    // TODO: add test
    #[test(owner = @dex_util, user = @0x1234)]
    fun end_to_end(
        owner: signer,
        user: signer,
    ) acquires StakingInfo, StakingToken {
        let owner_address = signer::address_of(&owner);
        let user_address = signer::address_of(&user);
        let (reward_coin_burn_cap, reward_coin_freeze_cap, reward_coin_mint_cap) = initialized_coin<RewardCoin>(&owner);
        let (lp_token_burn_cap, lp_token_freeze_cap, lp_token_mint_cap) = initialized_coin<LpToken>(&owner);

        set_block_info_for_testing(100, 5000);

        coin::register<RewardCoin>(&owner);
        coin::register<RewardCoin>(&user);
        coin::register<LpToken>(&owner);
        coin::register<LpToken>(&user);
        coin::deposit<RewardCoin>(owner_address, coin::mint<RewardCoin>(1000000000000000, &reward_coin_mint_cap));
        coin::deposit<LpToken>(user_address, coin::mint<LpToken>(1000000000000000, &lp_token_mint_cap));
        coin::deposit<LpToken>(owner_address, coin::mint<LpToken>(1000000000000000, &lp_token_mint_cap));

        register_staking<RewardCoin, LpToken>(&owner, vector[6000, 7000, 8000], vector[1000, 2000]);

        staking<RewardCoin, LpToken>(&user, 100);

        assert!(claimable_amount<RewardCoin, LpToken>(user_address) == 0, 1);
        set_block_info_for_testing(200, 6500);
        assert!(claimable_amount<RewardCoin, LpToken>(user_address) == 500, 2);
        set_block_info_for_testing(300, 7500);
        assert!(claimable_amount<RewardCoin, LpToken>(user_address) == 2000, 3);
        set_block_info_for_testing(400, 9000);
        assert!(claimable_amount<RewardCoin, LpToken>(user_address) == 3000, 4);

        set_block_info_for_testing(200, 6500);
        claim<RewardCoin, LpToken>(&user);
        assert!(claimable_amount<RewardCoin, LpToken>(user_address) == 0, 5);
        assert!(coin::balance<RewardCoin>(user_address) == 500, 6);

        withdraw<RewardCoin, LpToken>(&user, 50);
        staking<RewardCoin, LpToken>(&owner, 50);
        set_block_info_for_testing(250, 7000);
        assert!(claimable_amount<RewardCoin, LpToken>(user_address) == 250, 7);
        assert!(claimable_amount<RewardCoin, LpToken>(owner_address) == 250, 8);

        withdraw<RewardCoin, LpToken>(&owner, 50);
        assert!(coin::balance<RewardCoin>(owner_address) == 1000000000000000 - 3000 + 250, 9);

        staking<RewardCoin, LpToken>(&user, 50);
        assert!(coin::balance<RewardCoin>(user_address) == 750, 6);

        move_to(&owner, CoinCaps<RewardCoin> {
            burn_cap: reward_coin_burn_cap,
            freeze_cap: reward_coin_freeze_cap,
            mint_cap: reward_coin_mint_cap,
        });

        move_to(&owner, CoinCaps<LpToken> {
            burn_cap: lp_token_burn_cap,
            freeze_cap: lp_token_freeze_cap,
            mint_cap: lp_token_mint_cap,
        });
    }

    #[test(owner = @dex_util, user = @0x1234)]
    #[expected_failure(abort_code = 0x50000)]
    fun fail_register_unauthorized(
        owner: signer,
        user: signer,
    ) {
        let user_address = signer::address_of(&user);

        let (reward_coin_burn_cap, reward_coin_freeze_cap, reward_coin_mint_cap) = initialized_coin<RewardCoin>(&owner);
        let (lp_token_burn_cap, lp_token_freeze_cap, lp_token_mint_cap) = initialized_coin<LpToken>(&owner);

        coin::register<RewardCoin>(&user);
        coin::deposit<RewardCoin>(user_address, coin::mint<RewardCoin>(1000000000000000, &reward_coin_mint_cap));
        register_staking<RewardCoin, LpToken>(&user, vector[6000, 7000, 8000], vector[1000, 2000]);

        move_to(&owner, CoinCaps<RewardCoin> {
            burn_cap: reward_coin_burn_cap,
            freeze_cap: reward_coin_freeze_cap,
            mint_cap: reward_coin_mint_cap,
        });

        move_to(&owner, CoinCaps<LpToken> {
            burn_cap: lp_token_burn_cap,
            freeze_cap: lp_token_freeze_cap,
            mint_cap: lp_token_mint_cap,
        });
    }


    #[test(owner = @dex_util)]
    #[expected_failure(abort_code = 0x10001)]
    fun fail_register_args_num(
        owner: signer,
    ) {
        let owner_address = signer::address_of(&owner);
        let (reward_coin_burn_cap, reward_coin_freeze_cap, reward_coin_mint_cap) = initialized_coin<RewardCoin>(&owner);
        let (lp_token_burn_cap, lp_token_freeze_cap, lp_token_mint_cap) = initialized_coin<LpToken>(&owner);

        coin::register<RewardCoin>(&owner);
        coin::deposit<RewardCoin>(owner_address, coin::mint<RewardCoin>(1000000000000000, &reward_coin_mint_cap));
        register_staking<RewardCoin, LpToken>(&owner, vector[6000, 7000, 8000, 9000], vector[1000, 2000]);

        move_to(&owner, CoinCaps<RewardCoin> {
            burn_cap: reward_coin_burn_cap,
            freeze_cap: reward_coin_freeze_cap,
            mint_cap: reward_coin_mint_cap,
        });

        move_to(&owner, CoinCaps<LpToken> {
            burn_cap: lp_token_burn_cap,
            freeze_cap: lp_token_freeze_cap,
            mint_cap: lp_token_mint_cap,
        });
    }

    #[test(owner = @dex_util)]
    #[expected_failure(abort_code = 0x10002)]
    fun fail_register_past_time(
        owner: signer,
    ) {
        let owner_address = signer::address_of(&owner);
        let (reward_coin_burn_cap, reward_coin_freeze_cap, reward_coin_mint_cap) = initialized_coin<RewardCoin>(&owner);
        let (lp_token_burn_cap, lp_token_freeze_cap, lp_token_mint_cap) = initialized_coin<LpToken>(&owner);

        set_block_info_for_testing(400, 9000);

        coin::register<RewardCoin>(&owner);
        coin::deposit<RewardCoin>(owner_address, coin::mint<RewardCoin>(1000000000000000, &reward_coin_mint_cap));
        register_staking<RewardCoin, LpToken>(&owner, vector[6000, 7000, 8000], vector[1000, 2000]);

        move_to(&owner, CoinCaps<RewardCoin> {
            burn_cap: reward_coin_burn_cap,
            freeze_cap: reward_coin_freeze_cap,
            mint_cap: reward_coin_mint_cap,
        });

        move_to(&owner, CoinCaps<LpToken> {
            burn_cap: lp_token_burn_cap,
            freeze_cap: lp_token_freeze_cap,
            mint_cap: lp_token_mint_cap,
        });
    }
}
