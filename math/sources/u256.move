module math::u256 {
    use std::vector;
    use std::bcs;

    const ELENGTH: u64 = 0;
    const ESHIFT_AMOUNT: u64 = 1;
    const EDIV_ZERO: u64 = 2;
    const EZERO: u64 = 3;
    const EOVERFLOW: u64 = 4;
    
    const ZERO: vector<u8> = vector[
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ];

    const MAX: vector<u8> = vector[
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
    ];

    struct U256 has copy, drop, store {
        // bytes is big edian
        bytes: vector<u8>
    }

    public fun bytes(u256: &U256): vector<u8> {
        u256.bytes
    }

    public fun new(bytes: &vector<u8>): U256 {
        assert!(vector::length(bytes) == 32, ELENGTH);
        
        return U256 { bytes: *bytes }
    }

    /// new with little edian
    public fun new_le(le_bytes: &vector<u8>): U256 {
        assert!(vector::length(le_bytes) == 32, ELENGTH);
        let reverse = *le_bytes;
        vector::reverse(&mut reverse);
        
        return U256 { bytes: reverse }
    }

    public fun zero(): U256 {
        new(&ZERO)
    }

    public fun max(): U256 {
        new(&MAX)
    }

    public fun mul(left: &U256, right: &U256): U256 {
        let u64_vector_res: vector<u64> = vector[0, 0, 0, 0];
        let u64_vector_left = to_u64_vector(left);
        let u64_vector_right = to_u64_vector(right);

        let left_index = 3;

        while(left_index > 0) {
            let right_index = 3;
            while (right_index > 0) {
                if (left_index + right_index > 2) {
                    let mul = (*vector::borrow(&u64_vector_left, left_index) as u128) 
                        * (*vector::borrow(&u64_vector_right, right_index) as u128);
                    let remain = (mul & 0xffffffffffffffff as u64);
                    let carry = (mul >> 64 as u64);

                    let add_target = vector[0u64, 0u64, 0u64, 0u64, 0u64];

                    
                    let remain_part = vector::borrow_mut(&mut add_target, left_index + right_index - 2);
                    *remain_part = remain;
                    let carry_part = vector::borrow_mut(&mut add_target, left_index + right_index - 3);
                    *carry_part = carry;

                    assert!(!(vector::borrow(&add_target, 0) != &0u64), EOVERFLOW);

                    vector::remove(&mut add_target, 0);
                    u64_vector_res = add_u64_vector(&u64_vector_res, &add_target);
                } else {
                    assert!(
                        vector::borrow(&u64_vector_left, left_index) == &0u64 
                        || vector::borrow(&u64_vector_right, right_index) == &0u64,
                        EOVERFLOW
                    );
                };
                right_index = right_index - 1;
            };
            left_index = left_index - 1;
        };

        return from_u64_vector(&u64_vector_res)
    }

    /// return left / right
    /// left = sum(2^n * right * k) + l 
    /// where k is 0 or 1 and l < right
    public fun div(left: &U256, right: &U256, rounding_up: bool): U256 {
        let ns: vector<u64> = vector[];
        let sub_target = *left;

        let right_bit_length = get_bits_length(right);

        while (cmp(&sub_target, right) != 2) {
            
            let target_bit_length = get_bits_length(&sub_target);
            let bit_diff = target_bit_length - right_bit_length;
            let shifted = left_shift(right, bit_diff);
            let cmp = cmp(&sub_target, &shifted);

            if (cmp == 2 && bit_diff != 0) {
                shifted = right_shift(&shifted, 1);
                sub_target = sub(&sub_target, &shifted);
                let t = to_u64_vector(&sub_target);
                vector::reverse(&mut t);
                vector::push_back(&mut ns, bit_diff - 1);
            } else if(cmp <= 1) {
                sub_target = sub(&sub_target, &shifted);
                let t = to_u64_vector(&sub_target);
                vector::reverse(&mut t);
                vector::push_back(&mut ns, bit_diff);
            };
        };

        let s: vector<u8> = vector[0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80];
        // ns to u256
        let res = ZERO;
        let ns_length = vector::length(&ns);
        let index = 0;
        while (index < ns_length) {
            let n = *vector::borrow(&ns, index);
            let res_index = 31 - n / 8;
            let res_target = vector::borrow_mut(&mut res, (res_index as u64));
            *res_target = *res_target + *vector::borrow(&s, (n % 8 as u64));
            index = index + 1;
        };

        let u256_res = new(&res);

        if (rounding_up) {
            let div_by_2 = right_shift(right, 1);
            let last_byte = vector::borrow(&right.bytes, 31);
            let even = *last_byte % 2 == 0;
            let cmp = cmp(&sub_target, &div_by_2);
            if (even && (cmp == 1 || cmp == 0)) {
                let one = from_u64(&1u64);
                u256_res = add(&u256_res, &one);
            } else if (cmp == 1) {
                let one = from_u64(&1u64);
                u256_res = add(&u256_res, &one);
            }
        };

        u256_res
    }

    public fun add(left: &U256, right: &U256): U256 {
        let u64_vector_left = to_u64_vector(left);
        let u64_vector_right = to_u64_vector(right);

        let u64_vector_res = add_u64_vector(&u64_vector_left, &u64_vector_right);

        return from_u64_vector(&u64_vector_res)
    }

    public fun sub(left: &U256, right: &U256): U256 {
        assert!(cmp(left, right) != 2, EOVERFLOW);

        let u64_vector_left = to_u64_vector(left);
        let u64_vector_right = to_u64_vector(right);

        let u64_vector_res = sub_u64_vector(&u64_vector_left, &u64_vector_right);
        return from_u64_vector(&u64_vector_res)
    }

    public fun from_u128(num: &u128): U256 {
        let u128_bytes = bcs::to_bytes(num);
        let zeros = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ];
        vector::append(&mut u128_bytes, zeros);
        return new_le(&u128_bytes)
    }

    public fun from_u64(num: &u64): U256 {
        let u64_bytes = bcs::to_bytes(num);
        let zeros = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ];
        vector::append(&mut u64_bytes, zeros);
        return new_le(&u64_bytes)
    }

    public fun is_same(num1: &U256, num2: &U256): bool {
        let index = 0;
        while (index < 32) {
            let num1_byte = vector::borrow(&num1.bytes, index);
            let num2_byte = vector::borrow(&num2.bytes, index);
            if (num1_byte != num2_byte) {
                return false
            };

            index = index + 1;
        };

        return true
    }

    /// if num1 == num2, return 0
    /// if num1 > num2, return 1
    /// if num1 < num2, return 2
    public fun cmp(num1: &U256, num2: &U256): u8 {
        let index = 0;
        while (index < 32) {
            let num1_byte = vector::borrow(&num1.bytes, index);
            let num2_byte = vector::borrow(&num2.bytes, index);
            if (num1_byte != num2_byte) {
                if (*num1_byte > *num2_byte) {
                    return 1
                } else {
                    return 2
                }
            };

            index = index + 1;
        };


        return 0
    }

    public fun left_shift(target: &U256, shift: u64): U256 {
        let byte_shift_amount = shift / 8;
        let bit_shift_amount = shift % 8;

        let byte_shifted = bytes_left_shift(target, byte_shift_amount);
        let res = left_shift_(&byte_shifted, bit_shift_amount);

        return res
    }

    public fun right_shift(target: &U256, shift: u64): U256 {
        let byte_shift_amount = shift / 8;
        let bit_shift_amount = shift % 8;

        let byte_shifted = bytes_right_shift(target, byte_shift_amount);
        let res = right_shift_(&byte_shifted, bit_shift_amount);

        return res
    }

    fun bytes_left_shift(target: &U256, shift: u64): U256 {
        let res = new(&ZERO);
        if (shift >= 32) {
            return res
        };

        let target_index = shift;
        while (target_index < 32) {
            let res_index = target_index - shift;
            let byte = vector::borrow_mut(&mut res.bytes, res_index);
            *byte = *vector::borrow(&target.bytes, target_index);
            
            target_index = target_index + 1;
        };

        return res
    }

    fun bytes_right_shift(target: &U256, shift: u64): U256 {
        let res = new(&ZERO);
        if (shift >= 32) {
            return res
        };

        let res_index = shift;
        while (res_index < 32) {
            let target_index = res_index - shift;
            let byte = vector::borrow_mut(&mut res.bytes, res_index);
            *byte = *vector::borrow(&target.bytes, target_index);

            res_index = res_index + 1;
        };

        return res
    }

    fun get_bytes_length(num: &U256): u8 {
        assert!(!is_same(num, &new(&ZERO)), EZERO);
        let index = 0;
        loop {
            let bytes = vector::borrow(&num.bytes, index);
            if (*bytes != 0u8) {
                return (32 - index  as u8)
            };
            index = index + 1;
        }
    }

    fun get_bits_length(num: &U256): u64 {
        let byte_length = (get_bytes_length(num) as u64);
        let byte = vector::borrow(&num.bytes, (32 - byte_length as u64));
        let bit_count_of_byte = 8u64;
        let c = 0x80u8;
        while (bit_count_of_byte > 0) {
            if (c & *byte != 0) break;
            c = c / 2;
            bit_count_of_byte = bit_count_of_byte - 1;
        };


        return bit_count_of_byte + (byte_length - 1) * 8
    }

    /// left shift for shift < 8
    fun left_shift_(target: &U256, shift: u64): U256 {
        assert!(shift < 8, ESHIFT_AMOUNT);
        if (shift == 0) {
            return *target
        };

        let res = new(&ZERO);

        let index = 0;
        
        while (index < 31) {
            let byte = vector::borrow_mut(&mut res.bytes, index);
            let shifted = *vector::borrow(&target.bytes, index) << (shift as u8);
            let carry = *vector::borrow(&target.bytes, index + 1) >> (8 - shift as u8);
            *byte = shifted + carry;

            index = index + 1;
        };

        // last
        let byte = vector::borrow_mut(&mut res.bytes, 31);
        let shifted = *vector::borrow(&target.bytes, 31) << (shift as u8);
        *byte = shifted;

        return res
    }

        /// right shift for shift < 8
    fun right_shift_(target: &U256, shift: u64): U256 {
        assert!(shift < 8, ESHIFT_AMOUNT);
        if (shift == 0) {
            return *target
        };

        let res = new(&ZERO);

        // first 
        let byte = vector::borrow_mut(&mut res.bytes, 0);
        let shifted = *vector::borrow(&target.bytes, 0) >> (shift as u8);
        *byte = shifted;

        let index = 1;
        
        while (index < 32) {
            let byte = vector::borrow_mut(&mut res.bytes, index);
            let shifted = *vector::borrow(&target.bytes, index) >> (shift as u8);
            let carry = *vector::borrow(&target.bytes, index - 1) << (8 - shift as u8);
            *byte = shifted + carry;

            index = index + 1;
        };

        return res
    }

    public fun to_u64_vector(num: &U256): vector<u64> {
        let v: vector<u64> = vector[];
        let index = 0;
        while(index < 4) {
            let inner_index = 0;
            let u64_num = 0;
            let multiplier = 0x100000000000000;
            while(inner_index < 8) {
                let byte = *vector::borrow(&num.bytes, index * 8 + inner_index);
                u64_num = u64_num + (byte as u64) * multiplier;
                multiplier = multiplier >> 8;
                inner_index = inner_index + 1;
            };
    
            vector::push_back(&mut v, u64_num);
            index = index + 1;
        };

        v
    }

    public fun to_u128(num: &U256): u128 {
        let u128_max_bytes: vector<u8> = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
        ];
        let u128_max: U256 = new(&u128_max_bytes);

        let cmp = cmp(num, &u128_max);

        assert!(cmp != 1, EOVERFLOW);

        let new_num = 0u128;

        let index = 16;
        while(index < 32) {
            let byte = (*vector::borrow(&num.bytes, index) as u128);
            new_num = new_num + (byte << ((31 - index as u8) * 8));
            index = index + 1
        };

        new_num
    }

    fun from_u64_vector(v: &vector<u64>): U256 {
        assert!(vector::length(v) == 4, ELENGTH);

        let bytes: vector<u8> = vector[];
        let index = 0;
        while(index < 4) {
            let num = *vector::borrow(v, index);
    
            vector::append(
                &mut bytes,
                vector[
                    (num >> 56 & 0xff as u8),
                    (num >> 48 & 0xff as u8),
                    (num >> 40 & 0xff as u8),
                    (num >> 32 & 0xff as u8),
                    (num >> 24 & 0xff as u8),
                    (num >> 16 & 0xff as u8),
                    (num >> 8 & 0xff as u8),
                    (num & 0xff as u8),
                ]
            );

            index = index + 1;
        };

        new(&bytes)
    }

    fun add_u64_vector(left: &vector<u64>, right: &vector<u64>): vector<u64> {
        assert!(vector::length(left) == 4, ELENGTH);
        assert!(vector::length(right) == 4, ELENGTH);
        let res = vector[0u64, 0u64, 0u64, 0u64];
        let index = 3;
        let carry = 0u64;

        while(index >= 0) {
            let add =  (*vector::borrow(left, index) as u128)
                + (*vector::borrow(right, index) as u128)
                + (carry as u128);
            let remain_part = vector::borrow_mut(&mut res, index);
            *remain_part = (add & 0xffffffffffffffff as u64);
            carry = (add >> 64 as u64);

            if (index == 0) break;
            index = index - 1;
        };

        assert!(carry == 0u64, EOVERFLOW);

        res
    }

    fun sub_u64_vector(left: &vector<u64>, right: &vector<u64>): vector<u64> {
        assert!(vector::length(left) == 4, ELENGTH);
        assert!(vector::length(right) == 4, ELENGTH);
        let res: vector<u64> = vector[0u64, 0u64, 0u64, 0u64];
        let index = 3;
        let carry = 0u64;

        while(index >= 0) {
            let remain_part = vector::borrow_mut(&mut res, index);
            if (
                (*vector::borrow(left, index) as u128)
                < (*vector::borrow(right, index) as u128) + (carry as u128)
            ) {
                let sub_target = (*vector::borrow(left, index) as u128) + 0x10000000000000000u128;
                *remain_part = (sub_target - (*vector::borrow(right, index) as u128) - (carry as u128) as u64);
                carry = 1;
            } else {
                *remain_part = ((*vector::borrow(left, index) as u128) - (*vector::borrow(right, index) as u128) - (carry as u128) as u64);
                carry = 0;
            };

            if (index == 0) break;
            index = index - 1;
        };

        res
    }

    #[test]
    fun is_same_test() {
        let num1: u64 = 935298347023;
        let u256_num1 = from_u64(&num1);

        let num2: u64 = 9382749823479;
        let u256_num2 = from_u64(&num2);

        assert!(is_same(&u256_num1, &u256_num1), 0);
        assert!(!is_same(&u256_num1, &u256_num2), 0);
    }

        #[test]
    fun cmp_test() {
        let num1: u64 = 1232142298347023;
        let u256_num1 = from_u64(&num1);

        let num2: u64 = 9382749823479;
        let u256_num2 = from_u64(&num2);

        assert!(cmp(&u256_num1, &u256_num1) == 0, 0);
        assert!(cmp(&u256_num1, &u256_num2) == 1, 0);
        assert!(cmp(&u256_num2, &u256_num1) == 2, 0);
    }

    #[test]
    fun from_u128_test() {
        let num: u128 = 935298347023;
        let comparison_bytes = bcs::to_bytes(&num);
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::reverse(&mut comparison_bytes);
        let comparison = new(&comparison_bytes);

        let u256_num = from_u128(&num);

        assert!(is_same(&comparison, &u256_num), 0);
    }

    #[test]
    fun from_u64_test() {
        let num: u64 = 935298347023;
        let comparison_bytes = bcs::to_bytes(&num);
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u64));
        vector::reverse(&mut comparison_bytes);
        let comparison = new(&comparison_bytes);

        let u256_num = from_u64(&num);

        assert!(is_same(&comparison, &u256_num), 0);
    }

    #[test]
    fun add_test() {
        let num1: u64 = 9182493;
        let num2: u64 = 192389738;

        let u256_num1 = from_u64(&num1);
        let u256_num2 = from_u64(&num2);
        let u256_sum = from_u64(&(num1 + num2));

        assert!(is_same(&add(&u256_num1, &u256_num2), &u256_sum), 0);
    }

    #[test]
    fun sub_test() {
        let num1: u128 = 0x29fd491a293fa8791abf;
        let num2: u128 = 0x92fa89d8f7;

        let u256_num1 = from_u128(&num1);
        let u256_num2 = from_u128(&num2);
        let u256_sub = from_u128(&(0x29fd491a293fa8791abf - 0x92fa89d8f7));

        assert!(is_same(&sub(&u256_num1, &u256_num2), &u256_sub), 0);
    }

    #[test]
    fun mul_test() {
        let num1: u64 = 9182493;
        let num2: u64 = 192389738;

        let u256_num1 = from_u64(&num1);
        let u256_num2 = from_u64(&num2);
        let u256_mul = from_u64(&(num1 * num2));

        assert!(is_same(&mul(&u256_num1, &u256_num2), &u256_mul), 0);
    }

    #[test]
    fun div_test() {
        let num1: u128 = 0x29fd491a293fa8791abf;
        let num2: u128 = 0x92fa89d8f7;

        let u256_num1 = from_u128(&num1);
        let u256_num2 = from_u128(&num2);
        let u256_mul = from_u128(&(num1 / num2));

        assert!(is_same(&div(&u256_num1, &u256_num2, false), &u256_mul), 0);

        // rounding up
        let u256_mul = from_u128(&(num1 / num2 + 1));
        assert!(is_same(&div(&u256_num1, &u256_num2, true), &u256_mul), 0);
    }

    #[test]
    fun left_shfit_test() {
        let num: u64 = 9182493;

        let u256_num = from_u64(&num);
        let u256_shifted = from_u64(&(num << 11));

        assert!(is_same(&left_shift(&u256_num, 11), &u256_shifted), 0);
    }

    #[test]
    fun left_right_test() {
        let num: u128 = 210938098092810398;

        let u256_num = from_u128(&num);
        let u256_shifted = from_u128(&(num >> 11));

        assert!(is_same(&right_shift(&u256_num, 11), &u256_shifted), 0);
    }


    #[test]
    fun to_u128_test() {
        let num: u128 = 210938098092810398;

        let u256_num = from_u128(&num);

        assert!(to_u128(&u256_num) == num, 0);
    }

    #[test]
    fun div_test2() {
        let u256_num1 = new(&vector[240, 174, 214, 40, 188, 237, 96, 98, 65, 92, 29, 131, 216, 246, 218, 95, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let u256_num2 = new(&vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 208, 151, 243, 189, 253, 32, 34, 184, 132, 90, 216, 247, 146, 170, 88, 37]);
        let calculator_result = new(&vector[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 39, 97, 219, 82, 202, 148, 106, 79, 247, 89, 188, 44, 206, 248, 190, 203]);

        assert!(is_same(&div(&u256_num1, &u256_num2, false), &calculator_result), 0);
    }
}
