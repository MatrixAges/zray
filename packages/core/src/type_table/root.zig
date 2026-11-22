const model = @import("model.zig");
const schema = @import("../ir/schema.zig");
const Layout = schema.Types;
const Self = @This();
pub const borrow = @import("borrow.zig").columns;
pub const validStructure = @import("structure.zig").valid;

kinds: schema.column(Layout, "kinds", []const u8) = &.{},
first: schema.column(Layout, "first", []const u32) = &.{},
second: schema.column(Layout, "second", []const u32) = &.{},
labels: schema.column(Layout, "labels", []const []const u8) = &.{},
children: schema.column(Layout, "children", []const u32) = &.{},
field_types: schema.column(Layout, "field_types", []const u32) = &.{},
field_names: schema.column(Layout, "field_names", []const []const u8) = &.{},
names: schema.column(Layout, "names", []const []const u8) = &.{},
comptime {
    schema.checkFields(Layout, Self);
}

pub fn count(self: Self) usize {
    return self.kinds.len;
}

pub fn get(self: Self, id: model.TypeId) model.Type {
    return self.at(@backingInt(id));
}

pub fn prefix(self: Self, len: usize) Self {
    var result = self;
    result.kinds = self.kinds[0..len];
    result.first = self.first[0..len];
    result.second = self.second[0..len];
    result.labels = self.labels[0..len];

    const ends = if (comptime schema.generated) @import("publication.zig").ends(&result, len) else result.seedEnds();
    result.children = self.children[0..ends.children];
    result.field_types = self.field_types[0..ends.fields];
    result.field_names = self.field_names[0..ends.fields];
    result.names = self.names[0..ends.names];

    return result;
}

pub const Ends = struct { children: usize = 0, fields: usize = 0, names: usize = 0 };

fn seedEnds(self: Self) Ends {
    var ends: Ends = .{};

    for (self.kinds, self.first, self.second) |code, first, second| {
        const kind: model.Kind = @fromBackingInt(@intCast(code));
        const end = @as(usize, first) + @as(usize, second);

        switch (kind) {
            .object => ends.fields = @max(ends.fields, end),
            .tuple => ends.children = @max(ends.children, end),
            .error_set, .enumeration => ends.names = @max(ends.names, end),
            else => {},
        }
    }

    return ends;
}

pub fn at(self: Self, index: usize) model.Type {
    const kind: model.Kind = @fromBackingInt(@intCast(self.kinds[index]));
    const first: usize = self.first[index];
    const second: usize = self.second[index];

    return switch (kind) {
        .scalar => .{ .scalar = @fromBackingInt(@intCast(first)) },
        .object => .{ .object = .{
            .names = self.field_names[first..][0..second],
            .types = self.field_types[first..][0..second],
            .len = second,
        } },
        .optional => .{ .optional = @fromBackingInt(@intCast(first)) },
        .list => .{ .list = @fromBackingInt(@intCast(first)) },
        .tuple => .{ .tuple = .{ .values = self.children[first..][0..second], .len = second } },
        .error_set => .{ .error_set = self.names[first..][0..second] },
        .task => .{ .task = .{ .result = @fromBackingInt(@intCast(first)), .errors = @fromBackingInt(@intCast(second)) } },
        .enumeration => .{ .enumeration = .{ .name = self.labels[index], .members = self.names[first..][0..second] } },
        .native_reference => .{ .native_reference = self.labels[index] },
    };
}
