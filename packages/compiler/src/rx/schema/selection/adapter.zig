const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");
const rule = @import("generated_rx_selection_schema");
const Input = std.meta.Child(rule.Input);
const Branch = std.meta.Child(@FieldType(Input, "branches"));
const RuleResult = std.meta.Child(rule.Output);
const RuleFinding = if (@typeInfo(RuleResult) == .pointer) std.meta.Child(RuleResult) else RuleResult;
const Finding = struct { issue: @FieldType(RuleFinding, "issue"), index: usize };
const table_load_ratio = 2;

pub fn checkIf(allocator: std.mem.Allocator, children: anytype, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    var buffer: [256]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    const branches = try scratch.allocator().alloc(Branch, children.len);

    defer scratch.allocator().free(branches);

    for (children, branches) |child, *branch| branch.* = if (child == .@"else") .Else else .Step;

    var empty: []u64 = &.{};

    const finding = try run(allocator, &.{
        .kind = .If,
        .branches = branches,
        .keys = &.{},
        .string_buckets = @ptrCast(&empty),
        .expression_buckets = @ptrCast(&empty),
        .string_capacity = 0,
        .expression_capacity = 0,
    }) orelse return;

    return misplacedElse(dsl.ast.childAt(node, finding.index), reporter);
}

pub fn misplacedElse(input: anytype, reporter: *dsl.Reporter) dsl.Error {
    const child = dsl.ast.view(input);

    return reporter.fail(.{
        .code = .context,
        .location = child.location(),
        .element = child.name(),
        .message = "Else must follow the If body and appear once at the end",
    });
}

pub fn checkSwitch(allocator: std.mem.Allocator, children: anytype, node: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const finding = try findSwitch(allocator, children, node) orelse return;
    const child = dsl.ast.childAt(node, finding.index);

    return switch (finding.issue) {
        .DuplicateCase => checks.fail(child, "value", "Duplicate RX declaration", reporter),
        .DuplicateDefault => repeatedDefault(child, reporter),
        .MisplacedElse => unreachable,
    };
}

pub fn repeatedDefault(input: anytype, reporter: *dsl.Reporter) dsl.Error {
    const child = dsl.ast.view(input);

    return reporter.fail(.{
        .code = .context,
        .location = child.location(),
        .element = child.name(),
        .message = "Switch allows at most one Default",
    });
}

fn findSwitch(allocator: std.mem.Allocator, children: anytype, input: anytype) std.mem.Allocator.Error!?Finding {
    if (children.len < 2) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [512]u8 align(@alignOf(u64)) = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    const keys = try temporary.alloc([]const u8, children.len);
    const branches = try temporary.alloc(Branch, children.len);
    var nodes = dsl.ast.view(input).children();
    var strings_count: usize = 0;
    var expressions_count: usize = 0;

    for (children, branches, keys) |child, *branch, *key| {
        const element = nodes.next().?;

        if (child == .default) {
            branch.* = .Default;
            key.* = "";

            continue;
        }

        const attribute = dsl.ast.view(element).schemaAttribute(0);

        key.* = attribute.value;

        if (attribute.kind == .expression) {
            branch.* = .ExpressionCase;
            expressions_count += 1;
        } else {
            branch.* = .TextCase;
            strings_count += 1;
        }
    }

    const strings = try buckets(temporary, strings_count);
    const expressions = try buckets(temporary, expressions_count);

    return run(temporary, &.{
        .kind = .Switch,
        .branches = branches,
        .keys = keys,
        .string_buckets = @ptrCast(&strings),
        .expression_buckets = @ptrCast(&expressions),
        .string_capacity = strings.len,
        .expression_capacity = expressions.len,
    });
}

fn buckets(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]u64 {
    if (count < 2) return &.{};

    const required = std.math.mul(usize, count, table_load_ratio) catch return error.OutOfMemory;
    const capacity = std.math.ceilPowerOfTwo(usize, required) catch return error.OutOfMemory;
    const storage = try allocator.alloc(u64, capacity);

    @memset(storage, 0);

    return storage;
}

fn run(allocator: std.mem.Allocator, input: *const Input) std.mem.Allocator.Error!?Finding {
    const finding = rule.executeValue(allocator, input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    } orelse return null;

    return .{ .issue = finding.issue, .index = @intCast(finding.index) };
}
