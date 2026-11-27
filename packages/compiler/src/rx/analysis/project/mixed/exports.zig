const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Export = @import("../../project.zig").Export;
const State = @import("state.zig");
const Surface = frontend.project.artifact.source_link.Surface;
const generated = @import("rx_options").generated_graph and @bitSizeOf(usize) == 64 and @alignOf(usize) >= @alignOf(u64);
const invalid_name = "public module names must be nonempty and unique";
const missing_root = "public module was not compiled in the shared source graph";

pub fn collect(state: *State, requested: []const Export, roots: []const usize) State.Error![]const frontend.project.compiled.Export {
    if (requested.len == 0) return &.{};

    const location: rx.ast.Location = .{ .offset = 0, .line = 1, .column = 1 };

    if (!state.scratch.reset(.retain_capacity)) return error.OutOfMemory;

    const invalid = try frontend.project.public_exports.invalidRootName(state.scratch.allocator(), requested);
    const result = try state.allocator.alloc(frontend.project.compiled.Export, requested.len);

    if (comptime generated) {
        const rule = @import("generated_rx_mixed_exports");

        const input: std.meta.Child(rule.Input) = .{
            .roots = @ptrCast(roots),
            .compiled = state.finished.present,
            .invalid_name = invalid,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const plan = @import("zx").columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
        const count: usize = @intCast(plan.count);

        for (requested[0..count], roots[0..count], result[0..count]) |exported, root, *item| {
            const loaded = state.finished.getAssumePresent(root);

            item.* = try materialize(state, exported, state.finished.function(root), loaded);
        }

        if (plan.message) |message| return state.fail(location, message);

        return result;
    }

    for (requested, roots, result, 0..) |exported, root, *item, index| {
        if (invalid == index) return state.fail(location, invalid_name);

        const loaded = state.finished.get(root) orelse return state.fail(location, missing_root);

        item.* = try materialize(state, exported, state.finished.function(root), loaded);
    }

    return result;
}

fn materialize(state: *const State, exported: Export, function: ?@import("zx").ir.FunctionId, loaded: *const Surface) std.mem.Allocator.Error!frontend.project.compiled.Export {
    return .{
        .name = try state.allocator.dupe(u8, exported.name),
        .path = try state.allocator.dupe(u8, exported.path),
        .function = function,
        .types = loaded.exports,
        .constants = loaded.constant_exports,
        .members = loaded.members,
    };
}
