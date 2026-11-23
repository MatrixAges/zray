const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");
const tree = @import("../tree/adapter.zig");

pub fn check(allocator: std.mem.Allocator, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    if (node.childCount() < 2) return;

    if (comptime @import("rx_options").generated_rules and tree.supports(@TypeOf(node))) {
        const finding = try tree.run(@import("generated_rx_module_schema"), allocator, node) orelse return;
        const child = dsl.ast.childAt(node, @intCast(finding.index));

        return switch (finding.issue) {
            .DuplicateType => checks.fail(child, "as", "Duplicate RX declaration", reporter),
            .LateType => checks.fail(child, "from", "Type declarations must precede Args and module steps", reporter),
            .MisplacedArgs => checks.fail(child, "in", "Args must appear once after Type declarations and before module steps", reporter),
            .DuplicateStore => duplicateStore(child, reporter),
        };
    }

    return checkSeed(node, reporter);
}

fn duplicateStore(child: anytype, reporter: *dsl.Reporter) dsl.Error {
    return checks.fail(child, if (checks.attribute(child, "as") != null) "as" else "from", "Store reference alias is already registered", reporter);
}

fn checkSeed(node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    try checks.uniqueChildren(node, "Type", "as", reporter);

    var has_args = false;
    var has_steps = false;
    var children = node.children();
    var index: usize = 0;

    while (children.next()) |input| : (index += 1) {
        const child = dsl.ast.view(input);

        if (std.mem.eql(u8, child.name(), "Type")) {
            if (has_args or has_steps) return checks.fail(child, "from", "Type declarations must precede Args and module steps", reporter);

            continue;
        }

        if (std.mem.eql(u8, child.name(), "Args")) {
            if (has_args or has_steps) return checks.fail(child, "in", "Args must appear once after Type declarations and before module steps", reporter);

            has_args = true;

            continue;
        }

        has_steps = true;

        if (!std.mem.eql(u8, child.name(), "Store")) continue;

        const alias = checks.attribute(child, "as") orelse checks.attribute(child, "from").?;
        var earlier = node.children();

        for (0..index) |_| {
            const previous = dsl.ast.view(earlier.next().?);

            if (!std.mem.eql(u8, previous.name(), "Store")) continue;

            const prior = checks.attribute(previous, "as") orelse checks.attribute(previous, "from").?;

            if (std.mem.eql(u8, alias, prior)) return duplicateStore(child, reporter);
        }
    }
}
