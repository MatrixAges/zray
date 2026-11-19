const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Nodes = @import("../../../artifact/nodes.zig");
const Error = @import("../../../artifact/model.zig").Error;
const remap = @import("../../../artifact/nodes/remap.zig");
const columns = @import("../../../artifact/materializing/publication/columns.zig");
const Placement = @import("../../dependencies/host.zig").Placement;
const generated = @import("generated_artifact_body_publication");
const Parameter = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
const indirect = @typeInfo(Parameter) == .pointer;
const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
const Tail = std.meta.Child(@typeInfo(@FieldType(Input, "tail")).optional.child);
const AttributesArg = @FieldType(Input, "attributes");
const Attributes = if (@typeInfo(AttributesArg) == .pointer) std.meta.Child(AttributesArg) else AttributesArg;
const BodyArg = @FieldType(Input, "body");
const Body = if (@typeInfo(BodyArg) == .pointer) std.meta.Child(BodyArg) else BodyArg;
const Empty = std.meta.Child(@FieldType(Input, "empty"));

pub fn publish(nodes: *const Nodes, value: *const ir.Function, storage: *ir.FunctionStorage, linked: []?ir.FunctionId, index: usize, placement: Placement) Error!?Nodes.FunctionEntry {
    const first = storage.count();
    const append = placement == .Append;
    var request: remap.FunctionRequest = undefined;

    request.init(nodes, remap.BodyColumns.borrow(value), value.body, value.file_name, value.external, if (placement == .Retain) @fromBackingInt(@as(u32, @intCast(first))) else null, .unchecked);

    const lengths_slots = if (append) zx.memory.borrowColumnLengths(storage) else undefined;
    const lengths: zx.memory.ColumnLengths = &lengths_slots;
    var target: columns.Tail(Tail) = undefined;
    var tail: Tail = undefined;

    if (append) {
        target.init(storage);

        tail = .{
            .storage = @ptrCast(&target.storage),
            .shape = null,
            .lengths = @ptrCast(&lengths),
            .linked = @ptrCast(&linked),
            .module = index,
            .first = first,
        };
    }

    const attributes: Attributes = .{
        .ownership = @fromBackingInt(@intCast(@backingInt(value.output_ownership))),
        .store_mode = @fromBackingInt(@intCast(@backingInt(value.store_mode))),
        .root = if (value.body.root) |id| @backingInt(id) else null,
        .allocator_argument = false,
        .io_argument = false,
        .process_argument = false,
        .expand_tuple = false,
        .fallible = false,
        .concurrent = false,
    };

    const borrowed = zx.columns.borrow(Body, @as(*const @TypeOf(request.input), &request.input));

    const input: Input = .{
        .tables = if (append) columns.body(@FieldType(Input, "tables"), storage, 1) else columns.borrow(@FieldType(Input, "tables"), @as(ir.FunctionTable, .{})),
        .body = if (@typeInfo(BodyArg) == .pointer) &borrowed else borrowed,
        .tail = if (append) &tail else null,
        .attributes = if (@typeInfo(AttributesArg) == .pointer) &attributes else attributes,
        .empty = &.{
            .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
            .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
        },
    };

    const result = (generated.executeState(nodes.allocator, if (indirect) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    }) orelse return error.InvalidModule;

    if (append) columns.checkBorrow(input.tables, result.tables.?);

    return if (result.retained) |body| Nodes.FunctionEntry.fromLinked(Nodes.linkedBody(value, body), body) else null;
}
