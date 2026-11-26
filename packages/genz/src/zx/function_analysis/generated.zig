const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const generated = @import("generated_function_facts");
const Input = std.meta.Child(generated.Input);
const Program = std.meta.Child(@FieldType(Input, "program"));
const Functions = std.meta.Child(@FieldType(Program, "functions"));
const Errors = std.meta.Child(@FieldType(Input, "errors"));
const Boundaries = std.meta.Child(@FieldType(Input, "boundaries"));

pub const Facts = struct {
    value: @import("../value_call/analysis.zig").Summary,
    io: []const bool,
    process: []const bool,
    tasks: []const bool,
    fresh_outputs: []const bool,
    constructed_outputs: []const bool,
    identity_free: []const bool,
    errors: []const ?[]const []const u8,
    return_allocations: []const bool,
    layout_types: []const @import("../iteration_layout/generated.zig").Type,
    grows: []const bool,
};

/// Borrowed program views remain available until the analyzed result has been published.
pub fn analyze(allocator: std.mem.Allocator, workspace: std.mem.Allocator, program: ir.Program, exported: []const ir.FunctionId) std.mem.Allocator.Error!Facts {
    var scratch = std.heap.ArenaAllocator.init(workspace);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const sources = try @import("error_sources.zig").collect(temporary, program.types, program.functions);

    defer sources.deinit();

    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Program, "types")), program.types);
    var functions: Functions = undefined;

    inline for (@typeInfo(Functions).@"struct".field_names) |name| {
        @field(functions, name) = columns.slice(@FieldType(Functions, name), @field(program.functions, name));
    }

    const view = Program{
        .types = &types,
        .symbols = columns.pointer(@FieldType(Program, "symbols"), &program.symbols),
        .functions = &functions,
        .stores = columns.pointer(@FieldType(Program, "stores"), &program.stores),
        .expressions = columns.pointer(@FieldType(Program, "expressions"), &program.expressions),
        .contracts = columns.pointer(@FieldType(Program, "contracts"), &program.contracts),
        .control = columns.pointer(@FieldType(Program, "control"), program.body.control),
        .root = if (program.body.root) |root| @backingInt(root) else null,
        .output_type = @backingInt(program.output_type),
    };

    const error_sources: Errors = .{
        .names = sources.columns.names,
        .unknown = sources.columns.unknown,
        .callees = sources.columns.callees,
    };

    comptime std.debug.assert(@typeInfo(ir.FunctionId).@"enum".tag_type == u32);

    const boundaries: Boundaries = .{
        .input_type = @backingInt(program.input_type),
        .output_type = @backingInt(program.output_type),
        .exported = @ptrCast(exported),
    };

    const Allocators = std.meta.Child(@FieldType(Input, "allocators"));

    const allocators: Allocators = .{
        .owned = @ptrCast(&allocator),
        .names = @ptrCast(&allocator),
    };

    const input: Input = .{
        .program = &view,
        .errors = &error_sources,
        .boundaries = &boundaries,
        .allocators = &allocators,
    };

    const output = generated.executeIn(temporary, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .value = .{
            .pure = output.pure,
            .local = output.local,
            .values = output.values,
            .state = .{
                .element_storage = output.element_storage,
                .selected = output.selected,
                .borrowed = output.borrowed,
                .queries = try allocator.dupe(std.meta.Elem(@TypeOf(output.state_queries)), output.state_queries),
                .keys = std.mem.bytesAsSlice([32]u8, output.keys),
            },
        },
        .io = output.io,
        .process = output.process,
        .tasks = output.tasks,
        .grows = output.grows,
        .fresh_outputs = output.fresh_outputs,
        .constructed_outputs = output.constructed_outputs,
        .identity_free = output.identity_free,
        .errors = try allocator.dupe(std.meta.Elem(@TypeOf(output.errors)), output.errors),
        .return_allocations = try allocator.dupe(bool, output.return_allocations),
        .layout_types = try allocator.dupe(std.meta.Elem(@TypeOf(output.layout_types)), output.layout_types),
    };
}
