module math::pow {
    use std::vector;
    use std::error;

    use initia_std::decimal::{Self, Decimal};

    const EOUT_OF_BASE_RANGE: u64 = 0;

    const PRECISION: u128 = 1000000;

    fun integer_pow(base: u128, exp: u128): u128 {
        let res = 1;

        loop {
            if (exp & 1 == 1) {
                res = res * base;
            };
            exp = exp >> 1;
            if (exp == 0) {
                break
            };

            base = base * base;
        };

        res
    }

    /// a^x = 1 + sigma[(k^n)/n!]
    /// k = x * ln(a)
    fun decimal_pow(base: &Decimal, exp: &Decimal): Decimal {
        assert!(
            decimal::val(base) != 0 && decimal::val(base) < 2000000000000000000,
            error::invalid_argument(EOUT_OF_BASE_RANGE),
        );

        let res = decimal::one();
        let (ln_a, neg) = ln(base);
        let k = mul_decimals(&ln_a, exp);
        let comp = k;
        let index = 1;
        let subs: vector<Decimal> = vector[];
        while(decimal::val(&comp) > PRECISION) {
            if (index & 1 == 1 && neg) {
                vector::push_back(&mut subs, comp)
            } else {
                res = decimal::add(&res, &comp)
            };

            comp = decimal::div(&mul_decimals(&comp, &k), index + 1);
            index = index + 1;
        };

        let index = 0;
        while(index < vector::length(&subs)) {
            let comp = vector::borrow(&subs, index);
            res = decimal::sub(&res, comp);
            index = index + 1;
        };

        res
    }

    /// ln(1 + a) = sigma[(-1) ^ (n + 1) * (a ^ n / n)]
    fun ln(num: &Decimal): (Decimal, bool) {
        let one = decimal::val(&decimal::one());
        let num_val = decimal::val(num);
        let (a, a_neg) = if (num_val >= one) {
            (decimal::sub(num, &decimal::one()), false)
        } else {
            (decimal::sub(&decimal::one(), num), true)
        };

        let res = decimal::zero();
        let comp = a;
        let index = 1;

        if (index & 1 == 0 && !a_neg) {
            res = decimal::sub(&res, &comp);
        } else {
            res = decimal::add(&res, &comp);
        };

        while(decimal::val(&comp) > PRECISION) {
            // comp(old) = a ^ n / n
            // comp(new) = omp(old) * a * n / (n + 1) = a ^ (n + 1) / (n + 1)
            comp = decimal::div(
                &decimal::new(decimal::val(&mul_decimals(&comp, &a)) * index), // comp * a * index
                index + 1,
            );

            if (index & 1 == 0 && !a_neg) {
                res = decimal::sub(&res, &comp);
            } else {
                res = decimal::add(&res, &comp);
            };

            index = index + 1;
        };

        (res, a_neg)
    }

    fun mul_decimals(decimal_0: &Decimal, decimal_1: &Decimal): Decimal {
        let one = decimal::val(&decimal::one());
        let val_mul = decimal::val(decimal_0) * decimal::val(decimal_1);
        decimal::new(val_mul / one)
    }

    #[test]
    fun test_integer_pow() {
        let res = integer_pow(13, 17);

        assert!(res == 8650415919381337933, 0)
    }

    #[test]
    fun test_decimal_pow() {
        // .75
        let base = decimal::from_ratio(75, 100);
        // 2.25
        let exp = decimal::from_ratio(225, 100);

        // about 0.523465233244931060
        let res = decimal_pow(&base, &exp);

        std::debug::print(&decimal::val(&res));

        assert!(523465233244931060 - PRECISION <= decimal::val(&res) && decimal::val(&res) <= 523465233244931060 + PRECISION, 0)
    }
}
