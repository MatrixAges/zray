const State = @import("../host.zig").State;
const Error = @import("../../builder.zig").Error;
const operands = @import("../operands/host.zig");
const fixed = @import("../fixed.zig");

pub fn linkFixedPayload(handle: *const anyopaque, row: u32) Error!u32 {
    const state = State.borrow(handle);

    state.mapping.available = row;

    return @intCast(try fixed.append(state.builder, &state.mapping, &state.program.expressions, row, false));
}

pub const linkSequencePayload = effect(operands.sequence);
pub const linkCollectionPayload = effect(operands.collection);
pub const linkTransformPayload = effect(operands.transform);
pub const linkScopePayload = effect(operands.scope);
pub const linkSelectionPayload = effect(operands.match);
pub const linkObjectPayload = effect(operands.object);

fn effect(comptime publish: anytype) fn (*const anyopaque, u32) Error!u32 {
    return struct {
        fn apply(handle: *const anyopaque, row: u32) Error!u32 {
            const state = State.borrow(handle);
            const builder = state.builder;
            const source = &state.program.expressions;

            state.mapping.available = row;

            return @intCast(try publish(&builder.expressions, builder.allocator, &state.mapping, source, source.payloads[row]));
        }
    }.apply;
}
