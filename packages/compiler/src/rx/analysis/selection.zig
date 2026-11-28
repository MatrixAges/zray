const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const Prepared = @import("project/flow.zig");
const Diagnostic = @import("expression.zig").Diagnostic;
const Value = @FieldType(zx.ir.ExpressionRow, "value");
const enabled = @import("rx_options").generated_graph;
const Result = union(enum) { exhaustive: bool, diagnostic: Diagnostic };
const rule = if (enabled) @import("generated_rx_selection_check") else void;
const Input = if (enabled) std.meta.Child(rule.Input) else void;
const Label = if (enabled) std.meta.Elem(@FieldType(Input, "labels")) else void;
const View = if (enabled) std.meta.Child(std.meta.Child(Label)) else void;

pub fn check(allocator: std.mem.Allocator, types: zx.ir.TypeTable, subject: *const zx.ir.Program, attribute: rx.ast.Attribute, cases: []const ?*const zx.ir.Program, sources: []const Prepared.Case) std.mem.Allocator.Error!Result {
    if (comptime !enabled) return seed(types, subject, attribute, cases, sources);

    var arena = std.heap.ArenaAllocator.init(allocator);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const temporary = scratch.allocator();
    const target = types.get(subject.output_type);
    const labels = try temporary.alloc(Label, cases.len);
    const views = try temporary.alloc(View, cases.len);

    for (cases, labels, views) |program, *label_view, *view| {
        if (program) |value| {
            view.* = labelView(value);
            label_view.* = view;
        } else {
            label_view.* = null;
        }
    }

    const input: Input = .{
        .subject = &.{
            .type_id = @backingInt(subject.output_type),
            .enum_members = if (target == .enumeration) target.enumeration.members.len else null,
            .case_count = cases.len,
        },
        .labels = labels,
    };

    const result = rule.executeIn(temporary, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    if (!result.coverage.valid) return invalidSubject(attribute);

    if (result.failure.index) |index| {
        const source = sources[@intCast(index)].label.attribute().?;

        return if (result.failure.duplicate) duplicate(source) else invalidLabel(source);
    }

    return .{ .exhaustive = result.coverage.exhaustive };
}

fn labelView(program: *const zx.ir.Program) View {
    return .{
        .control = zx.columns.pointer(@FieldType(View, "control"), program.body.control),
        .expressions = zx.columns.pointer(@FieldType(View, "expressions"), &program.expressions),
        .root = if (program.body.root) |root| @backingInt(root) else null,
    };
}

fn seed(types: zx.ir.TypeTable, subject: *const zx.ir.Program, attribute: rx.ast.Attribute, cases: []const ?*const zx.ir.Program, sources: []const Prepared.Case) Result {
    const type_id = subject.output_type;
    const value_type = types.get(type_id);
    const integer = @backingInt(type_id) >= @backingInt(zx.ir.Scalar.u8) and @backingInt(type_id) <= @backingInt(zx.ir.Scalar.i64);
    const boolean = @backingInt(type_id) == @backingInt(zx.ir.Scalar.bool);
    const string = @backingInt(type_id) == @backingInt(zx.ir.Scalar.string);

    if (value_type != .enumeration and !integer and !boolean and !string) return invalidSubject(attribute);

    var has_default = false;

    for (cases, sources, 0..) |case, source, index| {
        const program = case orelse {
            has_default = true;

            continue;
        };

        const value = label(program.*);

        switch (value) {
            .integer, .negative_integer, .string, .boolean, .enum_value => {},
            else => return invalidLabel(source.label.attribute().?),
        }

        for (cases[0..index]) |previous| {
            if (previous) |other| if (same(value, label(other.*))) return duplicate(source.label.attribute().?);
        }
    }

    return .{ .exhaustive = has_default or (value_type == .enumeration and cases.len == value_type.enumeration.members.len) or (boolean and cases.len == 2) };
}

fn invalidSubject(attribute: rx.ast.Attribute) Result {
    return .{ .diagnostic = issue(attribute, .type_mismatch, "Switch.on requires an enum, integer, bool or string") };
}

fn invalidLabel(attribute: rx.ast.Attribute) Result {
    return .{ .diagnostic = issue(attribute, .type_mismatch, "Case.value must be a literal or enum member") };
}

fn duplicate(attribute: rx.ast.Attribute) Result {
    return .{ .diagnostic = issue(attribute, .name, "duplicate Switch case value") };
}

fn label(program: zx.ir.Program) Value {
    const block = program.body.block();

    return program.expression(block.at(block.len - 1).result.?).value;
}

fn same(left: Value, right: Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) {
        return (left == .integer and left.integer == 0 and right == .negative_integer and right.negative_integer == 0) or (right == .integer and right.integer == 0 and left == .negative_integer and left.negative_integer == 0);
    }

    return switch (left) {
        .integer => |value| value == right.integer,
        .negative_integer => |value| value == right.negative_integer,
        .string => |value| std.mem.eql(u8, value, right.string),
        .boolean => |value| value == right.boolean,
        .enum_value => |value| value == right.enum_value,
        else => false,
    };
}

fn issue(attribute: rx.ast.Attribute, code: @FieldType(zx.Diagnostic, "code"), message: []const u8) Diagnostic {
    const location = attribute.value_location;

    return .{ .location = location, .issue = .{ .code = code, .span = .{ .start = location.offset, .end = location.offset }, .message = message } };
}
