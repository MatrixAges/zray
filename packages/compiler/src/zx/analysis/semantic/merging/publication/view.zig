const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Origins = @import("nominal_data");
const Rule = @import("generated_type_merge_publication");
pub const Input = std.meta.Child(Rule.Input);
pub const Target = std.meta.Child(@FieldType(std.meta.Child(@import("generated_type_merge").Input), "publication"));
pub const Offsets = std.meta.Child(@typeInfo(@FieldType(Target, "offsets")).optional.child);
const TextMode = @FieldType(Target, "text_mode");

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

options: Options,
target: Target,
pub fn init(self: *Self, options: Options) void {
    self.* = .{
        .options = options,
        .target = .{
            .offsets = options.offsets,
            .base_labels = if (options.base_labels) |labels| labels.* else options.types.labels.items,
            .text_mode = options.text_mode,
            .native_owner = options.native_owner,
        },
    };
}

pub fn request(self: *const Self, comptime Layout: type, delta: @FieldType(Layout, "delta"), origins: @FieldType(Layout, "origins")) Layout {
    return .{
        .delta = delta,
        .origins = origins,
        .offsets = zx.columns.view(@FieldType(Layout, "offsets"), self.target.offsets),
        .base_labels = self.target.base_labels,
        .text_mode = @enumFromInt(@intFromEnum(self.target.text_mode)),
        .native_owner = self.target.native_owner,
    };
}

