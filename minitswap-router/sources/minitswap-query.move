module router::minitswap_query {

    use std::error;
    use std::string::String;
    use std::option;
    use std::vector;

    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::stableswap::{Self, Pool};
    use initia_std::object::Object;

    const A_PRECISION: u256 = 100;

    const ESAME_COIN_TYPE: u64 = 1;

    const ECOIN_TYPE: u64 = 2;

    struct ProvideSimulationResponse {
        return_amount: u64,
        fee_coin_metadata: vector<Object<Metadata>>,
        fee_coin_denoms: vector<String>,
        fee_amounts: vector<u64>,
    }

    struct WithdrawSimulationResponse {
        return_coin_metadata: vector<Object<Metadata>>,
        return_coin_denoms: vector<String>,
        return_amounts: vector<u64>,
        fee_coin_metadata: vector<Object<Metadata>>,
        fee_coin_denoms: vector<String>,
        fee_amounts: vector<u64>,
    }


    #[view]
    public fun stableswap_provide_simulation(
        pool_obj: Object<Pool>,
        amounts: vector<u64>,
    ): ProvideSimulationResponse {
        let (return_amount, fee_amounts) = stableswap::provide_simulation(pool_obj, amounts);
        let pool = stableswap::get_pool(pool_obj);
        let (coin_metadata, coin_denoms, _, _, _) = stableswap::unpack_pool_response(&pool);
        return ProvideSimulationResponse {
            return_amount: return_amount,
            fee_coin_metadata: coin_metadata,
            fee_coin_denoms: coin_denoms,
            fee_amounts,
        }
    }

    #[view]
    public fun stableswap_withdraw_simulation(
        pool_obj: Object<Pool>,
        liquidity_amount: u64,
    ): WithdrawSimulationResponse {
        let pool = stableswap::get_pool(pool_obj);
        let (coin_metadata, coin_denoms, pool_amounts, _, _) = stableswap::unpack_pool_response(&pool);

        let total_supply = option::extract(
            &mut fungible_asset::supply(pool_obj)
        );
        let return_amounts = vector[];

        let n = vector::length(&coin_metadata);
        let i = 0;
        while (i < n) {
            let pool_amount = *vector::borrow(&pool_amounts, i);
            let return_amount = (
                mul_div_u128(
                    (pool_amount as u128),
                    (liquidity_amount as u128),
                    total_supply
                ) as u64
            );

            vector::push_back(&mut return_amounts, return_amount);
            i = i + 1;
        };
        
        return WithdrawSimulationResponse {
            return_coin_metadata: coin_metadata,
            return_coin_denoms: coin_denoms,
            return_amounts,
            fee_coin_metadata: vector[],
            fee_coin_denoms: vector[],
            fee_amounts: vector[],
        }
    }

    #[view]
    public fun stableswap_single_asset_withdraw_simulation(
        pool_obj: Object<Pool>,
        return_coin_metadata: Object<Metadata>,
        liquidity_amount: u64,
    ): WithdrawSimulationResponse {
        let pool = stableswap::get_pool(pool_obj);
        let (coin_metadata, coin_denoms, _, _, _) = stableswap::unpack_pool_response(&pool);
        let (found, return_index) = vector::index_of(
            &coin_metadata,
            &return_coin_metadata
        );
        assert!(
            found,
            error::invalid_argument(ECOIN_TYPE)
        );

        let (return_amount, fee_amount) = stableswap::single_asset_withdraw_simulation(pool_obj, liquidity_amount, return_index);

        let return_coin_denom = *vector::borrow(&coin_denoms, return_index);
        
        return WithdrawSimulationResponse {
            return_coin_metadata: vector[return_coin_metadata],
            return_coin_denoms: vector[return_coin_denom],
            return_amounts: vector[return_amount],
            fee_coin_metadata:  vector[return_coin_metadata],
            fee_coin_denoms: vector[return_coin_denom],
            fee_amounts: vector[fee_amount],
        }
    }

    fun mul_div_u128(a: u128, b: u128, c: u128): u128 {
        return(
            (a as u256) * (b as u256) / (c as u256) as u128
        )
    }
}
