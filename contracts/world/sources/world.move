module world::world;

use sui::party;

public struct GovernorCap has key {
    id: UID,
    governor: address,
}

// TODO: mint initial supply of eve tokens
fun init(ctx: &mut TxContext) {
    let gov_cap = GovernorCap {
        id: object::new(ctx),
        governor: ctx.sender(),
    };

    transfer::party_transfer(gov_cap, party::single_owner(ctx.sender()));
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
