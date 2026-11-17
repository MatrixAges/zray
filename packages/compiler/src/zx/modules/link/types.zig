const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("../nominal_origins.zig");
const Module = @import("../artifact/model.zig").Module;
const table = @import("../../analysis/type_table.zig");
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{ InvalidModule, MissingNominalOrigin, ConflictingNominalType };

allocator: std.mem.Allocator,
items: ir.TypeStorage = .{},
origins: Origins,
pub fn init(allocator: std.mem.Allocator) Error!Self {
    var self = Self{ .allocator = allocator, .origins = .{ .allocator = allocator } };

    try table.initializeScalars(allocator, &self.items);

    return self;
}

pub fn append(self: *Self, temporary: std.mem.Allocator, module: Module) Error![]const ir.TypeId {
    return self.appendFrom(temporary, module.types, module.nominal_types, 0);
}

/// Extends a shared table while the caller owns only a temporary type-ID map.
pub fn appendTemporary(self: *Self, mapping_allocator: std.mem.Allocator, temporary: std.mem.Allocator, module: *const Module) Error![]const ir.TypeId {
    return self.appendValues(mapping_allocator, temporary, module.types, module.nominal_types, 0, false);
}

pub fn compact(self: *Self, temporary: std.mem.Allocator, first: usize, origin_count: usize) Error![]const ir.TypeId {
    const source = self.items.view();
    const origins = self.origins.items.view();
    const prefix = retainedPrefix(source, first);

    self.items.retainColumns(prefix);
    self.origins.items.retainPrefix(origin_count);

    errdefer {
        self.items.retainColumns(prefix);
        self.origins.items.retainPrefix(origin_count);
    }

    const mapping = try self.appendAnalyzed(self.allocator, temporary, source, origins, first);

    inline for (@typeInfo(ir.TypeStorage).@"struct".field_names) |name| {
        std.debug.assert(@field(self.items, name).items.ptr == @field(source, name).ptr);
    }

    inline for (@typeInfo(Origins.Storage).@"struct".field_names) |name| {
        std.debug.assert(@field(self.origins.items, name).items.ptr == @field(origins, name).ptr);
    }

    return mapping;
}

fn retainedPrefix(source: ir.TypeTable, count: usize) ir.TypeTable {
    if (comptime !@import("parser_options").generated_parser) return source.prefix(count);

    const rule = @import("generated_type_retained_payload");
    const Input = std.meta.Child(rule.Input);
    const input: Input = .{ .kinds = source.kinds, .first = source.first, .second = source.second, .count = count };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const ends = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return .{
        .kinds = source.kinds[0..count],
        .first = source.first[0..count],
        .second = source.second[0..count],
        .labels = source.labels[0..count],
        .children = source.children[0..@intCast(ends.children)],
        .field_types = source.field_types[0..@intCast(ends.fields)],
        .field_names = source.field_names[0..@intCast(ends.fields)],
        .names = source.names[0..@intCast(ends.names)],
    };
}

pub fn appendFrom(self: *Self, temporary: std.mem.Allocator, values: ir.TypeTable, nominal_types: Origins.Table, first: usize) Error![]const ir.TypeId {
    return self.appendValues(self.allocator, temporary, values, nominal_types, first, false);
}

/// Extends the shared table with a result analyzed against its existing prefix.
pub fn appendAnalyzed(self: *Self, mapping_allocator: std.mem.Allocator, temporary: std.mem.Allocator, values: ir.TypeTable, nominal_types: Origins.Table, first: usize) Error![]const ir.TypeId {
    return self.appendValues(mapping_allocator, temporary, values, nominal_types, first, true);
}

fn appendValues(self: *Self, mapping_allocator: std.mem.Allocator, temporary: std.mem.Allocator, values: ir.TypeTable, nominal_types: Origins.Table, first: usize, comptime analyzed: bool) Error![]const ir.TypeId {
    const checked = !analyzed or @import("../../ir/validate.zig").internal;

    if ((first == 0 or checked) and !@import("../../ir/type_rules.zig").validate(values)) return error.InvalidModule;

    var prepared = try @import("../../analysis/semantic/preflight.zig").prepare(mapping_allocator, temporary, values, nominal_types, self.items.view(), first, !analyzed);

    defer prepared.deinitScratch();
    errdefer mapping_allocator.free(prepared.mapping);

    if (!@import("parser_options").generated_parser) return @import("seed_types.zig").appendPrepared(self, temporary, values, nominal_types, first, prepared.origins, prepared.mapping);

    try @import("../../analysis/semantic/merge.zig").append(.{
        .allocator = self.allocator,
        .temporary = temporary,
        .source = values,
        .origins = nominal_types,
        .origin_indices = prepared.origins,
        .mapping = prepared.mapping,
        .items = &self.items,
        .nominal = &self.origins.items,
        .first = first,
        .checked = checked,
    });

    return prepared.mapping;
}
