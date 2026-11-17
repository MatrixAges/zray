const std = @import("std");
const ir = @import("zx").ir;
const Types = @import("types.zig");
const Origins = @import("../nominal_origins.zig");
const Nodes = @import("../artifact/nodes.zig");
const native = @import("native.zig");
pub const Error = Types.Error || @import("../artifact/model.zig").Error || error{ConflictingInterface};

pub const Input = struct {
    program: ir.Program,
    nominal_types: Origins.Table,
};

pub const Destination = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    types: *Types,
    functions: *ir.FunctionStorage,
    native_modules: *ir.NativeModuleStorage,
};

pub fn append(input: Input, destination: Destination) Error!Nodes {
    const program = input.program;
    const allocator = destination.allocator;
    const temporary = destination.temporary;

    if (try @import("../../ir/validate.zig").validate(temporary, program) != null) return error.InvalidIr;

    const type_mapping = try destination.types.appendFrom(temporary, program.types, input.nominal_types, 0);
    const range = try @import("function_table.zig").range(destination.functions.count(), program.functions.count(), 0, program.types.count(), program.native_modules.count());
    const native_mapping = try temporary.alloc(?ir.NativeModuleId, program.native_modules.count());

    var nodes = Nodes{
        .allocator = allocator,
        .types = .{ .mapped = type_mapping },
        .functions = .{ .range = .{ .first = range.first, .count = range.count } },
        .native_modules = .{ .indexed = native_mapping },
    };

    try native.link(temporary, destination.native_modules, program.native_modules, native_mapping, &nodes);
    try nodes.appendFunctions(destination.functions, program.functions, temporary);

    return nodes;
}
