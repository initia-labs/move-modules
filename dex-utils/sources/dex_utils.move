module dex_utils::dex_utils {
    use std::error;
    use std::signer;
    use std::string::String;
    use std::option::{Self, Option};
    use std::vector;

    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::decimal128::{Self, Decimal128};
    use initia_std::dex::{Self, Config};
    use initia_std::object::{Self, Object};
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};

    /// Errors
    
    const EMIN_RETURN: u64 = 1;

    public entry fun route_swap(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>, // path of pair
        amount: u64,
        min_return_amount: Option<u64>,
    ) {
        let addr = signer::address_of(account);
        let offer_coin = coin::withdraw(account, offer_asset_metadata, amount);

        let return_coin = route_swap_raw(account, offer_coin, route);
        if (option::is_some(&min_return_amount)) {
            let min_return = option::borrow(&min_return_amount); 
            assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
        };

        coin::deposit(addr, return_coin);
    }

    public fun route_swap_raw(
        _account: &signer,
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

    #[view]
    public fun get_route_swap_simulation(
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>, // path of pair
        offer_amount: u64,
    ): (u64, vector<Decimal128>) {
        let price_impacts: vector<Decimal128> = vector[];
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

    #[view]
    public fun provide_liquidity_cal(
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
    ): u64 {
        let (coin_a_amount_in, coin_b_amount_in) = get_exact_provide_amount(pair, coin_a_amount_in, coin_b_amount_in);
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
            let uinit_share_ratio = decimal128::from_ratio_u64(coin_a_amount_in, coin_a_amount);
            let counterpart_share_ratio = decimal128::from_ratio_u64(coin_b_amount_in, coin_b_amount);
            if (decimal128::val(&uinit_share_ratio) > decimal128::val(&counterpart_share_ratio)) {
                (decimal128::mul_u128(&counterpart_share_ratio, total_share) as u64)
            } else {
                (decimal128::mul_u128(&uinit_share_ratio, total_share) as u64)
            }
        }
    }

    #[view]
    public fun single_asset_provide_liquidity_cal(
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        amount_in: u64
    ): (u64, Decimal128) {
        let (coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight, swap_fee_rate) = dex::pool_info(pair, false);
        let (metadata_a, metadata_b) = dex::pool_metadata(pair);
        let price_before = get_spot_price(coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight);

        let is_coin_b = metadata_b == offer_asset_metadata;
        let is_coin_a = metadata_a == offer_asset_metadata;
        assert!(is_coin_b || is_coin_a, error::invalid_argument(112));

        let total_share = option::extract(&mut fungible_asset::supply(pair));
        assert!(total_share != 0, error::invalid_state(1));
        let (normalized_weight, pool_amount_in) = if (is_coin_a) {
            let normalized_weight = decimal128::from_ratio(
                decimal128::val(&coin_a_weight),
                decimal128::val(&coin_a_weight) + decimal128::val(&coin_b_weight)
            );

            coin_a_amount = coin_a_amount + amount_in;
            let pool_amount_in = coin_a_amount;
            (normalized_weight, pool_amount_in)
        } else {
            let normalized_weight = decimal128::from_ratio(
                decimal128::val(&coin_b_weight),
                decimal128::val(&coin_a_weight) + decimal128::val(&coin_b_weight)
            );

            coin_b_amount = coin_b_amount + amount_in;
            let pool_amount_in = coin_b_amount;
            (normalized_weight, pool_amount_in)
        };
        let price_after = get_spot_price(coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight);

        // compute fee amount with the assumption that we will swap (1 - normalized_weight) of amount_in
        let adjusted_swap_amount = decimal128::mul_u128(
            &decimal128::sub(&decimal128::one(), &normalized_weight),
            (amount_in as u128)
        );
        let fee_amount = decimal128::mul_u128(&swap_fee_rate, adjusted_swap_amount);

        // actual amount in after deducting fee amount
        let adjusted_amount_in = amount_in - (fee_amount as u64);

        // calculate new total share and new liquidity
        let base = decimal128::from_ratio((adjusted_amount_in + (pool_amount_in as u64) as u128), (pool_amount_in as u128));
        let pool_ratio = pow(&base, &normalized_weight);
        let new_total_share = decimal128::mul_u128(&pool_ratio, total_share);

        ((new_total_share - total_share as u64), get_price_impact(price_before, price_after))
    }

    #[view]
    public fun get_swap_simulation(
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        offer_amount: u64,
    ): (u64, Decimal128) {
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

    fun get_exact_provide_amount(pair: Object<Config>, coin_a_amount_in: u64, coin_b_amount_in : u64): (u64, u64) {
        let pool_info = dex::get_pool_info(pair);
        let coin_a_amount = dex::get_coin_a_amount_from_pool_info_response(&pool_info);
        let coin_b_amount = dex::get_coin_b_amount_from_pool_info_response(&pool_info);
        let total_share = option::extract(&mut fungible_asset::supply(pair));

        // calculate the best coin amount
        if (total_share == 0) {
            (coin_a_amount_in, coin_b_amount_in)
        } else {
            let uinit_share_ratio = decimal128::from_ratio_u64(coin_a_amount_in, coin_a_amount);
            let counterpart_share_ratio = decimal128::from_ratio_u64(coin_b_amount_in, coin_b_amount);
            if (decimal128::val(&uinit_share_ratio) > decimal128::val(&counterpart_share_ratio)) {
                coin_a_amount_in = decimal128::mul_u64(&counterpart_share_ratio, coin_a_amount);
            } else {
                coin_b_amount_in = decimal128::mul_u64(&uinit_share_ratio, coin_b_amount);
            };

            (coin_a_amount_in, coin_b_amount_in)
        }
    }

    fun get_spot_price(base_pool: u64, quote_pool: u64, base_weight: Decimal128, quote_weight: Decimal128): Decimal128 {
        decimal128::from_ratio_u64(
            decimal128::mul_u64(&base_weight, quote_pool), 
            decimal128::mul_u64(&quote_weight, base_pool),
        )
    }

    /// a^x = 1 + sigma[(k^n)/n!]
    /// k = x * ln(a)
    fun pow(base: &Decimal128, exp: &Decimal128): Decimal128 {
        assert!(
            decimal128::val(base) != 0 && decimal128::val(base) < 2000000000000000000,
            error::invalid_argument(123),
        );

        let res = decimal128::one();
        let (ln_a, neg) = ln(base);
        let k = mul_decimals(&ln_a, exp);
        let comp = k;
        let index = 1;
        let subs: vector<Decimal128> = vector[];
        while(decimal128::val(&comp) > 100000) {
            if (index & 1 == 1 && neg) {
                vector::push_back(&mut subs, comp)
            } else {
                res = decimal128::add(&res, &comp)
            };

            comp = decimal128::div(&mul_decimals(&comp, &k), index + 1);
            index = index + 1;
        };

        let index = 0;
        while(index < vector::length(&subs)) {
            let comp = vector::borrow(&subs, index);
            res = decimal128::sub(&res, comp);
            index = index + 1;
        };

        res
    }

    fun ln(num: &Decimal128): (Decimal128, bool) {
        let one = decimal128::val(&decimal128::one());
        let num_val = decimal128::val(num);
        let (a, a_neg) = if (num_val >= one) {
            (decimal128::sub(num, &decimal128::one()), false)
        } else {
            (decimal128::sub(&decimal128::one(), num), true)
        };

        let res = decimal128::zero();
        let comp = a;
        let index = 1;

        while (decimal128::val(&comp) > 100000) {
            if (index & 1 == 0 && !a_neg) {
                res = decimal128::sub(&res, &comp);
            } else {
                res = decimal128::add(&res, &comp);
            };

            // comp(old) = a ^ n / n
            // comp(new) = comp(old) * a * n / (n + 1) = a ^ (n + 1) / (n + 1)
            comp = decimal128::div(
                &decimal128::new(decimal128::val(&mul_decimals(&comp, &a)) * index), // comp * a * index
                index + 1,
            );

            index = index + 1;
        };

        (res, a_neg)
    }

    fun mul_decimals(decimal_0: &Decimal128, decimal_1: &Decimal128): Decimal128 {
        let one = decimal128::val(&decimal128::one());
        let val_mul = decimal128::val(decimal_0) * decimal128::val(decimal_1);
        decimal128::new(val_mul / one)
    }

    fun get_price_impact(price_before: Decimal128, price_after: Decimal128): Decimal128 {
        let val_before = decimal128::val(&price_before);
        let val_after = decimal128::val(&price_after);
        if (val_before > val_after) {
            decimal128::from_ratio(val_before - val_after, val_before)
        } else {
            decimal128::from_ratio(val_after - val_before, val_after)
        }
    }
}
