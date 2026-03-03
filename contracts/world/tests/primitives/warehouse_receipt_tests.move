#[test_only]
module world::warehouse_receipt_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    warehouse_receipt,
    test_helpers::{Self, governor}
};

const STORAGE_UNIT_ID_BYTES: vector<u8> =
    x"b78f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e8";
const STORAGE_UNIT_ID_BYTES_2: vector<u8> =
    x"a11f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e8";
const TYPE_ID: u64 = 88069;
const TYPE_ID_2: u64 = 88070;
const QUANTITY: u32 = 100;
const RECIPIENT: address = @0xCAFE;

fun storage_unit_id(): ID {
    object::id_from_bytes(STORAGE_UNIT_ID_BYTES)
}

fun storage_unit_id_2(): ID {
    object::id_from_bytes(STORAGE_UNIT_ID_BYTES_2)
}

// === Success Tests ===

#[test]
fun mint_and_burn() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        assert_eq!(receipt.storage_unit_id(), storage_unit_id());
        assert_eq!(receipt.type_id(), TYPE_ID);
        assert_eq!(receipt.quantity(), QUANTITY);

        let (su_id, type_id, quantity) = warehouse_receipt::burn_for_testing(receipt);
        assert_eq!(su_id, storage_unit_id());
        assert_eq!(type_id, TYPE_ID);
        assert_eq!(quantity, QUANTITY);
    };
    ts::end(ts);
}

#[test]
fun split_receipt() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );

        let split = receipt.split(30, ts.ctx());
        assert_eq!(receipt.quantity(), 70);
        assert_eq!(split.quantity(), 30);
        assert_eq!(split.storage_unit_id(), storage_unit_id());
        assert_eq!(split.type_id(), TYPE_ID);

        warehouse_receipt::burn_for_testing(receipt);
        warehouse_receipt::burn_for_testing(split);
    };
    ts::end(ts);
}

#[test]
fun join_receipts() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt_a = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            60,
            ts.ctx(),
        );
        let receipt_b = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            40,
            ts.ctx(),
        );

        receipt_a.join(receipt_b);
        assert_eq!(receipt_a.quantity(), 100);
        assert_eq!(receipt_a.storage_unit_id(), storage_unit_id());
        assert_eq!(receipt_a.type_id(), TYPE_ID);

        warehouse_receipt::burn_for_testing(receipt_a);
    };
    ts::end(ts);
}

#[test]
fun split_then_join() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );

        let split = receipt.split(25, ts.ctx());
        assert_eq!(receipt.quantity(), 75);

        receipt.join(split);
        assert_eq!(receipt.quantity(), QUANTITY);

        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
fun zero_receipt() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let receipt = warehouse_receipt::zero(storage_unit_id(), TYPE_ID, ts.ctx());
        assert_eq!(receipt.quantity(), 0);
        assert_eq!(receipt.storage_unit_id(), storage_unit_id());
        assert_eq!(receipt.type_id(), TYPE_ID);
        receipt.destroy_zero();
    };
    ts::end(ts);
}

#[test]
fun zero_as_join_accumulator() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut acc = warehouse_receipt::zero(storage_unit_id(), TYPE_ID, ts.ctx());
        let a = warehouse_receipt::mint_for_testing(storage_unit_id(), TYPE_ID, 30, ts.ctx());
        let b = warehouse_receipt::mint_for_testing(storage_unit_id(), TYPE_ID, 70, ts.ctx());
        acc.join(a);
        acc.join(b);
        assert_eq!(acc.quantity(), 100);
        warehouse_receipt::burn_for_testing(acc);
    };
    ts::end(ts);
}

#[test]
fun value_equals_quantity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        assert_eq!(receipt.quantity(), QUANTITY);
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
fun divide_into_n_even() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        // 100 / 4 = 25 each; 3 new receipts of 25, remainder 25 in self
        let mut parts = receipt.divide_into_n(4, ts.ctx());
        assert_eq!(parts.length(), 3);
        assert_eq!(receipt.quantity(), 25);

        let mut i = 0;
        while (i < parts.length()) {
            assert_eq!(parts[i].quantity(), 25);
            assert_eq!(parts[i].storage_unit_id(), storage_unit_id());
            assert_eq!(parts[i].type_id(), TYPE_ID);
            i = i + 1;
        };

        // Cleanup
        warehouse_receipt::burn_for_testing(receipt);
        while (!parts.is_empty()) {
            warehouse_receipt::burn_for_testing(parts.pop_back());
        };
        parts.destroy_empty();
    };
    ts::end(ts);
}

#[test]
fun divide_into_n_with_remainder() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        // 100 / 3 = 33 each; 2 new receipts of 33, remainder 34 in self
        let mut parts = receipt.divide_into_n(3, ts.ctx());
        assert_eq!(parts.length(), 2);
        assert_eq!(receipt.quantity(), 34);
        assert_eq!(parts[0].quantity(), 33);
        assert_eq!(parts[1].quantity(), 33);

        // Cleanup
        warehouse_receipt::burn_for_testing(receipt);
        while (!parts.is_empty()) {
            warehouse_receipt::burn_for_testing(parts.pop_back());
        };
        parts.destroy_empty();
    };
    ts::end(ts);
}

