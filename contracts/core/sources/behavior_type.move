module core::behavior_type;

// === Structs ===

public enum BehaviorType has copy, drop, store {
    Identity,
    Inventory,
    Metadata,
    // todo: will add Power Generator, Fuel, Capacitor, etc.
}

// === Public Functions ===

public fun identity(): BehaviorType { BehaviorType::Identity }

public fun inventory(): BehaviorType { BehaviorType::Inventory }

public fun metadata(): BehaviorType { BehaviorType::Metadata }
