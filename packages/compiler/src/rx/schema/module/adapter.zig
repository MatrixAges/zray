const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");
const rule = @import("generated_rx_module_schema");
const Input = std.meta.Child(rule.Input);
const Declaration = struct { tag: std.meta.Child(@FieldType(Input, "tags")), name: []const u8, child: u64 };
const RuleResult = std.meta.Child(rule.Output);
const RuleFinding = if (@typeInfo(RuleResult) == .pointer) std.meta.Child(RuleResult) else RuleResult;
const Finding = struct { issue: @FieldType(RuleFinding, "issue"), index: usize };

pub fn check(allocator: std.mem.Allocator, children: anytype, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const finding = try find(allocator, children) orelse return;
    const child = dsl.ast.childAt(node, finding.index);

    return switch (finding.issue) {
        .DuplicateType => checks.fail(child, "as", "Duplicate RX declaration", reporter),
        .LateType => checks.fail(child, "from", "Type declarations must precede Args and module steps", reporter),
        .MisplacedArgs => checks.fail(child, "in", "Args must appear once after Type declarations and before module steps", reporter),
        .DuplicateStore => checks.fail(child, if (children[finding.index].store.attributes.as != null) "as" else "from", "Store reference alias is already registered", reporter),
    };
}

fn find(allocator: std.mem.Allocator, children: anytype) std.mem.Allocator.Error!?Finding {
    if (children.len < 2) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [512]u8 align(@alignOf(Declaration)) = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    var declarations: std.MultiArrayList(Declaration) = .empty;

    for (children, 0..) |child, index| {
        const declaration: Declaration = switch (child) {
            .type => |item| .{ .tag = .Type, .name = item.attributes.as, .child = index },
            .store => |item| .{ .tag = .Store, .name = item.attributes.as orelse item.attributes.from, .child = index },
            .args => .{ .tag = .Args, .name = "", .child = index },
            else => continue,
        };

        try declarations.append(temporary, declaration);
    }

    if (declarations.len == 0) return null;

    const rows = declarations.slice();

    const finding = rule.executeValue(temporary, &.{
        .tags = rows.items(.tag),
        .names = rows.items(.name),
        .children = rows.items(.child),
    }) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    } orelse return null;

    return .{ .issue = finding.issue, .index = @intCast(finding.index) };
}
