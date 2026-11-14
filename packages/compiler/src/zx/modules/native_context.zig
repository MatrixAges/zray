const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated = @import("parser_options").generated_parser;

pub fn valid(types: ir.TypeTable, modules: ir.NativeModuleTable) bool {
    return @import("../ir/native_modules.zig").validate(.{
        .file_name = "shared",
        .types = types,
        .native_modules = modules,
        .input_type = @fromBackingInt(0),
        .output_type = @fromBackingInt(0),
        .symbols = .{},
        .expressions = .{},
        .body = .{},
        .type_only = true,
    });
}

pub fn copy(allocator: std.mem.Allocator, modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.NativeModuleTable {
    var result = try storage(allocator, modules);

    if (comptime generated) return result.view();

    return result.finish(allocator);
}

pub fn storage(allocator: std.mem.Allocator, modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.NativeModuleStorage {
    if (comptime !generated) return storageSeed(allocator, modules);
    if (modules.count() == 0) return .{};

    var result: ir.NativeModuleStorage = .{};

    errdefer result.deinit(allocator);

    inline for (@typeInfo(ir.NativeModuleStorage).@"struct".field_names) |name| {
        const column = &@field(result, name);

        try column.ensureTotalCapacityPrecise(allocator, modules.count());
        try column.resize(allocator, modules.count());

        @memset(column.items, if (comptime @typeInfo(std.meta.Elem(@TypeOf(column.items))) == .optional) null else &.{});
    }

    errdefer release(allocator, result.view());

    const entry = @import("generated_native_context_copy");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    const source = zx.columns.columns(Source, modules);

    const destination: Destination = .{
        .identities = @ptrCast(&result.identities.items),
        .import_names = @ptrCast(&result.import_names.items),
        .specifiers = @ptrCast(&result.specifiers.items),
        .type_ids = @ptrCast(&result.type_ids.items),
        .type_names = @ptrCast(&result.type_names.items),
        .type_namespaces = @ptrCast(&result.type_namespaces.items),
    };

    const input: Input = .{ .source = &source, .destination = &destination };

    zx.columns.invoke(entry.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return result;
}

fn release(allocator: std.mem.Allocator, table: ir.NativeModuleTable) void {
    for (table.identities) |identity| if (identity) |value| allocator.free(value);
    for (table.specifiers) |value| allocator.free(value);
    for (table.import_names) |value| allocator.free(value);
    for (table.type_ids) |ids| allocator.free(ids);

    for ([2][]const []const []const u8{ table.type_namespaces, table.type_names }) |column| {
        for (column) |names| {
            for (names) |name| allocator.free(name);

            allocator.free(names);
        }
    }
}

fn storageSeed(allocator: std.mem.Allocator, modules: ir.NativeModuleTable) std.mem.Allocator.Error!ir.NativeModuleStorage {
    var result: ir.NativeModuleStorage = .{};

    errdefer result.deinit(allocator);

    for (0..modules.count()) |index| {
        var module = modules.at(index);

        module.specifier = try allocator.dupe(u8, module.specifier);
        module.identity = if (module.identity) |identity| try allocator.dupe(u8, identity) else null;
        module.import_name = try allocator.dupe(u8, module.import_name);
        const namespace = try allocator.alloc([]const u8, module.type_namespace.len);

        for (module.type_namespace, namespace) |name, *owned| owned.* = try allocator.dupe(u8, name);

        module.type_namespace = namespace;

        const names = try allocator.alloc([]const u8, module.types.count());
        const ids = try allocator.dupe(u32, module.types.type_ids);

        for (module.types.names, names) |name, *owned| owned.* = try allocator.dupe(u8, name);

        module.types = .{ .names = names, .type_ids = ids };

        try result.append(allocator, module);
    }

    return result;
}
