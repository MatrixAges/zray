const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const rule = @import("generated_type_merge_publication");
const Input = std.meta.Child(rule.Input);
const Table = std.meta.Child(@FieldType(Input, "delta"));
const Bindings = std.meta.Child(@FieldType(Input, "origins"));
const Offsets = std.meta.Child(@typeInfo(@FieldType(Input, "offsets")).optional.child);
const TextMode = @FieldType(Input, "text_mode");
const Destination = std.meta.Child(@FieldType(Input, "destination"));
const TypeElements = std.meta.Child(@typeInfo(@FieldType(Destination, "elements")).optional.child);
const NominalElements = std.meta.Child(@typeInfo(@FieldType(Destination, "nominal_elements")).optional.child);
const Merge = @import("generated_type_merge");
const MergeInput = std.meta.Child(Merge.Input);
const Publication = std.meta.Child(@FieldType(MergeInput, "publication"));
pub const Preparation = std.meta.Child(@FieldType(MergeInput, "preparation"));
pub const Error = std.mem.Allocator.Error || error{InvalidModule};
const Operation = enum { register, publish };
const Registration = struct { temporary: std.mem.Allocator, preparation: *const Preparation };

const Options = struct {
    allocator: std.mem.Allocator,
    payload: std.mem.Allocator,
    types: *ir.TypeStorage,
    origins: ?*Origins.Storage,
    offsets: ?*const Offsets = null,
    text_mode: TextMode = .Own,
    precise: bool = false,
};

pub fn appendTypes(allocator: std.mem.Allocator, target: *ir.TypeStorage, delta: anytype) std.mem.Allocator.Error!void {
    try append(allocator, target, null, delta, @as(Origins.Table, .{}));
}

pub fn append(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    try appendWithPayload(allocator, allocator, target, origins, delta, bindings);
}

pub fn appendWithPayload(allocator: std.mem.Allocator, payload: std.mem.Allocator, target: *ir.TypeStorage, origins: ?*Origins.Storage, delta: anytype, bindings: anytype) std.mem.Allocator.Error!void {
    const base = offsets(target);

    try write(.publish, .{
        .allocator = allocator,
        .payload = payload,
        .types = target,
        .origins = origins,
        .offsets = &base,
    }, zx.columns.view(ir.TypeTable, delta), bindings, {});
}

pub fn appendConstructed(allocator: std.mem.Allocator, target: *ir.TypeStorage, table: ir.TypeTable, owns_names: bool) std.mem.Allocator.Error!void {
    try write(.publish, .{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = null,
        .text_mode = if (owns_names) .OwnNames else .Borrow,
    }, table, @as(Origins.Table, .{}), {});
}

pub fn snapshot(allocator: std.mem.Allocator, table: ir.TypeTable, comptime own_text: bool) std.mem.Allocator.Error!ir.TypeStorage {
    var target: ir.TypeStorage = .{};

    if (table.count() == 0) return target;

    errdefer target.deinit(allocator);

    try write(.publish, .{
        .allocator = allocator,
        .payload = allocator,
        .types = &target,
        .origins = null,
        .text_mode = if (own_text) .Own else .Borrow,
        .precise = true,
    }, table, @as(Origins.Table, .{}), {});

    return target;
}

fn offsets(target: *const ir.TypeStorage) Offsets {
    // Reservation validates the column lengths before they are used.
    return .{
        .children = @truncate(target.children.items.len),
        .fields = @truncate(target.field_types.items.len),
        .names = @truncate(target.names.items.len),
    };
}

pub fn register(allocator: std.mem.Allocator, target: *ir.TypeStorage, origins: *Origins.Storage, registration: Registration) Error!Merge.Output {
    const base = offsets(target);

    return write(.register, .{
        .allocator = allocator,
        .payload = allocator,
        .types = target,
        .origins = origins,
        .offsets = &base,
    }, .{}, @as(Origins.Table, .{}), registration);
}

fn write(
    comptime operation: Operation,
    options: Options,
    table: ir.TypeTable,
    bindings: anytype,
    registration: if (operation == .register) Registration else void,
) (if (operation == .register) Error!Merge.Output else std.mem.Allocator.Error!void) {
    var tails: ir.TypeTable = .{};
    var nominal_tails: Origins.Table = .{};
    var slots = zx.memory.bindColumnRanges(TypeElements, options.types, table, &tails);

    var nominal_slots = if (options.origins) |storage| zx.memory.bindColumnRanges(NominalElements, storage, .{
        .ids = bindings.ids,
        .kinds = bindings.kinds,
        .owners = bindings.owners,
        .members = bindings.members,
        .names = bindings.ids.len,
    }, &nominal_tails) else undefined;

    const ranges: zx.memory.ColumnRanges = &slots;
    const nominal_ranges: zx.memory.ColumnRanges = &nominal_slots;
    var copied: [1]u64 = .{0};
    const progress: []u64 = &copied;

    errdefer switch (options.text_mode) {
        .Own => {
            const ordered = .{ tails.labels, tails.field_names, tails.names, nominal_tails.owners, nominal_tails.members };

            inline for (ordered, 0..) |column, index| {
                if (index < copied[0]) for (column) |text| options.payload.free(text);
            }
        },
        .OwnNames => if (copied[0] != 0) for (tails.names) |text| options.payload.free(text),
        .Borrow => {},
    };

    const publication: Publication = .{
        .target = &.{
            .kinds = @ptrCast(&tails.kinds),
            .first = @ptrCast(&tails.first),
            .second = @ptrCast(&tails.second),
            .labels = @ptrCast(&tails.labels),
            .children = @ptrCast(&tails.children),
            .field_types = @ptrCast(&tails.field_types),
            .field_names = @ptrCast(&tails.field_names),
            .names = @ptrCast(&tails.names),
        },
        .nominal = &.{
            .ids = @ptrCast(&nominal_tails.ids),
            .kinds = @ptrCast(&nominal_tails.kinds),
            .owners = @ptrCast(&nominal_tails.owners),
            .members = @ptrCast(&nominal_tails.members),
            .names = @ptrCast(&nominal_tails.names),
        },
        .offsets = options.offsets,
        .base_labels = @ptrCast(&options.types.labels.items),
        .text_mode = options.text_mode,
        .progress = @ptrCast(&progress),
        .payload = @ptrCast(&options.payload),
        .destination = &.{
            .ranges = @ptrCast(&ranges),
            .nominal_ranges = if (options.origins != null) @ptrCast(&nominal_ranges) else null,
            .elements = null,
            .nominal_elements = null,
            .resource = @ptrCast(&options.allocator),
            .precise = options.precise,
        },
    };

    if (comptime operation == .register) {
        const input: MergeInput = .{ .preparation = registration.preparation, .publication = &publication };

        return Merge.executeIn(registration.temporary, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidModule,
        };
    }

    const types = ir.TypeTable.borrow(Table, table);

    const nominal: Bindings = .{
        .ids = bindings.ids,
        .kinds = bindings.kinds,
        .owners = bindings.owners,
        .members = bindings.members,
    };

    const input: Input = .{
        .delta = &types,
        .origins = &nominal,
        .target = publication.target,
        .nominal = publication.nominal,
        .offsets = publication.offsets,
        .base_labels = publication.base_labels,
        .text_mode = publication.text_mode,
        .progress = publication.progress,
        .destination = publication.destination,
        .payload = publication.payload,
    };

    rule.executeIn(options.payload, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}
