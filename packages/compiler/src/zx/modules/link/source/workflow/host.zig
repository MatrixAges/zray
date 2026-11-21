const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const source = @import("../../program.zig");
const merge_types = @import("../../../../analysis/semantic/merge.zig");
const TypePublication = @import("../../../../analysis/semantic/merging/publication/view.zig");
const Origins = @import("../../../nominal_origins.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const publication = @import("../../../artifact/materializing/publication/host.zig");
const validation = @import("../../../../ir/validate.zig");
const prepare = @import("generated_source_prepare_publication");
const Input = std.meta.Child(prepare.Input);
const Program = std.meta.Child(@typeInfo(@FieldType(Input, "validation")).optional.child);
const ValidationView = @import("../../../../ir/canonical/validation/input.zig").Storage(Program);
const Types = std.meta.Child(@FieldType(Input, "types"));
const Native = std.meta.Child(@typeInfo(@FieldType(Input, "natives")).optional.child);
const Functions = std.meta.Child(@FieldType(Input, "functions"));
const Row = std.meta.Child(std.meta.Child(@FieldType(Functions, "shape")));

pub fn merge(comptime form: source.Form, program: *const ir.Program, origins: Origins.Table, destination: *const source.Destination, extension: if (form == .AnalyzedBody) *const source.Extension else void) source.Error!Nodes {
    const rows = if (form == .Program) &program.functions else extension.tail;
    const nodes = try prepareStorage(form, program, origins, destination, extension, rows.count());

    try publication.appendReserved(&nodes, destination.functions, rows.*, destination.temporary);

    return nodes;
}

fn prepareStorage(comptime form: source.Form, program: *const ir.Program, origins: Origins.Table, destination: *const source.Destination, extension: if (form == .AnalyzedBody) *const source.Extension else void, added: usize) source.Error!Nodes {
    const complete = form == .Program;
    const native_count = program.native_modules.count();
    const first = destination.functions.count();
    const count = if (complete) program.functions.count() else extension.total;
    const base = if (complete) 0 else extension.base;
    const type_allocator = if (complete) destination.types.allocator else destination.temporary;
    var types: []u32 = &.{};
    var natives: []?ir.NativeModuleId = &.{};

    errdefer type_allocator.free(types);
    errdefer destination.temporary.free(natives);

    var arena = std.heap.ArenaAllocator.init(destination.temporary);

    defer arena.deinit();

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

    var mapping: merge_types.View = undefined;

    mapping.init(&registration, &types);

    if (complete) mapping.input.validation = null;

    const offsets = TypePublication.offsets(registration.items);

    const options: TypePublication.Options = .{
        .allocator = registration.allocator,
        .payload = registration.allocator,
        .types = registration.items,
        .origins = registration.nominal,
        .offsets = &offsets,
    };

    var type_output: TypePublication = undefined;

    type_output.init(&options, .{}, @as(Origins.Table, .{}));
    errdefer type_output.release(&options);

    const has_natives = complete and native_count != 0;
    var native_view: @import("../../native/host.zig").View = undefined;
    var bindings: Native = undefined;

    if (has_natives) {
        native_view.init(&destination.allocator, destination.native_modules, program.native_modules, &.{}, &natives);

        bindings = .{
            .source = borrow(@FieldType(Native, "source"), &native_view.rows),
            .base = borrow(@FieldType(Native, "base"), &native_view.base),
            .destination = borrow(@FieldType(Native, "destination"), &native_view.destination),
            .mapping = @ptrCast(&natives),
            .resource = @ptrCast(&destination.temporary),
        };
    }

    const slots = zx.memory.bindColumnSet(Row, true, destination.functions);
    const storage: zx.memory.ColumnSet = &slots;
    var started: [1]u8 = .{0};
    const marker: []u8 = &started;

    const input: Input = .{
        .validation = if (complete) &checked.input else null,
        .registration_started = @ptrCast(&marker),
        .types = &Types{
            .preparation = borrow(@FieldType(Types, "preparation"), &mapping.input),
            .publication = borrow(@FieldType(Types, "publication"), &type_output.target),
        },
        .range = &.{ .first = first, .count = count, .prefix = base, .types = source_first + source_types.count(), .native_modules = native_count },
        .natives = if (has_natives) &bindings else null,
        .functions = &.{ .storage = @ptrCast(&storage), .resource = @ptrCast(&destination.allocator), .shape = null, .count = added },
    };

    const result = prepare.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => return if (complete and started[0] == 0) error.InvalidIr else error.InvalidModule,
    };

    switch (result) {
        .Ready => {},
        .InvalidIr => return error.InvalidIr,
        .MissingOrigin => return error.MissingNominalOrigin,
        .ConflictingType => return error.ConflictingNominalType,
        .ConflictingInterface => return error.ConflictingInterface,
        .Exhausted => return error.OutOfMemory,
        .Invalid => return error.InvalidModule,
    }

    return .{
        .allocator = destination.allocator,
        .types = .{ .mapped = @ptrCast(types) },
        .functions = .{ .range = .{ .first = @intCast(first), .count = @intCast(count), .prefix = @intCast(base) } },
        .native_modules = if (complete) .{ .indexed = natives } else .{ .range = .{ .first = 0, .count = @intCast(native_count) } },
    };
}

fn borrow(comptime Target: type, pointer: anytype) Target {
    return zx.columns.pointer(Target, @as(*const std.meta.Child(@TypeOf(pointer)), pointer));
}
