const std = @import("std");
const zx = @import("zx");
const Unit = @import("genz").zx.modules.FunctionUnit;
const File = @import("modules.zig").File;
const registration = @import("generated_function_files_register");
pub const Error = std.mem.Allocator.Error || error{ConflictingFunction};

pub fn create(owned: std.mem.Allocator, backing: std.mem.Allocator, functions: *const zx.ir.FunctionTable, names: []const []const u8, units: []const Unit, sources: []const []const u8, native_names: []const []const u8, initializers: []const File) Error![]const File {
    if (units.len == 0) return initializers;

    const minimum = std.math.mul(usize, units.len, 2) catch return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, minimum) catch return error.OutOfMemory;
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const Input = std.meta.Child(registration.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const ids = zx.memory.borrowReadColumn(zx.ir.FunctionId, "id", units);
    const initializer_names = zx.memory.borrowTextColumn("name", initializers);
    const initializer_sources = zx.memory.borrowTextColumn("source", initializers);
    const initializer_imports = zx.memory.borrowReadColumn([]const []const u8, "imports", initializers);

    const input: Input = .{
        .registry = &.{ .keys = names, .ids = @ptrCast(&ids), .sources = sources, .capacity = capacity },
        .functions = &.{
            .expressions = zx.columns.slice(@FieldType(Functions, "expressions"), functions.expressions),
            .contracts = zx.columns.slice(@FieldType(Functions, "contracts"), functions.contracts),
        },
        .names = names,
        .initializers = &.{ .names = @ptrCast(&initializer_names), .sources = @ptrCast(&initializer_sources), .imports = @ptrCast(&initializer_imports), .count = initializers.len },
        .native_ids = functions.native_modules,
        .native_names = native_names,
    };

    const result = zx.columns.invoke(registration.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!result.valid) return error.ConflictingFunction;

    const output = try owned.alloc(File, result.files.len);

    for (result.files, 0..) |item, i| {
        output[i] = .{
            .name = item.name,
            .source = item.source,
            .imports = if (item.imports.len == 0) &.{} else try owned.dupe([]const u8, item.imports),
        };
    }

    return output;
}
