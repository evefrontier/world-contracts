module core::behavior_type;

// === Structs ===

public enum BehaviorType has copy, drop, store {
    Identity,
    Inventory,
    Metadata,
}

// === Public Functions ===

public fun identity(): BehaviorType { BehaviorType::Identity }

public fun inventory(): BehaviorType { BehaviorType::Inventory }

public fun metadata(): BehaviorType { BehaviorType::Metadata }
