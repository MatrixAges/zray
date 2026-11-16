const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const columns = zx.columns;
const generated = @import("generated_function_facts");
const error_publication = @import("generated_function_facts_errors");
const Input = std.meta.Child(generated.Input);
const Program = std.meta.Child(@FieldType(Input, "program"));
const Functions = std.meta.Child(@FieldType(Program, "functions"));
const Errors = std.meta.Child(@FieldType(Input, "errors"));
const Boundaries = std.meta.Child(@FieldType(Input, "boundaries"));

pub const Facts = struct {
    value: @import("../value_call/analysis.zig").Summary,
    io: []bool,
    process: []bool,
    tasks: []bool,
    fresh_outputs: []bool,
    constructed_outputs: []bool,
    identity_free: []bool,
    errors: []const ?[]const []const u8,
    layout_types: []const @import("../iteration_layout/generated.zig").Type,
    grows: []const bool,
};

/// Borrows the program columns for the generated facts and copies the results into the caller allocator.
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

    const input = Input{ .program = &view, .errors = &error_sources, .boundaries = &boundaries };

    const output = generated.execute(&scratch, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const grouped = try temporary.alloc([]const []const u8, output.errors.names.len);

    for (grouped, output.errors.names) |*target, source| target.* = try allocator.dupe([]const u8, source);

    const errors = columns.invoke(error_publication.executeValue, allocator, &.{
        .components = output.errors.components,
        .names = @as([]const []const []const u8, grouped),
        .unknown = output.errors.unknown,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .value = .{
            .pure = try allocator.dupe(bool, output.pure),
            .local = try allocator.dupe(bool, output.local),
            .values = try allocator.dupe(bool, output.values),
            .state = .{
                .element_storage = try allocator.dupe(bool, output.element_storage),
                .selected = try allocator.dupe(bool, output.selected),
                .borrowed = try allocator.dupe(bool, output.borrowed),
                .queries = try allocator.dupe(@import("../state_value/queries.zig").Kind, output.state_queries),
                .keys = try allocator.dupe([32]u8, std.mem.bytesAsSlice([32]u8, output.keys)),
            },
        },
        .io = try allocator.dupe(bool, output.io),
        .process = try allocator.dupe(bool, output.process),
        .tasks = try allocator.dupe(bool, output.tasks),
        .grows = try allocator.dupe(bool, output.grows),
        .fresh_outputs = try allocator.dupe(bool, output.fresh_outputs),
        .constructed_outputs = try allocator.dupe(bool, output.constructed_outputs),
        .identity_free = try allocator.dupe(bool, output.identity_free),
        .errors = errors,
        .layout_types = try allocator.dupe(@import("../iteration_layout/generated.zig").Type, output.layout_types),
    };
}
