const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Loaded = @import("../../native.zig");
const Artifact = @import("../../artifact/model.zig");
const restore = @import("../native_restore.zig");
const Input = @import("native_input.zig");
const publication = @import("../../link/signature/publication/host.zig");
const surface = @import("../../artifact/surface.zig");
const remap = @import("../../artifact/nodes/remap.zig");

pub fn apply(allocator: std.mem.Allocator, output: anytype, mapped: *const Input, artifact: *const Artifact.Module, current: restore.Current) restore.Error!Loaded.Result {
    const mapping = remap.typeMapping(surface.Mapping, .{ .mapped = @ptrCast(mapped.type_ids) });
    const exports = try surface.copyExports(allocator, artifact.exports, &mapping);
    const signatures = artifact.functions;

    const staged = if (signatures.count() != 0) owned: {
        const first_member = signatures.native_members[0];
        const rows: publication.SourceRows = .{ .cached = .{ .signatures = signatures, .inputs = mapped.input_ids, .outputs = mapped.output_ids } };

        break :owned try publication.stageNative(allocator, current.functions, rows, signatures.files[0], first_member[0 .. first_member.len - 1], current.module);
    } else publication.Staged{};

    const types = zx.columns.view(ir.TypeTable, output.types);

    try @import("../../../analysis/semantic/merging/commit.zig").append(allocator, current.types, &current.origins.items, types, output.origins);

    return .{ .types = current.types.view(), .exports = exports, .members = staged.members, .namespace = staged.namespace };
}
