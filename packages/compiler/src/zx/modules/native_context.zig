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

    const count = modules.count();

    if (count == 0) return .{};

    var result: ir.NativeModuleStorage = .{};

    try result.reserve(allocator, count);

    errdefer result.deinit(allocator);

    const entry = @import("generated_native_context_copy");
    const Parameter = @typeInfo(@TypeOf(entry.executeIn)).@"fn".param_types[1].?;
    const Input = if (@typeInfo(Parameter) == .pointer) std.meta.Child(Parameter) else Parameter;
    const source = zx.columns.columns(Input, modules);

    const copied = entry.executeIn(allocator, if (@typeInfo(Parameter) == .pointer) &source else source) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    result.identities.appendSliceAssumeCapacity(copied.identities);
    result.import_names.appendSliceAssumeCapacity(copied.import_names);
    result.specifiers.appendSliceAssumeCapacity(copied.specifiers);
    result.type_ids.appendSliceAssumeCapacity(copied.type_ids);
    result.type_names.appendSliceAssumeCapacity(copied.type_names);
    result.type_namespaces.appendSliceAssumeCapacity(copied.type_namespaces);
    allocator.free(copied.identities);
    allocator.free(copied.import_names);
    allocator.free(copied.specifiers);
    allocator.free(copied.type_ids);
    allocator.free(copied.type_names);
    allocator.free(copied.type_namespaces);

    return result;
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
