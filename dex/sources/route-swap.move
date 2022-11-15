module dex_util::route_swap {
    use std::signer;
    use std::error;

    use initia_std::coin::{Self, Coin};

    use dex::pair;
    
    // Errors
    const EMIN_RETURN: u64 = 0;

    // Data structures

    struct CoinStation<phantom CoinType> has key {
        coin: Coin<CoinType>,
    }

    public entry fun deposit<CoinType>(account: &signer, amount: u64) acquires CoinStation {
        let coin = coin::withdraw<CoinType>(account, amount);
        direct_deposit(account, coin);
    }

    public fun direct_deposit<CoinType>(account: &signer, coin: Coin<CoinType>) acquires CoinStation {
        let addr = signer::address_of(account);
        if (!exists<CoinStation<CoinType>>(addr)) {
            move_to(account, CoinStation<CoinType> {
                coin: coin::zero(),
            });
        };

        let station = borrow_global_mut<CoinStation<CoinType>>(addr);
        coin::merge(&mut station.coin, coin);
    }

    public entry fun withdraw<CoinType>(account: &signer): Coin<CoinType> acquires CoinStation {
        let addr = signer::address_of(account);
        let station = borrow_global_mut<CoinStation<CoinType>>(addr);
        coin::extract_all(&mut station.coin)
    }

    public entry fun swap<OfferCoin, ReturnCoin, LpToken>(
        account: &signer,
        is_first: bool,
        offer_amount: u64,
        is_last: bool,
        min_return_amount: u64,
    ) acquires CoinStation {
        let addr = signer::address_of(account);
        let offer_coin = if (is_first) {
            coin::withdraw<OfferCoin>(account, offer_amount)
        } else {
            withdraw<OfferCoin>(account)
        };

        let return_coin = pair::direct_swap<OfferCoin, ReturnCoin, LpToken>(account, offer_coin);

        if (is_last) {
            assert!(min_return_amount <= coin::value(&return_coin), error::aborted(EMIN_RETURN));
            coin::deposit(addr, return_coin)
        } else {
            direct_deposit<ReturnCoin>(account, return_coin)
        }
    }

    #[test_only]
    struct CoinA { }

    #[test_only]
    struct CoinB { }

    #[test_only]
    struct CoinC { }

    #[test_only]
    struct CoinD { }

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
    use std::string; 
    use dex_util::factory;
    use dex_util::factory::LiquidityToken;

    #[test(creator = @dex_util)]
    fun end_to_end(
        creator: signer,
    ) acquires CoinStation {
    // ){
        let creator_address = signer::address_of(&creator);
        let (coina_burn_cap, coina_freeze_cap, coina_mint_cap) = initialized_coin<CoinA>(&creator);
        let (coinb_burn_cap, coinb_freeze_cap, coinb_mint_cap) = initialized_coin<CoinB>(&creator);
        let (coinc_burn_cap, coinc_freeze_cap, coinc_mint_cap) = initialized_coin<CoinC>(&creator);
        let (coind_burn_cap, coind_freeze_cap, coind_mint_cap) = initialized_coin<CoinD>(&creator);

        coin::register<CoinA>(&creator);
        coin::register<CoinB>(&creator);
        coin::register<CoinC>(&creator);
        coin::register<CoinD>(&creator);

        coin::deposit<CoinA>(creator_address, coin::mint<CoinA>(1000000000000000, &coina_mint_cap));
        coin::deposit<CoinB>(creator_address, coin::mint<CoinB>(1000000000000000, &coinb_mint_cap));
        coin::deposit<CoinC>(creator_address, coin::mint<CoinC>(1000000000000000, &coinc_mint_cap));
        coin::deposit<CoinD>(creator_address, coin::mint<CoinD>(1000000000000000, &coind_mint_cap));

        factory::initialize(&creator);

        factory::create_pair<CoinA, CoinB>(&creator, string::utf8(b"0.003"));
        factory::create_pair<CoinB, CoinC>(&creator, string::utf8(b"0.003"));
        factory::create_pair<CoinC, CoinD>(&creator, string::utf8(b"0.003"));

        pair::register(&creator);

        pair::provie_liquidity<CoinB, CoinA, LiquidityToken<CoinB, CoinA>>(&creator, 1000000, 1000000, 9000);
        pair::provie_liquidity<CoinC, CoinB, LiquidityToken<CoinC, CoinB>>(&creator, 1000000, 1000000, 9000);
        pair::provie_liquidity<CoinD, CoinC, LiquidityToken<CoinD, CoinC>>(&creator, 1000000, 1000000, 9000);

        // execute 3 msgs at once
        swap<CoinA, CoinB, LiquidityToken<CoinB, CoinA>>(&creator, true, 1000, false, 0);
        swap<CoinB, CoinC, LiquidityToken<CoinC, CoinB>>(&creator, false, 0, false, 0);
        swap<CoinC, CoinD, LiquidityToken<CoinD, CoinC>>(&creator, false, 0, true, 900);

        assert!(coin::balance<CoinA>(creator_address) == 1000000000000000 - 1000000 - 1000, 0);
        assert!(coin::balance<CoinB>(creator_address) == 1000000000000000 - 2 * 1000000, 1);
        assert!(coin::balance<CoinC>(creator_address) == 1000000000000000 - 2 * 1000000, 2);
        assert!(coin::balance<CoinD>(creator_address) == 1000000000000000 - 1000000 + 991, 3);

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

        move_to(&creator, CoinCaps<CoinC> {
            burn_cap: coinc_burn_cap,
            freeze_cap: coinc_freeze_cap,
            mint_cap: coinc_mint_cap,
        });

        move_to(&creator, CoinCaps<CoinD> {
            burn_cap: coind_burn_cap,
            freeze_cap: coind_freeze_cap,
            mint_cap: coind_mint_cap,
        });
    }
}
