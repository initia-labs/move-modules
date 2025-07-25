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

    use vip::lock_staking;

    // Errors

    const EMIN_RETURN: u64 = 1;

    const EINVALID_TOKEN: u64 = 2;

    const EZERO_LIQUIDITY: u64 = 3;

    // Responses

    struct ProvideSimulationResponse {
        return_amount: u64,
        fee_coin_metadata: vector<Object<Metadata>>,
        fee_coin_denoms: vector<String>,
        fee_amounts: vector<u64>
    }

    struct WithdrawSimulationResponse {
        return_coin_metadata: vector<Object<Metadata>>,
        return_coin_denoms: vector<String>,
        return_amounts: vector<u64>,
        fee_coin_metadata: vector<Object<Metadata>>,
        fee_coin_denoms: vector<String>,
        fee_amounts: vector<u64>
    }

    // view functions. Simulate and calculate price impact

    #[view]
    /// Simulates a route swap on `0x1::dex`, returning the final amount received and the price impact for each pair.
    ///
    /// @param offer_asset_metadata: The metadata of the token being offered.
    /// @param route: A vector of trading pairs that make up the swap route.
    /// @param offer_amount: The amount of the offered token to be swapped.
    /// @return A tuple containing:
    ///         - The final amount received after completing the swap route.
    ///         - A vector of price impacts for each pair along the route.
    public fun get_route_swap_simulation(
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>,
        offer_amount: u64
    ): (u64, vector<BigDecimal>) {
        let price_impacts: vector<BigDecimal> = vector[];

        vector::for_each_ref(
            &route,
            |pair| {
                // simulate swap
                let (return_amount, price_impact) =
                    get_swap_simulation(*pair, offer_asset_metadata, offer_amount);

                // update next offer amount
                offer_amount = return_amount;

                // get next offer_asset_metdata
                let (metadata_a, metadata_b) = dex::pool_metadata(*pair);
                offer_asset_metadata =
                    if (offer_asset_metadata == metadata_a) {
                        metadata_b
                    } else {
                        metadata_a
                    };

                // append price impact
                vector::push_back(&mut price_impacts, price_impact);
            }
        );

        let return_amount = offer_amount;
        (return_amount, price_impacts)
    }

    #[view]
    /// Simulates a token swap on `0x1::dex`, returning the expected output amount and price impact.
    ///
    /// @param pair The trading pair to perform the swap on.
    /// @param offer_asset_metadata Metadata of the token being offered.
    /// @param offer_amount The amount of the offered token to swap.
    /// @return A tuple containing:
    ///         - The amount of the output token expected from the swap.
    ///         - The price impact of the swap.
    public fun get_swap_simulation(
        pair: Object<Config>, offer_asset_metadata: Object<Metadata>, offer_amount: u64
    ): (u64, BigDecimal) {
        // get pool info
        let (coin_a_pool, coin_b_pool, coin_a_weight, coin_b_weight, swap_fee_rate) =
            dex::pool_info(pair, true);

        // check coin type
        let (metadata_a, _) = dex::pool_metadata(pair);
        let is_offer_a = metadata_a == offer_asset_metadata;

        // set arguments
        let (offer_pool, return_pool, offer_weight, return_weight) =
            if (is_offer_a) {
                (coin_a_pool, coin_b_pool, coin_a_weight, coin_b_weight)
            } else {
                (coin_b_pool, coin_a_pool, coin_b_weight, coin_a_weight)
            };

        // get spot price before swap
        let price_before =
            get_spot_price(
                offer_pool,
                return_pool,
                offer_weight,
                return_weight
            );

        // simulate swap
        let (return_amount, _fee_amount) =
            dex::swap_simulation(
                offer_pool,
                return_pool,
                offer_weight,
                return_weight,
                offer_amount,
                swap_fee_rate
            );

        // get spot price after swap
        let price_after =
            get_spot_price(
                offer_pool + offer_amount,
                return_pool - return_amount,
                offer_weight,
                return_weight
            );

        (return_amount, get_price_impact(price_before, price_after))
    }

    #[view]
    /// Calculates the amount of liquidity tokens returned for a given input of token amounts.
    ///
    /// @param pair: The liquidity pool pair to which tokens are being provided.
    /// @param coin_a_amount_in: The amount of Coin A to provide.
    /// @param coin_b_amount_in: The amount of Coin B to provide.
    /// @return The amount of liquidity tokens to be minted for the provided tokens.
    public fun provide_liquidity_cal(
        pair: Object<Config>, coin_a_amount_in: u64, coin_b_amount_in: u64
    ): u64 {
        dex::get_provide_simulation(pair, coin_a_amount_in, coin_b_amount_in)
    }

    #[view]
    /// Calculates the amount of liquidity tokens to be minted for the given token inputs, including price impact.
    ///
    /// @param pair: The liquidity pool pair to which tokens are being provided.
    /// @param coin_a_amount_in: The amount of Coin A to provide.
    /// @param coin_b_amount_in: The amount of Coin B to provide.
    /// @return A tuple containing:
    ///         - The amount of liquidity tokens to be minted.
    ///         - The price impact resulting from the provided token amounts.
    public fun provide_liquidity_cal_with_price_impact(
        pair: Object<Config>, coin_a_amount_in: u64, coin_b_amount_in: u64
    ): (u64, BigDecimal) {
        // get price impact

        // get current pool info
        let (coin_a_amount, coin_b_amount, coin_a_weight, coin_b_weight, swap_fee_rate) =
            dex::pool_info(pair, false);

        // get current spot price
        let price_before =
            get_spot_price(
                coin_a_amount,
                coin_b_amount,
                coin_a_weight,
                coin_b_weight
            );

        // get spot price after liquidity provision
        let price_after =
            get_spot_price(
                coin_a_amount + coin_a_amount_in,
                coin_b_amount + coin_b_amount_in,
                coin_a_weight,
                coin_b_weight
            );

        // get price impact
        let price_impact = get_price_impact(price_before, price_after);

        // get return amount
        let return_amount =
            dex::get_provide_simulation(pair, coin_a_amount_in, coin_b_amount_in);

        (return_amount, price_impact)
    }

    #[view]
    #[deprecated]
    /// **Deprecated**: Use `provide_liquidity_cal_with_price_impact` instead.
    ///
    /// Estimates the liquidity tokens to be minted when providing a single asset to the pool.
    ///
    /// @param pair: The liquidity pool pair to which the asset is being provided.
    /// @param offer_asset_metadata: Metadata of the asset being offered.
    /// @param amount_in: The amount of the offered asset.
    /// @return A tuple containing:
    ///         - The amount of liquidity tokens to be minted.
    ///         - The price impact of the provided asset.
    public fun single_asset_provide_liquidity_cal(
        pair: Object<Config>, offer_asset_metadata: Object<Metadata>, amount_in: u64
    ): (u64, BigDecimal) {
        // get metadata
        let (metadata_a, metadata_b) = dex::pool_metadata(pair);

        // check coin types
        let is_coin_b = metadata_b == offer_asset_metadata;
        let is_coin_a = metadata_a == offer_asset_metadata;
        assert!(is_coin_b || is_coin_a, error::invalid_argument(EINVALID_TOKEN));

        // set amount in
        let (coin_a_amount_in, coin_b_amount_in) =
            if (is_coin_a) {
                (amount_in, 0)
            } else {
                (0, amount_in)
            };

        provide_liquidity_cal_with_price_impact(pair, coin_a_amount_in, coin_b_amount_in)
    }

    #[view]
    #[deprecated]
    /// **Deprecated**: Use `provide_liquidity_cal_with_price_impact` instead.
    ///
    /// Calculates the amount of liquidity tokens to be minted for the given token inputs, including price impact.
    ///
    /// @param pair: The liquidity pool pair to which tokens are being provided.
    /// @param coin_a_amount_in: The amount of Coin A to provide.
    /// @param coin_b_amount_in: The amount of Coin B to provide.
    /// @return A tuple containing:
    ///         - The amount of liquidity tokens to be minted.
    ///         - The price impact resulting from the provided token amounts.
    public fun unproportional_provide_liquidity_cal(
        pair: Object<Config>, coin_a_amount_in: u64, coin_b_amount_in: u64
    ): (u64, BigDecimal) {
        provide_liquidity_cal_with_price_impact(pair, coin_a_amount_in, coin_b_amount_in)
    }

    #[view]
    /// Simulates providing liquidity to a stableswap pool and returns the expected minted amount and associated fees.
    ///
    /// @param pool_obj: The stableswap pool object to which liquidity is being added.
    /// @param amounts: A vector of token amounts to provide, corresponding to the pool's assets.
    /// @return A `ProvideSimulationResponse` struct containing:
    ///         - `return_amount`: The expected amount of liquidity tokens to be minted.
    ///         - `fee_coin_metadata`: Metadata of the fee tokens.
    ///         - `fee_coin_denoms`: Denominations of the fee tokens.
    ///         - `fee_amounts`: Amounts of each fee charged.
    public fun stableswap_provide_simulation(
        pool_obj: Object<Pool>, amounts: vector<u64>
    ): ProvideSimulationResponse {
        // simulate liquidity provision
        let (return_amount, fee_amounts) =
            stableswap::provide_simulation(pool_obj, amounts);

        // get coin metadata and denoms
        let pool = stableswap::get_pool(pool_obj);
        let (coin_metadata, coin_denoms, _, _, _) =
            stableswap::unpack_pool_response(&pool);

        return ProvideSimulationResponse {
            return_amount: return_amount,
            fee_coin_metadata: coin_metadata,
            fee_coin_denoms: coin_denoms,
            fee_amounts
        }
    }

    #[view]
    /// Simulates withdrawing liquidity from a stableswap pool, returning expected token outputs and associated fees.
    ///
    /// @param pool_obj: The stableswap pool object from which liquidity is being withdrawn.
    /// @param liquidity_amount: The amount of liquidity tokens to burn for withdrawal.
    /// @return A `WithdrawSimulationResponse` struct containing:
    ///         - `return_coin_metadata`: Metadata of the tokens returned from the pool.
    ///         - `return_coin_denoms`: Denominations of the returned tokens.
    ///         - `return_amounts`: Amounts of each token returned.
    ///         - `fee_coin_metadata`: Metadata of the tokens used to pay fees.
    ///         - `fee_coin_denoms`: Denominations of the fee tokens.
    ///         - `fee_amounts`: Amounts of each fee charged.
    public fun stableswap_withdraw_simulation(
        pool_obj: Object<Pool>, liquidity_amount: u64
    ): WithdrawSimulationResponse {
        // get coin metadata and denoms
        let pool = stableswap::get_pool(pool_obj);
        let (coin_metadata, coin_denoms, pool_amounts, _, _) =
            stableswap::unpack_pool_response(&pool);

        // get current total supply
        let total_supply = option::extract(&mut fungible_asset::supply(pool_obj));

        // ger return amounts
        let return_amounts = vector::map_ref(
            &pool_amounts,
            // return amount = pool_amount * liquidity_amount / total_supply
            |pool_amount| mul_div_u128(
                (*pool_amount as u128),
                (liquidity_amount as u128),
                total_supply
            ) as u64
        );

        return WithdrawSimulationResponse {
            return_coin_metadata: coin_metadata,
            return_coin_denoms: coin_denoms,
            return_amounts,
            fee_coin_metadata: vector[],
            fee_coin_denoms: vector[],
            fee_amounts: vector[]
        }
    }

    #[view]
    /// Simulates a single-asset withdrawal from a stableswap pool, returning the expected output and associated fees.
    ///
    /// @param pool_obj: The stableswap pool object from which liquidity is being withdrawn.
    /// @param return_coin_metadata: Metadata of the token to be withdrawn from the pool.
    /// @param liquidity_amount: The amount of liquidity tokens to burn for the withdrawal.
    /// @return A `WithdrawSimulationResponse` struct containing:
    ///         - `return_coin_metadata`: Metadata of the returned token.
    ///         - `return_coin_denoms`: Denomination of the returned token.
    ///         - `return_amounts`: Amount of the token returned.
    ///         - `fee_coin_metadata`: Metadata of the tokens used to pay fees.
    ///         - `fee_coin_denoms`: Denominations of the fee tokens.
    ///         - `fee_amounts`: Amounts of each fee charged.
    public fun stableswap_single_asset_withdraw_simulation(
        pool_obj: Object<Pool>,
        return_coin_metadata: Object<Metadata>,
        liquidity_amount: u64
    ): WithdrawSimulationResponse {
        // get coin metadata and denoms
        let pool = stableswap::get_pool(pool_obj);
        let (coin_metadata, coin_denoms, _, _, _) =
            stableswap::unpack_pool_response(&pool);

        // find return coin index
        let (found, return_index) = vector::index_of(
            &coin_metadata, &return_coin_metadata
        );
        assert!(found, error::invalid_argument(EINVALID_TOKEN));

        // get return amount and fee amount
        let (return_amount, fee_amount) =
            stableswap::single_asset_withdraw_simulation(
                pool_obj, liquidity_amount, return_index
            );

        // load return coin denom
        let return_coin_denom = *vector::borrow(&coin_denoms, return_index);

        return WithdrawSimulationResponse {
            return_coin_metadata: vector[return_coin_metadata],
            return_coin_denoms: vector[return_coin_denom],
            return_amounts: vector[return_amount],
            fee_coin_metadata: vector[return_coin_metadata],
            fee_coin_denoms: vector[return_coin_denom],
            fee_amounts: vector[fee_amount]
        }
    }

    // entry functions

    /// Provides liquidity to a stableswap pool and stakes the resulting liquidity tokens to a validator.
    ///
    /// @param account: The signer account initiating the transaction.
    /// @param pool_obj: The stableswap pool object to which liquidity is being provided.
    /// @param coin_amounts: A vector of token amounts to provide, corresponding to the pool's assets.
    /// @param min_liquidity: Optional, minimum amount of liquidity tokens to receive; aborts if not met.
    /// @param validator: The Bech32-encoded address of the validator to stake the liquidity tokens with.
    public entry fun stableswap_provide_stake(
        account: &signer,
        pool_obj: Object<Pool>,
        coin_amounts: vector<u64>,
        min_liquidity: Option<u64>,
        validator: String
    ) {
        // get coin metadata
        let (coin_metadata, _, _, _) = stableswap::pool_info(pool_obj);

        // withdraw coins
        let coins: vector<FungibleAsset> = vector::zip_map_ref(
            &coin_metadata,
            &coin_amounts,
            |metadata, amount| coin::withdraw(account, *metadata, *amount)
        );

        // provide liquidity
        let liquidity_token = stableswap::provide_liquidity(
            pool_obj, coins, min_liquidity
        );

        // get liquidity amount
        let liquidity_amount = fungible_asset::amount(&liquidity_token);

        // deposit liquidity token
        coin::deposit(signer::address_of(account), liquidity_token);

        // delegate to validator
        cosmos::delegate(
            account,
            validator,
            object::convert<Pool, Metadata>(pool_obj),
            liquidity_amount
        );
    }

    /// Provides liquidity to a dex pool and stakes the resulting liquidity tokens to a validator.
    ///
    /// @param account: The signer account initiating the transaction.
    /// @param pair: The liquidity pool pair to which tokens are being provided.
    /// @param coin_a_amount_in: The amount of Coin A to provide.
    /// @param coin_b_amount_in: The amount of Coin B to provide.
    /// @param min_liquidity: Optional, minimum amount of liquidity tokens to receive; aborts if not met.
    /// @param validator: The Bech32-encoded address of the validator to stake the liquidity tokens with.
    public entry fun provide_stake(
        account: &signer,
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String
    ) {
        // get metadata
        let (metadata_a, metadata_b) = dex::pool_metadata(pair);

        // withdraw coins
        let coin_a = coin::withdraw(account, metadata_a, coin_a_amount_in);
        let coin_b = coin::withdraw(account, metadata_b, coin_b_amount_in);

        // provide liquidity
        let liquidity_token = dex::provide_liquidity(pair, coin_a, coin_b, min_liquidity);

        // get liquidity token amount
        let provide_amount = fungible_asset::amount(&liquidity_token);

        // deposit liquidity token
        coin::deposit(signer::address_of(account), liquidity_token);

        // delegate to validator
        cosmos::delegate(
            account,
            validator,
            object::convert<Config, Metadata>(pair),
            provide_amount
        );
    }

    #[deprecated]
    /// **Deprecated**: Use `provide_stake` instead.
    ///
    /// Provides liquidity to a dex pool using a single asset, and stakes the resulting liquidity tokens to a validator.
    ///
    /// @param account: The signer account initiating the transaction.
    /// @param pair: The liquidity pool pair to which tokens are being provided.
    /// @param offer_asset_metadata: Metadata of the asset being offered.
    /// @param amount_in: The amount of the offered asset.
    /// @param min_liquidity: Optional, minimum amount of liquidity tokens to receive; aborts if not met.
    /// @param validator: The Bech32-encoded address of the validator to stake the liquidity tokens with.
    public entry fun single_asset_provide_stake(
        account: &signer,
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String
    ) {
        // withdraw coin
        let provide_coin = coin::withdraw(account, offer_asset_metadata, amount_in);

        // provide liquidity
        let liquidity_token =
            dex::single_asset_provide_liquidity(pair, provide_coin, min_liquidity);

        // get liquidity token amount
        let provide_amount = fungible_asset::amount(&liquidity_token);

        // deposit liquidity token
        coin::deposit(signer::address_of(account), liquidity_token);

        // delegate to validator
        cosmos::delegate(
            account,
            validator,
            object::convert<Config, Metadata>(pair),
            provide_amount
        );
    }

    #[deprecated]
    /// **Deprecated**: Use `0x1::dex::provide_liquidity_script` instead.
    ///
    /// Provides liquidity to a DEX pool using unproportional token amounts.
    ///
    /// @param account The signer account initiating the transaction.
    /// @param pair The liquidity pool pair to which liquidity is being provided.
    /// @param coin_a_amount_in The amount of Coin A to provide.
    /// @param coin_b_amount_in The amount of Coin B to provide.
    /// @param min_liquidity Optional minimum amount of liquidity tokens to receive; aborts if not met.
    public entry fun unproportional_provide(
        account: &signer,
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>
    ) {
        dex::provide_liquidity_script(
            account,
            pair,
            coin_a_amount_in,
            coin_b_amount_in,
            min_liquidity
        )
    }

    /// **Deprecated**: Use `provide_stake` instead.
    ///
    /// Provides liquidity to a DEX pool using unproportional token amounts.
    ///
    /// @param account: The signer account initiating the transaction.
    /// @param pair: The liquidity pool pair to which tokens are being provided.
    /// @param coin_a_amount_in: The amount of Coin A to provide.
    /// @param coin_b_amount_in: The amount of Coin B to provide.
    /// @param min_liquidity: Optional, minimum amount of liquidity tokens to receive; aborts if not met.
    /// @param validator: The Bech32-encoded address of the validator to stake the liquidity tokens with.
    public entry fun unproportional_provide_stake(
        account: &signer,
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>,
        validator: String
    ) {
        provide_stake(
            account,
            pair,
            coin_a_amount_in,
            coin_b_amount_in,
            min_liquidity,
            validator
        )
    }

    /// **Deprecated**: Use `vip::lock_staking::provide_delegate` instead.
    ///
    /// Provides liquidity to a DEX pool with unproportional token amounts and delegates the liquidity tokens to a validator with a lock period.
    ///
    /// @param account The signer account initiating the transaction.
    /// @param pair The liquidity pool pair to which tokens are being provided.
    /// @param coin_a_amount_in The amount of Coin A to provide.
    /// @param coin_b_amount_in The amount of Coin B to provide.
    /// @param min_liquidity Optional minimum amount of liquidity tokens to receive; aborts if not met.
    /// @param release_time The LockStake release time (lock duration or timestamp).
    /// @param validator The Bech32-encoded address of the validator to stake the liquidity tokens with.
    public entry fun unproportional_provide_lock_stake(
        account: &signer,
        pair: Object<Config>,
        coin_a_amount_in: u64,
        coin_b_amount_in: u64,
        min_liquidity: Option<u64>,
        release_time: u64,
        validator: String
    ) {
        lock_staking::provide_delegate(
            account,
            object::convert(pair),
            coin_a_amount_in,
            coin_b_amount_in,
            min_liquidity,
            release_time,
            validator
        )
    }

    /// Executes a multi-hop swap along a specified route of trading pairs.
    ///
    /// @param account: The signer account initiating the swap.
    /// @param offer_asset_metadata: Metadata of the token being offered for the swap.
    /// @param route: A vector of trading pairs representing the swap path.
    /// @param amount: The amount of the offered token to swap.
    /// @param min_return_amount: Optional, minimum acceptable amount to receive from the swap; aborts if not met.
    public entry fun route_swap(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>,
        amount: u64,
        min_return_amount: Option<u64>
    ) {
        let addr = signer::address_of(account);
        let offer_coin = coin::withdraw(account, offer_asset_metadata, amount);

        let return_coin = route_swap_raw(offer_coin, route);
        if (option::is_some(&min_return_amount)) {
            let min_return = option::borrow(&min_return_amount);
            assert!(
                fungible_asset::amount(&return_coin) >= *min_return,
                error::invalid_state(EMIN_RETURN)
            );
        };

        coin::deposit(addr, return_coin);
    }

    // public functions

    /// Executes a raw multi-hop swap along a specified route of trading pairs using a `FungibleAsset`.
    ///
    /// @param offer_coin: The offered coin as a `FungibleAsset`.
    /// @param route: A vector of trading pairs representing the swap path.
    public fun route_swap_raw(
        offer_coin: FungibleAsset, route: vector<Object<Config>>
    ): FungibleAsset {
        vector::for_each_ref(
            &route,
            |pair| {
                offer_coin = dex::swap(*pair, offer_coin);
            }
        );

        let return_coin = offer_coin; // just for clarity
        return_coin
    }

    // util functions

    fun get_spot_price(
        base_pool: u64,
        quote_pool: u64,
        base_weight: BigDecimal,
        quote_weight: BigDecimal
    ): BigDecimal {
        bigdecimal::from_ratio_u64(
            bigdecimal::mul_by_u64_truncate(base_weight, quote_pool),
            bigdecimal::mul_by_u64_truncate(quote_weight, base_pool)
        )
    }

    fun get_price_impact(
        price_before: BigDecimal, price_after: BigDecimal
    ): BigDecimal {
        if (bigdecimal::gt(price_before, price_after)) {
            bigdecimal::div(bigdecimal::sub(price_before, price_after), price_before)
        } else {
            bigdecimal::div(bigdecimal::sub(price_after, price_before), price_after)
        }
    }

    fun mul_div_u128(a: u128, b: u128, c: u128): u128 {
        return ((a as u256) * (b as u256) / (c as u256) as u128)
    }
}
