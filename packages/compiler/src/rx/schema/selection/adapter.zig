const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");
const tree = @import("../tree/adapter.zig");
const generated = @import("rx_options").generated_rules;

pub fn checkIf(allocator: std.mem.Allocator, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    if (comptime generated and tree.supports(@TypeOf(node))) {
        const finding = try tree.run(@import("generated_rx_if_schema"), allocator, node) orelse return;

        return misplacedElse(dsl.ast.childAt(node, @intCast(finding.index)), reporter);
    }

    var children = node.children();
    var index: usize = 0;

    while (children.next()) |input| : (index += 1) {
        const child = dsl.ast.view(input);

        if (!std.mem.eql(u8, child.name(), "Else")) continue;
        if (index == 0 or index + 1 != node.childCount()) return misplacedElse(child, reporter);
    }
}

fn misplacedElse(input: anytype, reporter: *dsl.Reporter) dsl.Error {
    const child = dsl.ast.view(input);

    return reporter.fail(.{
        .code = .context,
        .location = child.location(),
        .element = child.name(),
        .message = "Else must follow the If body and appear once at the end",
    });
}

pub fn checkSwitch(allocator: std.mem.Allocator, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    if (node.childCount() < 2) return;

    if (comptime generated and tree.supports(@TypeOf(node))) {
        const finding = try tree.run(@import("generated_rx_switch_schema"), allocator, node) orelse return;
        const child = dsl.ast.childAt(node, @intCast(finding.index));

        return switch (finding.issue) {
            .DuplicateCase => checks.fail(child, "value", "Duplicate RX declaration", reporter),
            .DuplicateDefault => repeatedDefault(child, reporter),
            .MisplacedElse => unreachable,
        };
    }

    try checks.uniqueChildren(node, "Case", "value", reporter);

    var default_seen = false;
    var children = node.children();

    while (children.next()) |input| {
        const child = dsl.ast.view(input);

        if (!std.mem.eql(u8, child.name(), "Default")) continue;
        if (default_seen) return repeatedDefault(child, reporter);

        default_seen = true;
    }
}

fn repeatedDefault(input: anytype, reporter: *dsl.Reporter) dsl.Error {
    const child = dsl.ast.view(input);

    return reporter.fail(.{
        .code = .context,
        .location = child.location(),
        .element = child.name(),
        .message = "Switch allows at most one Default",
    });
}
