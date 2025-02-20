module dex_utils::dex_utils {
    use std::error;
    use std::signer;
    use std::string::String;
    use std::option::{Self, Option};
    use std::vector;

    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::bigdecimal::{Self, BigDecimal};
    use initia_std::biguint;
    use initia_std::dex::{Self, Config};
    use initia_std::stableswap::{Self, Pool};
    use initia_std::object::{Self, Object};
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};

    /// Errors
    
    const EMIN_RETURN: u64 = 1;

    const EINVALID_TOKEN: u64 = 2;

    // view functions. Simulate and calculate price impact

    #[view]
    public fun get_route_swap_simulation(
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>, // path of pair
        offer_amount: u64,
    ): (u64, vector<BigDecimal>) {
        let price_impacts: vector<BigDecimal> = vector[];
        let index = 0;
        let len = vector::length(&route);
        while(index < len) {
            let pair = *vector::borrow(&route, index);
            let (offer_amount_, price_impact) = get_swap_simulation(pair, offer_asset_metadata, offer_amount);
            offer_amount = offer_amount_;
            let (metadata_a, metadata_b) = dex::pool_metadata(pair);
            offer_asset_metadata = if (offer_asset_metadata == metadata_a) {
                metadata_b
            } else {
                metadata_a
            };
            vector::push_back(&mut price_impacts, price_impact);
            index = index + 1;
        };
        let return_amount =  offer_amount;
        (return_amount, price_impacts)
    }

    #[view]
    public fun provide_liquidity_cal(
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
    ): u64 {
        let total_share = option::extract(&mut fungible_asset::supply(pair));
        let pool_info = dex::get_pool_info(pair);
        let coin_a_amount = dex::get_coin_a_amount_from_pool_info_response(&pool_info);
        let coin_b_amount = dex::get_coin_b_amount_from_pool_info_response(&pool_info);

        if (total_share == 0) {
            if (coin_a_amount_in > coin_b_amount_in) {
                coin_a_amount_in
            } else {
                coin_b_amount_in
            }
        } else {
            let a_share_ratio = bigdecimal::from_ratio_u64(coin_a_amount_in, coin_a_amount);
            let b_share_ratio = bigdecimal::from_ratio_u64(coin_b_amount_in, coin_b_amount);
            if (bigdecimal::gt(a_share_ratio, b_share_ratio)) {
                (bigdecimal::mul_by_u128_truncate(b_share_ratio, total_share) as u64)
            } else {
                (bigdecimal::mul_by_u128_truncate(a_share_ratio, total_share) as u64)
            }
        }
    }

    #[view]
    public fun single_asset_provide_liquidity_cal(
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        amount_in: u64
    ): (u64, BigDecimal) {
        let (coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight, swap_fee_rate) = dex::pool_info(pair, false);
        let (metadata_a, metadata_b) = dex::pool_metadata(pair);
        let price_before = get_spot_price(coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight);

        let is_coin_b = metadata_b == offer_asset_metadata;
        let is_coin_a = metadata_a == offer_asset_metadata;
        assert!(is_coin_b || is_coin_a, error::invalid_argument(EINVALID_TOKEN));

        let total_share = option::extract(&mut fungible_asset::supply(pair));
        assert!(total_share != 0, error::invalid_state(1));
        let (normalized_weight, pool_amount_in) = if (is_coin_a) {
            let normalized_weight = bigdecimal::div(
                coin_a_weight,
                bigdecimal::add(coin_a_weight, coin_b_weight)
            );

            coin_a_amount = coin_a_amount + amount_in;
            let pool_amount_in = coin_a_amount;
            (normalized_weight, pool_amount_in)
        } else {
            let normalized_weight = bigdecimal::div(
                coin_b_weight,
                bigdecimal::add(coin_a_weight, coin_b_weight)
            );

            coin_b_amount = coin_b_amount + amount_in;
            let pool_amount_in = coin_b_amount;
            (normalized_weight, pool_amount_in)
        };
        let price_after = get_spot_price(coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight);

        // compute fee amount with the assumption that we will swap (1 - normalized_weight) of amount_in
        let adjusted_swap_amount = bigdecimal::mul_by_u128_truncate(
            bigdecimal::sub(bigdecimal::one(), normalized_weight),
            (amount_in as u128)
        );
        let fee_amount = bigdecimal::mul_by_u128_truncate(swap_fee_rate, adjusted_swap_amount);

        // actual amount in after deducting fee amount
        let adjusted_amount_in = amount_in - (fee_amount as u64);

        // calculate new total share and new liquidity
        let base = bigdecimal::from_ratio_u128((adjusted_amount_in + (pool_amount_in as u64) as u128), (pool_amount_in as u128));
        let pool_ratio = pow(base, normalized_weight);
        let new_total_share = bigdecimal::mul_by_u128_truncate(pool_ratio, total_share);

        ((new_total_share - total_share as u64), get_price_impact(price_before, price_after))
    }

    #[view]
    public fun get_swap_simulation(
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        offer_amount: u64,
    ): (u64, BigDecimal) {
        let (coin_a_pool, coin_b_pool, coin_a_weight, coin_b_weight, swap_fee_rate) = dex::pool_info(pair, true);
        let (metadata_a, _) = dex::pool_metadata(pair);
        let is_offer_a = metadata_a == offer_asset_metadata;
        let (offer_pool, return_pool, offer_weight, return_weight) = if (is_offer_a) {
            (coin_a_pool, coin_b_pool, coin_a_weight, coin_b_weight)
        } else {
            (coin_b_pool, coin_a_pool, coin_b_weight, coin_a_weight)
        };
        let price_before = get_spot_price(offer_pool, return_pool, offer_weight, return_weight);
        let (return_amount, _fee_amount) = dex::swap_simulation(
            offer_pool,
            return_pool,
            offer_weight,
            return_weight,
            offer_amount,
            swap_fee_rate,
        );

        let price_after = get_spot_price(offer_pool + offer_amount, return_pool - return_amount, offer_weight, return_weight);

        (return_amount, get_price_impact(price_before, price_after))
    }

    // entry functions

    public entry fun stableswap_provide_stake(
        account: &signer,
        pool_obj: Object<Pool>,
        coin_amounts: vector<u64>,
        min_liquidity: Option<u64>,
        validator: String,
    ) {
        let coins: vector<FungibleAsset> = vector[];
        let (coin_metadata,_,_,_) = stableswap::pool_info(pool_obj);

        let i = 0;
        let n = vector::length(&coin_amounts);
        while (i < n) {
            let metadata = *vector::borrow(&coin_metadata, i);
            let amount = *vector::borrow(&coin_amounts, i);
            vector::push_back(
                &mut coins,
                coin::withdraw(account, metadata, amount)
            );
            i = i + 1;
        };

        let liquidity_token = stableswap::provide_liquidity(pool_obj, coins, min_liquidity);
        let liquidity_amount = fungible_asset::amount(&liquidity_token);

        coin::deposit(signer::address_of(account), liquidity_token);
        cosmos::delegate(account, validator, object::convert<Pool, Metadata>(pool_obj), liquidity_amount);
    }

    public entry fun provide_stake(
        account: &signer,
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String,
    ) {
        let (metadata_a, metadata_b) = dex::pool_metadata(pair);

        // calculate the best coin amount
        let (coin_a_amount_in, coin_b_amount_in) = get_exact_provide_amount(pair, coin_a_amount_in, coin_b_amount_in);
        let coin_a = coin::withdraw(account, metadata_a, coin_a_amount_in);
        let coin_b = coin::withdraw(account, metadata_b, coin_b_amount_in);

        let liquidity_token = dex::provide_liquidity(
            pair,
            coin_a,
            coin_b,
            min_liquidity,
        );

        let provide_amount = fungible_asset::amount(&liquidity_token);

        coin::deposit(signer::address_of(account), liquidity_token);

        cosmos::delegate(account, validator, object::convert<Config, Metadata>(pair), provide_amount);
    }

    public entry fun single_asset_provide_stake(
        account: &signer,
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String,
    ) {
        let addr = signer::address_of(account);
        let provide_coin = coin::withdraw(account, offer_asset_metadata, amount_in);

        let liquidity_token = dex::single_asset_provide_liquidity(
            pair,
            provide_coin,
            min_liquidity,
        );

        let provide_amount = fungible_asset::amount(&liquidity_token);

        coin::deposit(addr, liquidity_token);

        cosmos::delegate(account, validator, object::convert<Config, Metadata>(pair), provide_amount);
    }

    public entry fun route_swap(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>, // path of pair
        amount: u64,
        min_return_amount: Option<u64>,
    ) {
        let addr = signer::address_of(account);
        let offer_coin = coin::withdraw(account, offer_asset_metadata, amount);

        let return_coin = route_swap_raw(offer_coin, route);
        if (option::is_some(&min_return_amount)) {
            let min_return = option::borrow(&min_return_amount); 
            assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
        };

        coin::deposit(addr, return_coin);
    }

    // public functions

    public fun route_swap_raw(
        offer_coin: FungibleAsset,
        route: vector<Object<Config>>, // path of pair
    ): FungibleAsset {
        let index = 0;
        let len = vector::length(&route);
        while(index < len) {
            let pair = vector::borrow(&route, index);
            offer_coin = dex::swap(*pair, offer_coin);
            index = index + 1;
        };
        let return_coin = offer_coin; // just for clarity
        return_coin
    }

    // util functions

    fun get_exact_provide_amount(pair: Object<Config>, coin_a_amount_in: u64, coin_b_amount_in : u64): (u64, u64) {
        let pool_info = dex::get_pool_info(pair);
        let coin_a_amount = dex::get_coin_a_amount_from_pool_info_response(&pool_info);
        let coin_b_amount = dex::get_coin_b_amount_from_pool_info_response(&pool_info);
        let total_share = option::extract(&mut fungible_asset::supply(pair));

        // calculate the best coin amount
        if (total_share == 0) {
            (coin_a_amount_in, coin_b_amount_in)
        } else {
            let a_share_ratio = bigdecimal::from_ratio_u64(coin_a_amount_in, coin_a_amount);
            let b_share_ratio = bigdecimal::from_ratio_u64(coin_b_amount_in, coin_b_amount);
            if (bigdecimal::gt(a_share_ratio, b_share_ratio)) {
                coin_a_amount_in = bigdecimal::mul_by_u64_truncate(b_share_ratio, coin_a_amount);
            } else {
                coin_b_amount_in = bigdecimal::mul_by_u64_truncate(a_share_ratio, coin_b_amount);
            };

            (coin_a_amount_in, coin_b_amount_in)
        }
    }

    fun get_spot_price(base_pool: u64, quote_pool: u64, base_weight: BigDecimal, quote_weight: BigDecimal): BigDecimal {
        bigdecimal::from_ratio_u64(
            bigdecimal::mul_by_u64_truncate(base_weight, quote_pool), 
            bigdecimal::mul_by_u64_truncate(quote_weight, base_pool),
        )
    }

    /// a^x = 1 + sigma[(k^n)/n!]
    /// k = x * ln(a)
    fun pow(base: BigDecimal, exp: BigDecimal): BigDecimal {
        assert!(
            !bigdecimal::is_zero(base) && bigdecimal::lt(base, bigdecimal::from_u64(2)),
            error::invalid_argument(123)
        );

        let res = bigdecimal::one();
        let (ln_a, neg) = ln(base);
        let k = bigdecimal::mul(ln_a, exp);
        let comp = k;
        let index = 1;
        let subs: vector<BigDecimal> = vector[];

        let precision = bigdecimal::from_scaled(biguint::from_u64(100000));
        while (bigdecimal::gt(comp, precision)) {
            if (index & 1 == 1 && neg) {
                vector::push_back(&mut subs, comp)
            } else {
                res = bigdecimal::add(res, comp)
            };

            comp = bigdecimal::div_by_u64(bigdecimal::mul(comp, k), index + 1);
            index = index + 1;
        };

        let index = 0;
        while (index < vector::length(&subs)) {
            let comp = vector::borrow(&subs, index);
            res = bigdecimal::sub(res, *comp);
            index = index + 1;
        };

        res
    }

    fun ln(num: BigDecimal): (BigDecimal, bool) {
        let one = bigdecimal::one();
        let (a, a_neg) =
            if (bigdecimal::ge(num, one)) {
                (bigdecimal::sub(num, one), false)
            } else {
                (bigdecimal::sub(one, num), true)
            };

        let res = bigdecimal::zero();
        let comp = a;
        let index = 1;

        let precision = bigdecimal::from_scaled(biguint::from_u64(100000));
        while (bigdecimal::gt(comp, precision)) {
            if (index & 1 == 0 && !a_neg) {
                res = bigdecimal::sub(res, comp);
            } else {
                res = bigdecimal::add(res, comp);
            };

            // comp(old) = a ^ n / n
            // comp(new) = comp(old) * a * n / (n + 1) = a ^ (n + 1) / (n + 1)
            comp = bigdecimal::div_by_u64(
                bigdecimal::mul_by_u64(bigdecimal::mul(comp, a), index), // comp * a * index
                index + 1
            );

            index = index + 1;
        };

        (res, a_neg)
    }

    fun get_price_impact(price_before: BigDecimal, price_after: BigDecimal): BigDecimal {
        if (bigdecimal::gt(price_before, price_after)) {
            bigdecimal::div(bigdecimal::sub(price_before, price_after), price_before)
        } else {
            bigdecimal::div(bigdecimal::sub(price_after, price_before), price_after)
        }
    }
}
