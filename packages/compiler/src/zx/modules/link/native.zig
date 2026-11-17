const std = @import("std");
const ir = @import("zx").ir;
const columns = @import("zx").columns;
const Nodes = @import("../artifact/nodes.zig");
const Error = @import("../artifact/model.zig").Error || error{ConflictingInterface};

pub fn link(temporary: std.mem.Allocator, modules: *ir.NativeModuleStorage, source: ir.NativeModuleTable, mapping: []?ir.NativeModuleId, nodes: *Nodes) Error!void {
    if (source.count() == 0) return;

    const allocator = nodes.allocator;

    if (comptime !@import("parser_options").generated_parser) {
        for (mapping, 0..) |*id, row| id.* = try appendSeed(allocator, modules, source.at(row), nodes);

        return;
    }

    const entry = @import("generated_native_link_plan");
    const Input = std.meta.Child(entry.Input);
    const Table = std.meta.Child(@FieldType(Input, "source"));
    const base = columns.columns(Table, modules.view());
    const rows = columns.columns(Table, source);
    const types: []const u32 = @ptrCast(nodes.types.mapped);
    const input: Input = .{ .base = &base, .source = &rows, .types = types, .target = @ptrCast(&mapping) };

    const plan = columns.invoke(entry.executeValue, temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    if (plan.failure) |status| return switch (status) {
        .Conflict => error.ConflictingInterface,
        .Full => error.OutOfMemory,
        else => error.InvalidModule,
    };

    for (plan.additions) |row| {
        try modules.append(allocator, try materialize(allocator, source.at(@intCast(row)), types));
    }
}

pub fn materialize(allocator: std.mem.Allocator, source: ir.NativeModule, mapping: []const u32) std.mem.Allocator.Error!ir.NativeModule {
    const entry = @import("generated_native_link_owned");
    const Input = std.meta.Child(entry.Input);
    const Binding = std.meta.Child(@FieldType(Input, "source"));

    const binding: Binding = .{
        .specifier = source.specifier,
        .identity = source.identity,
        .import_name = source.import_name,
        .namespace = source.type_namespace,
        .names = source.types.names,
        .ids = source.types.type_ids,
    };

    const input: Input = .{ .source = &binding, .mapping = mapping };
    const owned = columns.invoke(entry.executeValue, allocator, &input) catch return error.OutOfMemory;

    return .{
        .specifier = owned.specifier,
        .identity = owned.identity,
        .import_name = owned.import_name,
        .type_namespace = owned.namespace,
        .types = .{ .names = owned.names, .type_ids = owned.ids },
    };
}

fn appendSeed(allocator: std.mem.Allocator, modules: *ir.NativeModuleStorage, value: ir.NativeModule, nodes: *Nodes) Error!ir.NativeModuleId {
    const names = try allocator.alloc([]const u8, value.types.count());
    const ids = try allocator.alloc(u32, value.types.count());

    for (value.types.names, value.types.type_ids, names, ids) |name, id, *mapped_name, *mapped_id| {
        mapped_name.* = try allocator.dupe(u8, name);
        mapped_id.* = @backingInt(try nodes.types.include(@fromBackingInt(id)));
    }

    for (0..modules.count()) |index| {
        const existing = modules.at(index);

        if (!std.mem.eql(u8, existing.key(), value.key()) or !std.mem.eql(u8, existing.import_name, value.import_name)) continue;
        if (!stringsEqual(existing.type_namespace, value.type_namespace) or existing.types.count() != names.len) return error.ConflictingInterface;

        for (existing.types.names, existing.types.type_ids, names, ids) |left_name, left_id, right_name, right_id| {
            if (left_id != right_id or !std.mem.eql(u8, left_name, right_name)) return error.ConflictingInterface;
        }

        return @fromBackingInt(@intCast(index));
    }

    const id: ir.NativeModuleId = @fromBackingInt(@intCast(modules.count()));

    try modules.append(allocator, .{
        .specifier = try allocator.dupe(u8, value.specifier),
        .identity = if (value.identity) |key| try allocator.dupe(u8, key) else null,
        .import_name = try allocator.dupe(u8, value.import_name),
        .type_namespace = try nodes.strings(value.type_namespace),
        .types = .{ .names = names, .type_ids = ids },
    });

    return id;
}

pub fn sameExternalSeed(left: ir.External, right: ir.External) bool {
    if (left.module != right.module or left.allocator_argument != right.allocator_argument or left.io_argument != right.io_argument or left.process_argument != right.process_argument or left.expand_tuple != right.expand_tuple or left.fallible != right.fallible) return false;
    if (!stringsEqual(left.member, right.member)) return false;
    if (left.input) |input| return sameType(input, right.input orelse return false);

    return right.input == null;
}

fn sameType(left: ir.NativeType, right: ir.NativeType) bool {
    if (left.names.len != right.names.len) return false;

    for (left.names, right.names) |a, b| {
        if (a) |name| {
            if (!std.mem.eql(u8, name, b orelse return false)) return false;
        } else if (b != null) return false;
    }

    return true;
}

pub fn stringsEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;

    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }

    return true;
}
