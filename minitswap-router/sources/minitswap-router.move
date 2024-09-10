module router::minitswap_router {

    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::vector;

    use initia_std::address::to_sdk;
    use initia_std::block;
    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::bigdecimal;
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::json;
    use initia_std::minitswap::{Self, VirtualPool};
    use initia_std::stableswap::{Self, Pool};
    use initia_std::object::{Self, Object};
    use initia_std::primary_fungible_store;
    use initia_std::simple_map::{Self, SimpleMap};

    // Errors

    const EMIN_RETURN: u64 = 1;

    const EINVALID_ROUTE: u64 = 2;

    const EMAX_BATCH_COUNT: u64 = 3;

    const ENOT_OWNER: u64 = 4;

    const MINITSWAP: u8 = 0;
    const STABLESWAP: u8 = 1;
    const OP_BRIDGE: u8 = 2;

    struct Config has key {
        owner: address,
        max_batch_count: u64,
    }

    struct Key has copy, drop, store {
        route: u8,
        amount: u64,
    }

    struct MsgInitiateTokenDeposit has drop, copy, store {
        _type_: String,
        sender: String,
        bridge_id: u64,
        to: String,
        data: vector<u8>,
        amount: Coin
    }

    struct Coin has drop, copy, store {
        denom: String,
        amount: u64,
    }

    #[view]
    public fun swap_simulation(
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        offer_amount: u64,
        bridge_out: bool,
        preferred_route: Option<u8>,
        number_of_batches: Option<u64>,
    ): SwapSimulationResponse acquires Config {

        let is_l1_offered = is_l1_init_metadata(offer_asset_metadata);
        let l2_init_metadata =
            if (is_l1_offered) {
                return_asset_metadata
            } else {
                offer_asset_metadata
            };

        assert!(
            return_asset_metadata != offer_asset_metadata,
            error::invalid_argument(EINVALID_ROUTE),
        );

        let pools = minitswap::get_pools(l2_init_metadata);
        let (_, _, _, _, virtual_pool, stableswap_pool) =
            minitswap::unpack_pools_response(pools);
        let simulation_cache = simple_map::create();

        let (op_bridge_offer_amount, minitswap_offer_amount, stableswap_offer_amount) =
            get_offer_amounts(
                &mut simulation_cache,
                offer_asset_metadata,
                return_asset_metadata,
                offer_amount,
                bridge_out,
                preferred_route,
                number_of_batches,
                is_l1_offered,
                virtual_pool,
                stableswap_pool,
            );

        let (net_minitswap_return_amount, _) =
            simulation(
                &mut simulation_cache,
                option::none(),
                offer_asset_metadata,
                return_asset_metadata,
                Key { route: MINITSWAP, amount: minitswap_offer_amount },
            );

        let pool_addr =
            option::some(object::object_address(option::borrow(&stableswap_pool)));
        let (stableswap_return_amount, stableswap_fee_amount) =
            simulation(
                &mut simulation_cache,
                pool_addr,
                offer_asset_metadata,
                return_asset_metadata,
                Key { route: STABLESWAP, amount: stableswap_offer_amount },
            );

        SwapSimulationResponse {
            op_bridge_offer_amount,
            op_bridge_return_amount: op_bridge_offer_amount,
            minitswap_offer_amount,
            net_minitswap_return_amount,
            stableswap_offer_amount,
            net_stableswap_return_amount: stableswap_return_amount - stableswap_fee_amount,
        }
    }

    #[view]
    public fun swap_simulation_with_fee(
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        offer_amount: u64,
        bridge_out: bool,
        preferred_route: Option<u8>,
        number_of_batches: Option<u64>,
    ): vector<SwapSimulationResponseWithFee> acquires Config {
        let is_l1_offered = is_l1_init_metadata(offer_asset_metadata);
        let l2_init_metadata =
            if (is_l1_offered) {
                return_asset_metadata
            } else {
                offer_asset_metadata
            };

        assert!(
            return_asset_metadata != offer_asset_metadata,
            error::invalid_argument(EINVALID_ROUTE),
        );

        let pools = minitswap::get_pools(l2_init_metadata);
        let (_, _, _, _, virtual_pool, stableswap_pool) =
            minitswap::unpack_pools_response(pools);
        let simulation_cache = simple_map::create();

        let (op_bridge_offer_amount, minitswap_offer_amount, stableswap_offer_amount) =
            get_offer_amounts(
                &mut simulation_cache,
                offer_asset_metadata,
                return_asset_metadata,
                offer_amount,
                bridge_out,
                preferred_route,
                number_of_batches,
                is_l1_offered,
                virtual_pool,
                stableswap_pool,
            );

        let res: vector<SwapSimulationResponseWithFee> = vector[];
        let total_return_amount = op_bridge_offer_amount;

        let (minitswap_return_amount, minitswap_fee_amount) =
            simulation(
                &mut simulation_cache,
                option::none(),
                offer_asset_metadata,
                return_asset_metadata,
                Key { route: MINITSWAP, amount: minitswap_offer_amount },
            );
        total_return_amount = total_return_amount + minitswap_return_amount;

        let (stableswap_return_amount, stableswap_fee_amount) =
            if (option::is_none(&stableswap_pool)) { (0, 0) }
            else {
                let pool_addr =
                    option::some(object::object_address(option::borrow(&stableswap_pool)));
                simulation(
                    &mut simulation_cache,
                    pool_addr,
                    offer_asset_metadata,
                    return_asset_metadata,
                    Key { route: STABLESWAP, amount: stableswap_offer_amount },
                )
            };
        total_return_amount = total_return_amount + stableswap_return_amount - stableswap_fee_amount;

        if (op_bridge_offer_amount != 0) {
            vector::push_back(
                &mut res,
                SwapSimulationResponseWithFee {
                    route_type: string::utf8(b"OP bridge"),
                    offer_amount: op_bridge_offer_amount,
                    net_return_amount: op_bridge_offer_amount,
                    fee_metadata: offer_asset_metadata,
                    fee_amount: 0,
                    fee_rate: bigdecimal::zero(),
                },
            )
        };

        if (minitswap_offer_amount != 0) {
            vector::push_back(
                &mut res,
                SwapSimulationResponseWithFee {
                    route_type: string::utf8(b"Minitswap"),
                    offer_amount: minitswap_offer_amount,
                    net_return_amount: minitswap_return_amount,
                    fee_metadata: return_asset_metadata,
                    fee_amount: minitswap_fee_amount,
                    fee_rate: bigdecimal::from_ratio_u64(
                        minitswap_fee_amount, total_return_amount
                    ),
                },
            )
        };

        if (stableswap_offer_amount != 0) {
            vector::push_back(
                &mut res,
                SwapSimulationResponseWithFee {
                    route_type: string::utf8(b"Stableswap"),
                    offer_amount: stableswap_offer_amount,
                    net_return_amount: stableswap_return_amount - stableswap_fee_amount,
                    fee_metadata: return_asset_metadata,
                    fee_amount: stableswap_fee_amount,
                    fee_rate: bigdecimal::from_ratio_u64(
                        stableswap_fee_amount, total_return_amount
                    ),
                },
            )
        };

        res
    }

    struct SwapSimulationResponse has drop {
        op_bridge_offer_amount: u64,
        op_bridge_return_amount: u64,
        minitswap_offer_amount: u64,
        net_minitswap_return_amount: u64,
        stableswap_offer_amount: u64,
        net_stableswap_return_amount: u64,
    }

    struct SwapSimulationResponseWithFee has drop{
        route_type: String,
        offer_amount: u64,
        net_return_amount: u64,
        fee_metadata: Object<Metadata>,
        fee_amount: u64,
        fee_rate: bigdecimal::BigDecimal,
    }

    fun init_module(account: &signer) {
        move_to(
            account,
            Config { owner: signer::address_of(account), max_batch_count: 10, },
        );
    }

    public entry fun update_config(
        account: &signer, owner: address, max_batch_count: u64
    ) acquires Config {
        let config = borrow_global_mut<Config>(@router);
        assert!(
            signer::address_of(account) == config.owner,
            error::permission_denied(ENOT_OWNER),
        );
        config.owner = owner;
        config.max_batch_count = max_batch_count;
    }

    public entry fun swap(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        offer_amount: u64,
        receiver: address,
        bridge_out: bool,
        preferred_route: Option<u8>,
        min_return_amount: Option<u64>,
        number_of_batches: Option<u64>,
    ) acquires Config {
        let config = borrow_global<Config>(@router);
        let is_l1_offered = is_l1_init_metadata(offer_asset_metadata);

        let l2_init_metadata =
            if (is_l1_offered) {
                return_asset_metadata
            } else {
                offer_asset_metadata
            };

        assert!(
            return_asset_metadata != offer_asset_metadata,
            error::invalid_argument(EINVALID_ROUTE),
        );

        let number_of_batches =
            if (option::is_some(&number_of_batches)) {
                option::extract(&mut number_of_batches)
            } else { 1 };

        assert!(
            number_of_batches <= config.max_batch_count,
            error::invalid_argument(EMAX_BATCH_COUNT),
        );

        let pools = minitswap::get_pools(l2_init_metadata);
        let (_, _, op_bridge_id, ibc_channel, virtual_pool, stableswap_pool) =
            minitswap::unpack_pools_response(pools);

        let (op_bridge_amount, minitswap_amount, stableswap_amount) =
            if (option::is_some(&preferred_route)) {
                let route = option::extract(&mut preferred_route);
                assert!(route <= 2, error::invalid_argument(EINVALID_ROUTE));

                if (route == OP_BRIDGE) {
                    assert!(
                        is_l1_offered && bridge_out,
                        error::invalid_argument(EINVALID_ROUTE),
                    );
                    (offer_amount, 0, 0)
                } else if (route == MINITSWAP) {
                    assert!(
                        option::is_some(&virtual_pool),
                        error::invalid_argument(EINVALID_ROUTE),
                    );
                    (0, offer_amount, 0)
                    // return transfer_fa(account, return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
                } else {
                    assert!(
                        option::is_some(&stableswap_pool),
                        error::invalid_argument(EINVALID_ROUTE),
                    );
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
                while (index < number_of_batches) {
                    let amount =
                        if (index == number_of_batches - 1) {
                            remain // For the last batch, use the remaining amount
                        } else {
                            batch_amount
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
                        amount,
                    );

                    remain = remain - batch_amount;
                    index = index + 1;
                };

                (op_bridge_amount, minitswap_amount, stableswap_amount)
            };

        if (op_bridge_amount != 0) {
            initiate_token_deposit(
                account,
                op_bridge_id,
                receiver,
                offer_asset_metadata,
                op_bridge_amount,
                vector[],
            )
        };

        let minitswap_return_asset =
            if (minitswap_amount != 0) {
                let offer_asset =
                    primary_fungible_store::withdraw(
                        account, offer_asset_metadata, minitswap_amount
                    );
                minitswap::swap_internal(offer_asset, return_asset_metadata)
            } else {
                fungible_asset::zero(return_asset_metadata)
            };

        let stableswap_return_asset =
            if (stableswap_amount != 0) {
                let offer_asset =
                    primary_fungible_store::withdraw(
                        account, offer_asset_metadata, stableswap_amount
                    );
                stableswap::swap(
                    *option::borrow(&stableswap_pool),
                    offer_asset,
                    return_asset_metadata,
                    option::none(),
                )
            } else {
                fungible_asset::zero(return_asset_metadata)
            };

        fungible_asset::merge(&mut minitswap_return_asset, stableswap_return_asset);

        let total_return_amount =
            op_bridge_amount + fungible_asset::amount(&minitswap_return_asset);
        if (option::is_some(&min_return_amount)) {
            assert!(
                total_return_amount >= *option::borrow(&min_return_amount),
                error::invalid_state(EMIN_RETURN),
            );
        };

        if (is_l1_offered && bridge_out) {
            transfer_fa(
                account,
                minitswap_return_asset,
                to_sdk(receiver),
                string::utf8(b"transfer"),
                ibc_channel,
                string::utf8(b""),
            )
        } else {
            primary_fungible_store::deposit(receiver, minitswap_return_asset);
        }
    }

    fun get_offer_amounts(
        simulation_cache: &mut SimpleMap<Key, SimulationRes>,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        offer_amount: u64,
        bridge_out: bool,
        preferred_route: Option<u8>,
        number_of_batches: Option<u64>,
        is_l1_offered: bool,
        virtual_pool: Option<Object<VirtualPool>>,
        stableswap_pool: Option<Object<Pool>>
    ): (u64, u64, u64) acquires Config {

        let config = borrow_global<Config>(@router);
        let number_of_batches =
            if (option::is_some(&number_of_batches)) {
                option::extract(&mut number_of_batches)
            } else { 1 };

        assert!(
            number_of_batches <= config.max_batch_count,
            error::invalid_argument(EMAX_BATCH_COUNT),
        );
        if (option::is_some(&preferred_route)) {
            let route = option::extract(&mut preferred_route);
            assert!(route <= 2, error::invalid_argument(EINVALID_ROUTE));

            if (route == OP_BRIDGE) {
                assert!(
                    is_l1_offered && bridge_out, error::invalid_argument(EINVALID_ROUTE)
                );
                (offer_amount, 0, 0)
            } else if (route == MINITSWAP) {
                assert!(
                    option::is_some(&virtual_pool),
                    error::invalid_argument(EINVALID_ROUTE),
                );
                (0, offer_amount, 0)
                // return transfer_fa(account, return_asset, to_sdk(receiver), string::utf8(b"transfer"), ibc_channel, string::utf8(b""))
            } else {
                assert!(
                    option::is_some(&stableswap_pool),
                    error::invalid_argument(EINVALID_ROUTE),
                );
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
            while (index < number_of_batches) {
                let amount =
                    if (index == number_of_batches - 1) {
                        remain // For the last batch, use the remaining amount
                    } else {
                        batch_amount
                    };

                (op_bridge_amount, minitswap_amount, stableswap_amount) = find_best_route(
                    simulation_cache,
                    op_bridge_amount,
                    minitswap_amount,
                    stableswap_amount,
                    is_l1_offered && bridge_out,
                    option::is_some(&virtual_pool),
                    stableswap_pool,
                    offer_asset_metadata,
                    return_asset_metadata,
                    amount,
                );

                remain = remain - batch_amount;
                index = index + 1;
            };

            (op_bridge_amount, minitswap_amount, stableswap_amount)
        }
    }

    // A function that simulates all possible swap routes and finds the one with the best return amount.
    fun find_best_route(
        simulation_cache: &mut SimpleMap<Key, SimulationRes>,
        former_op_bridge_amount: u64,
        former_minitswap_amount: u64,
        former_stableswap_amount: u64,
        op_bridge_enable: bool,
        virtual_pool_exists: bool,
        stableswap_pool: Option<Object<stableswap::Pool>>,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        offer_amount: u64
    ): (u64, u64, u64) {
        let op_bridge_return_amount = if (op_bridge_enable) {
            offer_amount
        } else { 0 };

        let minitswap_return_amount =
            if (former_minitswap_amount != 0 && virtual_pool_exists) {
                let SimulationRes { return_amount, fee: _} = simple_map::borrow(
                    simulation_cache,
                    &Key { route: MINITSWAP, amount: former_minitswap_amount });
                let former_return_amount = *return_amount;
                let (return_amount, _) = simulation(
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
            } else { 0 };

        let stableswap_return_amount =
            if (option::is_some(&stableswap_pool) && former_stableswap_amount != 0) {
                let pool_addr =
                    option::some(object::object_address(option::borrow(&stableswap_pool)));
                let (return_amount, _) =
                    simulation(
                        simulation_cache,
                        pool_addr,
                        offer_asset_metadata,
                        return_asset_metadata,
                        Key {
                            route: STABLESWAP,
                            amount: former_stableswap_amount + offer_amount
                        },
                    );
                let SimulationRes { return_amount: former_return_amount, fee: _ } =
                    simple_map::borrow(
                        simulation_cache,
                        &Key { route: STABLESWAP, amount: former_stableswap_amount + offer_amount },
                    );
                return_amount - *former_return_amount
            } else { 0 };

        if (op_bridge_return_amount > minitswap_return_amount
                && op_bridge_return_amount > stableswap_return_amount) {
            return (
                former_op_bridge_amount + offer_amount,
                former_minitswap_amount,
                former_stableswap_amount
            )
        } else if (minitswap_return_amount > stableswap_return_amount) {
            return (
                former_op_bridge_amount,
                former_minitswap_amount + offer_amount,
                former_stableswap_amount
            )
        } else {
            return (
                former_op_bridge_amount,
                former_minitswap_amount,
                former_stableswap_amount + offer_amount
            )
        }
    }

    struct SimulationRes has drop, copy, store {
        return_amount: u64,
        fee: u64
    }

    fun simulation(
        simulation_cache: &mut SimpleMap<Key, SimulationRes>,
        pool_addr: Option<address>,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        key: Key,
    ): (u64, u64) {
        if (key.amount == 0) {
            return (0, 0)
        };
        if (!simple_map::contains_key(simulation_cache, &key)) {
            if (key.route == OP_BRIDGE) {
                simple_map::add(
                    simulation_cache,
                    key,
                    SimulationRes { return_amount: key.amount, fee: 0, },
                );
            } else if (key.route == MINITSWAP) {
                let (return_amount, fee) =
                    minitswap::safe_swap_simulation(
                        offer_asset_metadata, return_asset_metadata, key.amount
                    );
                simple_map::add(
                    simulation_cache,
                    key,
                    SimulationRes { return_amount, fee, },
                );
            } else if (key.route == STABLESWAP) {
                let pool_addr = *option::borrow(&pool_addr);
                let pool_obj = object::address_to_object<stableswap::Pool>(pool_addr);
                let (return_amount, fee) =
                    stableswap::swap_simulation(
                        pool_obj,
                        offer_asset_metadata,
                        return_asset_metadata,
                        key.amount,
                        true,
                    );
                simple_map::add(
                    simulation_cache,
                    key,
                    SimulationRes {
                        return_amount,
                        fee
                    },
                );
            };
        };

        let simulation_res = simple_map::borrow(simulation_cache, &key);
        return (simulation_res.return_amount, simulation_res.fee)
    }

    fun is_l1_init_metadata(metadata: Object<Metadata>): bool {
        metadata == l1_init_metadata()
    }

    fun l1_init_metadata(): Object<Metadata> {
        let addr = object::create_object_address(&@initia_std, b"uinit");
        object::address_to_object<Metadata>(addr)
    }

    fun transfer_fa(
        account: &signer,
        fa: FungibleAsset,
        receiver: String,
        source_port: String,
        source_channel: String,
        memo: String
    ) {
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

    fun deposit_fa(
        account: &signer,
        fa: FungibleAsset,
        bridge_id: u64,
        to: address,
        data: vector<u8>
    ) {
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
        let msg = MsgInitiateTokenDeposit {
            _type_: string::utf8(b"/opinit.ophost.v1.MsgInitiateTokenDeposit"),
            sender: to_sdk(signer::address_of(sender)),
            bridge_id,
            to: to_sdk(to),
            data,
            amount: Coin { denom: coin::metadata_to_denom(metadata), amount, }
        };
        cosmos::stargate(sender, json::marshal(&msg));
    }

    #[test_only]
    fun initialized_coin(account: &signer, symbol: String,)
        : (
        coin::BurnCapability, coin::FreezeCapability, coin::MintCapability
    ) {
        let (mint_cap, burn_cap, freeze_cap, _) =
            coin::initialize_and_generate_extend_ref(
                account,
                option::none(),
                string::utf8(b""),
                symbol,
                6,
                string::utf8(b""),
                string::utf8(b""),
            );

        return (burn_cap, freeze_cap, mint_cap)
    }

    #[test_only]
    fun test_setting(chain: &signer, router: &signer) {
        initia_std::primary_fungible_store::init_module_for_test();
        init_module(router);
        minitswap::init_module_for_test();
        stableswap::init_module_for_test();

        block::set_block_info(0, 100);

        let chain_addr = signer::address_of(chain);

        let (_, _, initia_mint_cap) = initialized_coin(chain, string::utf8(b"uinit"));
        let (_, _, ibc_op_init_1_mint_cap) =
            initialized_coin(
                chain,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );
        let (_, _, ibc_op_init_2_mint_cap) =
            initialized_coin(
                chain,
                string::utf8(
                    b"ibc/AD8D520BF2D981113B652A3BCD55368EF146FCB9E016F8B1DAECAA5D570BC8A1",
                ),
            );

        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );
        let ibc_op_init_2_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/AD8D520BF2D981113B652A3BCD55368EF146FCB9E016F8B1DAECAA5D570BC8A1",
                ),
            );

        coin::mint_to(&initia_mint_cap, chain_addr, 10000000000);
        coin::mint_to(&ibc_op_init_1_mint_cap, chain_addr, 10000000000);
        coin::mint_to(&ibc_op_init_2_mint_cap, chain_addr, 10000000000);

        minitswap::update_module_params(
            chain,
            option::none(),
            option::none(),
            option::none(),
            option::some(bigdecimal::from_ratio_u64(1, 10000)),
            option::some(bigdecimal::from_ratio_u64(1, 2)),
            option::some(1000),
            option::some(10000),
            option::none(),
            option::some(2),
            option::some(100),
        );

        minitswap::create_pool(
            chain,
            ibc_op_init_1_metadata,
            bigdecimal::from_ratio_u64(1000000000, 1),
            10000000,
            6000,
            bigdecimal::from_ratio_u64(6, 10),
            bigdecimal::from_ratio_u64(3, 1),
            0,
            string::utf8(b"0x1"),
            1,
            string::utf8(b"channel-0"),
        );

        minitswap::create_pool(
            chain,
            ibc_op_init_2_metadata,
            bigdecimal::from_ratio_u64(1000000000, 1),
            10000000,
            6000,
            bigdecimal::from_ratio_u64(6, 10),
            bigdecimal::from_ratio_u64(3, 1),
            1,
            string::utf8(b"0x1"),
            2,
            string::utf8(b"channel-2"),
        );
    }

    #[test(chain = @0x1, router = @router)]
    fun test_using_op_bridge(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );
        let ibc_op_init_2_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/AD8D520BF2D981113B652A3BCD55368EF146FCB9E016F8B1DAECAA5D570BC8A1",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());

        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            true,
            option::none(),
            option::none(),
            option::none(),
        );
        swap(
            &chain,
            init_metadata,
            ibc_op_init_2_metadata,
            1000,
            chain_addr,
            true,
            option::none(),
            option::none(),
            option::none(),
        );
    }

    #[test(chain = @0x1, router = @router)]
    fun test_prefer_op_bridge(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );
        let ibc_op_init_2_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/AD8D520BF2D981113B652A3BCD55368EF146FCB9E016F8B1DAECAA5D570BC8A1",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());

        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            true,
            option::some(OP_BRIDGE),
            option::none(),
            option::none(),
        );
        swap(
            &chain,
            init_metadata,
            ibc_op_init_2_metadata,
            1000,
            chain_addr,
            true,
            option::some(OP_BRIDGE),
            option::none(),
            option::none(),
        );
    }

    #[test(chain = @0x1, router = @router)]
    #[expected_failure(abort_code = 0x30007, location = initia_std::minitswap)]
    fun test_failure_ibc_op_init_price_too_low(
        chain: signer, router: signer
    ) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());

        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            true,
            option::some(MINITSWAP),
            option::none(),
            option::none(),
        );
    }

    #[test(chain = @0x1, router = @router)]
    #[expected_failure(abort_code = 0x10002, location = Self)]
    fun test_failure_stableswap_not_exists(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());

        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            true,
            option::some(STABLESWAP),
            option::none(),
            option::none(),
        );
    }

    #[test(chain = @0x1, router = @router)]
    fun test_minitswap_return_amount(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());

        minitswap::swap(
            &chain,
            ibc_op_init_1_metadata,
            init_metadata,
            2000000,
            option::none(),
        );
        let balance_before = coin::balance(chain_addr, ibc_op_init_1_metadata);
        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            true,
            option::some(MINITSWAP),
            option::none(),
            option::none(),
        );
        let balance_after = coin::balance(chain_addr, ibc_op_init_1_metadata);

        assert!(balance_after - balance_before == 1007, 0);
    }

    #[test(chain = @0x1, router = @router)]
    fun test_stableswap_return_amount(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());
        minitswap::create_stableswap_pool(
            &chain,
            1,
            string::utf8(b"channel-0"),
            ibc_op_init_1_metadata,
            10000000,
            10000000,
        );

        let pools = minitswap::get_pools(ibc_op_init_1_metadata);
        let (_, _, _, _, _, stableswap_pool) = minitswap::unpack_pools_response(pools);

        stableswap::swap_script(
            &chain,
            *option::borrow(&stableswap_pool),
            ibc_op_init_1_metadata,
            init_metadata,
            5000000,
            option::none(),
        );

        let SwapSimulationResponse {
            op_bridge_offer_amount: _,
            op_bridge_return_amount: _,
            minitswap_offer_amount: _,
            net_minitswap_return_amount: _,
            stableswap_offer_amount,
            net_stableswap_return_amount,
        } =
            swap_simulation(
                init_metadata,
                ibc_op_init_1_metadata,
                1000,
                true,
                option::some(STABLESWAP),
                option::none(),
            );
        assert!(stableswap_offer_amount == 1000, 0);

        let stableswap_return_amount_from_stableswap =
            stableswap::get_swap_simulation(
                *option::borrow(&stableswap_pool),
                init_metadata,
                ibc_op_init_1_metadata,
                1000,
            );

        let balance_before = coin::balance(chain_addr, ibc_op_init_1_metadata);
        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            true,
            option::some(STABLESWAP),
            option::none(),
            option::none(),
        );
        let balance_after = coin::balance(chain_addr, ibc_op_init_1_metadata);

        let actual_return_amount = balance_after - balance_before;

        assert!(net_stableswap_return_amount == stableswap_return_amount_from_stableswap, 1);
        assert!(net_stableswap_return_amount == actual_return_amount, 1);
    }

    #[test(chain = @0x1, router = @router)]
    #[expected_failure(abort_code = 0x10002, location = Self)]
    fun test_failure_use_op_bridge_with_bridge_out_false(
        chain: signer, router: signer
    ) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());

        minitswap::swap(
            &chain,
            ibc_op_init_1_metadata,
            init_metadata,
            2000000,
            option::none(),
        );
        swap(
            &chain,
            init_metadata,
            ibc_op_init_1_metadata,
            1000,
            chain_addr,
            false,
            option::some(OP_BRIDGE),
            option::none(),
            option::none(),
        );
    }

    #[test(chain = @0x1, router = @router)]
    fun test_batch(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());
        minitswap::create_stableswap_pool(
            &chain,
            1,
            string::utf8(b"channel-0"),
            ibc_op_init_1_metadata,
            10000000,
            10000000,
        );

        let pools = minitswap::get_pools(ibc_op_init_1_metadata);
        let (_, _, _, _, _, stableswap_pool) = minitswap::unpack_pools_response(pools);
        let stableswap_pool = *option::borrow(&stableswap_pool);
        minitswap::swap(
            &chain,
            ibc_op_init_1_metadata,
            init_metadata,
            450000,
            option::none(),
        );
        stableswap::swap_script(
            &chain,
            stableswap_pool,
            ibc_op_init_1_metadata,
            init_metadata,
            450000,
            option::none(),
        );

        let SwapSimulationResponse {
            op_bridge_offer_amount,
            op_bridge_return_amount,
            minitswap_offer_amount,
            net_minitswap_return_amount,
            stableswap_offer_amount,
            net_stableswap_return_amount,
        } =
            swap_simulation(
                init_metadata,
                ibc_op_init_1_metadata,
                900000,
                true,
                option::none(),
                option::some(3),
            );
            
        assert!(op_bridge_offer_amount == 300000, 0);
        assert!(minitswap_offer_amount == 300000, 1);
        assert!(stableswap_offer_amount == 300000, 2);
        assert!(op_bridge_return_amount == 300000, 3);
        assert!(net_minitswap_return_amount == 300276, 4);
        assert!(net_stableswap_return_amount == 300823, 5);
    }

    #[test(chain = @0x1, router = @router)]
    fun test_batch_l2_to_l1(chain: signer, router: signer) acquires Config {
        test_setting(&chain, &router);

        let chain_addr = signer::address_of(&chain);
        let init_metadata = coin::metadata(chain_addr, string::utf8(b"uinit"));
        let ibc_op_init_1_metadata =
            coin::metadata(
                chain_addr,
                string::utf8(
                    b"ibc/82EB1C694C571F954E68BFD68CFCFCD6123B0EBB69AAA8BAB7A082939B45E802",
                ),
            );

        minitswap::provide(&chain, 200000000, option::none());
        minitswap::create_stableswap_pool(
            &chain,
            1,
            string::utf8(b"channel-0"),
            ibc_op_init_1_metadata,
            10000000,
            10000000,
        );

        minitswap::swap(
            &chain,
            ibc_op_init_1_metadata,
            init_metadata,
            900000,
            option::none(),
        );

        let SwapSimulationResponse {
            op_bridge_offer_amount,
            op_bridge_return_amount,
            minitswap_offer_amount,
            net_minitswap_return_amount,
            stableswap_offer_amount,
            net_stableswap_return_amount,
        } =
            swap_simulation(
                ibc_op_init_1_metadata,
                init_metadata,
                900000,
                true,
                option::none(),
                option::some(3),
            );
        assert!(op_bridge_offer_amount == 0, 0);
        assert!(minitswap_offer_amount == 300000, 1);
        assert!(stableswap_offer_amount == 600000, 2);
        assert!(op_bridge_return_amount == 0, 3);
        assert!(net_minitswap_return_amount == 297906, 4);
        assert!(net_stableswap_return_amount == 597153, 5);
    }
}
