const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const Change = @import("../object_update.zig").Change;

pub const Plan = struct { change: Change, positions: []const u32 };

const entry = @import("generated_object_update_candidate");
const Input = std.meta.Child(entry.Input);
const Reuse = std.meta.Child(@import("generated_scope_reuse").Input);
const Environment = std.meta.Child(@FieldType(Reuse, "matching"));

pub const Borrow = struct {
    types: std.meta.Child(@FieldType(Environment, "types")),
    state_members: std.meta.Child(@FieldType(Environment, "state_members")),
    stack_members: std.meta.Child(@FieldType(Environment, "stack_members")),
    cache: std.meta.Child(@FieldType(Environment, "cache")),
    pub fn view(self: *Borrow, lowering: *const Lower) Environment {
        const program = &lowering.program;
        const flags = lowering.plan.flags;

        comptime std.debug.assert(@sizeOf(std.meta.Child(@TypeOf(flags))) == @sizeOf(u8));

        self.* = .{
            .types = ir.TypeTable.borrow(@TypeOf(self.types), program.types),
            .state_members = lowering.state_symbols.view(@TypeOf(self.state_members)),
            .stack_members = lowering.stack_symbols.view(@TypeOf(self.stack_members)),
            .cache = lowering.cache.view(@TypeOf(self.cache)),
        };

        return .{
            .expressions = zx.columns.pointer(@FieldType(Environment, "expressions"), &program.expressions),
            .types = &self.types,
            .state_members = &self.state_members,
            .stack_members = &self.stack_members,
            .symbol_types = program.symbols.types,
            .flags = std.mem.sliceAsBytes(flags),
            .selected = lowering.state_plan.selected,
            .borrowed = lowering.state_plan.borrowed,
            .state_active = lowering.state_active,
            .iteration = lowering.iteration_value != null,
            .loop_fields = lowering.loop_fields != null,
            .cache = &self.cache,
        };
    }
};

pub fn match(lowering: *const Lower, scratch: std.mem.Allocator, id: ir.ExprId, evaluated: bool) Lower.Error!?Plan {
    var storage: Borrow = undefined;
    const environment = storage.view(lowering);
    var input: Input = undefined;

    inline for (@typeInfo(Environment).@"struct".field_names) |name| @field(input, name) = @field(environment, name);

    input.id = @backingInt(id);
    input.evaluated = evaluated;

    const result = zx.columns.invoke(entry.executeValue, scratch, @as(*const Input, &input)) catch |err| switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    const output = result orelse return null;

    return .{
        .change = .{
            .previous = @fromBackingInt(output.previous),
            .reference = @fromBackingInt(output.reference),
            .field = .{ .index = output.field_index, .value = @fromBackingInt(output.field_value) },
            .type_id = @fromBackingInt(output.type_id),
            .object = id,
        },
        .positions = output.positions,
    };
}
