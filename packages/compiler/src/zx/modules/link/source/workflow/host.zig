const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const source = @import("../../program.zig");
const merge_types = @import("../../../../analysis/semantic/merge.zig");
const Origins = @import("../../../nominal_origins.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const tail = @import("tail.zig");
const columns = @import("../../../artifact/materializing/publication/columns.zig");
const remap = @import("../../../artifact/nodes/remap.zig");
const validation = @import("../../../../ir/validate.zig");
const generated = @import("generated_source_link_publication");
const preparation = @import("generated_source_link_preparation");
const Input = std.meta.Child(generated.Input);
const Reservation = std.meta.Child(@typeInfo(@FieldType(Input, "reserve")).optional.child);
const Check = std.meta.Child(preparation.Input);
const Write = std.meta.Child(@typeInfo(@FieldType(Input, "write")).optional.child);
const Batch = std.meta.Child(@typeInfo(@FieldType(Write, "batch")).optional.child);
const Single = std.meta.Child(@typeInfo(@FieldType(Write, "root")).optional.child);
const View = std.meta.Child(@FieldType(Batch, "source"));
const Root = std.meta.Child(@FieldType(Single, "source"));
pub const InitializerRegistration = std.meta.Child(@typeInfo(@FieldType(Write, "initializer")).optional.child);
const Mappings = std.meta.Child(@FieldType(Batch, "mappings"));
const Mapping = std.meta.Child(@FieldType(Mappings, "types"));
const Program = std.meta.Child(@typeInfo(@FieldType(Check, "validation")).optional.child);
const ValidationView = @import("../../../../ir/canonical/validation/input.zig").Storage(Program);
const Types = std.meta.Child(@FieldType(Check, "types"));
const Native = std.meta.Child(@typeInfo(@FieldType(Check, "natives")).optional.child);

pub fn merge(comptime form: source.Form, program: *const ir.Program, origins: Origins.Table, destination: *const source.Destination, extension: if (form == .AnalyzedBody) *const source.Extension else void) source.Error!Nodes {
    const complete = form == .Program;
    const rows = if (complete) &program.functions else extension.tail;
    const native_count = program.native_modules.count();
    const first = destination.functions.count();
    const count = if (complete) program.functions.count() else extension.total;
    const base = if (complete) 0 else extension.base;
    const type_allocator = if (complete) destination.types.allocator else destination.temporary;
    var mapped_types = remap.typeMapping(Mapping, .{ .mapped = &.{} });
    const ids: Mapping = .{ .kind = .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = first, .count = count, .prefix = base };
    var mapped_natives: Mapping = .{ .kind = if (complete) .Sparse else .Range, .dense = &.{}, .sparse = &.{}, .planned = &.{}, .first = 0, .count = native_count, .prefix = 0 };
    const types: *[]u32 = @ptrCast(&mapped_types.dense);
    const natives: *[]?ir.NativeModuleId = @ptrCast(&mapped_natives.sparse);
    var reserved = false;

    errdefer if (!reserved) {
        type_allocator.free(types.*);
        destination.temporary.free(natives.*);
    };

    var arena = std.heap.ArenaAllocator.init(destination.temporary);
    var arena_alive = true;

    defer if (arena_alive) arena.deinit();

    const temporary = arena.allocator();
    var checked: ValidationView = undefined;

    if (complete) checked.init(temporary, program, .{});

    const suffix = if (complete) null else extension.type_suffix;
    const source_first = if (suffix != null) extension.types else 0;
    const source_types = suffix orelse program.types;

    const registration: merge_types.Request = .{
        .allocator = destination.types.allocator,
        .mapping_allocator = type_allocator,
        .temporary = temporary,
        .source = source_types,
        .source_first = source_first,
        .origins = origins,
        .items = &destination.types.items,
        .nominal = &destination.types.origins.items,
        .first = if (complete) 0 else extension.types,
        .checked = complete or validation.internal,
        .complete = complete,
    };

    var view: merge_types.Registration = undefined;

    view.init(&registration, types);
    errdefer if (!reserved) view.output.release();

    if (complete) view.mapping.input.validation = null;

    const has_natives = complete and native_count != 0;
    var native_view: @import("../../native/host.zig").View = undefined;
    var bindings: Native = undefined;

    if (has_natives) {
        native_view.init(&destination.allocator, destination.native_modules, program.native_modules, &.{}, natives);

        bindings = .{
            .source = borrow(@FieldType(Native, "source"), &native_view.rows),
            .base = borrow(@FieldType(Native, "base"), &native_view.base),
            .destination = borrow(@FieldType(Native, "destination"), &native_view.destination),
            .mapping = @ptrCast(natives),
            .resource = @ptrCast(&destination.temporary),
        };
    }

    var started: [1]u8 = .{0};
    var marker: []u8 = &started;
    const registration_view = view.bind(Types);
    const range: std.meta.Child(@FieldType(Check, "range")) = .{ .first = first, .count = count, .prefix = base, .types = source_first + source_types.count(), .native_modules = native_count };

    const check: Check = .{
        .validation = if (complete) &checked.input else null,
        .registration_started = @ptrCast(&marker),
        .types = &registration_view,
        .range = &range,
        .natives = if (has_natives) &bindings else null,
    };

    const prepared = preparation.executeIn(temporary, &check) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return if (complete and started[0] == 0) error.InvalidIr else error.InvalidModule,
    };

    try requireReady(prepared);

    arena.deinit();

    arena_alive = false;

    const result = execute(rows.*, destination.functions, destination.temporary, &destination.allocator, &.{ .types = &mapped_types, .functions = &ids, .natives = &mapped_natives }, null, destination.allocator) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    reserved = true;

    try requireReady(result);

    return .{
        .allocator = destination.allocator,
        .types = .{ .mapped = @ptrCast(types.*) },
        .functions = .{ .range = .{ .first = @intCast(first), .count = @intCast(count), .prefix = @intCast(base) } },
        .native_modules = if (complete) .{ .indexed = natives.* } else .{ .range = .{ .first = 0, .count = @intCast(native_count) } },
    };
}

