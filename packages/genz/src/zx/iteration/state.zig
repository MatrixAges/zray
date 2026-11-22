const std = @import("std");
const zx = @import("zx");
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const statements = @import("../../node/import_statements.zig");

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
        .declaration = &binding,
        .tracking = args.tracking,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.FixedBufferAllocator.init(&buffer);
    const output = zx.columns.invoke(entry.executeValue, memory.allocator(), &input) catch |err| return failure(err);
    const frame: Publication = .{ .lowering = self, .body = body, .output = &output };
    const publish = @import("generated_publish_loop_state");

    const publication: std.meta.Child(publish.Input) = .{
        .target = @ptrCast(&frame),
        .tracked = output.tracker != null,
    };

    try @import("../expressions/evaluate.zig").execute(publish, &publication);

    const tracker = output.tracker orelse return null;

    return .{ .generated = .{
        .target = @fromBackingInt(tracker.target),
        .value = @fromBackingInt(tracker.value),
    } };
}

const state_entry = @import("generated_iteration_state_declaration");
const StateOutput = std.meta.Child(state_entry.Output);
const StateValue = @typeInfo(@typeInfo(@TypeOf(state_entry.executeValue)).@"fn".return_type.?).error_union.payload;

const Publication = struct {
    lowering: *Lower,
    body: *@import("../../node/blocks.zig").Sequence,
    output: *const StateValue,
    fn borrow(handle: *const anyopaque) *const Publication {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn appendLoopState(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const declaration = zx.columns.view(std.meta.Child(@FieldType(StateOutput, "declaration")), frame.output.declaration);

    statements.appendBorrowingText(frame.lowering.allocator, frame.body, &declaration) catch |err| return failure(err);
}

pub fn appendLoopTracker(handle: *const anyopaque) Lower.Error!void {
    const frame = Publication.borrow(handle);
    const tracker = frame.output.tracker.?;
    const lowering = frame.lowering;
    const TrackerOutput = std.meta.Child(@typeInfo(@FieldType(StateOutput, "tracker")).optional.child);
    const expressions = zx.columns.view(std.meta.Child(@FieldType(TrackerOutput, "expressions")), tracker.expressions);
    const flag = zx.columns.view(std.meta.Child(@FieldType(TrackerOutput, "declaration")), tracker.declaration);
    @import("../../node/import_rows.zig").appendBorrowed(lowering.allocator, &lowering.builder.nodes.expressions, &expressions) catch |err| return failure(err);

    statements.appendBorrowingText(lowering.allocator, frame.body, &flag) catch |err| return failure(err);
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
