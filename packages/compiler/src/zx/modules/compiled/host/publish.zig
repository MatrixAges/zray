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
const prepare = @import("generated_compiled_prepare_publication");
const publish = @import("generated_compiled_publish");
const Request = std.meta.Child(prepare.Input);
const Types = std.meta.Child(@FieldType(Request, "types"));
const Delta = std.meta.Child(@FieldType(Types, "delta"));
const Origins = std.meta.Child(@FieldType(Types, "origins"));
const Functions = std.meta.Child(@FieldType(Request, "functions"));
const Row = std.meta.Child(std.meta.Child(@FieldType(Functions, "shape")));

pub fn apply(allocator: std.mem.Allocator, temporary: std.mem.Allocator, input: *const Input, library: *const model.Library, output: *const Output, destination: load.Destination, call_scratch: ?load.CallScratch) (std.mem.Allocator.Error || error{InvalidModule})!model.Loaded {
    const function_allocator = if (call_scratch) |scratch| scratch.functions else allocator;
    const first_function = destination.functions.count();

    try prepareStorage(allocator, function_allocator, temporary, output, destination, library.program.functions.count());

    var functions: function.View = undefined;

    functions.init(destination.functions, library.program.functions, .{
        .types = output.functions.types,
        .natives = output.functions.natives,
        .first = first_function,
        .instance = library.instance,
    });

    var public: interface.View = undefined;
    const needs_interface = call_scratch == null;

    if (needs_interface) public.init(input, output, first_function);

    const result = publish.executeState(function_allocator, .{
        .functions = functions.input,
        .interface = if (needs_interface) &public.request else null,
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    try functions.check(result);

    const exports = if (needs_interface) public.result() else interface.Interface{};

    return .{ .types = destination.types.view(), .nominal_types = destination.origins.items.view(), .exports = exports.exports, .store_initializers = exports.initializers };
}

fn prepareStorage(allocator: std.mem.Allocator, function_allocator: std.mem.Allocator, temporary: std.mem.Allocator, output: *const Output, destination: load.Destination, count: usize) std.mem.Allocator.Error!void {
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
    errdefer types.release(&options);

    const pending = zx.columns.view(ir.NativeModuleTable, output.natives.*);
    var natives: native.View = undefined;

    natives.init(&allocator, destination.native_modules, pending, output.functions.types, null);

    const slots = zx.memory.bindColumnSet(Row, true, destination.functions);
    const storage: zx.memory.ColumnSet = &slots;
    const rows = ir.TypeTable.borrow(Delta, delta);
    const origins = zx.columns.view(Origins, output.origins.*);

    const request: Request = .{
        .types = &types.request(Types, &rows, &origins),
        .natives = &natives.publication,
        .functions = &.{ .storage = @ptrCast(&storage), .resource = @ptrCast(&function_allocator), .shape = null, .count = count },
    };

    prepare.executeIn(temporary, &request) catch return error.OutOfMemory;
}
