const std = @import("std");
const ir = @import("zx").ir;
const program_link = @import("program.zig");
const Origins = @import("../nominal_origins.zig");
const Nodes = @import("../artifact/nodes.zig");
const Initializer = @import("../compiled.zig").StoreInitializer;
const function_body = @import("../function_body.zig");
const generated = @import("parser_options").generated_parser;
const steps = @import("source/steps.zig");
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

    var tail: ir.FunctionTable = undefined;
    var count: usize = undefined;
    var type_prefix: usize = undefined;
    var mapping: []const ir.TypeId = undefined;
    var nodes: Nodes = undefined;
    const temporary = scratch.allocator();

    inline for (comptime steps.run(.Body)) |step| {
        switch (step) {
            .CheckViews => {
                const shared = if (input.base_types == null) sameView(base, destination.functions.view()) else base.count() <= destination.functions.count();

                if (!shared or !sameView(program.native_modules, destination.native_modules.view())) return error.InvalidModule;
            },
            .SelectSuffix => {
                tail = table.appendTail(program.functions, base, if (input.function_suffix) |*suffix| suffix else null) orelse return error.InvalidModule;
                count = std.math.add(usize, base.count(), tail.count()) catch return error.OutOfMemory;
            },
            .VerifyIr => if (comptime checks.internal) {
                var checked = program.*;

                if (input.function_suffix != null) checked.functions = try table.join(temporary, base, tail);
                if (try checks.validateExtending(temporary, checked, input.verified_functions) != null) return error.InvalidIr;
            },
            .MergeTypes => {
                type_prefix = input.base_types orelse destination.types.items.count();
                mapping = try destination.types.appendAnalyzed(temporary, temporary, program.types, input.nominal_types, type_prefix);
            },
            .AppendFunctions => {
                const range = try table.range(destination.functions.count(), count, base.count(), program.types.count(), program.native_modules.count());

                nodes = .{
                    .allocator = destination.allocator,
                    .types = .{ .mapped = mapping },
                    .functions = .{ .range = .{ .first = range.first, .count = range.count, .prefix = range.prefix } },
                    .native_modules = .{ .range = .{ .first = 0, .count = range.native_modules } },
                };

                try nodes.appendFunctions(destination.functions, tail, temporary);
            },
            .FinishBody => return finish(&input, destination, &nodes, function_body.ownTail(program.*, tail, base.count()), type_prefix),
            else => unreachable,
        }
    }

    unreachable;
}

fn finish(input: *const Input, destination: program_link.Destination, nodes: *Nodes, own: ?ir.FunctionId, type_prefix: usize) program_link.Error!Loaded {
    const program = &input.program;
    var result: Loaded = undefined;

    inline for (comptime steps.run(.Surface)) |step| {
        switch (step) {
            .PublishEntry => {
                result.function = if (own) |id| try nodes.functionId(id) else if (program.type_only) null else append: {
                    const id: ir.FunctionId = @fromBackingInt(@intCast(destination.functions.count()));

                    try nodes.appendFunction(destination.functions, &function_body.value(program.*));

                    break :append id;
                };
            },
            .PublishDeclarations => {
                const stable = if (input.owned_declarations) type_prefix else 0;

                result.exports, result.constant_exports = try publishDeclarations(nodes, program, stable);
            },
            .PublishInitializers => {
                result.store_initializers = try @import("source/initializers.zig").link(nodes, input.store_initializers, input.shared_initializers);
            },
            .PublishMembers => {
                const surface = try @import("source/members.zig").link(nodes, input.members, result.function);
                result.function = surface.entry;
                result.members = surface.members;
            },
            .ResolvePorts => if (result.function) |id| {
                const row = @backingInt(id);

                result.input_type = @fromBackingInt(destination.functions.input_types.items[row]);
                result.output_type = @fromBackingInt(destination.functions.output_types.items[row]);
            } else {
                result.input_type = try nodes.types.include(program.input_type);
                result.output_type = try nodes.types.include(program.output_type);
            },
            else => unreachable,
        }
    }

    return result;
}

fn publishDeclarations(nodes: *Nodes, program: *const ir.Program, type_prefix: usize) program_link.Error!struct { []const ir.Export, []const ir.Constant } {
    const allocator = nodes.allocator;

    if (comptime generated) {
        const surface = @import("../artifact/surface.zig");
        const types = @import("../artifact/nodes/remap.zig").typeMapping(surface.Mapping, nodes.types);
        const prefix = @import("source/declarations.zig");

        return .{
            if (prefix.contains(program.exports, type_prefix)) program.exports else try surface.copyExports(allocator, program.exports, &types),
            if (prefix.contains(program.constant_exports, type_prefix)) program.constant_exports else try surface.copyConstants(allocator, program.constant_exports, &types),
        };
    }

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
