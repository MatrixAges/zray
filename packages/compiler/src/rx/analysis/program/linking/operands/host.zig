const std = @import("std");
const zx = @import("zx");
const Builder = @import("../../builder.zig");
const State = @import("../host.zig").State;
const Request = @import("../abi.zig").Request;
const Work = std.meta.Child(@FieldType(Request, "operands"));
const Symbols = std.meta.Child(@FieldType(Work, "symbols"));
const Column = std.meta.Elem(@FieldType(Work, "slots"));
const Route = @FieldType(Work, "route");
const rules = @import("generated_rx_operand_layout");
const Kind = rules.Input;

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

pub const Frame = struct {
    input: Work = undefined,
    symbols: Symbols = undefined,
    layout: *const Layout = undefined,
    member_count: usize = undefined,
    evaluation_count: usize = undefined,
    pub fn initialize(self: *Frame, state: *State) void {
        self.input = .{
            .frame = @ptrCast(state),
            .data = zx.columns.pointer(@FieldType(Work, "data"), &state.program.expressions),
            .symbols = &self.symbols,
            .mapping = &.{},
            .index = undefined,
            .row = undefined,
            .payload = undefined,
            .members_first = undefined,
            .evaluation_first = undefined,
            .slots = &.{},
            .route = undefined,
        };
    }
    pub fn commit(self: *const Frame, builder: *Builder, patch: anytype) Builder.Error!void {
        const storage = &builder.expressions;
        const layout = self.layout;
        const header = layout.header[0..layout.header_len];
        const members = layout.members[0..layout.members_len];

        for (header) |key| try reserveColumn(storage, builder.allocator, key, 1);
        for (members) |key| try reserveColumn(storage, builder.allocator, key, self.member_count);

        if (patch.evaluation != null) {
            try reserveColumn(storage, builder.allocator, .object_evaluation_values, self.evaluation_count);
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

pub fn bindExpressionOperands(handle: *anyopaque, index: u32, route: Route, count: u32, evaluation_count: u32) error{InvalidModule}!void {
    const state = State.borrow(handle);
    const frame = &state.operands;
    const builder = state.builder;
    const storage = &builder.expressions;
    const layout = &layouts[@backingInt(state.program.expressions.kinds[index])];
    const header = layout.header[0..layout.header_len];
    const members = layout.members[0..layout.members_len];

    if (header.len == 0) return error.InvalidModule;

    frame.layout = layout;
    frame.member_count = count;
    frame.evaluation_count = evaluation_count;
    frame.symbols = @import("../operands.zig").symbolView(Symbols, &state.mapping);
    frame.input.slots = header;
    frame.input.route = route;
    frame.input.index = index;
    frame.input.row = state.program.expressions.payloads[index];
    frame.input.mapping = state.mapping.expressions[0..index];
    frame.input.payload = @intCast(columnLength(storage, header[0]));
    frame.input.members_first = if (members.len == 0) 0 else columnLength(storage, members[0]);
    frame.input.evaluation_first = storage.object_evaluation_values.items.len;
}

fn columnLength(storage: *const zx.ir.ExpressionStorage, key: Column) usize {
    return switch (key) {
        inline else => |column| @field(storage, @tagName(column)).items.len,
    };
}

fn reserveColumn(storage: *zx.ir.ExpressionStorage, allocator: std.mem.Allocator, key: Column, count: usize) std.mem.Allocator.Error!void {
    return switch (key) {
        inline else => |column| storage.reserveColumns(allocator, &.{@tagName(column)}, count),
    };
}

pub fn expressionOperandWords(handle: *anyopaque, key: Column) []const u32 {
    const data = &State.borrow(handle).program.expressions;

    return switch (key) {
        inline else => |column| if (@TypeOf(@field(data, @tagName(column))) == []const u32)
            @field(data, @tagName(column))
        else
            unreachable,
    };
}

pub fn expressionOperandBytes(handle: *anyopaque, key: Column) []const u8 {
    const data = &State.borrow(handle).program.expressions;

    return switch (key) {
        inline else => |column| std.mem.sliceAsBytes(@field(data, @tagName(column))),
    };
}

pub fn requireExpressionOperand(valid: bool) error{InvalidModule}!void {
    if (!valid) return error.InvalidModule;
}
