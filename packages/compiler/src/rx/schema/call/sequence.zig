const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");

pub fn check(parent: anytype, context: anytype, reporter: *dsl.Reporter) dsl.Error!void {
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

        if (std.mem.eql(u8, child.name(), "Call")) {
            if (!available and checks.attribute(child, "fn") != null and checks.attribute(child, "in") == null) {
                return fail(child.location(), reporter);
            }

            available = sequential;
        } else {
            available = sequential and std.mem.eql(u8, child.name(), "Task") and checks.attribute(child, "out") != null;

            if (child.childCount() != 0) try checkTree(child, reporter);
        }
    }
}