pub fn append(nodes: *const Nodes, storage: *ir.FunctionStorage, value: anytype, temporary: std.mem.Allocator, initializer: ?*const InitializerRegistration) @import("../../../artifact/model.zig").Error!void {
    const types = remap.typeMapping(Mapping, nodes.types);
    const ids = remap.idMapping(Mapping, nodes.functions);
    const natives = remap.idMapping(Mapping, nodes.native_modules);

    const result = execute(value, storage, temporary, &nodes.allocator, &.{
        .types = &types,
        .functions = &ids,
        .natives = &natives,
    }, initializer, nodes.allocator) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModule,
    };

    return switch (result) {
        .Ready => {},
        .Exhausted => error.OutOfMemory,
        else => error.InvalidModule,
    };
}

fn requireReady(status: anytype) source.Error!void {
    switch (status) {
        .Ready => {},
        .InvalidIr => return error.InvalidIr,
        .MissingOrigin => return error.MissingNominalOrigin,
        .ConflictingType => return error.ConflictingNominalType,
        .ConflictingInterface => return error.ConflictingInterface,
        .Exhausted => return error.OutOfMemory,
        .Invalid => return error.InvalidModule,
    }
}

fn execute(value: anytype, storage: *ir.FunctionStorage, scratch: std.mem.Allocator, owner: *const std.mem.Allocator, mappings: *const Mappings, initializer: ?*const InitializerRegistration, allocator: std.mem.Allocator) !generated.Output {
    const batch = @TypeOf(value) == ir.FunctionTable;
    const InputRow = if (batch) Batch else Single;
    var binding: tail.Storage(InputRow) = undefined;
    var input = binding.init(storage, scratch);

    defer binding.deinit();

    var external: if (batch) void else std.meta.Child(@typeInfo(@FieldType(Root, "external")).optional.child) = undefined;
    var attributes: if (batch) void else std.meta.Child(@FieldType(Root, "attributes")) = undefined;
    const input_rows = if (batch) columns.view(View, value) else tail.borrowRoot(Root, value, &external, &attributes, if (initializer) |entry| entry.identity else null);
    const count = if (batch) value.count() else 1;

    input.source = &input_rows;
    input.mappings = mappings;

    const reserve: Reservation = .{ .storage = input.target.storage, .shape = null, .resource = @ptrCast(owner), .count = count };
    const commit: std.meta.Child(@FieldType(Write, "commit")) = .{ .lengths = @ptrCast(&binding.lengths), .progress = input.progress };
    const write: Write = .{ .batch = if (batch) &input else null, .root = if (batch) null else &input, .initializer = initializer, .commit = &commit };

    return generated.executeIn(allocator, &.{ .reserve = if (count != 0) &reserve else null, .write = if (count != 0) &write else null });
}

fn borrow(comptime Target: type, pointer: anytype) Target {
    return zx.columns.pointer(Target, @as(*const std.meta.Child(@TypeOf(pointer)), pointer));
}
