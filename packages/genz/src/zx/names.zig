const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Names = @import("modules.zig").Names;
pub const Error = std.mem.Allocator.Error || error{ MissingNominalOrigin, InvalidNominalOrigin };
pub const Capabilities = struct { io: []const bool, process: []const bool };

pub fn create(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, origins: anytype) Error!Names {
    return createWith(allocator, workspace, program, origins, null);
}

pub fn createWith(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, origins: anytype, known: ?Capabilities) Error!Names {
    if (!@import("genz_options").generated_analysis) return @import("names/seed.zig").createWith(allocator, program, origins, known);

    const generated = @import("generated_stable_names");
    const Input = std.meta.Child(generated.Input);
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const tables = TypeInputs(Input).borrow(&program, origins);
    const functions = zx.columns.view(std.meta.Child(@FieldType(Input, "functions")), &program.functions);

    const input = Input{
        .types = &tables.types,
        .functions = &functions,
        .modules = &tables.modules,
        .origins = &tables.origins,
        .files = program.functions.files,
        .native_members = program.functions.native_members,
        .native_exports = program.functions.native_exports,
        .known = known != null,
        .io = if (known) |facts| facts.io else &.{},
        .process = if (known) |facts| facts.process else &.{},
    };

    const output = generated.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    try check(output.status);

    const type_names = try own(allocator, output.types);

    errdefer release(allocator, type_names);

    return .{ .types = type_names, .functions = try own(allocator, output.functions) };
}

pub fn createTypes(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: *const ir.Program, origins: anytype) Error![]const []const u8 {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    return own(allocator, try typeNamesIn(scratch.allocator(), program, origins));
}

pub fn typeNamesIn(scratch: std.mem.Allocator, program: *const ir.Program, origins: anytype) Error![]const []const u8 {
    if (!@import("genz_options").generated_analysis) return @import("names/seed.zig").typeNamesIn(scratch, program.*, origins);

    const entry = @import("generated_stable_type_names");
    const Input = std.meta.Child(entry.Input);
    const tables = TypeInputs(Input).borrow(program, origins);
    const input: Input = .{ .types = &tables.types, .modules = &tables.modules, .origins = &tables.origins };

    const result = entry.executeIn(scratch, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    try check(result.status);

    return result.types;
}

fn TypeInputs(comptime Input: type) type {
    return struct {
        types: std.meta.Child(@FieldType(Input, "types")),
        modules: std.meta.Child(@FieldType(Input, "modules")),
        origins: std.meta.Child(@FieldType(Input, "origins")),
        fn borrow(program: *const ir.Program, origins: anytype) @This() {
            return .{
                .types = ir.TypeTable.borrow(@FieldType(@This(), "types"), program.types),
                .modules = zx.columns.view(@FieldType(@This(), "modules"), &program.native_modules),
                .origins = zx.columns.view(@FieldType(@This(), "origins"), origins),
            };
        }
    };
}

fn check(status: anytype) Error!void {
    switch (status) {
        .InvalidOrigin => return error.InvalidNominalOrigin,
        .MissingOrigin => return error.MissingNominalOrigin,
        .Valid => {},
    }
}

fn own(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;

    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);

        allocator.free(result);
    }

    for (values, result) |value, *target| {
        target.* = try allocator.dupe(u8, value);
        initialized += 1;
    }

    return result;
}

fn release(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);

    allocator.free(values);
}
