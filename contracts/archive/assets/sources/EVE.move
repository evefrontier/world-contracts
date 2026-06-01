/// EVE token is the native token of the EVE Frontier game.
module assets::EVE;

use std::string;
use sui::{balance::{Self, Balance}, coin, coin_registry::{Self, Currency, MetadataCap}};

// === Constants ===
const DECIMALS: u8 = 9;
const TOTAL_SUPPLY: u64 = 10_000_000_000; // 10B tokens
const INITIAL_DEPLOYER_ALLOCATION: u64 = 10_000_000; // 10M to deployer at init
const SCALE: u64 = 1_000_000_000; // 10^DECIMALS
const SYMBOL: vector<u8> = b"EVE";
const NAME: vector<u8> = b"EVE Token";
const DESCRIPTION: vector<u8> =
    b"Native token for EVE Frontier on Sui. Powers the open, composable Eve Frontier Game and the builder-driven economy.";
const ICON_URL: vector<u8> = b"https://artifacts.evefrontier.com/logos/eve-test-token.png";

/// One-time witness for EVE; ensures a single currency per type.
public struct EVE has drop {}

/// Admin capability: holder can transfer from treasury and burn. Created once at init.
public struct AdminCap has key, store {
    id: object::UID,
}

/// Treasury holding the non-circulating EVE balance. Admin can transfer or burn from it.
public struct EveTreasury has key {
    id: object::UID,
    balance: Balance<EVE>,
}

// === Init ===
fun init(witness: EVE, ctx: &mut tx_context::TxContext) {
    let (mut initializer, mut treasury_cap) = coin_registry::new_currency_with_otw<EVE>(
        witness,
        DECIMALS,
        string::utf8(SYMBOL),
        string::utf8(NAME),
        string::utf8(DESCRIPTION),
        string::utf8(ICON_URL),
        ctx,
    );

    let total_supply_amount = TOTAL_SUPPLY * SCALE;
    let deployer_amount = INITIAL_DEPLOYER_ALLOCATION * SCALE;

    let mut all_coins = coin::mint(&mut treasury_cap, total_supply_amount, ctx);
    let deployer_coins = coin::split(&mut all_coins, deployer_amount, ctx);
    transfer::public_transfer(deployer_coins, tx_context::sender(ctx));

    let treasury_balance = coin::into_balance(all_coins);
    let treasury = EveTreasury {
        id: object::new(ctx),
        balance: treasury_balance,
    };
    transfer::transfer(treasury, tx_context::sender(ctx));

    let admin_cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(admin_cap, tx_context::sender(ctx));

    coin_registry::make_supply_burn_only_init(&mut initializer, treasury_cap);

    let metadata_cap = coin_registry::finalize(initializer, ctx);
    transfer::public_transfer(metadata_cap, tx_context::sender(ctx));
}

/// Call in a second transaction after publish to register the Currency in the CoinRegistry (0xc).
public fun complete_registration(
    registry: &mut coin_registry::CoinRegistry,
    currency: transfer::Receiving<Currency<EVE>>,
    ctx: &mut tx_context::TxContext,
) {
    coin_registry::finalize_registration(registry, currency, ctx);
}

public fun treasury_balance(treasury: &EveTreasury): u64 {
    balance::value(&treasury.balance)
}

public fun update_description(
    _: &AdminCap,
    currency: &mut Currency<EVE>,
    metadata_cap: &MetadataCap<EVE>,
    description: string::String,
) {
    coin_registry::set_description(currency, metadata_cap, description);
}

public fun update_icon_url(
    _: &AdminCap,
    currency: &mut Currency<EVE>,
    metadata_cap: &MetadataCap<EVE>,
    icon_url: string::String,
) {
    coin_registry::set_icon_url(currency, metadata_cap, icon_url);
}

/// Admin: transfer EVE from treasury to a recipient.
public fun transfer_from_treasury(
    treasury: &mut EveTreasury,
    _: &AdminCap,
    amount: u64,
    recipient: address,
    ctx: &mut tx_context::TxContext,
) {
    let coin = coin::take(&mut treasury.balance, amount, ctx);
    transfer::public_transfer(coin, recipient);
}

/// Admin: burn EVE from treasury to reduce supply in circulation. Requires Currency (shared at registry).
public fun burn_from_treasury(
    treasury: &mut EveTreasury,
    currency: &mut Currency<EVE>,
    _: &AdminCap,
    amount: u64,
    ctx: &mut tx_context::TxContext,
) {
    let coin = coin::take(&mut treasury.balance, amount, ctx);
    coin_registry::burn(currency, coin);
}

#[test_only]
public fun init_for_testing(ctx: &mut tx_context::TxContext) {
    init(EVE {}, ctx);
}
