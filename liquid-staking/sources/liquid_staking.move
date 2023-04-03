module liquid_staking::liquid_staking {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::option;
    
    use initia_std::coin::{Self, Coin};
    use initia_std::decimal128;
    use initia_std::dex;
    use initia_std::native_uinit::Coin as RewardCoin;
    use initia_std::staking::{Self, Delegation, Unbonding};

    /// Errors
    const ENOT_OWNER: u64 = 1;
    const EDELEGATION_STORE_ALREADY_EXISTS: u64 = 2;
    
    /// Coin type for liquid staking token
    struct LiquidStakingToken<phantom BondCoin> {}

    /// Coin capabilities of liquid staking token
    struct Capabilities<phantom BondCoin> has store {
        burn_cap: coin::BurnCapability<LiquidStakingToken<BondCoin>>,
        freeze_cap: coin::FreezeCapability<LiquidStakingToken<BondCoin>>,
        mint_cap: coin::MintCapability<LiquidStakingToken<BondCoin>>,
    }

    struct DelegationStore<phantom BondCoin> has key {
        delegation: Delegation<BondCoin>,
        rewards: Coin<RewardCoin>,
        caps: Capabilities<BondCoin>
    }

    // user store for store a unbondings
    struct UserStore<phantom BondCoin> has key {
        unbondings: vector<Unbonding<BondCoin>>,
    }

    /// Owner functions

    public entry fun add_bond_coin<LiquidityToken>(account: &signer, validator: String) {
        check_is_owner(account);
        assert!(!exists<DelegationStore<LiquidityToken>>(@liquid_staking), error::already_exists(EDELEGATION_STORE_ALREADY_EXISTS));

        let (burn_cap, freeze_cap, mint_cap)
            = coin::initialize<LiquidStakingToken<LiquidityToken>>(account, string::utf8(b"liquid staking token"), string::utf8(b"LST"), 6);

        let caps = Capabilities<LiquidityToken> { burn_cap, freeze_cap, mint_cap };
        let delegation_store = DelegationStore<LiquidityToken> {
            delegation: staking::empty_delegation<LiquidityToken>(validator),
            rewards: coin::zero(),
            caps,
        };

        move_to(account, delegation_store)
    }

    /// execute functions

    /// reinvest reward
    public entry fun reinvest<CoinA, CoinB, LiquidityToken>(account: &signer) acquires DelegationStore {
        let delegation_store = borrow_global_mut<DelegationStore<LiquidityToken>>(@liquid_staking);
        let reward_amount =  coin::value(&delegation_store.rewards);
        let reward = coin::extract(&mut delegation_store.rewards, reward_amount);
        let validator = staking::get_validator_from_delegation(&delegation_store.delegation);
        let bond_coin = dex::single_asset_provide_liquidity<CoinA, CoinB, LiquidityToken, RewardCoin>(account, reward, option::none());
        let delegation = staking::delegate(validator, bond_coin);

        let reward = staking::merge_delegation(&mut delegation_store.delegation, delegation);
        coin::merge(&mut delegation_store.rewards, reward);
    }

    public entry fun bond_script<LiquidityToken>(account: &signer, amount: u64) acquires DelegationStore {
        let addr = signer::address_of(account);
        assert!(amount != 1, 1);
        let bond_coin = coin::withdraw<LiquidityToken>(account, amount);
        assert!(amount != 2, 2);
        let lst = bond(bond_coin);
        assert!(amount != 3, 3);
        if (!coin::is_account_registered<LiquidStakingToken<LiquidityToken>>(addr)) {
            coin::register<LiquidStakingToken<LiquidityToken>>(account);
        };
        assert!(amount != 4, 4);

        coin::deposit<LiquidStakingToken<LiquidityToken>>(addr, lst);
        assert!(amount != 11, 11);
    }

    public entry fun unbond_script<LiquidityToken>(account: &signer, amount: u64) acquires DelegationStore {
        let addr = signer::address_of(account);
        let lst = coin::withdraw<LiquidStakingToken<LiquidityToken>>(account, amount);
        let unbonding = unbond<LiquidityToken>(lst);
        if (!staking::is_account_registered<LiquidStakingToken<LiquidityToken>>(addr)) {
            staking::register<LiquidStakingToken<LiquidityToken>>(account);
        };

        staking::deposit_unbonding(addr, unbonding);
    }

    /// Bond bond coin and get liquid staking token
    public fun bond<LiquidityToken>(
        bond_coin: Coin<LiquidityToken>
    ): Coin<LiquidStakingToken<LiquidityToken>> acquires DelegationStore {
        let delegation_store = borrow_global_mut<DelegationStore<LiquidityToken>>(@liquid_staking);
        let total_supply = coin::supply<LiquidStakingToken<LiquidityToken>>();
        let total_share = staking::get_share_from_delegation(&delegation_store.delegation);
        let validator = staking::get_validator_from_delegation(&delegation_store.delegation);
        let delegation = staking::delegate(validator, bond_coin);
        let share = staking::get_share_from_delegation(&delegation);

        let mint_amount = if (total_share == 0) {
           share
        } else {
            let mint_ratio = decimal128::from_ratio_u64(share, total_share);
            (decimal128::mul(&mint_ratio, total_supply) as u64)
        };

        let reward = staking::merge_delegation(&mut delegation_store.delegation, delegation);
        coin::merge(&mut delegation_store.rewards, reward);

        coin::mint(mint_amount, &delegation_store.caps.mint_cap)
    }

    public fun unbond<LiquidityToken>(
        lst: Coin<LiquidStakingToken<LiquidityToken>>
    ): Unbonding<LiquidityToken> acquires DelegationStore {
        let delegation_store = borrow_global_mut<DelegationStore<LiquidityToken>>(@liquid_staking);
        let total_supply = coin::supply<LiquidStakingToken<LiquidityToken>>();
        let share_ratio = decimal128::from_ratio((coin::value(&lst) as u128), total_supply);
        let unbond_share_amount = decimal128::mul(&share_ratio, total_supply);

        // burn LST
        coin::burn(lst, &delegation_store.caps.burn_cap);

        // unbond
        let delegation_for_unbonding = staking::extract_delegation(&mut delegation_store.delegation, (unbond_share_amount as u64));
        let (reward, unbonding) = staking::undelegate(delegation_for_unbonding);
        coin::merge(&mut delegation_store.rewards, reward);
        unbonding
    }

    fun check_is_owner(account: &signer) {
        let addr = signer::address_of(account);
        assert!(addr == @liquid_staking, error::permission_denied(ENOT_OWNER));
    }
}