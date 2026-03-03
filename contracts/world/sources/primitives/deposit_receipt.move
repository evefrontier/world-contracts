/// A bearer instrument representing a claim on items in a StorageUnit's bearer inventory.
///
/// Modelled after Sui's `Coin` — a `DepositReceipt` is an owned, transferable
/// object that proves entitlement to a specific quantity of a given `type_id`
/// stored inside a particular StorageUnit.
///
/// Supports the same composition primitives as `Coin`:
///
/// - **`split`** — carve off a sub-quantity into a new receipt.
/// - **`divide_into_n`** — split evenly into N receipts.
/// - **`join`** — merge two receipts (same storage unit + type) into one.
/// - **`zero`** — create an empty receipt for accumulation via `join`.
/// - **`destroy_zero`** — destroy a zero-quantity receipt.
/// - **`value`** / **`quantity`** — read the receipt's amount.
/// - **`transfer`** — native Sui transfer (enabled by `key + store`).
/// - **`split_and_transfer`** — split and send in a single transaction.
/// - **`join_vec`** — merge a vector of receipts into one.
///
/// Minting and burning are `public(package)` — only the assembly layer
/// (e.g. `storage_unit.move`) can create or consume receipts.
module world::deposit_receipt;

// === Errors ===
#[error(code = 0)]
const EStorageUnitMismatch: vector<u8> = b"Receipts must reference the same storage unit";
#[error(code = 1)]
const ETypeIdMismatch: vector<u8> = b"Receipts must have the same type_id";
#[error(code = 2)]
const ESplitQuantityInvalid: vector<u8> =
    b"Split quantity must be greater than 0 and less than receipt quantity";
#[error(code = 3)]
const EZeroQuantity: vector<u8> = b"Quantity must be greater than 0";
#[error(code = 4)]
const ENonZeroQuantity: vector<u8> = b"Cannot destroy a receipt with non-zero quantity";
#[error(code = 5)]
const EInvalidArg: vector<u8> = b"Invalid argument";
#[error(code = 6)]
const ENotEnough: vector<u8> = b"Cannot divide into more parts than receipt quantity";

// === Structs ===

/// Bearer instrument — anyone who holds this object can redeem the underlying
/// items from the referenced StorageUnit's bearer inventory.
public struct DepositReceipt has key, store {
    id: UID,
    storage_unit_id: ID,
    type_id: u64,
    quantity: u32,
}

// === Public Functions ===

/// Split `amount` from this receipt into a new receipt.
/// Analogous to `coin::split` — the original retains the remainder.
public fun split(receipt: &mut DepositReceipt, amount: u32, ctx: &mut TxContext): DepositReceipt {
    assert!(amount > 0 && amount < receipt.quantity, ESplitQuantityInvalid);
    receipt.quantity = receipt.quantity - amount;
    DepositReceipt {
        id: object::new(ctx),
        storage_unit_id: receipt.storage_unit_id,
        type_id: receipt.type_id,
        quantity: amount,
    }
}

/// Split `self` into `n - 1` receipts with equal quantities. The remainder is
/// left in `self`. Analogous to `coin::divide_into_n`.
public fun divide_into_n(
    self: &mut DepositReceipt,
    n: u32,
    ctx: &mut TxContext,
): vector<DepositReceipt> {
    assert!(n > 0, EInvalidArg);
    assert!(n <= self.quantity, ENotEnough);

    let split_amount = self.quantity / n;
    let mut i = 0;
    let mut result = vector[];
    while (i < n - 1) {
        result.push_back(self.split(split_amount, ctx));
        i = i + 1;
    };
    result
}

/// Merge another receipt into this one. Both must reference the same
/// storage unit and item type. Analogous to `coin::join`.
#[allow(lint(public_entry))]
public entry fun join(receipt: &mut DepositReceipt, other: DepositReceipt) {
    let DepositReceipt { id, storage_unit_id, type_id, quantity } = other;
    assert!(storage_unit_id == receipt.storage_unit_id, EStorageUnitMismatch);
    assert!(type_id == receipt.type_id, ETypeIdMismatch);
    receipt.quantity = receipt.quantity + quantity;
    id.delete();
}

/// Split `amount` from this receipt and transfer the new receipt to `recipient`.
/// Convenience entry point — no PTB required for the common "send some to a friend" flow.
#[allow(lint(public_entry))]
public entry fun split_and_transfer(
    self: &mut DepositReceipt,
    amount: u32,
    recipient: address,
    ctx: &mut TxContext,
) {
    transfer::public_transfer(self.split(amount, ctx), recipient);
}

/// Merge a vector of receipts into `self`. All must reference the same
/// storage unit and item type. Analogous to `sui::pay::join_vec`.
#[allow(lint(public_entry))]
public entry fun join_vec(self: &mut DepositReceipt, mut others: vector<DepositReceipt>) {
    while (!others.is_empty()) {
        self.join(others.pop_back());
    };
    others.destroy_empty();
}

/// Destroy a zero-quantity receipt. Useful after repeated splits.
#[allow(lint(public_entry))]
public entry fun destroy_zero(receipt: DepositReceipt) {
    let DepositReceipt { id, quantity, .. } = receipt;
    assert!(quantity == 0, ENonZeroQuantity);
    id.delete();
}

/// Make a zero-quantity receipt. Useful as a join accumulation target.
public fun zero(storage_unit_id: ID, type_id: u64, ctx: &mut TxContext): DepositReceipt {
    DepositReceipt {
        id: object::new(ctx),
        storage_unit_id,
        type_id,
        quantity: 0,
    }
}

// === View Functions ===

/// The StorageUnit this receipt is a claim against.
public fun storage_unit_id(receipt: &DepositReceipt): ID {
    receipt.storage_unit_id
}

/// The item type this receipt represents.
public fun type_id(receipt: &DepositReceipt): u64 {
    receipt.type_id
}

/// How many units of the item this receipt entitles the bearer to.
public fun quantity(receipt: &DepositReceipt): u32 {
    receipt.quantity
}

// === Package Functions ===

/// Mint a new deposit receipt. Only callable from within the `world` package.
public(package) fun mint(
    storage_unit_id: ID,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): DepositReceipt {
    assert!(quantity > 0, EZeroQuantity);
    DepositReceipt {
        id: object::new(ctx),
        storage_unit_id,
        type_id,
        quantity,
    }
}

/// Burn a deposit receipt, returning `(storage_unit_id, type_id, quantity)`.
/// Only callable from within the `world` package.
public(package) fun burn(receipt: DepositReceipt): (ID, u64, u32) {
    let DepositReceipt { id, storage_unit_id, type_id, quantity } = receipt;
    id.delete();
    (storage_unit_id, type_id, quantity)
}

// === Test Functions ===

#[test_only]
public fun mint_for_testing(
    storage_unit_id: ID,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): DepositReceipt {
    mint(storage_unit_id, type_id, quantity, ctx)
}

#[test_only]
public fun burn_for_testing(receipt: DepositReceipt): (ID, u64, u32) {
    burn(receipt)
}
