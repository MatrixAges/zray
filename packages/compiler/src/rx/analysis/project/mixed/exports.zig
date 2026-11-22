const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const Export = @import("../../project.zig").Export;
const State = @import("state.zig");
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
        const target: Publication = .{ .state = state, .requested = requested, .result = result };

        const input: std.meta.Child(rule.Input) = .{
            .target = @ptrCast(&target),
            .roots = @ptrCast(roots),
            .compiled = state.finished.present,
            .invalid_name = invalid,
        };

        try @import("body.zig").run(rule, &input);

        return result;
    }

    for (requested, roots, result, 0..) |exported, root, *item, index| {
        if (invalid == index) return state.fail(location, invalid_name);

        const loaded = state.finished.get(root) orelse return state.fail(location, missing_root);

        item.* = try materialize(state, exported, loaded);
    }

    return result;
}

const Publication = struct {
    state: *State,
    requested: []const Export,
    result: []frontend.project.compiled.Export,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn installMixedExport(handle: *const anyopaque, row: u64, root: u64) std.mem.Allocator.Error!void {
    const target = Publication.borrow(handle);
    const index: usize = @intCast(row);

    target.result[index] = try materialize(target.state, target.requested[index], target.state.finished.getAssumePresent(@intCast(root)));
}

pub fn rejectMixedExport(handle: *const anyopaque, message: []const u8) State.Error!void {
    return Publication.borrow(handle).state.fail(.{ .offset = 0, .line = 1, .column = 1 }, message);
}

fn materialize(state: *const State, exported: Export, loaded: frontend.project.artifact.source_link.Loaded) std.mem.Allocator.Error!frontend.project.compiled.Export {
    return .{
        .name = try state.allocator.dupe(u8, exported.name),
        .path = try state.allocator.dupe(u8, exported.path),
        .function = loaded.function,
        .types = loaded.exports,
        .constants = loaded.constant_exports,
        .members = loaded.members,
    };
}
