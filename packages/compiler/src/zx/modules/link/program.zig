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

pub const Form = enum { Program, AnalyzedBody };

pub const Extension = struct {
    types: usize,
    base: usize,
    total: usize,
    tail: *const ir.FunctionTable,
    type_suffix: ?ir.TypeTable = null,
};

pub fn append(input: Input, destination: Destination) Error!Nodes {
    return merge(.Program, &input.program, input.nominal_types, &destination, {});
}

pub fn appendAnalyzed(program: *const ir.Program, origins: Origins.Table, destination: *const Destination, extension: *const Extension) Error!Nodes {
    return merge(.AnalyzedBody, program, origins, destination, extension);
}

fn merge(comptime form: Form, program: *const ir.Program, origins: Origins.Table, destination: *const Destination, extension: if (form == .AnalyzedBody) *const Extension else void) Error!Nodes {
    if (comptime @import("parser_options").generated_parser) return @import("source/workflow/host.zig").merge(form, program, origins, destination, extension);

    const temporary = destination.temporary;
    const complete = form == .Program;

    if (complete and try @import("../../ir/validate.zig").validate(temporary, program.*) != null) return error.InvalidIr;

    const types = if (complete)
        try destination.types.appendFrom(temporary, program.types, origins, 0)
    else
        try destination.types.appendAnalyzed(temporary, temporary, program.types, origins, extension.types);

    const count = if (complete) program.functions.count() else extension.total;
    const base = if (complete) 0 else extension.base;
    const range = try @import("function_table.zig").range(destination.functions.count(), count, base, program.types.count(), program.native_modules.count());
    const natives: []?ir.NativeModuleId = if (complete) try temporary.alloc(?ir.NativeModuleId, range.native_modules) else &.{};

    var nodes: Nodes = .{
        .allocator = destination.allocator,
        .types = .{ .mapped = types },
        .functions = .{ .range = .{ .first = range.first, .count = range.count, .prefix = range.prefix } },
        .native_modules = if (complete) .{ .indexed = natives } else .{ .range = .{ .first = 0, .count = range.native_modules } },
    };

    if (complete) try native.link(temporary, destination.native_modules, program.native_modules, natives, &nodes);
    try nodes.appendFunctions(destination.functions, if (complete) program.functions else extension.tail.*, temporary);

    return nodes;
}
