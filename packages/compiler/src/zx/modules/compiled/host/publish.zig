const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const model = @import("../../compiled.zig");
const load = @import("../load.zig");
const Input = @import("input.zig");
const Output = std.meta.Child(@import("generated_compiled_library").Output);
const function = @import("function.zig");
const interface = @import("interface.zig");
const native = @import("../../link/native/host.zig");
const TypeView = @import("../../../analysis/semantic/merging/publication/view.zig");
const publish = @import("generated_compiled_publish");
const Preparation = std.meta.Child(@FieldType(function.Request, "preparation"));
const Types = std.meta.Child(@FieldType(Preparation, "types"));
const Delta = std.meta.Child(@FieldType(Types, "delta"));
const Origins = std.meta.Child(@FieldType(Types, "origins"));

pub fn apply(allocator: std.mem.Allocator, temporary: std.mem.Allocator, input: *const Input, library: *const model.Library, output: *const Output, destination: load.Destination, call_scratch: ?load.CallScratch) (std.mem.Allocator.Error || error{InvalidModule})!model.Loaded {
    const function_allocator = if (call_scratch) |scratch| scratch.functions else allocator;
    const first_function = destination.functions.count();
    const source = library.program.functions;
    var functions: function.View = undefined;

    functions.init(destination.functions, source, .{
        .types = output.functions.types,
        .natives = output.functions.natives,
        .first = first_function,
        .instance = library.instance,
    });

    defer @import("../../column_lengths.zig").publish(&functions.lengths, functions.completed[0]);

    const offsets = TypeView.offsets(destination.types);

    const options: TypeView.Options = .{
        .allocator = allocator,
        .payload = allocator,
        .types = destination.types,
        .origins = &destination.origins.items,
        .offsets = &offsets,
    };

    const delta = zx.columns.view(ir.TypeTable, output.types.*);
    var types: TypeView = undefined;

    types.init(&options, delta, output.origins.*);
    errdefer types.release();

    const pending = zx.columns.view(ir.NativeModuleTable, output.natives.*);
    var natives: native.View = undefined;

    natives.init(&allocator, destination.native_modules, pending, output.functions.types, null);

    const rows = ir.TypeTable.borrow(Delta, delta);
    const origins = zx.columns.view(Origins, output.origins.*);
    var prepared = [1]bool{false};
    const prepared_view: []bool = &prepared;
    var scope: zx.memory.ArenaScope = .{ .active = temporary };
    var public: interface.View = undefined;
    const needs_interface = call_scratch == null;

    if (needs_interface) public.init(input, output, first_function);

    publish.executeIn(scope.allocator(), &.{
        .preparation = &.{
            .types = &types.request(Types, &rows, &origins),
            .natives = &natives.publication,
            .functions = &.{ .storage = functions.target.storage, .resource = @ptrCast(&function_allocator), .shape = null, .count = source.count() },
            .prepared = @ptrCast(&prepared_view),
            .resources = @ptrCast(&scope),
            .owner = @ptrCast(&function_allocator),
        },
        .functions = &functions.input,
        .interface = if (needs_interface) &public.request else null,
        .commit = &.{ .lengths = @ptrCast(&functions.lengths), .progress = functions.input.progress },
    }) catch |err| {
        if (!prepared[0]) return error.OutOfMemory;

        return switch (@as(anyerror, err)) {
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
            else => error.InvalidModule,
        };
    };

    std.debug.assert(destination.functions.count() - first_function == source.count());

    const exports = if (needs_interface) public.result() else interface.Interface{};

    return .{ .types = destination.types.view(), .nominal_types = destination.origins.items.view(), .exports = exports.exports, .store_initializers = exports.initializers };
}
