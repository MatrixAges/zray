const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const Merge = @import("generated_type_merge");
pub const Target = std.meta.Child(@FieldType(std.meta.Child(Merge.Input), "publication"));
pub const Offsets = std.meta.Child(@typeInfo(@FieldType(Target, "offsets")).optional.child);
const TextMode = @FieldType(Target, "text_mode");
const Destination = std.meta.Child(@FieldType(Target, "destination"));

pub const Options = struct {
    allocator: std.mem.Allocator,
    payload: std.mem.Allocator,
    types: *ir.TypeStorage,
    origins: ?*Origins.Storage,
    offsets: ?*const Offsets = null,
    base_labels: ?*const []const []const u8 = null,
    text_mode: TextMode = .Own,
    native_owner: ?[]const u8 = null,
    precise: bool = false,
};

const Self = @This();
const Types = std.meta.Child(@FieldType(Target, "target"));
const Nominal = std.meta.Child(@FieldType(Target, "nominal"));

tails: ir.TypeTable,
nominal_tails: Origins.Table,
slots: [@typeInfo(ir.TypeStorage).@"struct".field_names.len]zx.memory.ColumnRange,
nominal_slots: [@typeInfo(Origins.Storage).@"struct".field_names.len]zx.memory.ColumnRange,
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
    self.slots = zx.memory.bindColumnRanges(options.types, table, &self.tails);

    if (options.origins) |storage| {
        self.nominal_slots = zx.memory.bindColumnRanges(storage, .{
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
        .resource = @ptrCast(&options.allocator),
        .precise = options.precise,
    };

    self.target = .{
        .target = &self.columns,
        .nominal = &self.nominal,
        .offsets = options.offsets,
        .base_labels = @ptrCast(options.base_labels orelse @as(*const []const []const u8, @ptrCast(&options.types.labels.items))),
        .text_mode = options.text_mode,
        .native_owner = options.native_owner,
        .progress = @ptrCast(&self.progress),
        .payload = @ptrCast(&options.payload),
        .destination = &self.destination,
    };
}

pub fn release(self: *const Self) void {
    const generated = @import("generated_type_merge_release");
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    generated.executeIn(scratch.allocator(), &self.target) catch unreachable;
}

pub fn request(self: *const Self, comptime Input: type, delta: @FieldType(Input, "delta"), origins: @FieldType(Input, "origins")) Input {
    return .{
        .delta = delta,
        .origins = origins,
        .target = self.target.target,
        .nominal = self.target.nominal,
        .offsets = self.target.offsets,
        .base_labels = self.target.base_labels,
        .text_mode = self.target.text_mode,
        .native_owner = self.target.native_owner,
        .progress = self.target.progress,
        .destination = self.target.destination,
        .payload = self.target.payload,
    };
}

pub fn offsets(target: *const ir.TypeStorage) Offsets {
    // Reservation validates the column lengths before they are used.
    return .{
        .children = @truncate(target.children.items.len),
        .fields = @truncate(target.field_types.items.len),
        .names = @truncate(target.names.items.len),
    };
}
