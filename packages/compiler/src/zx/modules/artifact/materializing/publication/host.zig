const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../nodes.zig");
const remap = @import("../../nodes/remap.zig");
const Error = @import("../../model.zig").Error;
const columns = @import("columns.zig");
const batch = @import("generated_source_function_batch");
const root = @import("generated_source_function_root");
const initializer = @import("generated_source_initializer_publish");
const stack_depth_slots = 2048 / @sizeOf(u32);

pub fn appendRoot(nodes: *const Nodes, storage: *ir.FunctionStorage, source: anytype, temporary: std.mem.Allocator) Error!void {
    try storage.reserve(nodes.allocator, 1);

    return publish(root, nodes, storage, source, 1, temporary, {});
}

const InitializerInput = std.meta.Child(initializer.Input);
pub const InitializerRegistration = std.meta.Child(@FieldType(InitializerInput, "registry"));

pub fn appendInitializer(nodes: *const Nodes, storage: *ir.FunctionStorage, source: *const ir.Program, temporary: std.mem.Allocator, registration: *const InitializerRegistration) Error!void {
    try storage.reserve(nodes.allocator, 1);

    return publish(initializer, nodes, storage, source, 1, temporary, registration);
}

pub fn append(nodes: *const Nodes, storage: *ir.FunctionStorage, source: ir.FunctionTable, temporary: std.mem.Allocator) Error!void {
    const count = source.count();

    if (count == 0) return;
    try storage.reserve(nodes.allocator, count);

    return appendReserved(nodes, storage, source, temporary);
}

pub fn appendReserved(nodes: *const Nodes, storage: *ir.FunctionStorage, source: ir.FunctionTable, temporary: std.mem.Allocator) Error!void {
    const count = source.count();

    if (count == 0) return;

    return publish(batch, nodes, storage, source, count, temporary, {});
}

fn publish(comptime entry: type, nodes: *const Nodes, storage: *ir.FunctionStorage, source: anytype, count: usize, temporary: std.mem.Allocator, registration: if (entry == initializer) *const InitializerRegistration else void) Error!void {
    const single = entry != batch;
    const State = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;

    const Input = if (entry == initializer)
        @FieldType(State, "body")
    else
        State;

    const Columns = @FieldType(Input, "target");
    const Mappings = std.meta.Child(@FieldType(Input, "mappings"));
    const Mapping = std.meta.Child(@FieldType(Mappings, "types"));
    const Empty = std.meta.Child(@FieldType(Input, "empty"));
    const Workspace = std.meta.Child(@FieldType(Input, "workspace"));
    const Source = @FieldType(Input, "source");
    const Root = if (single) std.meta.Child(Source) else void;
    const External = if (single) std.meta.Child(@typeInfo(@FieldType(Root, "external")).optional.child) else void;
    var external: External = undefined;
    var attributes: if (single) std.meta.Child(@FieldType(Root, "attributes")) else void = undefined;
    const identity = if (entry == initializer) registration.identity else null;
    const descriptor = if (single) borrowRoot(Root, source, &external, &attributes, identity) else {};
    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;
    const length_slots = zx.memory.borrowColumnLengths(storage);
    const lengths: zx.memory.ColumnLengths = &length_slots;
    const target = columns.borrow(Columns, storage.reservedTail(count), true);
    const types = remap.typeMapping(Mapping, nodes.types);
    const functions = remap.idMapping(Mapping, nodes.functions);
    const natives = remap.idMapping(Mapping, nodes.native_modules);
    var fixed: [stack_depth_slots]u32 = undefined;
    var scratch: zx.memory.U32Scratch = .{ .allocator = temporary, .items = &fixed };

    defer scratch.deinit();

    const input: Input = .{
        .source = if (single) &descriptor else columns.borrow(Source, source, false),
        .target = target,
        .mappings = &.{ .types = &types, .functions = &functions, .natives = &natives },
        .empty = &.{
            .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
            .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
        },
        .workspace = &scratch.borrow(Workspace, false),
        .max_offset = std.math.maxInt(usize),
        .progress = @ptrCast(&progress),
        .lengths = @ptrCast(&lengths),
    };

    const result = if (entry == initializer)
        entry.executeState(nodes.allocator, .{ .body = input, .registry = registration })

    else
        entry.executeState(nodes.allocator, input);

    const output = result catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (output.status) {
        .Exhausted => return error.OutOfMemory,
        .Invalid => return error.InvalidModule,
        .Complete => columns.checkBorrow(target, output.columns.?),
    }

    std.debug.assert(completed[0] == count);
}

fn borrowRoot(comptime Root: type, source: anytype, external: anytype, attributes: anytype, identity: ?[]const u8) Root {
    const signature: ?ir.External = if (@hasField(std.meta.Child(@TypeOf(source)), "external")) source.external else null;

    if (signature) |native| external.* = .{
        .members = native.member,
        .errors = native.errors,
        .export_name = native.export_name,
        .parameters = if (native.input) |input| input.names else null,
    };

    attributes.* = .{
        .ownership = switch (source.output_ownership) {
            .copy => .Copy,
            .borrowed => .Borrowed,
            .owned => .Owned,
        },
        .store_mode = @fromBackingInt(@intCast(@backingInt(if (identity != null) ir.StoreMode.transaction else source.store_mode))),
        .root = if (source.body.root) |id| @backingInt(id) else null,
        .allocator_argument = if (signature) |native| native.allocator_argument else false,
        .io_argument = if (signature) |native| native.io_argument else false,
        .process_argument = if (signature) |native| native.process_argument else false,
        .expand_tuple = if (signature) |native| native.expand_tuple else false,
        .fallible = if (signature) |native| native.fallible else false,
        .concurrent = if (signature) |native| native.concurrent else false,
    };

    return .{
        .file = identity orelse source.file_name,
        .input_type = @backingInt(source.input_type),
        .output_type = @backingInt(source.output_type),
        .attributes = attributes,
        .native_module = if (signature) |native| @backingInt(native.module) else null,
        .external = if (signature != null) external else null,
        .stores = zx.columns.pointer(@FieldType(Root, "stores"), &source.stores),
        .symbols = zx.columns.pointer(@FieldType(Root, "symbols"), &source.symbols),
        .expressions = zx.columns.pointer(@FieldType(Root, "expressions"), &source.expressions),
        .contracts = zx.columns.pointer(@FieldType(Root, "contracts"), &source.contracts),
        .control = zx.columns.pointer(@FieldType(Root, "control"), source.body.control),
    };
}
