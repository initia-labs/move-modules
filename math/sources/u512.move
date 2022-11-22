module math::u512 {
    use std::vector;
    use std::bcs;

    use math::u256::{Self, U256};

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
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff,
    ];

    struct U512 has copy, drop, store {
        // bytes is big edian
        bytes: vector<u8>
    }

    public fun new(bytes: &vector<u8>): U512 {
        assert!(vector::length(bytes) == 64, ELENGTH);
        
        return U512 { bytes: *bytes }
    }

    /// new with little edian
    public fun new_le(le_bytes: &vector<u8>): U512 {
        assert!(vector::length(le_bytes) == 64, ELENGTH);
        let reverse = *le_bytes;
        vector::reverse(&mut reverse);
        
        return U512 { bytes: reverse }
    }

    public fun zero(): U512 {
        new(&ZERO)
    }

    public fun max(): U512 {
        new(&MAX)
    }

    public fun mul(left: &U512, right: &U512): U512 {
        let u64_vector_res: vector<u64> = vector[0, 0, 0, 0, 0, 0, 0, 0];
        let u64_vector_left = to_u64_vector(left);
        let u64_vector_right = to_u64_vector(right);

        let left_index = 7;

        while(left_index > 0) {
            let right_index = 7;
            while (right_index > 0) {
                if (left_index + right_index > 6) {
                    let mul = (*vector::borrow(&u64_vector_left, left_index) as u128) 
                        * (*vector::borrow(&u64_vector_right, right_index) as u128);
                    let remain = (mul & 0xffffffffffffffff as u64);
                    let carry = (mul >> 64 as u64);

                    let add_target = vector[0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64];

                    
                    let remain_part = vector::borrow_mut(&mut add_target, left_index + right_index - 6);
                    *remain_part = remain;
                    let carry_part = vector::borrow_mut(&mut add_target, left_index + right_index - 7);
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
    public fun div(left: &U512, right: &U512, rounding_up: bool): U512 {
        let ns: vector<u64> = vector[];
        let sub_target = *left;

        let right_bit_length = get_bits_length(right);

        while (cmp(&sub_target, right) != 2) {
            
            let tartget_bit_length = get_bits_length(&sub_target);
            let bit_diff = tartget_bit_length - right_bit_length;
            let shifted = left_shift(right, bit_diff);
            let cmp = cmp(&sub_target, &shifted);

            if (cmp == 2 && bit_diff != 0) {
                shifted = right_shift(&shifted, 1);
                sub_target = sub(&sub_target, &shifted);
                vector::push_back(&mut ns, bit_diff - 1);
            } else if(cmp <= 1) {
                sub_target = sub(&sub_target, &shifted);
                vector::push_back(&mut ns, bit_diff);
            };
        };

        let s: vector<u8> = vector[0x1, 0x2, 0x4, 0x8, 0x10, 0x20, 0x40, 0x80];
        // ns to u512
        let res = ZERO;
        let ns_length = vector::length(&ns);
        let index = 0;
        while (index < ns_length) {
            let n = *vector::borrow(&ns, index);
            let res_index = 63 - n / 8;
            let res_target = vector::borrow_mut(&mut res, (res_index as u64));
            *res_target = *res_target + *vector::borrow(&s, (n % 8 as u64));
            index = index + 1;
        };

        let u512_res = new(&res);

        if (rounding_up) {
            let div_by_2 = right_shift(right, 1);
            let last_byte = vector::borrow(&right.bytes, 63);
            let even = *last_byte % 2 == 0;
            let cmp = cmp(&sub_target, &div_by_2);
            if (even && (cmp == 1 || cmp == 0)) {
                let one = from_u64(&1u64);
                u512_res = add(&u512_res, &one);
            } else if (cmp == 1) {
                let one = from_u64(&1u64);
                u512_res = add(&u512_res, &one);
            }
        };

        u512_res
    }

    // mul div for u256
    public fun mul_div(a: &U256, b: &U256, c: &U256, rounding_up: bool): U256 {
        let a: U512 = from_u256(a);
        let b: U512 = from_u256(b);
        let c: U512 = from_u256(c);

        let mul = mul(&a, &b);

        let muldiv = div(&mul, &c, rounding_up);

        to_u256(&muldiv)
    }

    public fun add(left: &U512, right: &U512): U512 {
        let u64_vector_left = to_u64_vector(left);
        let u64_vector_right = to_u64_vector(right);

        let u64_vector_res = add_u64_vector(&u64_vector_left, &u64_vector_right);

        return from_u64_vector(&u64_vector_res)
    }

    public fun sub(left: &U512, right: &U512): U512 {
        assert!(cmp(left, right) != 2, EOVERFLOW);

        let u64_vector_left = to_u64_vector(left);
        let u64_vector_right = to_u64_vector(right);

        let u64_vector_res = sub_u64_vector(&u64_vector_left, &u64_vector_right);
        return from_u64_vector(&u64_vector_res)
    }

    public fun from_u256(num: &U256): U512 {
        let u256_bytes = u256::bytes(num);
        let zeros = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ];
        vector::append(&mut zeros, u256_bytes);
        return new(&zeros)
    }

    public fun from_u128(num: &u128): U512 {
        let u128_bytes = bcs::to_bytes(num);
        let zeros = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ];
        vector::append(&mut u128_bytes, zeros);
        return new_le(&u128_bytes)
    }

    public fun from_u64(num: &u64): U512 {
        let u64_bytes = bcs::to_bytes(num);
        let zeros = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
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

    public fun is_same(num1: &U512, num2: &U512): bool {
        let index = 0;
        while (index < 64) {
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
    public fun cmp(num1: &U512, num2: &U512): u8 {
        let index = 0;
        while (index < 64) {
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

    public fun left_shift(target: &U512, shift: u64): U512 {
        let byte_shift_amount = shift / 8;
        let bit_shift_amount = shift % 8;

        let byte_shifted = bytes_left_shift(target, byte_shift_amount);
        let res = left_shift_(&byte_shifted, bit_shift_amount);

        return res
    }

    public fun right_shift(target: &U512, shift: u64): U512 {
        let byte_shift_amount = shift / 8;
        let bit_shift_amount = shift % 8;

        let byte_shifted = bytes_right_shift(target, byte_shift_amount);
        let res = right_shift_(&byte_shifted, bit_shift_amount);

        return res
    }

    fun bytes_left_shift(target: &U512, shift: u64): U512 {
        let res = new(&ZERO);
        if (shift >= 64) {
            return res
        };

        let target_index = shift;
        while (target_index < 64) {
            let res_index = target_index - shift;
            let byte = vector::borrow_mut(&mut res.bytes, res_index);
            *byte = *vector::borrow(&target.bytes, target_index);
            
            target_index = target_index + 1;
        };

        return res
    }

    fun bytes_right_shift(target: &U512, shift: u64): U512 {
        let res = new(&ZERO);
        if (shift >= 64) {
            return res
        };

        let res_index = shift;
        while (res_index < 64) {
            let target_index = res_index - shift;
            let byte = vector::borrow_mut(&mut res.bytes, res_index);
            *byte = *vector::borrow(&target.bytes, target_index);

            res_index = res_index + 1;
        };

        return res
    }

    fun get_bytes_length(num: &U512): u8 {
        assert!(!is_same(num, &new(&ZERO)), EZERO);
        let index = 0;
        loop {
            let bytes = vector::borrow(&num.bytes, index);
            if (*bytes != 0u8) {
                return (64 - index  as u8)
            };
            index = index + 1;
        }
    }

    fun get_bits_length(num: &U512): u64 {
        let byte_length = (get_bytes_length(num) as u64);
        let byte = vector::borrow(&num.bytes, (64 - byte_length as u64));
        let bit_count_of_byte = 8;
        let c = 0x80u8;
        while (bit_count_of_byte > 0) {
            if (c & *byte != 0) break;
            c = c / 2;
            bit_count_of_byte = bit_count_of_byte - 1;
        };

        return bit_count_of_byte + (byte_length - 1) * 8
    }

    /// left shift for shift < 8
    fun left_shift_(target: &U512, shift: u64): U512 {
        assert!(shift < 8, ESHIFT_AMOUNT);
        if (shift == 0) {
            return *target
        };

        let res = new(&ZERO);

        let index = 0;
        
        while (index < 63) {
            let byte = vector::borrow_mut(&mut res.bytes, index);
            let shifted = *vector::borrow(&target.bytes, index) << (shift as u8);
            let carry = *vector::borrow(&target.bytes, index + 1) >> (8 - shift as u8);
            *byte = shifted + carry;

            index = index + 1;
        };

        // last
        let byte = vector::borrow_mut(&mut res.bytes, 63);
        let shifted = *vector::borrow(&target.bytes, 63) << (shift as u8);
        *byte = shifted;

        return res
    }

        /// right shift for shift < 8
    fun right_shift_(target: &U512, shift: u64): U512 {
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
        
        while (index < 64) {
            let byte = vector::borrow_mut(&mut res.bytes, index);
            let shifted = *vector::borrow(&target.bytes, index) >> (shift as u8);
            let carry = *vector::borrow(&target.bytes, index - 1) << (8 - shift as u8);
            *byte = shifted + carry;

            index = index + 1;
        };

        return res
    }

    fun to_u64_vector(num: &U512): vector<u64> {
        let v: vector<u64> = vector[];
        let index = 0;
        while(index < 8) {
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

    fun to_u256(num: &U512): U256 {
        let u256_max_bytes: vector<u8> = vector[
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
        ];
        let u256_max: U512 = new(&u256_max_bytes);

        let cmp = cmp(num, &u256_max);

        assert!(cmp != 1, EOVERFLOW);

        let new_bytes: vector<u8> = vector[];
        let index = 32;
        while(index < 64) {
            let byte = *vector::borrow(&num.bytes, index);
            vector::push_back(&mut new_bytes, byte);
            index = index + 1;
        };

        u256::new(&new_bytes)
    }

    fun from_u64_vector(v: &vector<u64>): U512 {
        assert!(vector::length(v) == 8, ELENGTH);

        let bytes: vector<u8> = vector[];
        let index = 0;
        while(index < 8) {
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
        assert!(vector::length(left) == 8, ELENGTH);
        assert!(vector::length(right) == 8, ELENGTH);
        let res = vector[0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64];
        let index = 7;
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
        assert!(vector::length(left) == 8, ELENGTH);
        assert!(vector::length(right) == 8, ELENGTH);
        let res: vector<u64> = vector[0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64, 0u64];
        let index = 7;
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
        let u512_num1 = from_u64(&num1);

        let num2: u64 = 9382749823479;
        let u512_num2 = from_u64(&num2);

        assert!(is_same(&u512_num1, &u512_num1), 0);
        assert!(!is_same(&u512_num1, &u512_num2), 0);
    }

        #[test]
    fun cmp_test() {
        let num1: u64 = 1232142298347023;
        let u512_num1 = from_u64(&num1);

        let num2: u64 = 9382749823479;
        let u512_num2 = from_u64(&num2);

        assert!(cmp(&u512_num1, &u512_num1) == 0, 0);
        assert!(cmp(&u512_num1, &u512_num2) == 1, 0);
        assert!(cmp(&u512_num2, &u512_num1) == 2, 0);
    }

    #[test]
    fun from_u128_test() {
        let num: u128 = 935298347023;
        let comparison_bytes = bcs::to_bytes(&num);
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::reverse(&mut comparison_bytes);
        let comparison = new(&comparison_bytes);

        let u512_num = from_u128(&num);

        assert!(is_same(&comparison, &u512_num), 0);
    }

    #[test]
    fun from_u64_test() {
        let num: u64 = 935298347023;
        let comparison_bytes = bcs::to_bytes(&num);
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u128));
        vector::append(&mut comparison_bytes, bcs::to_bytes(&0u64));
        vector::reverse(&mut comparison_bytes);
        let comparison = new(&comparison_bytes);

        let u512_num = from_u64(&num);

        assert!(is_same(&comparison, &u512_num), 0);
    }

    #[test]
    fun add_test() {
        let num1: u64 = 9182493;
        let num2: u64 = 192389738;

        let u512_num1 = from_u64(&num1);
        let u512_num2 = from_u64(&num2);
        let u512_sum = from_u64(&(num1 + num2));

        assert!(is_same(&add(&u512_num1, &u512_num2), &u512_sum), 0);
    }

    #[test]
    fun sub_test() {
        let num1: u128 = 0x29fd491a293fa8791abf;
        let num2: u128 = 0x92fa89d8f7;

        let u512_num1 = from_u128(&num1);
        let u512_num2 = from_u128(&num2);
        let u512_sub = from_u128(&(0x29fd491a293fa8791abf - 0x92fa89d8f7));

        assert!(is_same(&sub(&u512_num1, &u512_num2), &u512_sub), 0);
    }

    #[test]
    fun mul_test() {
        let num1: u64 = 9182493;
        let num2: u64 = 192389738;

        let u512_num1 = from_u64(&num1);
        let u512_num2 = from_u64(&num2);
        let u512_mul = from_u64(&(num1 * num2));

        assert!(is_same(&mul(&u512_num1, &u512_num2), &u512_mul), 0);
    }

    #[test]
    fun div_test() {
        let num1: u128 = 0x29fd491a293fa8791abf;
        let num2: u128 = 0x92fa89d8f7;

        let u512_num1 = from_u128(&num1);
        let u512_num2 = from_u128(&num2);
        let u512_div = from_u128(&(num1 / num2));

        assert!(is_same(&div(&u512_num1, &u512_num2, false), &u512_div), 0);


        // round up (when num2 is even)
        let num1: u128 = 3;
        let num2: u128 = 2;

        let u512_num1 = from_u128(&num1);
        let u512_num2 = from_u128(&num2);
        let u512_div = from_u128(&(num1 / num2 + 1));
        assert!(is_same(&div(&u512_num1, &u512_num2, true), &u512_div), 0);

        // round up (when num2 is odd)
        let num1: u128 = 8;
        let num2: u128 = 3;

        let u512_num1 = from_u128(&num1);
        let u512_num2 = from_u128(&num2);
        let u512_div = from_u128(&(num1 / num2 + 1));
        assert!(is_same(&div(&u512_num1, &u512_num2, true), &u512_div), 0);
    }

    #[test]
    fun mul_div_test() {
        let num1: u128 = 0x29fd491a293fa8791abf;
        let num2: u128 = 0x92fa89d8f7;
        let num3: u128 = 0xa6d786;

        let u256_num1 = u256::from_u128(&num1);
        let u256_num2 = u256::from_u128(&num2);
        let u256_num3 = u256::from_u128(&num3);
        let u256_mul_div = u256::from_u128(&(num1 * num2 / num3));
        
        assert!(u256::is_same(&mul_div(&u256_num1, &u256_num2, &u256_num3, false), &u256_mul_div), 0);

        // round up
        let u256_mul_div = u256::from_u128(&(num1 * num2 / num3 + 1));
        assert!(u256::is_same(&mul_div(&u256_num1, &u256_num2, &u256_num3, true), &u256_mul_div), 0);
    }

    #[test]
    fun left_shfit_test() {
        let num: u64 = 9182493;

        let u512_num = from_u64(&num);
        let u512_shifted = from_u64(&(num << 11));

        assert!(is_same(&left_shift(&u512_num, 11), &u512_shifted), 0);
    }

    #[test]
    fun right_shift_test() {
        let num: u128 = 210938098092810398;

        let u512_num = from_u128(&num);
        let u512_shifted = from_u128(&(num >> 11));

        assert!(is_same(&right_shift(&u512_num, 11), &u512_shifted), 0);
    }
}
