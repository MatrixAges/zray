const std = @import("std");
const Lower = @import("../../lower.zig");
const evaluation = @import("../../expressions/evaluate.zig");
const Sequence = @import("../../../node/blocks.zig").Sequence;
const rows = @import("../../../node/import_rows.zig");
const field_rows = @import("../../../node/import_fields.zig");
const Layout = std.meta.Child(@import("generated_loop_fields_layout").Output);
const Projection = std.meta.Child(@typeInfo(@import("generated_loop_fields_projection").Output).optional.child);
const Error = Lower.Error;

const Frame = struct {
    lowering: *Lower,
    body: ?*Sequence = null,
    source: union(enum) {
        layout: *const Layout,
        projection: *const Projection,
    },
    name: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

pub fn layout(lowering: *Lower, body: *Sequence, output: *const Layout) Error!void {
    var frame: Frame = .{ .lowering = lowering, .body = body, .source = .{ .layout = output } };

    return publish(&frame, output.valid, output.origin_owned);
}

pub fn projection(lowering: *Lower, output: *const Projection) Error!void {
    var frame: Frame = .{ .lowering = lowering, .source = .{ .projection = output } };

    return publish(&frame, output.valid, output.origin_owned);
}

fn publish(frame: *Frame, valid: bool, origin: bool) Error!void {
    if (!valid) return error.OutOfMemory;

    const entry = @import("generated_publish_loop_fields");
    const input: std.meta.Child(entry.Input) = .{ .target = @ptrCast(frame), .layout = frame.source == .layout, .origin = origin };

    return evaluation.execute(entry, &input);
}

pub fn ownLoopBindingName(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    frame.name = try frame.lowering.allocator.dupe(u8, frame.source.layout.statements.constant_name[0]);
}

pub fn ownLoopOriginName(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    const names = switch (frame.source) {
        .layout => |output| output.fields.name,
        .projection => |output| output.expressions.field_name,
    };

    frame.origin = try frame.lowering.allocator.dupe(u8, names[names.len - 1]);
}

pub fn appendLoopFieldExpressions(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const target = &self.builder.nodes.expressions;

    switch (frame.source) {
        inline else => |output| rows.appendBorrowed(self.allocator, target, output.expressions) catch |err| return failure(err),
    }

    switch (frame.source) {
        .layout => {
            const identifiers = target.payloads.identifier.values.items;

            identifiers[identifiers.len - 1] = frame.name.?;
        },
        .projection => if (frame.origin) |origin| {
            const names = target.payloads.field.fields.name.values.items;

            names[names.len - 1] = origin;
        },
    }
}

pub fn appendLoopFields(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const target = &self.builder.nodes.field_columns;

    const source = switch (frame.source) {
        inline else => |output| output.fields,
    };

    _ = field_rows.appendBorrowingText(self.allocator, target, source) catch |err| return failure(err);

    if (frame.origin) |origin| {
        const names = target.fields.name.values.items;

        names[names.len - 1] = origin;
    }
}

pub fn finishLoopFieldLayout(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const output = frame.source.layout;
    const names = [_][]const u8{frame.name.?};
    var source = output.statements.*;
    source.constant_name = &names;
    @import("../../../node/import_statements.zig").appendBorrowingText(self.allocator, frame.body.?, &source) catch |err| return failure(err);
    self.serial = @intCast(output.serial);
}

fn failure(err: rows.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidAst => unreachable,
    };
}
