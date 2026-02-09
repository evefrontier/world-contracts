/// Example builder extension for `world::gate` using the typed-witness extension pattern.
///
/// This module demonstrates how builders/players can enforce custom jump rules by issuing a
/// `world::gate::JumpPermit` from extension logic:
/// - Gate owners configure a gate to use this extension by authorizing the witness type `XAuth`
///   on the gate (via `world::gate::authorize_extension<XAuth>`).
/// - Once configured, travelers must use `world::gate::jump_with_permit`; default `jump` is not allowed.
/// - This extension issues permits through `issue_jump_permit`, which:
///   - checks a simple rule (character must belong to the configured starter `tribe`)
///   - sets an expiry window (currently 5 days from `Clock`)
///   - calls `world::gate::issue_jump_permit<XAuth>` to mint a single-use permit to the character.
///
/// `GateRules` is a shared object holding configurable parameters,
#[allow(unused_use)]
module extension_examples::tribe_permit;

use extension_examples::config::{Self, AdminCap, XAuth, ExtensionConfig};
use sui::clock::Clock;
use world::{character::Character, gate::{Self, Gate}};

// === Errors ===
#[error(code = 0)]
const ENotStarterTribe: vector<u8> = b"Character is not a starter tribe";
#[error(code = 1)]
const ENoTribeConfig: vector<u8> = b"Missing TribeConfig on ExtensionConfig";

/// Stored as a dynamic field value under `ExtensionConfig`.
public struct TribeConfig has drop, store {
    tribe: u32,
}

/// Dynamic-field key for `TribeConfig`.
public struct TribeConfigKey has copy, drop, store {}

// === View Functions ===
public fun tribe(extension_config: &ExtensionConfig): u32 {
    extension_config.borrow_rule<TribeConfigKey, TribeConfig>(TribeConfigKey {}).tribe
}

// === Admin Functions ===
/// Issue a `JumpPermit` to only starter tribes
public fun issue_jump_permit(
    extension_config: &ExtensionConfig,
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    _: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(extension_config.has_rule<TribeConfigKey>(TribeConfigKey {}), ENoTribeConfig);
    let tribe_cfg = extension_config.borrow_rule<TribeConfigKey, TribeConfig>(TribeConfigKey {});

    // Check if the character's tribe is a starter tribe
    assert!(character.tribe() == tribe_cfg.tribe, ENotStarterTribe);

    // 5 days in milliseconds. Please make this configurable.
    let expires_at_timestamp_ms = clock.timestamp_ms() + 5 * 24 * 60 * 60 * 1000;
    gate::issue_jump_permit<XAuth>(
        source_gate,
        destination_gate,
        character,
        config::x_auth(),
        expires_at_timestamp_ms,
        ctx,
    );
}

public fun set_tribe_config(
    extension_config: &mut ExtensionConfig,
    admin_cap: &AdminCap,
    tribe: u32,
) {
    extension_config.set_rule<TribeConfigKey, TribeConfig>(
        admin_cap,
        TribeConfigKey {},
        TribeConfig { tribe },
    );
}
