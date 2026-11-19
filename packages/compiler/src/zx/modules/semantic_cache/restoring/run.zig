const std = @import("std");
const zx = @import("zx");
const Artifact = @import("../../artifact/model.zig");
const Nodes = @import("../../artifact/nodes.zig");
const restore = @import("../restore.zig");
const Current = restore.Current;
const Checkpoint = @import("checkpoint.zig");
const rebind = @import("rebind/host.zig");
const types = @import("types/host.zig");
const publication = @import("publication/host.zig");
const schedule = @import("generated_semantic_restore_steps");

pub fn run(module: *const Artifact.Module, current: *const Current, temporary: std.mem.Allocator, decoded: bool) Artifact.Error!restore.Restored {
    const steps = comptime zx.staticSequence(schedule, {});
    var checkpoint: ?Checkpoint = null;
    var maps: rebind.Maps = .{ .allocator = temporary };
    var entry: ?zx.ir.FunctionId = undefined;
    var restored: restore.Restored = undefined;

    errdefer if (checkpoint) |*saved| saved.rollback(current);

    const payload = current.payloads.allocator();

    inline for (steps) |step| switch (step) {
        .Preflight => {
            if (!try @import("preflight/host.zig").check(temporary, module, current, decoded)) return error.InvalidModule;
        },
        .Checkpoint => checkpoint = Checkpoint.save(current),
        .Rebind => {
            var workspace = zx.Arena.init(temporary);

            defer workspace.deinit();

            const plan = try types.prepare(workspace.allocator(), module, current, &maps, decoded);

            try types.commit(current, payload, plan.types);

            entry = plan.entry;
        },
        .Materialize => {
            var nodes: Nodes = .{
                .allocator = payload,
                .types = .{ .mapped = @ptrCast(maps.types) },
                .functions = .{ .indexed = maps.functions },
                .native_modules = .{ .indexed = maps.natives },
            };

            restored = try publication.materialize(&nodes, module, .{
                .allocator = current.allocator,
                .functions = current.functions,
                .tables = .{
                    .types = current.types.view(),
                    .functions = current.functions.view(),
                    .native_modules = current.native_modules,
                },
                .path = current.path,
            }, entry, if (decoded) .validated else .unchecked);
        },
        .Verify => {
            const validation = try @import("../../../ir/canonical/validation/host.zig").verify(temporary, &restored.program, current.verified.*) orelse return error.InvalidIr;
            current.verified.* = validation.verified;
        },
    };

    return restored;
}
