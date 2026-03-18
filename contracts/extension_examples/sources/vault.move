/// Shared vault that holds one OwnerCap<NetworkNode> via Sui Receiving (transfer_to_object).
///
/// Does not use Table (OwnerCap has no `store`). The vault holds at most one cap at a time.
/// Enables: deposit from character, borrow/use/return, withdraw back to character.
module extension_examples::vault;

use extension_examples::config::AdminCap;
use sui::table::{Self, Table};
use sui::transfer::Receiving;
use world::access::{Self, OwnerCap};
use world::network_node::NetworkNode;
use world::character::Character;
// === Errors ===
#[error(code = 0)]
const EReceiptMismatch: vector<u8> = b"Return receipt does not match vault or OwnerCap";
#[error(code = 1)]
const ENotTribeMember: vector<u8> = b"Sender is not a tribe member";

/// Receipt proving the OwnerCap was borrowed from this vault; must be used to return it.
public struct VaultReturnReceipt has drop, store {
    owner_cap_id: ID,
    vault_id: ID,
}

/// Shared object; holds at most one OwnerCap<NetworkNode> in its Receiving at a time.
/// Only tribe members may call borrow_owner_cap or withdraw_to_character.
public struct NodeOwnerCapVault has key {
    id: UID,
    tribe_members: Table<address, bool>,
}

// === Public entrypoints ===

/// Deposit an OwnerCap<NetworkNode> into the vault (transfer to object; vault receives it).
/// Caller typically borrows from character first, then deposits (character receipt is dropped).
public fun deposit_owner_cap(vault: &mut NodeOwnerCapVault, owner_cap: OwnerCap<NetworkNode>) {
    access::transfer_owner_cap(owner_cap, object::id_address(vault));
}

/// Borrow OwnerCap from the vault. Caller must return it with `return_owner_cap`.
/// Only tribe members may borrow. Pass the Receiving ticket (ref to the OwnerCap in the vault).
public fun borrow_owner_cap(
    vault: &mut NodeOwnerCapVault,
    ticket: Receiving<OwnerCap<NetworkNode>>,
    ctx: &TxContext,
): (OwnerCap<NetworkNode>, VaultReturnReceipt) {
    assert!(table::contains(&vault.tribe_members, ctx.sender()), ENotTribeMember);
    let owner_cap = access::receive_owner_cap(&mut vault.id, ticket);
    let owner_cap_id = object::id(&owner_cap);
    let receipt = VaultReturnReceipt {
        owner_cap_id,
        vault_id: object::id(vault),
    };
    (owner_cap, receipt)
}

/// Return a borrowed OwnerCap to the vault. Consumes the receipt.
public fun return_owner_cap(
    vault: &mut NodeOwnerCapVault,
    owner_cap: OwnerCap<NetworkNode>,
    receipt: VaultReturnReceipt,
) {
    let VaultReturnReceipt {
        owner_cap_id: receipt_cap_id,
        vault_id: receipt_vault_id,
    } = receipt;
    assert!(object::id(vault) == receipt_vault_id, EReceiptMismatch);
    assert!(object::id(&owner_cap) == receipt_cap_id, EReceiptMismatch);
    access::transfer_owner_cap(owner_cap, object::id_address(vault));
}

public fun return_owner_cap_to_character(
    vault: &mut NodeOwnerCapVault,
    ticket: Receiving<OwnerCap<NetworkNode>>,
    character: &Character,
    ctx: &TxContext,
) {
    assert!(table::contains(&vault.tribe_members, ctx.sender()), ENotTribeMember);
    let owner_cap = access::receive_owner_cap(&mut vault.id, ticket);
    access::transfer_owner_cap(owner_cap, object::id_address(character));
}

/// Check if an address is a tribe member.
public fun is_tribe_member(vault: &NodeOwnerCapVault, addr: address): bool {
    table::contains(&vault.tribe_members, addr)
}
  
// === Admin ===
public fun create_vault(_: &AdminCap, ctx: &mut TxContext) {
    let vault = NodeOwnerCapVault {
        id: object::new(ctx),
        tribe_members: table::new(ctx),
    };
    transfer::share_object(vault);
}

/// Add an address as a tribe member (may borrow and withdraw).
public fun add_tribe_member(vault: &mut NodeOwnerCapVault, _: &AdminCap, addr: address) {
    if (!table::contains(&vault.tribe_members, addr)) {
        table::add(&mut vault.tribe_members, addr, true);
    };
}

/// Remove an address from tribe members.
public fun remove_tribe_member(vault: &mut NodeOwnerCapVault, _: &AdminCap, addr: address) {
    if (table::contains(&vault.tribe_members, addr)) {
        let _ = table::remove(&mut vault.tribe_members, addr);
    };
}