// module swap_transfer::swap_transfer {

//     use std::error;
//     use std::signer;
//     use std::vector;
//     use std::string::String;
//     use std::option::{Self, Option};

//     use initia_std::block;
//     use initia_std::fungible_asset::{Self, FungibleAsset, Metadata};
//     use initia_std::primary_fungible_store;
//     use initia_std::cosmos;
//     use initia_std::dex::{Self, Config};
//     use initia_std::object::{Self, Object};
//     use me::minit_swap;
//     use initia_std::from_bcs;

//     use dex_utils::dex_utils;

//     // Errors
    
//     const EMIN_RETURN: u64 = 1;

//     public entry fun swap_transfer(
//         account: &signer,
//         pair: Object<Config>,
//         offer_asset_metadata: Object<Metadata>,
//         offer_asset_amount: u64,
//         min_return_amount: Option<u64>,
//         receiver: String,
//         source_port: String,
//         source_channel: String,
//         memo: String,
//     ) {
//         let (_, timestamp) = block::get_block_info();
//         let addr = signer::address_of(account);

//         let offer_coin = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
//         let return_coin = dex::swap(pair, offer_coin);

//         if (option::is_some(&min_return_amount)) {
//             let min_return = option::borrow(&min_return_amount); 
//             assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
//         };

//         let amount = fungible_asset::amount(&return_coin);
//         let return_asset_metadata = fungible_asset::metadata_from_asset(&return_coin);
//         primary_fungible_store::deposit(addr, return_coin);

//         cosmos::transfer(
//             account,
//             receiver,
//             return_asset_metadata,
//             amount,
//             source_port,
//             source_channel,
//             0,
//             0,
//             (timestamp + 1000) * 1000000000,
//             memo,
//         )
//     }

//     public entry fun swap_deposit(
//         account: &signer,
//         pair: Object<Config>,
//         offer_asset_metadata: Object<Metadata>,
//         offer_asset_amount: u64,
//         min_return_amount: Option<u64>,
//         bridge_id: u64,
//         to: address,
//         data: vector<u8>
//     ) {
//         let addr = signer::address_of(account);

//         let offer_coin = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);
//         let return_coin = dex::swap(pair, offer_coin);

//         if (option::is_some(&min_return_amount)) {
//             let min_return = option::borrow(&min_return_amount); 
//             assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
//         };

//         let amount = fungible_asset::amount(&return_coin);
//         let return_asset_metadata = fungible_asset::metadata_from_asset(&return_coin);
//         primary_fungible_store::deposit(addr, return_coin);

//         cosmos::initiate_token_deposit(account, bridge_id, to, return_asset_metadata, amount, data);
//     }

//     public entry fun minit_swap_deposit(
//         account: &signer,
//         offer_asset_metadata: Object<Metadata>,
//         return_asset_metadata: Object<Metadata>,
//         amount: u64,
//         min_return_amount: Option<u64>,
//         bridge_id: u64,
//         to: address,
//         data: vector<u8>
//     ) {
//         let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, amount);
//         let return_asset = minit_swap::swap_internal(account, offer_asset, return_asset_metadata);
//         let return_amount = fungible_asset::amount(&return_asset);
//         if (option::is_some(&min_return_amount)) {
//             let min_return = option::extract(&mut min_return_amount);
//             assert!(return_amount >= min_return, error::invalid_state(EMIN_RETURN))
//         };

//         primary_fungible_store::deposit(signer::address_of(account), return_asset);
//         cosmos::initiate_token_deposit(account, bridge_id, to, return_asset_metadata, return_amount, data);
//     }

//     public entry fun minit_swap_to(
//         account: &signer,
//         offer_asset_metadata: Object<Metadata>,
//         return_asset_metadata: Object<Metadata>,
//         amount: u64,
//         min_return: Option<u64>,
//         to: address,
//     ) {
//         let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, amount);
//         let return_asset = minit_swap::swap_internal(account, offer_asset, return_asset_metadata);
//         if (option::is_some(&min_return)) {
//             let min_return = option::extract(&mut min_return);
//             assert!(fungible_asset::amount(&return_asset) >= min_return, error::invalid_state(EMIN_RETURN))
//         };
//         primary_fungible_store::deposit(to, return_asset);
//     }

