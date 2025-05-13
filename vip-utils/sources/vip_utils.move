module vip_utils::vip_utils {
    use std::signer;
    use std::vector;

    use initia_std::bigdecimal::{Self, BigDecimal};

    use vip::weight_vote;

    public entry fun vote_with_amount(
        account: &signer,
        cycle: u64,
        bridge_ids: vector<u64>,
        amounts: vector<u64>
    ) {
        let total_voting_power =
            weight_vote::get_voting_power(signer::address_of(account));
        let weights = vector::map(
            amounts,
            |amount| { get_weight_ratio(total_voting_power, amount) }
        );

        weight_vote::vote(account, cycle, bridge_ids, weights)
    }

    fun get_weight_ratio(total: u64, amount: u64): BigDecimal {
        // to prevent rounding error, use slightly higher value
        // a / b < (a * 10 + 9) / (b * 10) <  (a + 1) / b
        return bigdecimal::from_ratio_u128((amount as u128) * 10 + 9, (total as u128)
            * 10)
    }

    #[test]
    fun test_get_weight_ratio() {
        let total = 129381946982171283;
        let amount = 12387214896283;

        let weight = get_weight_ratio(total, amount);

        assert!(amount == bigdecimal::mul_by_u64_truncate(weight, total));
    }
}
