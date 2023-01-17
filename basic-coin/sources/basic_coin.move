module your_address::basic_coin {
    use std::coin;
    use std::string;
    use std::signer;

    struct Coin {}

    struct Capabilities has key {
        burn_cap: coin::BurnCapability<Coin>,
        freeze_cap: coin::FreezeCapability<Coin>,
        mint_cap: coin::MintCapability<Coin>,
    }

    public entry fun initialize(account: &signer) {
        let (burn_cap, freeze_cap, mint_cap)
            = coin::initialize<Coin>(account, string::utf8(b"basic coin"), string::utf8(b"BASIC"), 6);

        let caps = Capabilities { burn_cap, freeze_cap, mint_cap };
        move_to(account, caps);    
    }

    public entry fun mint_to(account: &signer, amount: u64, to: address) acquires Capabilities {
        let addr = signer::address_of(account);
        let caps = borrow_global<Capabilities>(addr);
        let coin = coin::mint<Coin>(amount, &caps.mint_cap);
        coin::deposit<Coin>(to, coin);
    }
}