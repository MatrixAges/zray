const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const abi = @import("function_analysis/abi.zig");
const seed = @import("references/seed.zig");

comptime {
    std.debug.assert(@typeInfo(ir.FunctionId).@"enum".tag_type == u32);
}

pub fn reachable(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program) std.mem.Allocator.Error![]const bool {
    return discover(allocator, workspace, program.functions, &.{&program}, &.{});
}

pub fn discover(allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: ir.FunctionTable, roots: []const *const ir.Program, members: []const ir.FunctionId) std.mem.Allocator.Error![]const bool {
    return (try plan(allocator, workspace, functions, roots, members)).needed;
}

pub const Reachability = struct { needed: []const bool, count: usize };

pub fn plan(allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: ir.FunctionTable, roots: []const *const ir.Program, members: []const ir.FunctionId) std.mem.Allocator.Error!Reachability {
    const needed = try allocator.alloc(bool, functions.count());

    errdefer allocator.free(needed);

    if (!@import("genz_options").generated_analysis) {
        @memset(needed, false);
        for (roots) |program| seed.markRoot(needed, program.*);
        for (members) |id| needed[@backingInt(id)] = true;

        seed.close(needed, functions);

        return .{ .needed = needed, .count = std.mem.countScalar(bool, needed, true) };
    }

    const generated = @import("generated_reference_graph");
    const Input = std.meta.Child(generated.Input);
    const Functions = std.meta.Child(@FieldType(Input, "functions"));
    const Bodies = abi.List(@FieldType(Input, "roots"));
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const bodies = try Bodies.init(temporary, roots.len);

    for (bodies.values, roots) |*body, program| body.* = .{
        .expressions = zx.columns.pointer(@FieldType(Bodies.Value, "expressions"), &program.expressions),
        .contracts = zx.columns.pointer(@FieldType(Bodies.Value, "contracts"), &program.contracts),
    };

    const table = Functions{
        .expressions = zx.columns.slice(@FieldType(Functions, "expressions"), functions.expressions),
        .contracts = zx.columns.slice(@FieldType(Functions, "contracts"), functions.contracts),
    };

    comptime std.debug.assert(@sizeOf(bool) == 1);

    const flags = std.mem.sliceAsBytes(needed);

    const input = Input{
        .needed = @ptrCast(&flags),
        .functions = &table,
        .roots = try bodies.finish(temporary),
        .members = @as([*]const u32, @ptrCast(members.ptr))[0..members.len],
    };

    const count = zx.columns.invoke(generated.executeValue, temporary, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{ .needed = needed, .count = @intCast(count) };
}

pub fn imports(allocator: std.mem.Allocator, workspace: std.mem.Allocator, expressions: ir.ExpressionTable, contracts: ir.ContractTable, names: []const []const u8, members: []const ir.FunctionId) std.mem.Allocator.Error![]const []const u8 {
    if (!@import("genz_options").generated_analysis) return seed.importsWithMembers(allocator, expressions, contracts, names, members);

    return importsBorrowed(allocator, workspace, &expressions, &contracts, names, members, null);
}

/// The import names are owned by the same bundle as the returned slice.
pub fn fileImports(allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: *const ir.FunctionTable, index: usize, names: []const []const u8, native_names: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const native = if (functions.native_modules[index]) |id| native_names[id] else null;
    const expressions = functions.expressions[index];
    const contracts = functions.contracts[index];

    if (comptime !@import("genz_options").generated_analysis) {
        if (native) |name| return allocator.dupe([]const u8, &.{name});

        return seed.importsWithMembers(allocator, expressions.*, contracts.*, names, &.{});
    }

    return importsBorrowed(allocator, workspace, expressions, contracts, names, &.{}, native);
}

fn importsBorrowed(allocator: std.mem.Allocator, workspace: std.mem.Allocator, expressions: *const ir.ExpressionTable, contracts: *const ir.ContractTable, names: []const []const u8, members: []const ir.FunctionId, native: ?[]const u8) std.mem.Allocator.Error![]const []const u8 {
    const generated = @import("generated_reference_imports");
    const Input = std.meta.Child(generated.Input);
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();

    const input = Input{
        .expressions = zx.columns.pointer(@FieldType(Input, "expressions"), expressions),
        .contracts = zx.columns.pointer(@FieldType(Input, "contracts"), contracts),
        .names = names,
        .members = @as([*]const u32, @ptrCast(members.ptr))[0..members.len],
        .native = native,
        .destination = null,
    };

    const output = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return allocator.dupe([]const u8, output);
}
