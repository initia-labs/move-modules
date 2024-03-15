module swap_transfer::swap_transfer {

    use std::error;
    use std::signer;
    use std::vector;
    use std::string::{Self, String};
    use std::option::{Self, Option};

    use initia_std::address::to_sdk;
    use initia_std::base64;
    use initia_std::block;
    use initia_std::coin;
    use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
    use initia_std::primary_fungible_store;
    use initia_std::cosmos;
    use initia_std::dex::{Self, Config};
    use initia_std::object::{Self, Object};
    use initia_std::minitswap;
    use initia_std::from_bcs;
    use initia_std::json;
    use initia_std::simple_json;

    use dex_utils::dex_utils;

    // Errors
    
    const EMIN_RETURN: u64 = 1;

    const EUNKNOWN_TYPE: u64 = 2;

    /// swap on dex and ibc transfer to
    public entry fun swap_transfer(
        account: &signer,
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        offer_asset_amount: u64,
        min_return_amount: Option<u64>,
        receiver: String,
        source_port: String,
        source_channel: String,
        memo: String,
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
        let return_asset = dex::swap(pair, offer_asset);
        assert_min_amount(min_return_amount, &return_asset);

        transfer_fa(account, return_asset, receiver, source_port, source_channel, memo);
    }

    /// swap on dex and deposit via op bridge
    public entry fun swap_deposit(
        account: &signer,
        pair: Object<Config>,
        offer_asset_metadata: Object<Metadata>,
        offer_asset_amount: u64,
        min_return_amount: Option<u64>,
        bridge_id: u64,
        to: address,
        data: vector<u8>
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
        let return_asset = dex::swap(pair, offer_asset);
        assert_min_amount(min_return_amount, &return_asset);

        deposit_fa(account, return_asset, bridge_id, to, data);
    }

    /// swap on minitswap and deposit via op bridge
    public entry fun minit_swap_deposit(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        amount: u64,
        min_return_amount: Option<u64>,
        bridge_id: u64,
        to: address,
        data: vector<u8>
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, amount);
        let return_asset = minitswap::swap_internal(offer_asset, return_asset_metadata);
        assert_min_amount(min_return_amount, &return_asset);

        deposit_fa(account, return_asset, bridge_id, to, data);
    }

    /// swap on minitswap and transfer to any
    public entry fun minit_swap_to(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        return_asset_metadata: Object<Metadata>,
        amount: u64,
        min_return_amount: Option<u64>,
        to: address,
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, amount);
        let return_asset = minitswap::swap_internal(offer_asset, return_asset_metadata);
        assert_min_amount(min_return_amount, &return_asset);

        primary_fungible_store::deposit(to, return_asset);
    }

    public entry fun route_swap_transfer(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        route: vector<Object<Config>>,
        offer_asset_amount: u64,
        min_return_amount: Option<u64>,
        receiver: String,
        source_port: String,
        source_channel: String,
        memo: String,
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
        let return_asset = dex_utils::route_swap_raw(account, offer_asset, route);
        assert_min_amount(min_return_amount, &return_asset);

        transfer_fa(account, return_asset, receiver, source_port, source_channel, memo);
    }

    public entry fun mixed_route_swap_transfer(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        routes: vector<vector<vector<u8>>>,
        offer_asset_amount: u64,
        min_return_amount: Option<u64>,
        receiver: String,
        source_port: String,
        source_channel: String,
        memo: String,
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
        let return_asset = mixed_swap(routes, offer_asset);
        assert_min_amount(min_return_amount, &return_asset);

        transfer_fa(account, return_asset, receiver, source_port, source_channel, memo);
    }

    public entry fun mixed_route_swap_deposit(
        account: &signer,
        offer_asset_metadata: Object<Metadata>,
        routes: vector<vector<vector<u8>>>,
        offer_asset_amount: u64,
        min_return_amount: Option<u64>,
        bridge_id: u64,
        to: address,
        data: vector<u8>
    ) {
        let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
        let return_asset = mixed_swap(routes, offer_asset);
        assert_min_amount(min_return_amount, &return_asset);

        deposit_fa(account, return_asset, bridge_id, to, data);
    }

    /// routes: vector[
    ///     path: u8, // 0 for dex, 1 for minitswap
    ///     ...args: vector<any>,
    /// ]
    public fun mixed_swap(routes: vector<vector<vector<u8>>>, offer_asset: FungibleAsset): FungibleAsset {
        let len = vector::length(&routes);
        let index = 0;
        while(index < len) {
            let route = vector::borrow(&routes, index);
            let type = from_bcs::to_u8(*vector::borrow(route, 0));

            assert!(type < 2, error::invalid_argument(EUNKNOWN_TYPE));
            offer_asset = if (type == 0) {
                let config_addr = from_bcs::to_address(*vector::borrow(route, 1));
                let pair = object::address_to_object<Config>(config_addr);
                dex::swap(pair, offer_asset)
            } else { // else if (type == 1) {
                let return_asset_metadata_address = from_bcs::to_address(*vector::borrow(route, 1));
                let return_asset_metadata = object::address_to_object<Metadata>(return_asset_metadata_address);
                minitswap::swap_internal(offer_asset, return_asset_metadata)
            };
            index = index + 1;
        };

        offer_asset
    }

    fun assert_min_amount(min_return_amount: Option<u64>, return_asset: &FungibleAsset) {
        if (option::is_some(&min_return_amount)) {
            let min_return = option::borrow(&min_return_amount); 
            assert!(fungible_asset::amount(return_asset) >= *min_return, error::invalid_state(EMIN_RETURN));
        };
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
        simple_json::set_int_raw(&mut obj, option::some(string::utf8(b"bridge_id")), true, (bridge_id as u256));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"to")), to_sdk(to));
        simple_json::set_string(&mut obj, option::some(string::utf8(b"data")), base64::to_string(data));
        simple_json::set_object(&mut obj, option::some(string::utf8(b"amount")));
        simple_json::increase_depth(&mut obj);
        simple_json::set_string(&mut obj, option::some(string::utf8(b"denom")), coin::metadata_to_denom(metadata));
        simple_json::set_int_raw(&mut obj, option::some(string::utf8(b"amount")), true, (amount as u256));

        let req = json::stringify(simple_json::to_json_object(&obj));
        cosmos::stargate(sender, req);
    }
}