//     public entry fun route_swap_transfer(
//         account: &signer,
//         offer_coin_metadata: Object<Metadata>,
//         route: vector<Object<Config>>,
//         offer_coin_amount: u64,
//         min_return_amount: Option<u64>,
//         receiver: String,
//         source_port: String,
//         source_channel: String,
//         memo: String,
//     ) {
//         let (_, timestamp) = block::get_block_info();
//         let addr = signer::address_of(account);

//         let offer_coin = primary_fungible_store::withdraw(account, offer_coin_metadata, offer_coin_amount);
//         let return_coin = dex_utils::route_swap_raw(account, offer_coin, route);

//         if (option::is_some(&min_return_amount)) {
//             let min_return = option::borrow(&min_return_amount); 
//             assert!(fungible_asset::amount(&return_coin) >= *min_return, error::invalid_state(EMIN_RETURN));
//         };

//         let amount = fungible_asset::amount(&return_coin);
//         let return_asset_metadata = fungible_asset::metadata_from_asset(&return_coin);
//         primary_fungible_store::deposit(addr, return_coin);

//         cosmos::transfer(
//             account,
//             receiver,
//             return_asset_metadata,
//             amount,
//             source_port,
//             source_channel,
//             0,
//             0,
//             (timestamp + 1000) * 1000000000,
//             memo,
//         )
//     }

//     public entry fun mixed_route_swap_transfer(
//         account: &signer,
//         offer_asset_metadata: Object<Metadata>,
//         routes: vector<vector<vector<u8>>>,
//         offer_asset_amount: u64,
//         min_return_amount: Option<u64>,
//         receiver: String,
//         source_port: String,
//         source_channel: String,
//         memo: String,
//     ) {
//         let (_, timestamp) = block::get_block_info();
//         let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);

//         let return_asset = mixed_swap(account, routes, offer_asset);
//         let return_asset_metadata = fungible_asset::metadata_from_asset(&return_asset);
//         let amount = fungible_asset::amount(&return_asset);
//         if (option::is_some(&min_return_amount)) {
//             let min_return = option::extract(&mut min_return_amount);
//             assert!(amount >= min_return, error::invalid_state(EMIN_RETURN));
//         };
        
//         primary_fungible_store::deposit(signer::address_of(account), return_asset);

//         cosmos::transfer(
//             account,
//             receiver,
//             return_asset_metadata,
//             amount,
//             source_port,
//             source_channel,
//             0,
//             0,
//             (timestamp + 1000) * 1000000000,
//             memo,
//         )
//     }

//     public entry fun mixed_route_swap_deposit(
//         account: &signer,
//         offer_asset_metadata: Object<Metadata>,
//         routes: vector<vector<vector<u8>>>,
//         offer_asset_amount: u64,
//         min_return_amount: Option<u64>,
//         bridge_id: u64,
//         to: address,
//         data: vector<u8>
//     ) {
//         let offer_asset = primary_fungible_store::withdraw(account, offer_asset_metadata, offer_asset_amount);

//         let return_asset = mixed_swap(account, routes, offer_asset);
//         let return_asset_metadata = fungible_asset::metadata_from_asset(&return_asset);
//         let amount = fungible_asset::amount(&return_asset);
//         if (option::is_some(&min_return_amount)) {
//             let min_return = option::extract(&mut min_return_amount);
//             assert!(amount >= min_return, error::invalid_state(EMIN_RETURN));
//         };
        
//         primary_fungible_store::deposit(signer::address_of(account), return_asset);

//         cosmos::initiate_token_deposit(account, bridge_id, to, return_asset_metadata, amount, data);
//     }

//     public fun mixed_swap(account: &signer, routes: vector<vector<vector<u8>>>, offer_asset: FungibleAsset): FungibleAsset {
//         let len = vector::length(&routes);
//         let index = 0;
//         while(index < len) {
//             let route = vector::borrow(&routes, index);
//             let type = from_bcs::to_u8(*vector::borrow(route, 0));
//             offer_asset = if (type == 0) {
//                 let config_addr = from_bcs::to_address(*vector::borrow(route, 1));
//                 let pair = object::address_to_object<Config>(config_addr);
//                 dex::swap(pair, offer_asset)
//             } else if (type == 1) {
//                 let return_asset_metadata_address = from_bcs::to_address(*vector::borrow(route, 1));
//                 let return_asset_metadata = object::address_to_object<Metadata>(return_asset_metadata_address);
//                 minit_swap::swap_internal(account, offer_asset, return_asset_metadata)
//             } else {
//                 assert!(false, 123);
//                 offer_asset
//             };

//             index = index + 1;
//         };

//         offer_asset
//     }
// }
