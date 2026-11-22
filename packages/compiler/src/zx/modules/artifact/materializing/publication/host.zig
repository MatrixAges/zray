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
    const State = std.meta.Child(entry.Input);

    const Input = if (entry == initializer)
        std.meta.Child(@FieldType(State, "body"))

    else
        State;

    const Target = std.meta.Child(@FieldType(Input, "target"));
    const Mappings = std.meta.Child(@FieldType(Input, "mappings"));
    const Mapping = std.meta.Child(@FieldType(Mappings, "types"));
    const Empty = std.meta.Child(@FieldType(Input, "empty"));
    const Workspace = std.meta.Child(@FieldType(Input, "workspace"));
    const Source = @FieldType(Input, "source");
    const Root = if (single) std.meta.Child(Source) else void;
    const source_view = if (!single) columns.view(std.meta.Child(Source), source) else {};
    const External = if (single) std.meta.Child(@typeInfo(@FieldType(Root, "external")).optional.child) else void;
    var external: External = undefined;
    var attributes: if (single) std.meta.Child(@FieldType(Root, "attributes")) else void = undefined;
    const identity = if (entry == initializer) registration.identity else null;
    const descriptor = if (single) borrowRoot(Root, source, &external, &attributes, identity) else {};
    var completed: [1]u64 = .{0};
    const progress: []u64 = &completed;
    const length_slots = zx.memory.borrowColumnLengths(storage);
    const lengths: zx.memory.ColumnLengths = &length_slots;

    defer @import("../../../column_lengths.zig").publish(&lengths, completed[0]);

    var target: columns.Tail(Target) = undefined;

    target.init(storage);

    const types = remap.typeMapping(Mapping, nodes.types);
    const functions = remap.idMapping(Mapping, nodes.functions);
    const natives = remap.idMapping(Mapping, nodes.native_modules);
    var fixed: [stack_depth_slots]u32 = undefined;
    var scratch: zx.memory.U32Scratch = .{ .allocator = temporary, .items = &fixed };

    defer scratch.deinit();

    const input: Input = .{
        .source = if (single) &descriptor else &source_view,
        .target = &.{ .storage = @ptrCast(&target.storage), .shape = null },
        .mappings = &.{ .types = &types, .functions = &functions, .natives = &natives },
        .empty = &.{
            .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
            .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
        },
        .workspace = &scratch.borrow(Workspace, false),
        .max_offset = std.math.maxInt(usize),
        .progress = @ptrCast(&progress),
    };

    const result = if (entry == initializer)
        entry.executeIn(nodes.allocator, &.{ .body = &input, .registry = registration })

    else
        entry.executeIn(nodes.allocator, &input);

    const output = result catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (output) {
        .Exhausted => return error.OutOfMemory,
        .Invalid => return error.InvalidModule,
        .Complete => {},
    }

    std.debug.assert(completed[0] == count);
}

fn borrowRoot(comptime Root: type, source: anytype, external: anytype, attributes: anytype, identity: ?[]const u8) Root {
    const view = ir.FunctionView.borrow(source);
    const native = view.signature.external;

    if (native) |value| external.* = @import("../external_host.zig").borrow(@TypeOf(external.*), value);

    attributes.* = remap.attributes(@TypeOf(attributes.*), &view, if (identity != null) .transaction else view.store_mode);

    return .{
        .file = identity orelse view.signature.file_name,
        .input_type = @backingInt(view.signature.input_type),
        .output_type = @backingInt(view.signature.output_type),
        .attributes = attributes,
        .native_module = if (native) |value| @backingInt(value.module) else null,
        .external = if (native != null) external else null,
        .stores = zx.columns.pointer(@FieldType(Root, "stores"), view.stores),
        .symbols = zx.columns.pointer(@FieldType(Root, "symbols"), view.symbols),
        .expressions = zx.columns.pointer(@FieldType(Root, "expressions"), view.expressions),
        .contracts = zx.columns.pointer(@FieldType(Root, "contracts"), view.contracts),
        .control = zx.columns.pointer(@FieldType(Root, "control"), view.body.control),
    };
}
