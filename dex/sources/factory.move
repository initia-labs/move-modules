module dex_util::factory {
    use std::table::{Self, Table};
    use std::signer;
    use std::vector;
    use std::string::{Self, String};
    use std::error;
    use std::comparator;
    
    use initia_std::type_info;
    use initia_std::coin;

    use dex::pair;

    // Errors
    const EUNAUTHORIZED: u64 = 0;
    const EPOOL_ALREADY_EXIST: u64 = 1;
    const EPOOL_NOT_FOUND: u64 = 2;
    const ESAME_COIN_TYPE: u64 = 3;

    // Data structures
    struct LiquidityToken<phantom Coin0, phantom Coin1> { }

    struct ModuleStore has key {
        // Key: Coin0 + Coin1
        pairs: Table<vector<u8>, bool>,
    }

    struct CapabilityStore<phantom LiquidityToken> has key {
        cap: pair::ChangeFeeRateCapability<LiquidityToken>,
    }

    ///
    /// Query entry functions
    ///
    
    public entry fun pair_exist<Coin0, Coin1>(): bool acquires ModuleStore {
        let module_store = borrow_global_mut<ModuleStore>(@dex_util);
        let pool_key = gen_pool_key<Coin0, Coin1>();

        table::contains(&module_store.pairs, pool_key)
    } 

    ///
    /// Execute entry functions
    ///

    public entry fun initialize(account: &signer) {
        assert!(@dex_util == signer::address_of(account), error::permission_denied(EUNAUTHORIZED));
        
        let store = ModuleStore {
            pairs: table::new(account),
        };

        move_to(account, store);
    }

    public entry fun create_pair<Coin0, Coin1>(
        account: &signer,
        fee_rate: String,
    ) acquires ModuleStore {
        assert!(@dex_util == signer::address_of(account), error::permission_denied(EUNAUTHORIZED));

        let module_store = borrow_global_mut<ModuleStore>(@dex_util);
        let pool_key = gen_pool_key<Coin0, Coin1>();

        assert!(!table::contains(&module_store.pairs, pool_key), error::already_exists(EPOOL_ALREADY_EXIST));
        table::add(
            &mut module_store.pairs,
            pool_key,
            true,
        );

        let type_name1 = type_info::type_name<Coin0>();
        let type_name2 = type_info::type_name<Coin1>();
        let compare = comparator::compare<vector<u8>>(string::bytes(&type_name1), string::bytes(&type_name2));

        if (comparator::is_greater_than(&compare)) {
            let cap = pair::create_pool<Coin0, Coin1, LiquidityToken<Coin0, Coin1>>(account, fee_rate);
            move_to(account, CapabilityStore { cap })
        } else {
            let cap = pair::create_pool<Coin0, Coin1, LiquidityToken<Coin1, Coin0>>(account, fee_rate);
            move_to(account, CapabilityStore { cap })
        };

        let cap = pair::create_pool<Coin0, Coin1, LiquidityToken<Coin0, Coin1>>(account, fee_rate);
        move_to(account, CapabilityStore { cap })
    }

    public entry fun update_fee_rate<Coin0, Coin1>(
        account: &signer,
        new_fee_rate: String,
    ) acquires ModuleStore, CapabilityStore {
        assert!(@dex_util == signer::address_of(account), error::permission_denied(EUNAUTHORIZED));

        let module_store = borrow_global_mut<ModuleStore>(@dex_util);
        let pool_key = gen_pool_key<Coin0, Coin1>();

        assert!(table::contains(&module_store.pairs, pool_key), error::not_found(EPOOL_NOT_FOUND));

        let cap_store = borrow_global<CapabilityStore<LiquidityToken<Coin0, Coin1>>>(@dex_util);

        pair::update_fee_rate<Coin0, Coin1, LiquidityToken<Coin0, Coin1>>(account, new_fee_rate, &cap_store.cap);
    }

    /// generate pool key
    fun gen_pool_key<Coin0, Coin1>(): vector<u8> {
        let type_name1 = type_info::type_name<Coin0>();
        let type_name2 = type_info::type_name<Coin1>();

        let compare = comparator::compare<vector<u8>>(string::bytes(&type_name1), string::bytes(&type_name2));

        assert!(!comparator::is_equal(&compare), error::invalid_argument(ESAME_COIN_TYPE));

        let key: vector<u8>;

        if (comparator::is_greater_than(&compare)) {
            key = *string::bytes(&type_name1);
            vector::append(&mut key, *string::bytes(&type_name2));
        } else {
            key = *string::bytes(&type_name2);
            vector::append(&mut key, *string::bytes(&type_name1));
        };

        return key
    }

    #[test_only]
    struct CoinA { }

    #[test_only]
    struct CoinB { }

    #[test_only]
    struct CoinC { }

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

    #[test(creator = @dex_util)]
    fun end_to_end(
        creator: signer,
    ) acquires ModuleStore {
        initialize(&creator);

        let (coina_burn_cap, coina_freeze_cap, coina_mint_cap) = initialized_coin<CoinA>(&creator);
        let (coinb_burn_cap, coinb_freeze_cap, coinb_mint_cap) = initialized_coin<CoinB>(&creator);

        create_pair<CoinA, CoinB>(&creator, string::utf8(b"0.003"));

        assert!(pair_exist<CoinA, CoinB>(), 0);

        let (amount0, amount1, liquidity) = pair::pair_state<CoinB, CoinA, LiquidityToken<CoinB, CoinA>>();
        assert!(amount0 + amount1 == 0 && liquidity == 0, 1);

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
    }
}
