module swap_transfer::swap_transfer {

    use std::error;
    use std::signer;
    use std::string::String;
    use std::option::{Self, Option};

    use initia_std::block;
    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::primary_fungible_store;
    use initia_std::cosmos;
    use initia_std::dex::{Self, Config};
    use initia_std::object::Object;

    use dex_utils::dex_utils;

    // Errors
    
    const EMIN_RETURN: u64 = 1;

    public entry fun swap_transfer(
        account: &signer,
        pair: Object<Config>,
        offer_coin_metadata: Object<Metadata>,
        offer_coin_amount: u64,
        min_return_amount: Option<u64>,
        receiver: String,
        source_port: String,
        source_channel: String,
        memo: String,
    ) {
        let (_, timestamp) = block::get_block_info();
        let addr = signer::address_of(account);

        let offer_coin = primary_fungible_store::withdraw(account, offer_coin_metadata, offer_coin_amount);
        let return_coin = dex::swap(account, pair, offer_coin);

        if (option::is_some(&min_return_amount)) {
            let min_return = option::borrow(&min_return_amount); 
            assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
        };

        let amount = fungible_asset::amount(&return_coin);
        let return_coin_metadata = fungible_asset::metadata_from_asset(&return_coin);
        primary_fungible_store::deposit(addr, return_coin);

        cosmos::transfer(
            account,
            receiver,
            return_coin_metadata,
            amount,
            source_port,
            source_channel,
            0,
            0,
            (timestamp + 1000) * 1000000000,
            memo,
        )
    }

    public entry fun route_swap_transfer(
        account: &signer,
        offer_coin_metadata: Object<Metadata>,
        route: vector<Object<Config>>,
        offer_coin_amount: u64,
        min_return_amount: Option<u64>,
        receiver: String,
        source_port: String,
        source_channel: String,
        memo: String,
    ) {
        let (_, timestamp) = block::get_block_info();
        let addr = signer::address_of(account);

        let offer_coin = primary_fungible_store::withdraw(account, offer_coin_metadata, offer_coin_amount);
        let return_coin = dex_utils::route_swap_raw(account, offer_coin, route);

        if (option::is_some(&min_return_amount)) {
            let min_return = option::borrow(&min_return_amount); 
            assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
        };

        let amount = fungible_asset::amount(&return_coin);
        let return_coin_metadata = fungible_asset::metadata_from_asset(&return_coin);
        primary_fungible_store::deposit(addr, return_coin);

        cosmos::transfer(
            account,
            receiver,
            return_coin_metadata,
            amount,
            source_port,
            source_channel,
            0,
            0,
            (timestamp + 1000) * 1000000000,
            memo,
        )
    }
}
