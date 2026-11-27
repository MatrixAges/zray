const std = @import("std");
const ir = @import("zx").ir;
const Builder = @import("../../builder.zig");
const abi = @import("../abi.zig");
const Input = std.meta.Child(@FieldType(abi.Request, "literals"));
const Bases = std.meta.Child(@FieldType(abi.Payload, "literals"));
const names = @typeInfo(Bases).@"struct".field_names;

pub const Frame = struct {
    input: Input = undefined,
    bases: Bases = undefined,
    views: [names.len][]u8 = undefined,
    columns: [names.len][]const u8 = undefined,
    counts: [names.len]u64 = undefined,
    pub fn prepare(self: *Frame, builder: *Builder, source: *const ir.ExpressionTable, borrow_text: bool) Builder.Error!bool {
        const storage = &builder.expressions;
        var count: usize = 0;
        var owned: ?[]const []const u8 = null;

        inline for (names, 0..) |name, index| {
            const values = @field(source, name);
            const target = &@field(storage, name);

            @field(self.bases, name) = target.items.len;

            self.counts[index] = values.len;

            if (values.len != 0) {
                try storage.reserveColumns(builder.allocator, &.{name}, values.len);

                const own_text = comptime std.mem.eql(u8, name, "strings");

                if (own_text and !borrow_text) {
                    owned = values;
                } else {
                    self.views[count] = std.mem.sliceAsBytes(target.unusedCapacitySlice()[0..values.len]);
                    self.columns[count] = std.mem.sliceAsBytes(values);
                    count += 1;
                }
            }
        }

        self.input = .{
            .columns = self.columns[0..count],
            .owned_text = owned,
            .counts = &self.counts,
        };

        return count != 0 or owned != null;
    }
    pub fn commit(self: *const Frame, builder: *Builder, rows: *const Input) Builder.Error!void {
        const storage = &builder.expressions;

        copyColumns(self.views[0..rows.columns.len], rows.columns);

        if (rows.owned_text) |text| try ownText(builder.allocator, storage.strings.unusedCapacitySlice()[0..text.len], text);

        inline for (names, 0..) |name, index| @field(storage, name).items.len += rows.counts[index];
    }
};

pub fn copyColumns(targets: []const []u8, sources: []const []const u8) void {
    for (targets, sources) |target, source| @memcpy(target, source);
}

pub fn ownText(allocator: std.mem.Allocator, targets: [][]const u8, sources: []const []const u8) std.mem.Allocator.Error!void {
    var copied: usize = 0;

    errdefer for (targets[0..copied]) |text| allocator.free(text);

    for (targets, sources) |*target, source| {
        target.* = try allocator.dupe(u8, source);
        copied += 1;
    }
}
