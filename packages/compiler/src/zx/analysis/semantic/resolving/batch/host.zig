const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const rule = @import("generated_type_batch_resolution");
const Input = std.meta.Child(rule.Input);
const Source = std.meta.Child(@FieldType(Input, "source"));
const Aliases = std.meta.Child(@FieldType(Input, "aliases"));
const Cache = std.meta.Child(@FieldType(Input, "resolved"));
const Group = std.meta.Child(@typeInfo(@FieldType(Input, "grouping")).optional.child);
const Store = std.meta.Child(@typeInfo(@FieldType(Input, "store")).optional.child);
const Types = @import("../../../types.zig");

pub const Grouping = struct {
    owners: []const u64,
    imports: *const zx.memory.ReadColumn,
};

pub const StoreFields = struct {
    mismatch: ?usize,
    ends: []const u64,
    expressions: []const []const u8,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    target: *ir.TypeStorage,
    ids: []ir.TypeId,
    aliases: []const ir.Export = &.{},
    resolved: ?*const @FieldType(Types, "resolved") = null,
    grouping: ?Grouping = null,
    store: ?StoreFields = null,
};

pub fn resolve(arena: *std.heap.ArenaAllocator, request: Request, text: []const u8, parsed: anytype) std.mem.Allocator.Error!?zx.Diagnostic {
    const tree = zx.columns.view(std.meta.Child(@FieldType(Source, "types")), parsed.types);
    const order = zx.columns.view(std.meta.Child(@FieldType(Source, "order")), parsed.type_order);

    const source: Source = .{
        .bytes = text,
        .types = &tree,
        .order = &order,
        .declarations = zx.columns.slice(@FieldType(Source, "declarations"), parsed.declarations),
        .members = &.{},
    };

    const base = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "base")), request.target.view());
    const resolved = if (request.resolved) |names| names.view(Cache) else Cache{ .names = &.{}, .ids = &.{} };
    const rows = @import("../host/aliases.zig").borrow(request.aliases);
    const aliases = rows.view(Aliases);

    const grouping: ?Group = if (request.grouping) |group| materialize: {
        const temporary = arena.allocator();
        const RowView = @import("../host/aliases.zig").Rows;
        const views = try temporary.alloc(RowView, group.imports.count);
        const group_aliases = try temporary.alloc(*const Aliases, views.len);
        const records = try temporary.alloc(Aliases, views.len);

        for (views, group_aliases, records, 0..) |*view, *alias, *record, index| {
            const offset = group.imports.offset + index * group.imports.stride;
            const items = std.mem.bytesToValue([]const zx.memory.NamedId, group.imports.bytes[offset..][0..@sizeOf([]const zx.memory.NamedId)]);

            view.* = .{ .items = items };
            record.* = view.view(Aliases);
            alias.* = record;
        }

        break :materialize .{ .owners = group.owners, .aliases = group_aliases };
    } else null;

    const store = if (request.store) |fields| Store{
        .mismatch = if (fields.mismatch) |row| row else null,
        .ends = fields.ends,
        .expressions = fields.expressions,
    } else null;

    const input: Input = .{
        .source = &source,
        .base = &base,
        .resolved = &resolved,
        .aliases = &aliases,
        .grouping = if (grouping) |*view| view else null,
        .store = if (store) |*rules| rules else null,
    };

    const result = rule.execute(arena, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (result.diagnostic.message.len != 0) return .{
        .code = std.meta.stringToEnum(@FieldType(zx.Diagnostic, "code"), result.diagnostic.code) orelse unreachable,
        .span = .{ .start = @intCast(result.diagnostic.start), .end = @intCast(result.diagnostic.end) },
        .message = result.diagnostic.message,
    };

    for (result.ids, 0..) |id, index| request.ids[index] = @fromBackingInt(id);

    if (result.delta.kinds.len != 0) {
        try @import("../../merging/commit.zig").appendTypes(request.allocator, request.target, result.delta.*);
    }

    return null;
}
