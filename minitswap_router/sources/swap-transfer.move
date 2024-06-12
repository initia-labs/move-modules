module router::minitswap_router {

    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::option::{Self, Option};

    use initia_std::address::to_sdk;
    use initia_std::base64;
    use initia_std::block;
    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::json;
    use initia_std::minitswap;
    use initia_std::stableswap;
    use initia_std::object::{Self, Object};
    use initia_std::primary_fungible_store;
    use initia_std::simple_json;
    use initia_std::simple_map::{Self, SimpleMap};
    use initia_std::string_utils::to_string;

    // Errors
    
    const EMIN_RETURN: u64 = 1;

    const EINVALID_ROUTE: u64 = 2;

    const MINITSWAP: u8 = 0;
    const STABLESWAP: u8 = 1;
    const OP_BRIDGE: u8 = 2;

    struct Key has copy, drop, store {
        route: u8,
        amount: u64,
    }

    #[view]
    public fun swap_simulation(
        offer_asset_metadata: Object<Metadata>,
        offer_amount: u64,
        l2_init_metadata: Object<Metadata>,
        bridge_out: bool,
        preferred_route: Option<u8>,
        number_of_batches: Option<u64>,
    ): SwapSimulationResponse {
       let is_l1_offered = is_l1_init_metadata(offer_asset_metadata);

        let return_asset_metadata = if (is_l1_offered) {
            l2_init_metadata
        } else {
            l1_init_metadata()
        };

        if (!is_l1_offered) {
            assert!(l2_init_metadata == offer_asset_metadata, error::invalid_argument(EINVALID_ROUTE)); 
        };

        let number_of_batches = if (option::is_some(&number_of_batches)) {
            option::extract(&mut number_of_batches)
        } else {
            1
        };

        let pools = minitswap::get_pools(l2_init_metadata);
        let (_, _, virtual_pool, stableswap_pool) = minitswap::unpack_pools_response(pools);
        let simulation_cache = simple_map::create();

        let (op_bridge_offer_amount, minitswap_offer_amount, stableswap_offer_amount) = if (option::is_some(&preferred_route)) {
            let route = option::extract(&mut preferred_route);
            assert!(route <= 2, error::invalid_argument(EINVALID_ROUTE));

            if (route == OP_BRIDGE) {
                assert!(!is_l1_offered, error::invalid_argument(EINVALID_ROUTE));
                (offer_amount, 0, 0)
            } else if (route == MINITSWAP) {
                assert!(option::is_some(&virtual_pool), error::invalid_argument(EINVALID_ROUTE));
                (0, offer_amount, 0)
                // return transfer_fa(account, return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
            } else {
                assert!(option::is_some(&stableswap_pool), error::invalid_argument(EINVALID_ROUTE));
                (0, 0, offer_amount)
                // return transfer_fa(account, return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
            }
        } else {
            let op_bridge_amount = 0;
            let minitswap_amount = 0;
            let stableswap_amount = 0;
            let remain = offer_amount;
            let batch_amount = offer_amount / number_of_batches;
            if (batch_amount == 0) {
                number_of_batches = 1
            };
            let index = 0;
            while (index < number_of_batches - 1) {
                (op_bridge_amount, minitswap_amount, stableswap_amount) = find_best_route(
                    &mut simulation_cache,
                    op_bridge_amount,
                    minitswap_amount,
                    stableswap_amount,
                    is_l1_offered,
                    option::is_some(&virtual_pool),
                    stableswap_pool,
                    offer_asset_metadata,
                    return_asset_metadata,
                    batch_amount,
                );

                remain = remain - batch_amount;
                index = index + 1;
            };

            (op_bridge_amount, minitswap_amount, stableswap_amount) = find_best_route(
                &mut simulation_cache,
                op_bridge_amount,
                minitswap_amount,
                stableswap_amount,
                is_l1_offered && bridge_out,
                option::is_some(&virtual_pool),
                stableswap_pool,
                offer_asset_metadata,
                return_asset_metadata,
                remain,
            );

            (op_bridge_amount, minitswap_amount, stableswap_amount)
        };

        let minitswap_return_amount = simulation(
            &mut simulation_cache,
            option::none(),
            offer_asset_metadata,
            return_asset_metadata,
            Key { route: MINITSWAP, amount: minitswap_offer_amount }
        );

        let pool_addr = option::some(object::object_address(*option::borrow(&stableswap_pool)));
        let stableswap_return_amount = simulation(
            &mut simulation_cache,
            pool_addr,
            offer_asset_metadata,
            return_asset_metadata,
            Key { route: STABLESWAP, amount: stableswap_offer_amount }
        );

        SwapSimulationResponse {
            op_bridge_offer_amount,
            op_bridge_return_amount: op_bridge_offer_amount,
            minitswap_offer_amount,
            minitswap_return_amount,
            stableswap_offer_amount,
            stableswap_return_amount,
        }
    }

    struct SwapSimulationResponse {
        op_bridge_offer_amount: u64,
        op_bridge_return_amount: u64,
        minitswap_offer_amount: u64,
        minitswap_return_amount: u64,
        stableswap_offer_amount: u64,
        stableswap_return_amount: u64,
    }

    public entry fun swap(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        offer_amount: u64,
        l2_init_metadata: Object<Metadata>,
        receiver: address,
        bridge_out: bool,
        preferred_route: Option<u8>,
        min_return_amount: Option<u64>,
        number_of_batches: Option<u64>,
    ) {
        let is_l1_offered = is_l1_init_metadata(offer_asset_metadata);

        let return_asset_metadata = if (is_l1_offered) {
            l2_init_metadata
        } else {
            l1_init_metadata()
        };

        if (!is_l1_offered) {
            assert!(l2_init_metadata == offer_asset_metadata, error::invalid_argument(EINVALID_ROUTE)); 
        };

        let number_of_batches = if (option::is_some(&number_of_batches)) {
            option::extract(&mut number_of_batches)
        } else {
            1
        };

        let pools = minitswap::get_pools(l2_init_metadata);
        let (op_bridge_id, ibc_channel, virtual_pool, stableswap_pool) = minitswap::unpack_pools_response(pools);

        let (op_bridge_amount, minitswap_amount, stableswap_amount) = if (option::is_some(&preferred_route)) {
            let route = option::extract(&mut preferred_route);
            assert!(route <= 2, error::invalid_argument(EINVALID_ROUTE));

            if (route == OP_BRIDGE) {
                assert!(!is_l1_offered, error::invalid_argument(EINVALID_ROUTE));
                (offer_amount, 0, 0)
            } else if (route == MINITSWAP) {
                assert!(option::is_some(&virtual_pool), error::invalid_argument(EINVALID_ROUTE));
                (0, offer_amount, 0)
                // return transfer_fa(account, return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
            } else {
                assert!(option::is_some(&stableswap_pool), error::invalid_argument(EINVALID_ROUTE));
                (0, 0, offer_amount)
                // return transfer_fa(account, return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
            }
        } else {
            let op_bridge_amount = 0;
            let minitswap_amount = 0;
            let stableswap_amount = 0;
            let remain = offer_amount;
            let simulation_cache = simple_map::create();
            let batch_amount = offer_amount / number_of_batches;
            if (batch_amount == 0) {
                number_of_batches = 1
            };
            let index = 0;
            while (index < number_of_batches - 1) {
                (op_bridge_amount, minitswap_amount, stableswap_amount) = find_best_route(
                    &mut simulation_cache,
                    op_bridge_amount,
                    minitswap_amount,
                    stableswap_amount,
                    is_l1_offered,
                    option::is_some(&virtual_pool),
                    stableswap_pool,
                    offer_asset_metadata,
                    return_asset_metadata,
                    batch_amount,
                );

                remain = remain - batch_amount;
                index = index + 1;
            };

            (op_bridge_amount, minitswap_amount, stableswap_amount) = find_best_route(
                &mut simulation_cache,
                op_bridge_amount,
                minitswap_amount,
                stableswap_amount,
                is_l1_offered && bridge_out,
                option::is_some(&virtual_pool),
                stableswap_pool,
                offer_asset_metadata,
                return_asset_metadata,
                remain,
            );

            (op_bridge_amount, minitswap_amount, stableswap_amount)
        };

        if (op_bridge_amount != 0) {
            return initiate_token_deposit(account, op_bridge_id, receiver, offer_asset_metadata, op_bridge_amount, vector[])
        };

        let minitswap_return_asset = if (minitswap_amount != 0) {
            let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, minitswap_amount);
            minitswap::swap_internal(offer_asset, return_asset_metadata)
        } else {
            fungible_asset::zero(return_asset_metadata)
        };

        let stableswap_return_asset = if (stableswap_amount != 0) {
            let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, minitswap_amount);
            stableswap::swap(*option::borrow(&stableswap_pool), offer_asset, return_asset_metadata, option::none())
        } else {
            fungible_asset::zero(return_asset_metadata)
        };

        fungible_asset::merge(&mut minitswap_return_asset, stableswap_return_asset);
        
        let total_return_amount = op_bridge_amount + fungible_asset::amount(&minitswap_return_asset);
        if (option::is_some(&min_return_amount)) {
            assert!(total_return_amount >= *option::borrow(&min_return_amount), error::invalid_state(EMIN_RETURN));
        };

        if (is_l1_offered && bridge_out) {
            transfer_fa(account, minitswap_return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
        } else {
            primary_fungible_store::deposit(receiver, minitswap_return_asset);
        }
    }

    fun find_best_route(
        simulation_cache: &mut SimpleMap<Key, u64>,
        former_op_bridge_amount: u64,
        former_minitswap_amount: u64,
        former_stableswap_amount: u64,
        op_bridge_enable: bool,
        virtual_pool_exists: bool,
        stableswap_pool: Option<Object<stableswap::Pool>>,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        offer_amount: u64,
    ): (u64, u64, u64) {
        let op_bridge_return_amount = if (op_bridge_enable) {
            offer_amount
        } else {
            0
        };

        let minitswap_return_amount = if (virtual_pool_exists) {
            let former_return_amount = *simple_map::borrow(simulation_cache, &Key { route: MINITSWAP, amount: former_minitswap_amount });
            let return_amount = simulation(
                simulation_cache,
                option::none(),
                offer_asset_metadata,
                return_asset_metadata,
                Key { route: MINITSWAP, amount: former_minitswap_amount + offer_amount }
            );
            if (return_amount == 0) {
                0
            } else {
                return_amount - former_return_amount
            }
        } else {
            0
        };

        let stableswap_return_amount = if (option::is_some(&stableswap_pool)) {
            let former_return_amount = *simple_map::borrow(simulation_cache, &Key { route: STABLESWAP, amount: former_stableswap_amount });
            let pool_addr = option::some(object::object_address(*option::borrow(&stableswap_pool)));
            let return_amount = simulation(
                simulation_cache,
                pool_addr,
                offer_asset_metadata,
                return_asset_metadata,
                Key { route: STABLESWAP, amount: former_stableswap_amount + offer_amount }
            );
            return_amount - former_return_amount
        } else {
            0
        };

        if (op_bridge_return_amount > minitswap_return_amount && op_bridge_return_amount > stableswap_return_amount) {
            return (former_op_bridge_amount + offer_amount, former_minitswap_amount, former_stableswap_amount)
        } else if (minitswap_return_amount > stableswap_return_amount) {
            return (former_op_bridge_amount, former_minitswap_amount + offer_amount, former_stableswap_amount)
        } else {
            return (former_op_bridge_amount, former_minitswap_amount, former_stableswap_amount + offer_amount)
        }
    }

    fun simulation(
        simulation_cache: &mut SimpleMap<Key, u64>,
        pool_addr: Option<address>,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        key: Key,
    ): u64 {
        if (!simple_map::contains_key(simulation_cache, &key)) {
            if (key.route == OP_BRIDGE) {
                simple_map::add(simulation_cache, key, key.amount);
            } else if (key.route == MINITSWAP) {
                let (return_amount, _) = minitswap::safe_swap_simulation(offer_asset_metadata, return_asset_metadata, key.amount);
                simple_map::add(simulation_cache, key, return_amount);
            } else if (key.route == STABLESWAP) {
                let pool_addr = *option::borrow(&pool_addr);
                let pool_obj = object::address_to_object<stableswap::Pool>(pool_addr);
                let return_amount = stableswap::get_swap_simulation(pool_obj, offer_asset_metadata, return_asset_metadata, key.amount);
                simple_map::add(simulation_cache, key, return_amount);
            };
        };

        return *simple_map::borrow(simulation_cache, &key)
    }

    fun is_l1_init_metadata(metadata: Object<Metadata>): bool {
        metadata == l1_init_metadata()
    }

    fun l1_init_metadata(): Object<Metadata> {
        let addr = object::create_object_address(@initia_std, b"uinit");
        object::address_to_object<Metadata>(addr)
    }

    fun transfer_fa(account: &signer, fa: FungibleAsset, receiver: String, source_port: String, source_channel: String, memo: String) {
        let addr = signer::address_of(account);
        let (_, timestamp) = block::get_block_info();
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount = fungible_asset::amount(&fa);
        primary_fungible_store::deposit(addr, fa);

        cosmos::transfer(
            account,
            receiver,
            metadata,
            amount,
            source_port,
            source_channel,
            0,
            0,
            (timestamp + 1000) * 1000000000,
            memo,
        )
    }

    fun deposit_fa(account: &signer, fa: FungibleAsset, bridge_id: u64, to: address, data: vector<u8>) {
        let addr = signer::address_of(account);
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount = fungible_asset::amount(&fa);
        primary_fungible_store::deposit(addr, fa);

        initiate_token_deposit(account, bridge_id, to, metadata, amount, data);
    }

    fun initiate_token_deposit(
        sender: &signer,
        bridge_id: u64,
        to: address,
        metadata: Object<Metadata>,
        amount: u64,
        data: vector<u8>
    ) {
        let obj = simple_json::empty();
        simple_json::set_object(&mut obj, option::none<String>());
        simple_json::increase_depth(&mut obj);
        simple_json::set_string(&mut obj, option::some(string::utf8(b"@type")), string::utf8(b"/opinit.ophost.v1.MsgInitiateTokenDeposit"));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"sender")), to_sdk(signer::address_of(sender)));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"bridge_id")), to_string(&bridge_id));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"to")), to_sdk(to));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"data")), base64::to_string(data));
        simple_json::set_object(&mut obj, option::some(string::utf8(b"amount")));
        simple_json::increase_depth(&mut obj);
        simple_json::set_string(&mut obj, option::some(string::utf8(b"denom")), coin::metadata_to_denom(metadata));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"amount")), to_string(&amount));

        let req = json::stringify(simple_json::to_json_object(&obj));
        cosmos::stargate(sender, req);
    }
}
