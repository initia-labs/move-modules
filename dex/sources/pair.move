module dex::pair {
    use std::event::{Self, EventHandle};
    use std::signer;
    use std::error;
    use std::string::{Self, String};

    use initia_std::coin::{Self, Coin};
    use initia_std::type_info;
    use initia_std::comparator;

    use dex::decimal::{Self, Decimal};

    //
    // Errors.
    //

    const ESAME_COIN_TYPE: u64 = 0;
    const EZERO_LIQUIDITY: u64 = 1;
    const EMIN_LIQUIDITY: u64 = 2;
    const EUNAUTHORIZED: u64 = 3;

    // Data structures

    /// Capability required to mint coins.
    struct ChangeFeeRateCapability<phantom LiquidityToken> has copy, store { }

    struct CoinCapabilities<phantom LiquidityToken> has store {
        burn_cap: coin::BurnCapability<LiquidityToken>,
        freeze_cap: coin::FreezeCapability<LiquidityToken>,
        mint_cap: coin::MintCapability<LiquidityToken>,
    }

    struct PairInfo<phantom Coin0, phantom Coin1, phantom LiquidityToken> has key {
        coin0: Coin<Coin0>,
        coin1: Coin<Coin1>,
        fee_rate: Decimal,
        lp_token_capabilities: CoinCapabilities<LiquidityToken>,
    }

    struct PairEvents has key {
        swap_events: EventHandle<SwapEvent>,
        provide_events: EventHandle<ProvideEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
    }

    struct SwapEvent has drop, store {
        offer_coin_type: String,
        offer_amount: u64,
        return_coin_type: String, 
        return_amount: u64,
        commission_amount: u64
    }

    struct ProvideEvent has drop, store {
        provide_liquidity: u64,
        coin0_type: String,
        coin0_provide_amount: u64,
        coin1_type: String,
        coin1_provide_amount: u64,
    }

    struct WithdrawEvent has drop, store {
        withdraw_liquidity: u64,
        coin0_type: String,
        coin0_withdraw_amount: u64,
        coin1_type: String,
        coin1_withdraw_amount: u64,
    }

    struct PairStateResponse has drop {
        coin0_amount: u64,
        coin1_amount: u64,
        total_liquidity: u128,
    }

    ///
    /// Query entry functions
    /// 

    public entry fun get_fee_rate<Coin0, Coin1, LiquidityToken>(): Decimal acquires PairInfo {
        let pair_info = borrow_global<PairInfo<Coin0, Coin1, LiquidityToken>>(@dex);
        pair_info.fee_rate
    }

    // return (coin0_amount, coin1_amount, total_liquidity)
    public entry fun pair_state<Coin0, Coin1, LpToken>(): PairStateResponse acquires PairInfo {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);
        let pair = borrow_global<PairInfo<Coin0, Coin1, LpToken>>(pair_owner);
        let total_liquidity = coin::supply<LpToken>();

        PairStateResponse {
            coin0_amount: coin::value(&pair.coin0),
            coin1_amount: coin::value(&pair.coin1),
            total_liquidity
        }
    }

    public fun coin0_amount_from_pair_state_res(res: &PairStateResponse): u64 {
        res.coin0_amount
    }

    public fun coin1_amount_from_pair_state_res(res: &PairStateResponse): u64 {
        res.coin1_amount
    }

    public fun total_liquidity_from_pair_state_res(res: &PairStateResponse): u128 {
        res.total_liquidity
    }

    public entry fun swap_simulation<OfferCoin, ReturnCoin, LpToken>(
        offer_amount: u64
    ): u64 acquires PairInfo {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);

        let compare = coin_type_compare<OfferCoin, ReturnCoin>();

        if (comparator::is_greater_than(&compare)) {
            let pair = borrow_global_mut<PairInfo<OfferCoin, ReturnCoin, LpToken>>(pair_owner);
            let offer_coin_index = 0;
            let (res, _) = swap_calculation(pair, offer_amount, offer_coin_index);
            res
        } else {
            let pair = borrow_global_mut<PairInfo<ReturnCoin, OfferCoin, LpToken>>(pair_owner);
            let offer_coin_index = 1;
            let (res, _) = swap_calculation(pair, offer_amount, offer_coin_index);
            res
        }
    }

    ///
    /// Execute entry functions
    ///

    /// Create a new pair
    public fun create_pool<Coin0, Coin1, LpToken>(
        account: &signer,
        fee_rate: String
    ): ChangeFeeRateCapability<LpToken> {
        let type_name1 = type_info::type_name<Coin0>();
        let type_name2 = type_info::type_name<Coin1>();

        assert!(type_name1 != type_name2, error::invalid_argument(ESAME_COIN_TYPE));

        let compare = coin_type_compare<Coin0, Coin1>();

        if (comparator::is_greater_than(&compare)) {
            store_pair_info<Coin0, Coin1, LpToken>(account, decimal::from_string(&fee_rate));
        } else {
            store_pair_info<Coin1, Coin0, LpToken>(account, decimal::from_string(&fee_rate));
        };

        ChangeFeeRateCapability<LpToken> { }
    }

    public fun update_fee_rate<Coin0, Coin1, LpToken>(
        _account: &signer,
        new_fee_rate: String, // decimal_fee_rate = fee_rate / 100,000)
        _cap: &ChangeFeeRateCapability<LpToken>
    ) acquires PairInfo {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);
        let pair = borrow_global_mut<PairInfo<Coin0, Coin1, LpToken>>(pair_owner);

        pair.fee_rate = decimal::from_string(&new_fee_rate);
    }

    /// register for events
    public entry fun register(account: &signer) {
        if (!exists<PairEvents>(signer::address_of(account))) {
            let pair_events = PairEvents {
                swap_events: event::new_event_handle<SwapEvent>(account),
                provide_events: event::new_event_handle<ProvideEvent>(account),
                withdraw_events: event::new_event_handle<WithdrawEvent>(account),
            };

            move_to<PairEvents>(account, pair_events)
        };
    }
    

    /// provide liquidity
    public entry fun provide_liquidity<Coin0, Coin1, LpToken>(
        account: &signer,
        coin0_amount: u64,
        coin1_amount: u64,
        min_liquidity: u64,
    ) acquires PairInfo, PairEvents {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);
        let pair = borrow_global<PairInfo<Coin0, Coin1, LpToken>>(pair_owner);
        
        let total_liquidity = coin::supply<LpToken>();

        // calculate the best coin amount
        let (coin0, coin1) = if (total_liquidity == 0) {
            (
                coin::withdraw<Coin0>(account, coin0_amount),
                coin::withdraw<Coin1>(account, coin1_amount),
            )
        } else {
            let coin0_share = decimal::from_ratio((coin0_amount as u128), (coin::value(&pair.coin0) as u128));
            let coin1_share = decimal::from_ratio((coin1_amount as u128), (coin::value(&pair.coin1) as u128));

            if (decimal::val(&coin0_share) > decimal::val(&coin1_share)) {
                coin0_amount = (decimal::mul(&coin1_share, (coin::value(&pair.coin0) as u128)) as u64);
            } else {
                coin1_amount = (decimal::mul(&coin0_share, (coin::value(&pair.coin1) as u128)) as u64);
            };

            (
                coin::withdraw<Coin0>(account, coin0_amount),
                coin::withdraw<Coin1>(account, coin1_amount),
            )
        };

        let liquidity_token = direct_provie_liquidity<Coin0, Coin1, LpToken>(account, coin0, coin1, min_liquidity);

        if (!coin::is_account_registered<LpToken>(signer::address_of(account))) {
            coin::register<LpToken>(account);
        };

        coin::deposit(signer::address_of(account), liquidity_token);
    }

    /// provide liquidity with coin and return lp token 
    public fun direct_provie_liquidity<Coin0, Coin1, LpToken>(
        account: &signer,
        coin0: Coin<Coin0>,
        coin1: Coin<Coin1>,
        min_liquidity: u64,
    ): Coin<LpToken> acquires PairInfo, PairEvents {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);
        let pair = borrow_global_mut<PairInfo<Coin0, Coin1, LpToken>>(pair_owner);
        
        let total_liquidity = coin::supply<LpToken>();

        let coin0_amount = coin::value(&coin0);
        let coin1_amount = coin::value(&coin1);

        let liquidity = if (total_liquidity == 0) {
            (sqrt((coin0_amount as u128) * (coin1_amount as u128)) as u64)
        } else {
            let coin0_share = decimal::from_ratio((coin0_amount as u128), (coin::value(&pair.coin0) as u128));
            let coin1_share = decimal::from_ratio((coin1_amount as u128), (coin::value(&pair.coin1) as u128));

            let liquidity = if (decimal::val(&coin0_share) > decimal::val(&coin1_share)) {
                decimal::mul(&coin1_share, total_liquidity)
            } else {
                decimal::mul(&coin0_share, total_liquidity)
            };

            (liquidity as u64)
        };

        assert!(min_liquidity < liquidity, error::aborted(EMIN_LIQUIDITY));

        coin::merge(&mut pair.coin0, coin0);
        coin::merge(&mut pair.coin1, coin1);

        let pair_events = borrow_global_mut<PairEvents>(signer::address_of(account));

        event::emit_event<ProvideEvent>(
            &mut pair_events.provide_events,
            ProvideEvent {
                provide_liquidity: liquidity,
                coin0_type: type_info::type_name<Coin0>(),
                coin0_provide_amount: (coin0_amount as u64),
                coin1_type: type_info::type_name<Coin1>(),
                coin1_provide_amount: (coin1_amount as u64),
            },
        );

        coin::mint((liquidity as u64), &pair.lp_token_capabilities.mint_cap)
    }

    /// swap offer coin to return coin
    public entry fun swap<OfferCoin, ReturnCoin, LpToken>(
        account: &signer,
        offer_coin_amount: u64,
    ) acquires PairEvents, PairInfo {
        let offer_coin = coin::withdraw<OfferCoin>(account, offer_coin_amount);

        let return_coin = direct_swap<OfferCoin, ReturnCoin, LpToken>(account, offer_coin);

        coin::deposit<ReturnCoin>(signer::address_of(account), return_coin);
    }

    /// swap with coin
    public fun direct_swap<OfferCoin, ReturnCoin, LpToken>(
        account: &signer,
        offer_coin: Coin<OfferCoin>,
    ): Coin<ReturnCoin> acquires PairEvents, PairInfo {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);
        let offer_amount = coin::value(&offer_coin);

        let compare = coin_type_compare<OfferCoin, ReturnCoin>();

        let pair_events = borrow_global_mut<PairEvents>(signer::address_of(account));

        if (comparator::is_greater_than(&compare)) {
            let pair = borrow_global_mut<PairInfo<OfferCoin, ReturnCoin, LpToken>>(pair_owner);
            let offer_coin_index = 0;
            let (total_return_amount, total_commission_amount) = swap_calculation(pair, offer_amount, offer_coin_index);

            let user_return_amount = total_return_amount - total_commission_amount;

            event::emit_event<SwapEvent>(
                &mut pair_events.swap_events,
                SwapEvent {
                    offer_coin_type: type_info::type_name<OfferCoin>(),
                    offer_amount: coin::value(&offer_coin),
                    return_coin_type: type_info::type_name<ReturnCoin>(),
                    return_amount: user_return_amount,
                    commission_amount: total_commission_amount,
                },
            );

            coin::merge<OfferCoin>(&mut pair.coin0, offer_coin);
            coin::extract<ReturnCoin>(&mut pair.coin1, user_return_amount)
        } else {
            let pair = borrow_global_mut<PairInfo<ReturnCoin, OfferCoin, LpToken>>(pair_owner);
            let offer_coin_index = 1;
            let (total_return_amount, total_commission_amount) = swap_calculation(pair, offer_amount, offer_coin_index);

            let user_return_amount = total_return_amount - total_commission_amount;
            event::emit_event<SwapEvent>(
                &mut pair_events.swap_events,
                SwapEvent {
                    offer_coin_type: type_info::type_name<OfferCoin>(),
                    offer_amount: coin::value(&offer_coin),
                    return_coin_type: type_info::type_name<ReturnCoin>(),
                    return_amount: user_return_amount,
                    commission_amount: total_commission_amount,
                },
            );

            coin::merge<OfferCoin>(&mut pair.coin1, offer_coin);
            coin::extract<ReturnCoin>(&mut pair.coin0, user_return_amount)
        }
    }

    /// withdraw liqudiity
    public entry fun withdraw_liquidity<Coin0, Coin1, LpToken>(
        account: &signer,
        liquidity: u64,
    ) acquires PairEvents, PairInfo {
        assert!(liquidity != 0, error::invalid_argument(EZERO_LIQUIDITY));

        let liquidity_token = coin::withdraw<LpToken>(account, liquidity);

        let (coin0, coin1) = direct_withdraw_liquidity(account, liquidity_token);

        // deposit
        coin::deposit<Coin0>(signer::address_of(account) ,coin0);
        coin::deposit<Coin1>(signer::address_of(account) ,coin1);
    }

    /// withdraw liqudiity with lp token
    public fun direct_withdraw_liquidity<Coin0, Coin1, LpToken>(
        account: &signer,
        liquidity_token: Coin<LpToken>,
    ): (Coin<Coin0>, Coin<Coin1>) acquires PairEvents, PairInfo {
        let type_info = type_info::type_of<LpToken>();
        let pair_owner = type_info::account_address(&type_info);
        let pair = borrow_global_mut<PairInfo<Coin0, Coin1, LpToken>>(pair_owner);
        let liquidity = coin::value(&liquidity_token);

        let total_liquidity = coin::supply<LpToken>();

        let withdrawn_share = decimal::from_ratio((liquidity as u128) ,total_liquidity);

        coin::burn(liquidity_token, &pair.lp_token_capabilities.burn_cap); 

        // calculate withdraw_amount
        let coin0_amount = decimal::mul(&withdrawn_share, (coin::value(&pair.coin0) as u128));
        let coin1_amount = decimal::mul(&withdrawn_share, (coin::value(&pair.coin1) as u128));

        // withdraw
        let coin0 = coin::extract<Coin0>(&mut pair.coin0, (coin0_amount as u64));
        let coin1 = coin::extract<Coin1>(&mut pair.coin1, (coin1_amount as u64));

        let pair_events = borrow_global_mut<PairEvents>(signer::address_of(account));
        event::emit_event<WithdrawEvent>(
            &mut pair_events.withdraw_events,
            WithdrawEvent {
                withdraw_liquidity: liquidity,
                coin0_type: type_info::type_name<Coin0>(),
                coin0_withdraw_amount: (coin0_amount as u64),
                coin1_type: type_info::type_name<Coin1>(),
                coin1_withdraw_amount: (coin1_amount as u64),
            },
        );

        (coin0, coin1)
    }

    fun coin_type_compare<Coin0, Coin1>(): comparator::Result {
        let type_name1 = type_info::type_name<Coin0>();
        let type_name2 = type_info::type_name<Coin1>();

        comparator::compare<vector<u8>>(string::bytes(&type_name1), string::bytes(&type_name2))
    }

    /// calculate swap
    fun swap_calculation<Coin0, Coin1, LpToken>(
        pair: &PairInfo<Coin0, Coin1, LpToken>,
        offer_amount: u64,
        offer_coin_index: u8,
    ): (u64, u64) {
        let (offer_pool_amount, return_pool_amount) = if (offer_coin_index == 0) {
            (
                coin::value(&pair.coin0),
                coin::value(&pair.coin1),
            )
        } else {
            (
                coin::value(&pair.coin1),
                coin::value(&pair.coin0),
            )
        };

        let total_return_amount = ((return_pool_amount as u128) * (offer_amount as u128)) 
            / ((offer_pool_amount as u128) + (offer_amount as u128));

        let total_commission_amount = decimal::mul(&pair.fee_rate, total_return_amount);

        ((total_return_amount as u64), (total_commission_amount as u64))
    }

    /// initialize lp token and make pair info
    fun store_pair_info<Coin0, Coin1, LpToken>(account: &signer, fee_rate: Decimal) {
        let symbol0 = coin::symbol<Coin0>();
        let symbol1 = coin::symbol<Coin1>();
        let name = symbol0;
        string::append_utf8(&mut name, b"-");
        string::append(&mut name, symbol1);
        string::append_utf8(&mut name, b" lp token");

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LpToken>(
            account,
            name,
            string::utf8(b"LP"),
            6,
        );

        move_to(account, PairInfo<Coin0, Coin1, LpToken> {
            coin0: coin::zero<Coin0>(),
            coin1: coin::zero<Coin1>(),
            fee_rate,
            lp_token_capabilities: CoinCapabilities<LpToken> {
                burn_cap, 
                freeze_cap,
                mint_cap,
            },
        });
    }

    /// calculate int squre root
    fun sqrt(num: u128): u128 {
        if (num < 2) {
            return num
        };

        let s = sqrt(num >> 2) << 1;
        let l = s + 1;

        if (l * l > num) {
            return s
        } else {
            return l
        }
    }

    #[test]
    fun test_sqrt() {
        assert!(sqrt(296192746897) == 544235, 0)
    }

    #[test_only]
    struct CoinA { }

    #[test_only]
    struct CoinB { }

    #[test_only]
    struct LpToken { }

    #[test_only]
    struct CoinCaps<phantom CoinType> has key { 
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    #[test_only]
    struct FeeCapWraper<phantom LpToken> has key {
        cap: ChangeFeeRateCapability<LpToken>,
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

    #[test(creator = @dex, user = @0x4)]
    fun end_to_end(
        creator: signer,
        user: signer
    ) acquires PairEvents, PairInfo {
        let creator_address = signer::address_of(&creator);
        let user_address = signer::address_of(&user);

        let (coina_burn_cap, coina_freeze_cap, coina_mint_cap) = initialized_coin<CoinA>(&creator);
        let (coinb_burn_cap, coinb_freeze_cap, coinb_mint_cap) = initialized_coin<CoinB>(&creator);

        coin::register<CoinA>(&creator);
        coin::register<CoinB>(&creator);
        coin::register<CoinA>(&user);
        coin::register<CoinB>(&user);
        register(&creator);
        register(&user);

        coin::deposit<CoinA>(creator_address, coin::mint<CoinA>(1000000000000000, &coina_mint_cap));
        coin::deposit<CoinB>(creator_address, coin::mint<CoinB>(1000000000000000, &coinb_mint_cap));
        coin::deposit<CoinA>(user_address, coin::mint<CoinA>(1000000000000000, &coina_mint_cap));
        coin::deposit<CoinB>(user_address, coin::mint<CoinB>(1000000000000000, &coinb_mint_cap));

        // create_pool
        let change_fee_cap = create_pool<CoinA, CoinB, LpToken>(&creator, string::utf8(b"0.003"));

        // provide_test
        provide_liquidity<CoinB, CoinA, LpToken>(&user, 1000000, 1000000, 9000);

        let PairStateResponse { coin0_amount, coin1_amount, total_liquidity } = pair_state<CoinB, CoinA, LpToken>();
        assert!(coin0_amount == 1000000, 0);
        assert!(coin1_amount == 1000000, 1);
        assert!(total_liquidity == 1000000, 2);

        assert!(coin::balance<LpToken>(user_address) == 1000000, 3);

        // swap CoinA to CoinB
        swap<CoinA, CoinB, LpToken>(&user, 1000);

        let PairStateResponse { coin0_amount, coin1_amount, total_liquidity } = pair_state<CoinB, CoinA, LpToken>();
        assert!(coin0_amount == 999003, 4);
        assert!(coin1_amount == 1001000, 5);
        assert!(total_liquidity == 1000000, 6);

        assert!(coin::balance<CoinA>(user_address) == 1000000000000000 - 1001000, 7);
        assert!(coin::balance<CoinB>(user_address) == 1000000000000000 - 999003, 8);

        // withdraw
        withdraw_liquidity<CoinB, CoinA, LpToken>(&user, 500000);

        let PairStateResponse { coin0_amount, coin1_amount, total_liquidity } = pair_state<CoinB, CoinA, LpToken>();
        assert!(coin0_amount == 499502, 9);
        assert!(coin1_amount == 500500, 10);
        assert!(total_liquidity == 500000, 11);

        assert!(coin::balance<CoinA>(user_address) == 1000000000000000 - 500500, 12);
        assert!(coin::balance<CoinB>(user_address) == 1000000000000000 - 499502, 13);

        // update fee
        update_fee_rate<CoinB, CoinA, LpToken>(&creator, string::utf8(b"0.01"), &change_fee_cap);
        assert!(get_fee_rate<CoinB, CoinA, LpToken>() == decimal::from_ratio(1, 100), 14);

        // clear
        move_to(&creator, CoinCaps<CoinA> {
            burn_cap: coina_burn_cap,
            freeze_cap: coina_freeze_cap,
            mint_cap: coina_mint_cap,
        });

        move_to(&creator, CoinCaps<CoinB> {
            burn_cap: coinb_burn_cap,
            freeze_cap: coinb_freeze_cap,
            mint_cap: coinb_mint_cap,
        });

        move_to(&creator, FeeCapWraper<LpToken> {
            cap: change_fee_cap,
        });
    }

    #[test(source = @dex)]
    #[expected_failure(abort_code = 0x10000)]
    fun test_create_with_same_coin_type(source: signer) {
        let (coina_burn_cap, coina_freeze_cap, coina_mint_cap) = initialized_coin<CoinA>(&source);
        let change_fee_cap = create_pool<CoinA, CoinA, LpToken>(&source, string::utf8(b"0.003"));

        // clear
        move_to(&source, FeeCapWraper<LpToken> {
            cap: change_fee_cap,
        });

        move_to(&source, CoinCaps<CoinA> {
            burn_cap: coina_burn_cap,
            freeze_cap: coina_freeze_cap,
            mint_cap: coina_mint_cap,
        });
    }

    #[test(source = @dex)]
    fun test_provide_share_calc(source: signer) acquires PairEvents, PairInfo {
        let source_addr = signer::address_of(&source);
        let (coina_burn_cap, coina_freeze_cap, coina_mint_cap) = initialized_coin<CoinA>(&source);
        let (coinb_burn_cap, coinb_freeze_cap, coinb_mint_cap) = initialized_coin<CoinB>(&source);

        let change_fee_cap = create_pool<CoinA, CoinB, LpToken>(&source, string::utf8(b"0.003"));

        coin::register<CoinA>(&source);
        coin::register<CoinB>(&source);
        register(&source);

        coin::deposit<CoinA>(source_addr, coin::mint<CoinA>(1000000000000000, &coina_mint_cap));
        coin::deposit<CoinB>(source_addr, coin::mint<CoinB>(1000000000000000, &coinb_mint_cap));

        // provide
        provide_liquidity<CoinB, CoinA, LpToken>(&source, 1000000, 1000000, 9000);

        // provide
        provide_liquidity<CoinB, CoinA, LpToken>(&source, 2000000, 1000000, 9000); // 1000000 CoinB will be returned

        let PairStateResponse { coin0_amount, coin1_amount, total_liquidity } = pair_state<CoinB, CoinA, LpToken>();
        assert!(coin0_amount == 2000000, 0);
        assert!(coin1_amount == 2000000, 1);
        assert!(total_liquidity == 2000000, 2);

        move_to(&source, FeeCapWraper<LpToken> {
            cap: change_fee_cap,
        });

        move_to(&source, CoinCaps<CoinA> {
            burn_cap: coina_burn_cap,
            freeze_cap: coina_freeze_cap,
            mint_cap: coina_mint_cap,
        });

        move_to(&source, CoinCaps<CoinB> {
            burn_cap: coinb_burn_cap,
            freeze_cap: coinb_freeze_cap,
            mint_cap: coinb_mint_cap,
        });
    }


    #[test(source = @dex)]
    fun test_withdraw_calc(source: signer) acquires PairEvents, PairInfo {
        let source_addr = signer::address_of(&source);
        let (coina_burn_cap, coina_freeze_cap, coina_mint_cap) = initialized_coin<CoinA>(&source);
        let (coinb_burn_cap, coinb_freeze_cap, coinb_mint_cap) = initialized_coin<CoinB>(&source);

        let change_fee_cap = create_pool<CoinA, CoinB, LpToken>(&source, string::utf8(b"0.003"));

        coin::register<CoinA>(&source);
        coin::register<CoinB>(&source);
        register(&source);

        coin::deposit<CoinA>(source_addr, coin::mint<CoinA>(1000000000000000, &coina_mint_cap));
        coin::deposit<CoinB>(source_addr, coin::mint<CoinB>(1000000000000000, &coinb_mint_cap));

        // provide
        provide_liquidity<CoinB, CoinA, LpToken>(&source, 1000000, 1000000, 9000);

        // withdraw
        withdraw_liquidity<CoinB, CoinA, LpToken>(&source, 200000);

        let PairStateResponse { coin0_amount, coin1_amount, total_liquidity } = pair_state<CoinB, CoinA, LpToken>();
        assert!(coin0_amount == 800000, 0);
        assert!(coin1_amount == 800000, 1);
        assert!(total_liquidity == 800000, 2);

        assert!(coin::balance<CoinA>(source_addr) == 1000000000000000 - 800000, 3);
        assert!(coin::balance<CoinB>(source_addr) == 1000000000000000 - 800000, 4);

        move_to(&source, FeeCapWraper<LpToken> {
            cap: change_fee_cap,
        });

        move_to(&source, CoinCaps<CoinA> {
            burn_cap: coina_burn_cap,
            freeze_cap: coina_freeze_cap,
            mint_cap: coina_mint_cap,
        });

        move_to(&source, CoinCaps<CoinB> {
            burn_cap: coinb_burn_cap,
            freeze_cap: coinb_freeze_cap,
            mint_cap: coinb_mint_cap,
        });
    }
}
