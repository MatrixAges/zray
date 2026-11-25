const std = @import("std");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub const Declaration = struct {
    name: []const u8,
    layout: node.ExpressionId,
    initial: node.ExpressionId,
    mutable: bool = true,
    tracking: ?[]const u8 = null,
};

pub const Tracker = union(enum) {
    seed: []const u8,
    generated: @FieldType(node.Statement, "assignment"),
    pub fn markSeed(self: Tracker, lowering: *Lower, body: *std.ArrayList(node.Statement)) Lower.Error!void {
        const target = try lowering.builder.identifier(self.seed);
        const value = try lowering.builder.expression(.{ .boolean = true });

        try body.append(lowering.allocator, .{ .assignment = .{ .target = target, .value = value } });
    }
};

pub fn declare(self: *Lower, body: *@import("../iteration_value/root.zig").Statements, args: Declaration) Lower.Error!?Tracker {
    if (!@import("genz_options").generated_analysis) return seed(self, body, args);

    const entry = @import("generated_iteration_state_declaration");
    const Input = std.meta.Child(entry.Input);
    const Binding = std.meta.Child(@FieldType(Input, "declaration"));

    const binding: Binding = .{
        .name = args.name,
        .layout = @backingInt(args.layout),
        .initial = @backingInt(args.initial),
        .mutable = args.mutable,
    };

    const input: Input = .{
        .writer = @ptrCast(self),
        .body = @ptrCast(body),
        .declaration = &binding,
        .tracking = args.tracking,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = (entry.executeIn(memory.allocator(), &input) catch |err| return failure(err)) orelse return null;

    return .{ .generated = .{
        .target = @fromBackingInt(output.target),
        .value = @fromBackingInt(output.value),
    } };
}

fn seed(self: *Lower, body: *std.ArrayList(node.Statement), args: Declaration) Lower.Error!?Tracker {
    const declaration: node.Constant = .{ .name = args.name, .type_expr = args.layout, .value = args.initial };

    try body.append(self.allocator, if (args.mutable) .{ .variable = declaration } else .{ .constant = declaration });

    const name = args.tracking orelse return null;

    try body.append(self.allocator, .{ .variable = .{
        .name = name,
        .value = try self.builder.expression(.{ .boolean = false }),
    } });

    return .{ .seed = name };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
