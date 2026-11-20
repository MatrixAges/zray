const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Error = @import("../../../artifact/model.zig").Error;
const columns = @import("../../../artifact/materializing/publication/columns.zig");
const Bound = @import("../../dependencies/host.zig").Bound;
const generated = @import("generated_artifact_body_publication");
const Input = std.meta.Child(generated.Input);
const Prepared = @typeInfo(@FieldType(Bound, "body")).optional.child;
const Parameter = @typeInfo(@TypeOf(generated.executeState)).@"fn".param_types[1].?;
const indirect = @typeInfo(Parameter) == .pointer;
const State = if (indirect) std.meta.Child(Parameter) else Parameter;
const Tail = std.meta.Child(@typeInfo(@FieldType(State, "tail")).optional.child);
const Publication = std.meta.Child(@typeInfo(generated.Output).optional.child);
pub const Retained = @typeInfo(@FieldType(Publication, "retained")).optional.child;

pub fn publish(allocator: std.mem.Allocator, storage: *ir.FunctionStorage, linked: []?ir.FunctionId, index: usize, prepared: Prepared) Error!?Retained {
    const first = prepared.append orelse return retain(allocator, prepared);
    const lengths_slots = zx.memory.borrowColumnLengths(storage);
    const lengths: zx.memory.ColumnLengths = &lengths_slots;
    var target: columns.Tail(Tail) = undefined;

    target.init(storage);

    const tail: Tail = .{
        .storage = @ptrCast(&target.storage),
        .shape = null,
        .lengths = @ptrCast(&lengths),
        .linked = @ptrCast(&linked),
        .module = index,
        .first = first,
    };

    const Request = @FieldType(State, "request");
    const request_is_pointer = @typeInfo(Request) == .pointer;
    const request = zx.columns.borrow(if (request_is_pointer) std.meta.Child(Request) else Request, prepared);

    const input: State = .{
        .tables = columns.body(@FieldType(State, "tables"), storage, 1),
        .request = if (request_is_pointer) &request else request,
        .tail = &tail,
        .empty = &empty(std.meta.Child(@FieldType(State, "empty"))),
    };

    const output = generated.executeState(allocator, if (indirect) &input else input) catch |err| return failure(err);
    const result = output orelse return error.InvalidModule;

    columns.checkBorrow(input.tables, result.tables.?);

    return null;
}

fn retain(allocator: std.mem.Allocator, prepared: Prepared) Error!?Retained {
    const Tables = std.meta.Child(@FieldType(Input, "tables"));
    const tables = columns.view(Tables, @as(ir.FunctionTable, .{}));

    const input: Input = .{
        .tables = &tables,
        .request = zx.columns.pointer(@FieldType(Input, "request"), prepared),
        .tail = null,
        .empty = &empty(std.meta.Child(@FieldType(Input, "empty"))),
    };

    const output = generated.executeIn(allocator, &input) catch |err| return failure(err);
    const result = output orelse return error.InvalidModule;

    return result.retained;
}

fn empty(comptime Empty: type) Empty {
    return .{
        .control = zx.columns.pointer(@FieldType(Empty, "control"), (ir.ControlBody{}).control),
        .stores = zx.columns.pointer(@FieldType(Empty, "stores"), &ir.FunctionStorage.empty_stores),
    };
}

fn failure(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModule,
    };
}
