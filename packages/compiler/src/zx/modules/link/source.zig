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
    const own = if (extended) function_body.own(input.program) else null;

    return finish(&input, destination, &nodes, own, 0);
}

pub fn appendBody(input: Input, destination: program_link.Destination) program_link.Error!Loaded {
    const program = &input.program;
    const base = input.base_functions orelse program.functions;
    var scratch = std.heap.ArenaAllocator.init(destination.temporary);

    defer scratch.deinit();

    const shared = if (input.base_types == null) sameView(base, destination.functions.view()) else base.count() <= destination.functions.count();

    if (!shared or !sameView(program.native_modules, destination.native_modules.view())) return error.InvalidModule;

    const tail = table.appendTail(program.functions, base, if (input.function_suffix) |*suffix| suffix else null) orelse return error.InvalidModule;
    const count = std.math.add(usize, base.count(), tail.count()) catch return error.OutOfMemory;
    const temporary = scratch.allocator();

    if (comptime checks.internal) {
        var checked = program.*;

        if (input.function_suffix != null) checked.functions = try table.join(temporary, base, tail);
        if (try checks.validateExtending(temporary, checked, input.verified_functions) != null) return error.InvalidIr;
    }

    const type_prefix = input.base_types orelse destination.types.items.count();
    var workspace = destination;
    workspace.temporary = temporary;

    var nodes = try program_link.appendAnalyzed(program, input.nominal_types, &workspace, &.{
        .types = type_prefix,
        .base = base.count(),
        .total = count,
        .tail = &tail,
    });

    return finish(&input, destination, &nodes, function_body.ownTail(program.*, tail, base.count()), type_prefix);
}

fn finish(input: *const Input, destination: program_link.Destination, nodes: *Nodes, own: ?ir.FunctionId, type_prefix: usize) program_link.Error!Loaded {
    const program = &input.program;
    const entry = try publishEntry(program, destination.functions, nodes, own, destination.temporary);
    var result: Loaded = undefined;

    if (comptime generated) {
        try @import("source/surface/host.zig").publish(input, destination.functions, nodes, entry, type_prefix, &result);
    } else {
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

fn publishEntry(program: *const ir.Program, storage: *ir.FunctionStorage, nodes: *Nodes, own: ?ir.FunctionId, temporary: std.mem.Allocator) program_link.Error!?ir.FunctionId {
    if (comptime generated) {
        const rule = @import("generated_source_link_entry");
        const EntryInput = std.meta.Child(rule.Input);
        const Mapping = std.meta.Child(@FieldType(EntryInput, "functions"));
        const functions = @import("../artifact/nodes/remap.zig").idMapping(Mapping, nodes.functions);

        const input: EntryInput = .{
            .own = if (own) |id| @backingInt(id) else null,
            .type_only = program.type_only,
            .next = storage.count(),
            .functions = &functions,
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        const output = @import("zx").columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        if (output.append) try nodes.appendFunction(storage, &function_body.value(program.*), temporary);

        return if (output.function) |id| @fromBackingInt(id) else null;
    }

    if (own) |id| return try nodes.functionId(id);
    if (program.type_only) return null;

    const id: ir.FunctionId = @fromBackingInt(@intCast(storage.count()));

    try nodes.appendFunction(storage, &function_body.value(program.*), temporary);

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

fn sameView(left: anytype, right: @TypeOf(left)) bool {
    inline for (@typeInfo(@TypeOf(left)).@"struct".field_names) |name| {
        const a = @field(left, name);
        const b = @field(right, name);

        if (a.len != b.len or (a.len != 0 and a.ptr != b.ptr)) return false;
    }

    return true;
}
