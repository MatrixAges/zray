const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const Merge = @import("generated_type_merge");
pub const Target = std.meta.Child(@FieldType(std.meta.Child(Merge.Input), "publication"));
pub const Offsets = std.meta.Child(@typeInfo(@FieldType(Target, "offsets")).optional.child);
const TextMode = @FieldType(Target, "text_mode");
const Destination = std.meta.Child(@FieldType(Target, "destination"));
const TypeElements = std.meta.Child(@typeInfo(@FieldType(Destination, "elements")).optional.child);
const NominalElements = std.meta.Child(@typeInfo(@FieldType(Destination, "nominal_elements")).optional.child);

pub const Options = struct {
    allocator: std.mem.Allocator,
    payload: std.mem.Allocator,
    types: *ir.TypeStorage,
    origins: ?*Origins.Storage,
    offsets: ?*const Offsets = null,
    text_mode: TextMode = .Own,
    precise: bool = false,
};

const Self = @This();
const Types = std.meta.Child(@FieldType(Target, "target"));
const Nominal = std.meta.Child(@FieldType(Target, "nominal"));

tails: ir.TypeTable,
nominal_tails: Origins.Table,
slots: [@typeInfo(TypeElements).@"struct".field_types.len]zx.memory.ColumnRange,
nominal_slots: [@typeInfo(NominalElements).@"struct".field_types.len]zx.memory.ColumnRange,
ranges: zx.memory.ColumnRanges,
nominal_ranges: zx.memory.ColumnRanges,
copied: [1]u64,
progress: []u64,
columns: Types,
nominal: Nominal,
destination: Destination,
target: Target,
pub fn init(self: *Self, options: *const Options, table: ir.TypeTable, bindings: anytype) void {
    self.tails = .{};
    self.nominal_tails = .{};
    self.slots = zx.memory.bindColumnRanges(TypeElements, options.types, table, &self.tails);

    if (options.origins) |storage| {
        self.nominal_slots = zx.memory.bindColumnRanges(NominalElements, storage, .{
            .ids = bindings.ids,
            .kinds = bindings.kinds,
            .owners = bindings.owners,
            .members = bindings.members,
            .names = bindings.ids.len,
        }, &self.nominal_tails);
    }

    self.ranges = &self.slots;
    self.nominal_ranges = &self.nominal_slots;
    self.copied = .{0};
    self.progress = &self.copied;

    self.columns = .{
        .kinds = @ptrCast(&self.tails.kinds),
        .first = @ptrCast(&self.tails.first),
        .second = @ptrCast(&self.tails.second),
        .labels = @ptrCast(&self.tails.labels),
        .children = @ptrCast(&self.tails.children),
        .field_types = @ptrCast(&self.tails.field_types),
        .field_names = @ptrCast(&self.tails.field_names),
        .names = @ptrCast(&self.tails.names),
    };

    self.nominal = .{
        .ids = @ptrCast(&self.nominal_tails.ids),
        .kinds = @ptrCast(&self.nominal_tails.kinds),
        .owners = @ptrCast(&self.nominal_tails.owners),
        .members = @ptrCast(&self.nominal_tails.members),
        .names = @ptrCast(&self.nominal_tails.names),
    };

    self.destination = .{
        .ranges = @ptrCast(&self.ranges),
        .nominal_ranges = if (options.origins != null) @ptrCast(&self.nominal_ranges) else null,
        .elements = null,
        .nominal_elements = null,
        .resource = @ptrCast(&options.allocator),
        .precise = options.precise,
    };

    self.target = .{
        .target = &self.columns,
        .nominal = &self.nominal,
        .offsets = options.offsets,
        .base_labels = @ptrCast(&options.types.labels.items),
        .text_mode = options.text_mode,
        .progress = @ptrCast(&self.progress),
        .payload = @ptrCast(&options.payload),
        .destination = &self.destination,
    };
}

pub fn release(self: *const Self, options: *const Options) void {
    switch (options.text_mode) {
        .Own => {
            const ordered = .{ self.tails.labels, self.tails.field_names, self.tails.names, self.nominal_tails.owners, self.nominal_tails.members };

            inline for (ordered, 0..) |column, index| {
                if (index < self.copied[0]) for (column) |text| options.payload.free(text);
            }
        },
        .OwnNames => if (self.copied[0] != 0) for (self.tails.names) |text| options.payload.free(text),
        .Borrow => {},
    }
}
