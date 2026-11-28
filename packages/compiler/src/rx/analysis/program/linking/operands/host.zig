const std = @import("std");
const zx = @import("zx");
const Builder = @import("../../builder.zig");
const Request = @import("../abi.zig").Request;
const Source = std.meta.Child(@typeInfo(@FieldType(Request, "operands")).optional.child);
const Symbols = std.meta.Child(@FieldType(Source, "symbols"));
const Metadata = std.meta.Child(@FieldType(Source, "metadata"));
const rules = @import("generated_rx_operand_layout");
const Kind = rules.Input;
const Column = std.meta.Elem(std.meta.Elem(@FieldType(Source, "headers")));

const Layout = struct {
    header: [7]Column = undefined,
    members: [3]Column = undefined,
    header_len: usize,
    members_len: usize,
};

const layouts = blk: {
    @setEvalBranchQuota(100_000);

    var result: [@typeInfo(Kind).@"enum".field_names.len]Layout = undefined;

    for (&result, 0..) |*target, index| {
        var buffer: [2048]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);
        const layout = rules.executeValue(scratch.allocator(), @fromBackingInt(index)) catch unreachable;

        target.* = .{ .header_len = layout.header.len, .members_len = layout.members.len };

        @memcpy(target.header[0..target.header_len], layout.header);
        @memcpy(target.members[0..target.members_len], layout.members);
    }

    break :blk result;
};

const headers = blk: {
    var rows: [layouts.len][]const Column = undefined;

    for (&layouts, &rows) |*layout, *row| row.* = layout.header[0..layout.header_len];

    break :blk rows;
};

pub const Frame = struct {
    input: Source = undefined,
    symbols: Symbols = undefined,
    metadata: Metadata = undefined,
    empty: usize = 0,
    slots: [1 + 2 * layouts.len]*usize = undefined,
    lengths: zx.memory.ColumnLengths = undefined,
    pub fn initialize(self: *Frame, storage: *zx.ir.ExpressionStorage, source: *const zx.ir.ExpressionTable) void {
        comptime std.debug.assert(@sizeOf(std.meta.Elem(@TypeOf(source.kinds))) == @sizeOf(u8));

        self.slots[0] = &storage.object_evaluation_values.items.len;

        inline for (layouts, 0..) |layout, index| {
            const first = 1 + index * 2;
            self.slots[first] = if (comptime layout.header_len == 0) &self.empty else &@field(storage, @tagName(layout.header[0])).items.len;
            self.slots[first + 1] = if (comptime layout.members_len == 0) &self.empty else &@field(storage, @tagName(layout.members[0])).items.len;
        }

        self.lengths = &self.slots;

        self.metadata = .{
            .kinds = std.mem.sliceAsBytes(source.kinds),
            .unary = std.mem.sliceAsBytes(source.unary_operators),
            .binary = std.mem.sliceAsBytes(source.binary_operators),
            .iteration = std.mem.sliceAsBytes(source.iteration_postconditions),
            .collection = std.mem.sliceAsBytes(source.collection_kinds),
            .transform = std.mem.sliceAsBytes(source.transform_kinds),
            .scope = std.mem.sliceAsBytes(source.scope_borrows),
        };

        self.input = .{
            .data = zx.columns.pointer(@FieldType(Source, "data"), source),
            .metadata = &self.metadata,
            .symbols = &self.symbols,
            .mapping = &.{},
            .headers = &headers,
            .lengths = @ptrCast(&self.lengths),
        };
    }

    pub fn bind(self: *Frame, mapping: *const @import("../../mapping.zig")) void {
        self.symbols = @import("../operands.zig").symbolView(Symbols, mapping);
        self.input.mapping = mapping.expressions;
    }

    pub fn commit(builder: *Builder, publication: anytype) Builder.Error!void {
        const storage = &builder.expressions;
        const layout = &layouts[publication.kind];
        const patch = publication.patch;
        const header = layout.header[0..layout.header_len];
        const members = layout.members[0..layout.members_len];

        for (header) |key| try reserveColumn(storage, builder.allocator, key, 1);
        for (members) |key| try reserveColumn(storage, builder.allocator, key, publication.count);

        if (patch.evaluation) |values| {
            try reserveColumn(storage, builder.allocator, .object_evaluation_values, values.len);
        }

        for (header, patch.header) |key, cell| {
            switch (key) {
                inline else => |column| {
                    const target = &@field(storage, @tagName(column));
                    const Item = std.meta.Elem(@TypeOf(target.items));

                    const value: Item = switch (Item) {
                        u32 => cell.word.?,
                        ?u32 => cell.symbol,
                        bool => cell.byte.? != 0,
                        else => @fromBackingInt(@as(@typeInfo(Item).@"enum".tag_type, @intCast(cell.byte.?))),
                    };

                    target.appendAssumeCapacity(value);
                },
            }
        }

        for (members, patch.members) |key, values| {
            switch (key) {
                inline else => |column| {
                    const target = &@field(storage, @tagName(column));
                    const Item = std.meta.Elem(@TypeOf(target.items));

                    switch (Item) {
                        u32 => target.appendSliceAssumeCapacity(values.words.?),
                        ?u32 => target.appendSliceAssumeCapacity(values.symbols.?),
                        bool => {
                            const bytes = values.bytes.?;

                            @memcpy(std.mem.sliceAsBytes(target.unusedCapacitySlice()[0..bytes.len]), bytes);

                            target.items.len += bytes.len;
                        },
                        else => unreachable,
                    }
                },
            }
        }

        if (patch.evaluation) |values| storage.object_evaluation_values.appendSliceAssumeCapacity(values);
    }
};

fn reserveColumn(storage: *zx.ir.ExpressionStorage, allocator: std.mem.Allocator, key: Column, count: usize) std.mem.Allocator.Error!void {
    return switch (key) {
        inline else => |column| storage.reserveColumns(allocator, &.{@tagName(column)}, count),
    };
}
