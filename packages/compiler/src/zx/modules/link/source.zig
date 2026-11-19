const std = @import("std");
const ir = @import("zx").ir;
const program_link = @import("program.zig");
const Origins = @import("../nominal_origins.zig");
const Nodes = @import("../artifact/nodes.zig");
const Initializer = @import("../compiled.zig").StoreInitializer;
const function_body = @import("../function_body.zig");
const generated = @import("parser_options").generated_parser;
const table = @import("function_table.zig");
const checks = @import("../../ir/validate.zig");

pub const Input = struct {
    program: ir.Program,
    base_functions: ?ir.FunctionTable = null,
    /// Newly analyzed functions with absolute IDs following the borrowed base.
    function_suffix: ?ir.FunctionTable = null,
    verified_functions: ir.FunctionTable = .{},
    nominal_types: Origins.Table,
    store_initializers: []const Initializer = &.{},
    shared_initializers: []const Initializer = &.{},
    members: []const @import("../function_import.zig") = &.{},
    /// The declaration rows and their text already live in the result or retained signature arena.
    owned_declarations: bool = false,
    /// The length of the shared type table the body was analyzed against, when the tables grew since; its base
    /// functions are then a prefix of the shared ones rather than all of them.
    base_types: ?usize = null,
};

pub const Loaded = struct {
    function: ?ir.FunctionId,
    input_type: ir.TypeId,
    output_type: ir.TypeId,
    exports: []const ir.Export,
    constant_exports: []const ir.Constant = &.{},
    store_initializers: []const Initializer,
    members: []const @import("../function_import.zig") = &.{},
};

pub fn append(input: Input, destination: program_link.Destination) program_link.Error!Loaded {
    if (input.function_suffix != null) return error.InvalidModule;

    var nodes = try program_link.append(.{ .program = input.program, .nominal_types = input.nominal_types }, destination);
    const extended = if (input.base_functions) |base| input.program.functions.count() > base.count() else true;
    const tail = if (extended) &input.program.functions else &ir.FunctionTable{};

    return finish(&input, destination, &nodes, tail, 0, 0);
}

pub fn appendBody(input: Input, destination: program_link.Destination) program_link.Error!Loaded {
    const program = &input.program;
    const base = input.base_functions orelse program.functions;
    var scratch = std.heap.ArenaAllocator.init(destination.temporary);

    defer scratch.deinit();

    const extension = try table.extend(program.functions, base, if (input.function_suffix) |*suffix| suffix else null, .{
        .functions = destination.functions,
        .natives = destination.native_modules,
        .source_natives = program.native_modules,
        .type_count = destination.types.items.count(),
        .base_types = input.base_types,
    });

    const tail = extension.tail;
    const temporary = scratch.allocator();

    if (comptime checks.internal) {
        var checked = program.*;

        if (input.function_suffix != null) checked.functions = try table.join(temporary, base, tail);
        if (try checks.validateExtending(temporary, checked, input.verified_functions) != null) return error.InvalidIr;
    }

    const type_prefix = extension.types;
    var workspace = destination;
    workspace.temporary = temporary;

    var nodes = try program_link.appendAnalyzed(program, input.nominal_types, &workspace, &.{
        .types = type_prefix,
        .base = base.count(),
        .total = @intCast(extension.total),
        .tail = &tail,
    });

    return finish(&input, destination, &nodes, &tail, base.count(), type_prefix);
}

fn finish(input: *const Input, destination: program_link.Destination, nodes: *Nodes, tail: *const ir.FunctionTable, first: usize, type_prefix: usize) program_link.Error!Loaded {
    const program = &input.program;
    var result: Loaded = undefined;

    if (comptime generated) {
        const entry = try @import("source/entry/host.zig").publish(program, tail, first, destination.functions, nodes, destination.temporary);

        try @import("source/surface/host.zig").publish(input, destination.functions, nodes, entry, type_prefix, &result);
    } else {
        const own = function_body.ownTail(program.*, tail.*, first);
        const entry = try publishSeedEntry(program, destination.functions, nodes, own);
        result.exports, result.constant_exports = try publishSeedDeclarations(nodes, program);
        result.store_initializers = try @import("source/initializers.zig").link(nodes, input.store_initializers, input.shared_initializers);
        const surface = try @import("source/members.zig").link(nodes, input.members, entry);
        result.function = surface.entry;
        result.members = surface.members;

        if (result.function) |id| {
            const row = @backingInt(id);

            result.input_type = @fromBackingInt(destination.functions.input_types.items[row]);
            result.output_type = @fromBackingInt(destination.functions.output_types.items[row]);
        } else {
            result.input_type = try nodes.types.include(program.input_type);
            result.output_type = try nodes.types.include(program.output_type);
        }
    }

    return result;
}

fn publishSeedEntry(program: *const ir.Program, storage: *ir.FunctionStorage, nodes: *Nodes, own: ?ir.FunctionId) program_link.Error!?ir.FunctionId {
    if (own) |id| return try nodes.functionId(id);
    if (program.type_only) return null;

    const id: ir.FunctionId = @fromBackingInt(@intCast(storage.count()));

    try storage.append(nodes.allocator, try nodes.function(function_body.value(program.*)));

    return id;
}

fn publishSeedDeclarations(nodes: *Nodes, program: *const ir.Program) program_link.Error!struct { []const ir.Export, []const ir.Constant } {
    const allocator = nodes.allocator;
    const aliases = try allocator.alloc(ir.Export, program.exports.len);

    for (program.exports, aliases) |source, *exported| {
        exported.* = .{ .name = try allocator.dupe(u8, source.name), .type_id = try nodes.types.include(source.type_id) };
    }

    return .{ aliases, try nodes.constants(program.constant_exports) };
}
