module dex::decimal {
    use std::string::{Self, String};
    use std::vector;
    const EDIV_WITH_ZERO: u64 = 0;

    const DECIMAL_FRACTIONAL: u128 = 1000000000000000000; // 1_000_000_000_000_000_000
    
    /// A fixed-point decimal value with 18 fractional digits, i.e. Decimal{ numerator: 1_000_000_000_000_000_000 } == 1.0
    struct Decimal has copy, drop, store {
        val: u128
    }

    public fun new(val: u128): Decimal {
        Decimal { val }
    }

    public fun one(): Decimal {
        Decimal { val: DECIMAL_FRACTIONAL }
    }

    public fun zero(): Decimal {
        Decimal { val: 0u128 }
    }

    public fun from_ratio(numerator: u128, denominator: u128): Decimal {
        assert!(denominator != 0, EDIV_WITH_ZERO);

        new(numerator * DECIMAL_FRACTIONAL / denominator)
    }

    public fun add(left: &Decimal, right: &Decimal): Decimal {
        new(left.val + right.val)
    }
    
    public fun sub(left: &Decimal, right: &Decimal): Decimal {
        new(left.val - right.val)
    }

    public fun mul(decimal: &Decimal, int: u128): u128 {
        decimal.val * int / DECIMAL_FRACTIONAL
    }

    public fun div(decimal: &Decimal, int: u128): Decimal {
        new(decimal.val / int)
    }

    public fun val(decimal: &Decimal): u128 {
        decimal.val
    }

    public fun is_same(left: &Decimal, right: &Decimal): bool {
        left.val == right.val
    }

    public fun from_string(num: &String): Decimal {
        let vec = string::bytes(num);
        let dot_index = 0;
        while(dot_index < vector::length(vec)) {
            if (vector::borrow(vec, dot_index) == &46) break;
            dot_index = dot_index + 1;
        };

        let index = 0;
        let val: u128 = 0;
        while(index < vector::length(vec)) {
            if (index != dot_index) {
                val = val * 10;
                let n = (*vector::borrow(vec, index) - 48 as u128);
                val = val + n;
            };

            index = index + 1;
        };

        val = val * pow(10, 18 - (vector::length(vec) - dot_index -  1));
        new(val)
    }

    fun pow(num: u128, pow_amount: u64): u128 {
        let index = 0;
        let val = 1;
        while(index < pow_amount) {
            val = val * num;
            index = index + 1;
        };

        val
    }

    #[test]
    fun test() {
        assert!(from_string(&string::utf8(b"1234.5678")) == new(1234567800000000000000), 0)
    }
}