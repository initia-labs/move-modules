/// wrap fungible asset to resource based coin
module launch::coin_wrapper {
    use std::error;

    use initia_std::object::{Self, ExtendRef, Object};
    use initia_std::fungible_asset::{Self, Metadata, FungibleAsset};
    use initia_std::primary_fungible_store;

    const EFUNGIBLE_ASSET_MISMATCH: u64 = 1;
    const EINSUFFICIENT_BALANCE: u64 = 2;
    const EAMOUNT_IS_NOT_ZERO: u64 = 3;

    struct ModuleStore has key {
        extend_ref: ExtendRef
    }

    struct WrappedCoin has store {
        metadata: Object<Metadata>,
        amount: u64,
    }

    fun init_module(l: &signer) {
        let constructor_ref = object::create_object(@initia_std);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        move_to(l, ModuleStore { extend_ref });
    }

    public fun wrap(fa: FungibleAsset): WrappedCoin acquires ModuleStore {
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let amount = fungible_asset::amount(&fa);
        let m_store = borrow_global<ModuleStore>(@launch);
        let wrap_addr = object::address_from_extend_ref(&m_store.extend_ref);
        primary_fungible_store::deposit(wrap_addr, fa);
        WrappedCoin { metadata, amount }
    }

    public fun unwrap(wrapped_coin: WrappedCoin): FungibleAsset acquires ModuleStore {
        let WrappedCoin { metadata, amount } = wrapped_coin;
        let m_store = borrow_global<ModuleStore>(@launch);
        let wrap_signer = object::generate_signer_for_extending(&m_store.extend_ref);
        primary_fungible_store::withdraw(&wrap_signer, metadata, amount)
    }

    public fun merge(dst_coin: &mut WrappedCoin, src_coin: WrappedCoin) {
        let WrappedCoin { metadata, amount } = src_coin;
        assert!(metadata == dst_coin.metadata, error::invalid_argument(EFUNGIBLE_ASSET_MISMATCH));
        dst_coin.amount = dst_coin.amount + amount;
    }

    public fun extract(wrapped_coin: &mut WrappedCoin, amount: u64): WrappedCoin {
        assert!(wrapped_coin.amount >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));
        wrapped_coin.amount = wrapped_coin.amount - amount;
        WrappedCoin {
            metadata: wrapped_coin.metadata,
            amount,
        }
    }

    public fun destroy_zero(wrapped_coin: WrappedCoin) {
        let WrappedCoin { amount, metadata: _ } = wrapped_coin;
        assert!(amount == 0, error::invalid_argument(EAMOUNT_IS_NOT_ZERO));
    }

    public fun metadata(wrapped_coin: &WrappedCoin): Object<Metadata> {
        wrapped_coin.metadata
    }

    public fun amount(wrapped_coin: &WrappedCoin): u64 {
        wrapped_coin.amount
    }

    #[test_only]
    public fun init_module_for_test(c: &signer) {
        init_module(c);
    }
}