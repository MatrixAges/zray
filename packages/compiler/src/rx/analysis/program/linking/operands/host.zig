const std = @import("std");
const zx = @import("zx");
const State = @import("../host.zig").State;
const Request = @import("../abi.zig").Request;
const Work = std.meta.Child(@FieldType(Request, "operands"));
const Allocation = std.meta.Child(@FieldType(Work, "allocation"));
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
    allocation: Allocation = undefined,
    symbols: Symbols = undefined,
    header: zx.memory.ColumnRangeGroup(7) = .{},
    members: zx.memory.ColumnRangeGroup(3) = .{},
    evaluation: zx.memory.ColumnRangeGroup(1) = .{},
    pub fn initialize(self: *Frame, state: *State) void {
        self.input = .{
            .frame = @ptrCast(state),
            .data = zx.columns.pointer(@FieldType(Work, "data"), &state.program.expressions),
            .allocation = &self.allocation,
            .symbols = &self.symbols,
            .mapping = &.{},
            .index = undefined,
            .row = undefined,
            .slots = &.{},
            .route = undefined,
        };
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

    frame.header.len = 0;
    frame.members.len = 0;
    frame.evaluation.len = 0;

    for (header) |column| bind(&frame.header, storage, column, 1);
    for (members) |column| bind(&frame.members, storage, column, count);
    if (route == .Object) bind(&frame.evaluation, storage, .object_evaluation_values, evaluation_count);

    frame.symbols = @import("../operands.zig").symbolView(Symbols, &state.mapping);
    frame.input.slots = header;
    frame.input.route = route;
    frame.input.index = index;
    frame.input.row = state.program.expressions.payloads[index];
    frame.input.mapping = state.mapping.expressions[0..index];

    frame.allocation = .{
        .resource = @ptrCast(&builder.allocator),
        .header = @ptrCast(ranges(&frame.header)),
        .members = @ptrCast(ranges(&frame.members)),
        .evaluation = @ptrCast(ranges(&frame.evaluation)),
    };
}

var empty: zx.memory.ColumnRanges = &.{};

fn ranges(group: anytype) *anyopaque {
    return @ptrCast(group.freeze() orelse &empty);
}

fn bind(group: anytype, storage: *zx.ir.ExpressionStorage, key: Column, count: usize) void {
    switch (key) {
        inline else => |column| {
            const target = &@field(storage, @tagName(column));
            const Item = std.meta.Elem(@TypeOf(target.items));

            _ = group.bind(target, count, @typeInfo(Item) == .@"enum" or Item == bool);
        },
    }
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