#[test]
fun divide_into_one() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        // n=1 means 0 new receipts, self keeps everything
        let parts = receipt.divide_into_n(1, ts.ctx());
        assert_eq!(parts.length(), 0);
        assert_eq!(receipt.quantity(), QUANTITY);

        warehouse_receipt::burn_for_testing(receipt);
        parts.destroy_empty();
    };
    ts::end(ts);
}

#[test]
fun split_and_transfer_receipt() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        receipt.split_and_transfer(40, RECIPIENT, ts.ctx());
        assert_eq!(receipt.quantity(), 60);
        warehouse_receipt::burn_for_testing(receipt);
    };

    // Verify recipient received the split receipt
    ts::next_tx(&mut ts, RECIPIENT);
    {
        let receipt = ts::take_from_sender<warehouse_receipt::WarehouseReceipt>(&ts);
        assert_eq!(receipt.quantity(), 40);
        assert_eq!(receipt.storage_unit_id(), storage_unit_id());
        assert_eq!(receipt.type_id(), TYPE_ID);
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
fun join_vec_multiple_receipts() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut base = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            10,
            ts.ctx(),
        );
        let others = vector[
            warehouse_receipt::mint_for_testing(storage_unit_id(), TYPE_ID, 20, ts.ctx()),
            warehouse_receipt::mint_for_testing(storage_unit_id(), TYPE_ID, 30, ts.ctx()),
            warehouse_receipt::mint_for_testing(storage_unit_id(), TYPE_ID, 40, ts.ctx()),
        ];
        base.join_vec(others);
        assert_eq!(base.quantity(), 100);
        assert_eq!(base.storage_unit_id(), storage_unit_id());
        warehouse_receipt::burn_for_testing(base);
    };
    ts::end(ts);
}

#[test]
fun join_vec_empty() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        receipt.join_vec(vector[]);
        assert_eq!(receipt.quantity(), QUANTITY);
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
fun destroy_zero_entry() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let receipt = warehouse_receipt::zero(storage_unit_id(), TYPE_ID, ts.ctx());
        warehouse_receipt::destroy_zero(receipt);
    };
    ts::end(ts);
}

// === Failure Tests ===

#[test]
#[expected_failure(abort_code = warehouse_receipt::EZeroQuantity)]
fun mint_zero_quantity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            0,
            ts.ctx(),
        );
        // Abort happens above; cleanup below satisfies the compiler
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::ESplitQuantityInvalid)]
fun split_zero_amount() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        let split = receipt.split(0, ts.ctx());
        // Abort happens above; cleanup below satisfies the compiler
        warehouse_receipt::burn_for_testing(split);
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::ESplitQuantityInvalid)]
fun split_entire_amount() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        let split = receipt.split(QUANTITY, ts.ctx());
        // Abort happens above; cleanup below satisfies the compiler
        warehouse_receipt::burn_for_testing(split);
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::EStorageUnitMismatch)]
fun join_different_storage_units() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt_a = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            50,
            ts.ctx(),
        );
        let receipt_b = warehouse_receipt::mint_for_testing(
            storage_unit_id_2(),
            TYPE_ID,
            50,
            ts.ctx(),
        );
        receipt_a.join(receipt_b);
        // Abort happens above; cleanup below satisfies the compiler
        warehouse_receipt::burn_for_testing(receipt_a);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::ETypeIdMismatch)]
fun join_different_type_ids() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt_a = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            50,
            ts.ctx(),
        );
        let receipt_b = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID_2,
            50,
            ts.ctx(),
        );
        receipt_a.join(receipt_b);
        // Abort happens above; cleanup below satisfies the compiler
        warehouse_receipt::burn_for_testing(receipt_a);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::EInvalidArg)]
fun divide_into_zero_parts() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        let mut parts = receipt.divide_into_n(0, ts.ctx());
        // Abort happens above; cleanup below satisfies the compiler
        while (!parts.is_empty()) {
            warehouse_receipt::burn_for_testing(parts.pop_back());
        };
        parts.destroy_empty();
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::ENotEnough)]
fun divide_into_more_than_quantity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            3,
            ts.ctx(),
        );
        // quantity=3, n=4 — not enough
        let mut parts = receipt.divide_into_n(4, ts.ctx());
        // Abort happens above; cleanup below satisfies the compiler
        while (!parts.is_empty()) {
            warehouse_receipt::burn_for_testing(parts.pop_back());
        };
        parts.destroy_empty();
        warehouse_receipt::burn_for_testing(receipt);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::ENonZeroQuantity)]
fun destroy_non_zero_receipt() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let receipt = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            QUANTITY,
            ts.ctx(),
        );
        receipt.destroy_zero();
        // Abort happens above; cleanup unreachable but satisfies compiler
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = warehouse_receipt::EStorageUnitMismatch)]
fun join_vec_different_storage_units() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, governor());
    {
        let mut base = warehouse_receipt::mint_for_testing(
            storage_unit_id(),
            TYPE_ID,
            50,
            ts.ctx(),
        );
        let others = vector[
            warehouse_receipt::mint_for_testing(storage_unit_id(), TYPE_ID, 20, ts.ctx()),
            warehouse_receipt::mint_for_testing(storage_unit_id_2(), TYPE_ID, 30, ts.ctx()),
        ];
        base.join_vec(others);
        // Abort happens above; cleanup below satisfies the compiler
        warehouse_receipt::burn_for_testing(base);
    };
    ts::end(ts);
}
