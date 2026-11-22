const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Flow = @import("../flow_compile.zig");
const Loop = @import("../module.zig").Call.Loop;

pub fn compile(flow: *Flow, row: u32, callee: zx.ir.Program) Flow.Error!?Loop {
    const predicate = flow.inputs.calls.items(.loop_condition)[row] orelse return null;

    if (callee.input_type != callee.output_type or callee.input_type == frontend.types.scalarId(.void)) {
        return invalid(flow, predicate);
    }

    const text = std.mem.trim(u8, predicate.value, " \t\r\n");
    const prefix = "$in.";

    if (std.mem.startsWith(u8, text, prefix)) {
        const name = text[prefix.len..];

        if (std.zig.isValidId(name)) {
            if (field(flow, callee, name)) |index| return .{ .field = index };
        }
    }

    return .{ .predicate = try flow.keep(try flow.loopPredicate(predicate.*, callee.input_type)) };
}

fn field(flow: *const Flow, callee: zx.ir.Program, field_name: []const u8) ?u32 {
    if (callee.input_type != callee.output_type) return null;

    const state = flow.types.get(callee.input_type);
    const bool_type = @backingInt(frontend.types.scalarId(.bool));

    if (state != .object) return null;

    for (state.object.names, state.object.types, 0..) |name, type_id, index| {
        if (type_id == bool_type and std.mem.eql(u8, name, field_name)) return @intCast(index);
    }

    return null;
}

fn invalid(flow: *Flow, predicate: *const rx.ast.Attribute) Flow.Error {
    const location = predicate.value_location;

    flow.issue = .{ .location = location, .issue = .{
        .code = .type_mismatch,
        .span = .{ .start = location.offset, .end = location.offset },
        .message = "Loop requires the same non-void input and output type for its Call",
    } };

    return error.InvalidFlow;
}
