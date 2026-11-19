const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const model = @import("root.zig");
const artifact = frontend.project.artifact;
const Types = artifact.type_link.Table;
const Initializers = @import("initializers.zig");
pub const Error = Types.Error || artifact.Error || Initializers.Error || @import("validate.zig").Error || error{ ConflictingInterface, InvalidAnalysis, InvalidIr, DuplicateExport, ConflictingStore };

pub fn link(allocator: std.mem.Allocator, inputs: []const model.Input) Error!model.Result {
    if (inputs.len == 0) return error.InvalidModule;

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    const owned = arena.allocator();
    var temporary = std.heap.ArenaAllocator.init(allocator);

    defer temporary.deinit();

    const scratch = temporary.allocator();
    var types = try Types.init(owned);
    var functions: ir.FunctionStorage = .{};
    var native_modules: ir.NativeModuleStorage = .{};
    var initializers = Initializers{ .allocator = owned, .scratch = scratch, .types = &types, .functions = &functions, .registry = .{ .buckets = .{ .allocator = allocator } } };

    defer initializers.registry.deinit();

    const exports = try owned.alloc(model.Export, inputs.len);
    var name_buffer: [1024]u8 = undefined;
    var name_memory = std.heap.BufferFirstAllocator.init(&name_buffer, scratch);
    var names: @import("index.zig") = .{};

    for (inputs, 0..) |input, row| {
        try names.admit(name_memory.allocator(), input.name, row, input.analysis.value == .ir);

        const program = input.analysis.value.ir;

        var nodes = try artifact.program_link.append(.{
            .program = program,
            .nominal_types = input.analysis.nominal_types,
        }, .{
            .allocator = owned,
            .temporary = scratch,
            .types = &types,
            .functions = &functions,
            .native_modules = &native_modules,
        });

        const range = nodes.functions.range;

        try initializers.registry.merge(owned, input.analysis.store_initializers, .{ .first = range.first, .count = range.count, .prefix = range.prefix }, &.{ .local = &functions }, true);
        for (input.initializers) |*initial| try initializers.source(initial.borrow(), input.analysis.nominal_types);
        for (input.borrowed_initializers) |initial| try initializers.source(initial, input.analysis.nominal_types);

        const function_id = try @import("entry.zig").bind(&functions, &nodes, program, input.analysis.entry_function, scratch);

        try @import("publication/host.zig").publish(owned, exports, row, input, function_id, &nodes);
    }

    const linked_functions = functions.view();

    try @import("stores.zig").validate(allocator, linked_functions.stores);

    const program = ir.Program{
        .file_name = "library",
        .types = types.items.view(),
        .input_type = @fromBackingInt(@intCast(@backingInt(ir.Scalar.void))),
        .output_type = @fromBackingInt(@intCast(@backingInt(ir.Scalar.void))),
        .symbols = .{},
        .expressions = .{},
        .body = .{},
        .functions = linked_functions,
        .native_modules = native_modules.view(),
        .type_only = true,
    };

    if (try frontend.validateIr(scratch, program) != null) return error.InvalidIr;

    const result = model.Result{ .arena = arena, .program = program, .exports = exports, .nominal_types = types.origins.items.view(), .store_initializers = initializers.registry.rows.items };

    try @import("validate.zig").validate(scratch, &result);

    return result;
}
