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
    /// Newly analyzed functions with absolute IDs following the borrowed base.
    function_suffix: ?ir.FunctionTable = null,
    nominal_types: Origins.Table,
    store_initializers: []const Initializer = &.{},
    members: []const @import("../function_import.zig") = &.{},
    /// The declaration rows and their text already live in the result or retained signature arena.
    owned_declarations: bool = false,
    type_suffix: ?ir.TypeTable = null,
};

pub const Surface = struct {
    input_type: ir.TypeId,
    output_type: ir.TypeId,
    exports: []const ir.Export,
    constant_exports: []const ir.Constant = &.{},
    store_initializers: []const Initializer,
    members: []const @import("../function_import.zig") = &.{},
};

pub const Output = struct {
    surface: *Surface,
    function: *?u32,
};

pub const Loaded = struct {
    surface: Surface,
    function: ?u32,
    pub fn destination(self: *Loaded) Output {
        return .{ .surface = &self.surface, .function = &self.function };
    }
};

pub const Body = struct {
    input: *const Input,
    destination: program_link.Destination,
    output: Output,
    prefix: usize,
    verified: usize,
    shared_initializers: []const Initializer,
    pub fn link(self: *const Body, replace_prefix: bool, type_prefix: ?usize, values: []const Initializer) std.mem.Allocator.Error!?usize {
        appendBody(self, replace_prefix, type_prefix, values) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return null;
        };

        return self.destination.functions.count();
    }
};

fn appendBody(body: *const Body, replace_prefix: bool, type_prefix: ?usize, values: []const Initializer) program_link.Error!void {
    const input = body.input;
    const destination = body.destination;
    const program = &input.program;
    const shared = destination.functions.view();
    const base = shared.prefix(body.prefix);
    const functions = if (replace_prefix) base else program.functions;
    var scratch = std.heap.ArenaAllocator.init(destination.temporary);

    defer scratch.deinit();

    const extension = try table.extend(functions, base, if (input.function_suffix) |*suffix| suffix else null, .{
        .functions = destination.functions,
        .natives = destination.native_modules,
        .source_natives = program.native_modules,
        .type_count = destination.types.items.count(),
        .base_types = type_prefix,
    });

    const tail = extension.tail;
    const temporary = scratch.allocator();

    if (comptime checks.internal) {
        var checked = program.*;

        checked.functions = if (input.function_suffix != null) try table.join(temporary, base, tail) else functions;

        if (try checks.validateExtending(temporary, checked, shared.prefix(body.verified)) != null) return error.InvalidIr;
    }

    var workspace = destination;

    workspace.temporary = temporary;

    var nodes = try program_link.appendAnalyzed(program, input.nominal_types, &workspace, &.{
        .types = extension.types,
        .base = base.count(),
        .total = @intCast(extension.total),
        .tail = &tail,
        .type_suffix = input.type_suffix,
    });

    try finish(body, &nodes, &tail, extension.types, values);
}

fn finish(body: *const Body, nodes: *Nodes, tail: *const ir.FunctionTable, type_prefix: usize, values: []const Initializer) program_link.Error!void {
    const input = body.input;
    const output = body.output;
    const program = &input.program;
    const functions = body.destination.functions;

    if (comptime generated) {
        try @import("source/surface/host.zig").publish(body, nodes, tail, type_prefix, values);
    } else {
        const own = function_body.ownTail(program.*, tail.*, body.prefix);
        const entry = try publishSeedEntry(program, functions, nodes, own);
        const result = output.surface;

        result.exports, result.constant_exports = try publishSeedDeclarations(nodes, program);
        result.store_initializers = try @import("source/initializers.zig").link(nodes, values, body.shared_initializers);
        const surface = try @import("source/members.zig").link(nodes, input.members, entry);
        result.members = surface.members;
        output.function.* = if (surface.entry) |id| @backingInt(id) else null;

        if (surface.entry) |id| {
            const row = @backingInt(id);

            result.input_type = @fromBackingInt(functions.input_types.items[row]);
            result.output_type = @fromBackingInt(functions.output_types.items[row]);
        } else {
            result.input_type = try nodes.types.include(program.input_type);
            result.output_type = try nodes.types.include(program.output_type);
        }
    }
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
