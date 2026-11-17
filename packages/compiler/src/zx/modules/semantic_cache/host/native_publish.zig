const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Loaded = @import("../../native.zig");
const Current = @import("../native_restore.zig").Current;
const Input = @import("native_input.zig");
const publication = @import("../../link/signature/publication/host.zig");

pub fn apply(allocator: std.mem.Allocator, output: anytype, mapped: *const Input, signatures: ir.SignatureTable, current: Current) std.mem.Allocator.Error!Loaded.Result {
    const exports = try allocator.alloc(ir.Export, mapped.export_rows.len);

    for (exports, mapped.export_rows, mapped.export_ids) |*item, row, id| {
        item.* = .{ .name = try allocator.dupe(u8, row.name), .type_id = @fromBackingInt(id) };
    }

    const staged = if (signatures.count() != 0) owned: {
        const first_member = signatures.native_members[0];
        const rows: publication.SourceRows = .{ .cached = .{ .signatures = signatures, .inputs = mapped.input_ids, .outputs = mapped.output_ids } };

        break :owned try publication.stageNative(allocator, current.functions, rows, signatures.files[0], first_member[0 .. first_member.len - 1], current.module);
    } else publication.Staged{};

    const types = zx.columns.view(ir.TypeTable, output.types);

    try @import("../../../analysis/semantic/merging/commit.zig").append(allocator, current.types, &current.origins.items, types, output.origins);

    return .{ .types = current.types.view(), .exports = exports, .members = staged.members, .namespace = staged.namespace };
}
