const std = @import("std");
const ir = @import("zx").ir;
const program_link = @import("program.zig");
const Origins = @import("../nominal_origins.zig");
const Nodes = @import("../artifact/nodes.zig");
const Initializer = @import("../compiled.zig").StoreInitializer;
const function_body = @import("../function_body.zig");
const generated = @import("parser_options").generated_parser;

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

    return finish(input, destination, &nodes, own);
}

pub fn appendBody(input: Input, destination: program_link.Destination) program_link.Error!Loaded {
    const program = input.program;
    const base = input.base_functions orelse program.functions;
    const shared = if (input.base_types == null) sameView(base, destination.functions.view()) else base.count() <= destination.functions.count();

    if (!shared or !sameView(program.native_modules, destination.native_modules.view())) return error.InvalidModule;

    const table = @import("function_table.zig");

    if (!table.hasPrefix(program.functions, base)) return error.InvalidModule;

    const tail = if (input.function_suffix) |suffix| split: {
        if (program.functions.count() != base.count() or !suffix.validStructure()) return error.InvalidModule;

        break :split suffix;
    } else program.functions.suffix(base.count());

    const count = std.math.add(usize, base.count(), tail.count()) catch return error.OutOfMemory;
    const checks = @import("../../ir/validate.zig");

    if (comptime checks.internal) {
        var checked = program;

        if (input.function_suffix != null) checked.functions = try table.join(destination.temporary, base, tail);
        if (try checks.validateExtending(destination.temporary, checked, input.verified_functions) != null) return error.InvalidIr;
    }

    const mapping = try destination.types.appendAnalyzed(destination.temporary, program.types, input.nominal_types, input.base_types orelse destination.types.items.count());
    const range = try table.range(destination.functions.count(), count, base.count(), program.types.count(), program.native_modules.count());

    var nodes = Nodes{
        .allocator = destination.allocator,
        .types = .{ .mapped = mapping },
        .functions = .{ .range = .{ .first = range.first, .count = range.count, .prefix = range.prefix } },
        .native_modules = .{ .range = .{ .first = 0, .count = range.native_modules } },
    };

    try nodes.appendFunctions(destination.functions, tail);

    return finish(input, destination, &nodes, function_body.ownTail(program, tail, base.count()));
}

fn finish(input: Input, destination: program_link.Destination, nodes: *Nodes, own: ?ir.FunctionId) program_link.Error!Loaded {
    const allocator = destination.allocator;
    const program = input.program;
    var function: ?ir.FunctionId = null;

    if (own) |id| {
        function = try nodes.functionId(id);
    } else if (!program.type_only) {
        function = @fromBackingInt(@intCast(destination.functions.count()));

        try nodes.appendFunction(destination.functions, function_body.value(program));
    }

    const exports, const constants = if (comptime generated) source: {
        const surface = @import("../artifact/surface.zig");
        const types = @import("../artifact/nodes/remap.zig").typeMapping(surface.Mapping, nodes.types);

        break :source .{ try surface.copyExports(allocator, program.exports, &types), try surface.copyConstants(allocator, program.constant_exports, &types) };
    } else seed: {
        const aliases = try allocator.alloc(ir.Export, program.exports.len);

        for (program.exports, aliases) |source, *exported| {
            exported.* = .{ .name = try allocator.dupe(u8, source.name), .type_id = try nodes.types.include(source.type_id) };
        }

        break :seed .{ @as([]const ir.Export, aliases), try nodes.constants(program.constant_exports) };
    };

    const initializers = try @import("source/initializers.zig").link(nodes, input.store_initializers, input.shared_initializers);
    const surface = try @import("source/members.zig").link(nodes, input.members, function);
    const entry = if (surface.entry) |id| destination.functions.at(@backingInt(id)) else null;

    return .{
        .function = surface.entry,
        .input_type = if (entry) |value| value.input_type else try nodes.types.include(program.input_type),
        .output_type = if (entry) |value| value.output_type else try nodes.types.include(program.output_type),
        .exports = exports,
        .constant_exports = constants,
        .members = surface.members,
        .store_initializers = initializers,
    };
}

fn sameView(left: anytype, right: @TypeOf(left)) bool {
    inline for (@typeInfo(@TypeOf(left)).@"struct".field_names) |name| {
        const a = @field(left, name);
        const b = @field(right, name);

        if (a.len != b.len or (a.len != 0 and a.ptr != b.ptr)) return false;
    }

    return true;
}
