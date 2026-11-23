const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");
const tree = @import("../tree/adapter.zig");

pub fn check(allocator: std.mem.Allocator, parent: anytype, context: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    if (comptime @hasDecl(@TypeOf(parent), "missingCall")) {
        if (parent.missingCall()) |location| return fail(location, reporter);

        return;
    }

    if (comptime @TypeOf(context) == ?@import("frontend").xml_references.Sequence) {
        if (context) |sequence| {
            if (sequence.missing) |node| return fail(node.location, reporter);

            return;
        }
    }

    if (comptime @import("rx_options").generated_rules and tree.supports(@TypeOf(parent))) {
        if (parent.childCount() == 0) return;

        const found = try tree.run(@import("generated_rx_call_input_tree"), allocator, parent) orelse return;

        return fail(tree.location(parent, found), reporter);
    }

    return checkTree(parent, reporter);
}

fn fail(location: dsl.ast.Location, reporter: *dsl.Reporter) dsl.Error {
    return reporter.fail(.{ .code = .missing_attribute, .location = location, .element = "Call", .attribute = "in", .message = "Call.fn needs in or a preceding output in the same sequence" });
}

fn checkTree(parent: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const sequential = !std.mem.eql(u8, parent.name(), "Parallel");
    var available = false;
    var children = parent.children();

    while (children.next()) |item| {
        const child = dsl.ast.view(item);

        const call = if (std.mem.eql(u8, child.name(), "Loop"))
            dsl.ast.view(dsl.ast.childAt(child, 0))

        else
            child;

        if (std.mem.eql(u8, call.name(), "Call")) {
            if (!available and checks.attribute(call, "fn") != null and checks.attribute(call, "in") == null) {
                return fail(call.location(), reporter);
            }

            available = sequential;
        } else {
            available = sequential and std.mem.eql(u8, child.name(), "Task") and checks.attribute(child, "out") != null;

            if (child.childCount() != 0) try checkTree(child, reporter);
        }
    }
}