pub fn prepare(self: *const Self, scratch: std.mem.Allocator, table: ir.TypeTable, bindings: anytype) std.mem.Allocator.Error!Pending {
    const Table = std.meta.Child(@FieldType(Input, "delta"));
    const Bindings = std.meta.Child(@FieldType(Input, "origins"));
    const types = ir.TypeTable.borrow(Table, table);

    const nominal: Bindings = .{
        .ids = bindings.ids,
        .kinds = bindings.kinds,
        .owners = bindings.owners,
        .members = bindings.members,
    };

    const input = self.request(Input, &types, &nominal);

    const plan = Rule.executeIn(scratch, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    return self.stage(plan);
}

pub fn commit(self: *const Self, plan: anytype) std.mem.Allocator.Error!void {
    var pending = try self.stage(plan);

    pending.publish();
}

pub const Pending = struct {
    options: Options,
    types: ir.TypeStorage,
    nominal: Origins.Storage,
    own_labels: bool,
    own_names: bool,
    origins_owned: enum { none, all, shared },
    pub fn release(self: *Pending) void {
        const options = self.options;
        const payload = options.payload;
        const types = &self.types;

        if (self.own_labels) {
            freeText(payload, types.labels.items[options.types.labels.items.len..]);
            freeText(payload, types.field_names.items[options.types.field_names.items.len..]);
        }

        if (self.own_names) freeText(payload, types.names.items[options.types.names.items.len..]);

        if (options.origins) |storage| {
            const first = storage.owners.items.len;
            const owners = self.nominal.owners.items[first..];
            const members = self.nominal.members.items[first..];

            switch (self.origins_owned) {
                .none => {},
                .all => {
                    freeText(payload, owners);
                    freeText(payload, members);
                },
                .shared => if (owners.len != 0) {
                    payload.free(owners[0]);
                    payload.free(members[0]);
                },
            }

            discard(&self.nominal, storage, options.allocator);
        }

        discard(types, options.types, options.allocator);
    }

    pub fn publish(self: *Pending) void {
        const options = self.options;

        if (options.origins) |storage| {
            discard(storage, &self.nominal, options.allocator);

            storage.* = self.nominal;
        }

        discard(options.types, &self.types, options.allocator);

        options.types.* = self.types;
    }
};

pub fn stage(self: *const Self, plan: anytype) std.mem.Allocator.Error!Pending {
    const options = self.options;
    const allocator = options.allocator;
    const payload = options.payload;
    const delta = zx.columns.view(ir.TypeTable, plan.delta);

    const origin_rows: Origins.Table = .{
        .ids = plan.origins.ids,
        .kinds = plan.origins.kinds,
        .owners = plan.origins.owners,
        .members = plan.origins.members,
        .names = plan.nominal_names,
    };

    var types = try reserve(ir.TypeStorage, options.types, delta, allocator, options.precise, !options.precise);

    errdefer discard(&types, options.types, allocator);

    var nominal: Origins.Storage = .{};
    const original = options.origins;

    if (original) |storage| nominal = try reserve(Origins.Storage, storage, origin_rows, allocator, false, false);

    errdefer if (original) |storage| discard(&nominal, storage, allocator);

    inline for (.{ "kinds", "first", "second", "children", "field_types" }) |name| {
        @field(types, name).appendSliceAssumeCapacity(@field(delta, name));
    }

    const text = plan.text;

    try appendText(&types.labels, delta.labels, payload, text.own_labels);

    errdefer if (text.own_labels) freeText(payload, types.labels.items[options.types.labels.items.len..]);

    try appendText(&types.field_names, delta.field_names, payload, text.own_labels);

    errdefer if (text.own_labels) freeText(payload, types.field_names.items[options.types.field_names.items.len..]);

    try appendText(&types.names, delta.names, payload, text.own_names);

    errdefer if (text.own_names) freeText(payload, types.names.items[options.types.names.items.len..]);

    if (original) |storage| {
        const first = storage.owners.items.len;
        const labels = types.labels.items[options.types.labels.items.len..];

        nominal.ids.appendSliceAssumeCapacity(origin_rows.ids);
        nominal.kinds.appendSliceAssumeCapacity(origin_rows.kinds);

        switch (text.origin_text) {
            .Borrow => {
                nominal.owners.appendSliceAssumeCapacity(origin_rows.owners);
                nominal.members.appendSliceAssumeCapacity(origin_rows.members);
            },
            .Own => {
                try appendText(&nominal.owners, origin_rows.owners, payload, true);

                errdefer freeText(payload, nominal.owners.items[first..]);

                try appendText(&nominal.members, origin_rows.members, payload, true);
            },
            .Shared => if (origin_rows.ids.len != 0) {
                const owner = try payload.dupe(u8, origin_rows.owners[0]);

                errdefer payload.free(owner);

                const member = try payload.dupe(u8, origin_rows.members[0]);

                repeat(&nominal.owners, owner, origin_rows.ids.len);
                repeat(&nominal.members, member, origin_rows.ids.len);
            },
            .Native => {
                repeat(&nominal.owners, text.native_owner.?, origin_rows.ids.len);
                repeat(&nominal.members, "", origin_rows.ids.len);
            },
        }

        if (plan.label_rows.len == 0) {
            nominal.names.appendSliceAssumeCapacity(origin_rows.names);
        } else {
            for (plan.label_rows, origin_rows.names) |label_row, name| {
                nominal.names.appendAssumeCapacity(if (label_row) |row| labels[row] else name);
            }
        }
    }

    return .{
        .options = options,
        .types = types,
        .nominal = nominal,
        .own_labels = text.own_labels,
        .own_names = text.own_names,
        .origins_owned = switch (text.origin_text) {
            .Own => .all,
            .Shared => .shared,
            .Borrow, .Native => .none,
        },
    };
}

// Keep the original allocation available until every column and string is ready.
fn reserve(comptime Storage: type, original: *const Storage, rows: anytype, allocator: std.mem.Allocator, precise: bool, limited: bool) std.mem.Allocator.Error!Storage {
    var staged = original.*;

    errdefer discard(&staged, original, allocator);

    inline for (@typeInfo(Storage).@"struct".field_names) |name| {
        const column = &@field(staged, name);
        const required = std.math.add(usize, column.items.len, @field(rows, name).len) catch return error.OutOfMemory;

        if (limited and required > std.math.maxInt(u32)) return error.OutOfMemory;

        if (required > column.capacity) {
            const prefix = column.items;
            var grown: @TypeOf(column.*) = .empty;

            if (precise) {
                try grown.ensureTotalCapacityPrecise(allocator, required);
            } else {
                try grown.ensureTotalCapacity(allocator, required);
            }

            grown.appendSliceAssumeCapacity(prefix);

            column.* = grown;
        }
    }

    return staged;
}

fn discard(storage: anytype, retained: *const std.meta.Child(@TypeOf(storage)), allocator: std.mem.Allocator) void {
    inline for (@typeInfo(std.meta.Child(@TypeOf(storage))).@"struct".field_names) |name| {
        const column = &@field(storage, name);

        if (column.capacity != @field(retained, name).capacity) column.deinit(allocator);
    }
}

fn appendText(column: *std.ArrayList([]const u8), source: []const []const u8, allocator: std.mem.Allocator, own: bool) std.mem.Allocator.Error!void {
    if (!own) {
        column.appendSliceAssumeCapacity(source);

        return;
    }

    const first = column.items.len;

    errdefer freeText(allocator, column.items[first..]);

    for (source) |text| column.appendAssumeCapacity(try allocator.dupe(u8, text));
}

fn freeText(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |text| allocator.free(text);
}

fn repeat(column: *std.ArrayList([]const u8), value: []const u8, count: usize) void {
    @memset(column.addManyAsSliceAssumeCapacity(count), value);
}

pub fn offsets(target: *const ir.TypeStorage) Offsets {
    return .{
        .children = @truncate(target.children.items.len),
        .fields = @truncate(target.field_types.items.len),
        .names = @truncate(target.names.items.len),
    };
}
