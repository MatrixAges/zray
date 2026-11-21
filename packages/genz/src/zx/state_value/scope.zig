const std = @import("std");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_lowering_scope") else struct {};
const Form = if (generated) entry.Input else enum { Represented, Borrowed, Adapter, Value, Iteration, Projected, Deferred };
const Plan = if (generated) @typeInfo(@typeInfo(@TypeOf(entry.executeValue)).@"fn".return_type.?).error_union.payload else void;
const Field = if (generated) @FieldType(Plan, "first") else enum { StateActive, Cache, Plan, ValueOutput, IterationValue, LoopFields, DeferredLists };

pub fn Frame(comptime form: Form) type {
    const fields = comptime fieldsFor(form);

    return struct {
        const Self = @This();
        pub const Values = FieldTypes(fields);
        lowering: *Lower,
        previous: Values,
        pub inline fn restore(self: Self) void {
            inline for (fields) |field| {
                @field(self.lowering, name(field)) = @field(self.previous, name(field));
            }
        }
    };
}

pub inline fn enter(lowering: *Lower, comptime form: Form, next: Frame(form).Values) Frame(form) {
    var previous: Frame(form).Values = undefined;

    inline for (comptime fieldsFor(form)) |field| {
        const slot = comptime name(field);

        @field(previous, slot) = @field(lowering, slot);
        @field(lowering, slot) = @field(next, slot);
    }

    return .{ .lowering = lowering, .previous = previous };
}

pub inline fn applies(lowering: *const Lower, comptime form: Form) bool {
    const if_inactive = if (generated) (comptime plan(form)).if_inactive else form == .Represented;

    return !if_inactive or !lowering.state_active;
}

fn FieldTypes(comptime fields: []const Field) type {
    var names: [fields.len][]const u8 = undefined;
    var types: [fields.len]type = undefined;

    for (fields, &names, &types) |field, *key, *value| {
        key.* = name(field);
        value.* = @FieldType(Lower, key.*);
    }

    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn name(field: Field) []const u8 {
    return switch (field) {
        .StateActive => "state_active",
        .Cache => "cache",
        .Plan => "plan",
        .ValueOutput => "value_output",
        .IterationValue => "iteration_value",
        .LoopFields => "loop_fields",
        .DeferredLists => "deferred_lists",
    };
}

fn fieldsFor(comptime form: Form) []const Field {
    if (generated) {
        const selected = comptime plan(form);

        return if (selected.second) |second| &.{ selected.first, second } else &.{selected.first};
    }

    return switch (form) {
        .Represented => &.{ .Cache, .StateActive },
        .Borrowed => &.{.StateActive},
        .Adapter => &.{ .Cache, .Plan },
        .Value => &.{.ValueOutput},
        .Iteration => &.{.IterationValue},
        .Projected => &.{.LoopFields},
        .Deferred => &.{.DeferredLists},
    };
}

fn plan(comptime form: Form) Plan {
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    return entry.executeValue(fixed.allocator(), form) catch unreachable;
}
