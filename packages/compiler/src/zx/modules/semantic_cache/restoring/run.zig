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
const validation = @import("../../../ir/canonical/validation/host.zig");

pub fn run(module: *const Artifact.Module, current: *const Current, temporary: std.mem.Allocator, decoded: bool) Artifact.Error!restore.Restored {
    const publication_result = published: {
        var maps: rebind.Maps = .{ .allocator = temporary };
        var workspace = zx.Arena.init(temporary);

        defer workspace.deinit();

        const plan = try types.prepare(workspace.allocator(), module, current, &maps, decoded);
        const checkpoint = Checkpoint.save(current);

        errdefer checkpoint.rollback(current);

        var nodes: Nodes = .{
            .allocator = current.payloads.allocator(),
            .types = .{ .mapped = @ptrCast(maps.types) },
            .functions = .{ .indexed = maps.functions },
            .native_modules = .{ .indexed = maps.natives },
        };

        const restored = try publication.materialize(&nodes, module, current, plan.types, plan.entry, if (decoded) .validated else .unchecked);

        break :published .{ checkpoint, restored };
    };

    const checkpoint = publication_result[0];
    const restored = publication_result[1];

    errdefer checkpoint.rollback(current);

    const checked = try validation.verify(temporary, &restored.program, current.verified.*) orelse return error.InvalidIr;
    current.verified.* = checked.verified;

    return restored;
}
