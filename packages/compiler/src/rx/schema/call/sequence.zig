const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");

pub fn check(parent: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const sequential = !std.mem.eql(u8, parent.name(), "Parallel");
    var available = false;
    var children = parent.children();

    while (children.next()) |item| {
        const child = dsl.ast.view(item);

        if (std.mem.eql(u8, child.name(), "Call")) {
            if (!available and checks.attribute(child, "fn") != null and checks.attribute(child, "in") == null) {
                return reporter.fail(.{ .code = .missing_attribute, .location = child.location(), .element = child.name(), .attribute = "in", .message = "Call.fn needs in or a preceding output in the same sequence" });
            }

            available = sequential;
        } else {
            available = sequential and std.mem.eql(u8, child.name(), "Task") and checks.attribute(child, "out") != null;

            if (child.childCount() != 0) try check(child, reporter);
        }
    }
}
