const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Lower = @import("../lower.zig");
const seed = @import("locals_seed.zig");
const generated = @import("genz_options").generated_analysis;

pub fn parameters(self: *Lower, value: ir.Transform) Lower.Error!@import("../members.zig").Checkpoint {
    if (!generated) return seed.parameters(self, value);

    const entry = @import("generated_state_locals_parameters");
    const Parameter = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;
    const Input = Child(Parameter);
    const Facts = Child(@FieldType(Input, "facts"));
    const Elements = Child(@FieldType(Input, "elements"));
    const types = ir.TypeTable.borrow(Child(@FieldType(Elements, "types")), self.program.types);

    const elements: Elements = .{
        .types = &types,
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
        .list = @backingInt(self.program.expression(value.target).type_id),
    };

    const data: Facts = .{
        .symbol_types = self.program.symbols.types,
        .queries = zx.columns.slice(@FieldType(Facts, "queries"), self.state_plan.queries),
    };

    const input: Input = .{
        .facts = &data,
        .index = self.state_symbols.current().*,
        .active = self.state_active,
        .elements = &elements,
        .kind = @fromBackingInt(@backingInt(value.kind)),
        .parameters = .{ .items = @as([*]const u32, @ptrCast(value.parameters.ptr))[0..value.parameters.len], .storage = .plain },
    };

    const before = self.state_symbols.checkpoint();
    const index = entry.executeState(self.allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);

    self.state_symbols.current().* = zx.columns.view(@TypeOf(self.state_symbols.current().*), index);

    return before;
}

pub fn registerOwned(self: *Lower, symbols: []const ir.SymbolId) Lower.Error!void {
    if (!self.state_active) return;

    const entry = @import("generated_state_locals_owned");
    const Parameter = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;
    const InputType = Child(Parameter);

    const input: InputType = .{
        .symbol_types = self.program.symbols.types,
        .queries = zx.columns.slice(@FieldType(InputType, "queries"), self.state_plan.queries),
        .symbols = @import("../../node/view.zig").slice(@FieldType(InputType, "symbols"), symbols),
    };

    const index = entry.executeState(self.allocator, if (@typeInfo(Parameter) == .pointer) &input else input) catch |err| return failure(err);

    self.state_symbols.state = zx.columns.view(@FieldType(@TypeOf(self.state_symbols), "state"), index);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn Child(comptime Value: type) type {
    return if (@typeInfo(Value) == .pointer) std.meta.Child(Value) else Value;
}
