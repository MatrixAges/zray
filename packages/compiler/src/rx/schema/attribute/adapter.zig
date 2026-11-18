const std = @import("std");
const dsl = @import("dsl");
const checks = @import("../../checks.zig");
const generated = @import("rx_options").generated_rules;
const rule = if (generated) @import("generated_rx_attribute_schema") else void;
pub const Policy = enum { Common, Module, Call, Import, Type, Field, StoreField, Route };

const Issue = if (generated) @FieldType(std.meta.Child(rule.Output), "issue") else enum {
    None,
    Expression,
    Static,
    Empty,
    EmptyField,
    CallTarget,
    CallSetter,
    CallModule,
    ModuleChildren,
    ModuleFunction,
    ImportModule,
    TypeSource,
    TypeAlias,
    FieldName,
    RouteService,
};

pub const Finding = struct { issue: Issue, index: usize = 0 };

pub fn check(comptime policy: Policy, attributes: anytype, input: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);
    const count = node.attributeCount();

    if (count == 0 and (policy == .Common or policy == .Module)) return;

    const result = if (generated) source(policy, attributes, node, count) else @import("seed.zig").inspect(policy, attributes, node);

    switch (result.issue) {
        .None => {},
        .Expression, .Static, .Empty, .EmptyField => {
            const attribute = node.schemaAttribute(result.index);

            return reporter.fail(.{
                .code = if (result.issue == .Expression or result.issue == .Static) .invalid_attribute else .context,
                .location = attribute.value_location,
                .element = node.name(),
                .attribute = attribute.name,
                .message = switch (result.issue) {
                    .Expression => "This attribute requires a braced expression",
                    .Static => "This attribute requires a quoted static string",
                    .Empty => "RX attribute must not be empty",
                    .EmptyField => "Field name and type must not be empty",
                    else => unreachable,
                },
            });
        },
        .CallTarget => return checks.fail(node, "module", "Call requires exactly one of fn or module", reporter),
        .CallSetter => return checks.fail(node, "setter", "Store authorization belongs inside the called RX module", reporter),
        .CallModule => return checks.fail(node, "module", "Module must reference a local RX path or a declared package module", reporter),
        .ModuleChildren => return checks.fail(node, "fn", "Module.fn cannot be combined with child declarations or steps", reporter),
        .ModuleFunction => return checks.fail(node, "fn", "Module.fn must reference a ZX source file", reporter),
        .ImportModule => return checks.fail(node, "from", "Import must reference a relative module file path", reporter),
        .TypeSource => return checks.fail(node, "from", "Type must reference a ZX source file", reporter),
        .TypeAlias => return checks.fail(node, "as", "Type alias must be one ZX identifier", reporter),
        .FieldName => return checks.fail(node, "name", "Field name must be one ZX identifier", reporter),
        .RouteService => return checks.fail(node, "service", "Route service must reference a relative module file path", reporter),
    }
}

fn source(comptime policy: Policy, attributes: anytype, node: anytype, count: usize) Finding {
    const Reference = std.meta.Child(@FieldType(std.meta.Child(rule.Input), "reference"));
    const capacity = @typeInfo(@TypeOf(attributes)).@"struct".field_names.len;
    var names: [capacity][]const u8 = undefined;
    var values: [capacity][]const u8 = undefined;
    var expressions: [capacity]bool = undefined;

    for (0..count) |index| {
        const attribute = node.schemaAttribute(index);

        names[index] = attribute.name;
        values[index] = attribute.value;
        expressions[index] = attribute.kind == .expression;
    }

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = rule.executeValue(empty.allocator(), &.{
        .attributes = &.{
            .element = node.name(),
            .names = names[0..count],
            .values = values[0..count],
            .expressions = expressions[0..count],
            .store_field = policy == .StoreField,
        },
        .reference = &.{
            .policy = if (policy == .StoreField) .Common else @field(@FieldType(Reference, "policy"), @tagName(policy)),
            .reference = switch (policy) {
                .Module => attributes.@"fn",
                .Call => attributes.module,
                .Import, .Type => attributes.from,
                .Route => attributes.service,
                else => null,
            },
            .identifier = switch (policy) {
                .Type => attributes.as,
                .Field => attributes.name,
                else => "",
            },
            .has_children = policy == .Module and node.childCount() != 0,
            .has_function = policy == .Call and attributes.@"fn" != null,
            .has_setter = policy == .Call and attributes.setter != null,
        },
    }) catch |err| switch (err) {
        error.InvalidUtf8 => return .{ .issue = switch (policy) {
            .Type => .TypeAlias,
            .Field => .FieldName,
            else => unreachable,
        } },
        else => unreachable,
    };

    return .{ .issue = result.issue, .index = @intCast(result.index) };
}
