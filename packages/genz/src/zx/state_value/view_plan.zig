const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const planning = @import("generated_state_view_plan");
const requirement = @import("generated_state_view_satisfy");
const Conversion = std.meta.Child(@import("generated_state_conversion_plan").Input);
const Plan = std.meta.Child(@import("generated_state_conversion_plan").Output);

pub fn required(self: *Lower, id: ir.TypeId, input: bool) Lower.Error!bool {
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Conversion, "types")), self.program.types);

    const conversion: Conversion = .{
        .types = &types,
        .queries = zx.columns.slice(@FieldType(Conversion, "queries"), self.state_plan.queries),
        .selected = self.state_plan.selected,
        .element_storage = self.state_plan.element_storage,
        .root = @backingInt(id),
        .mode = if (input) .ViewValue else .ViewLayout,
    };

    const Input = std.meta.Child(requirement.Input);
    const source = borrow(std.meta.Child(@FieldType(Input, "source")), self, &conversion);

    const request: Input = .{
        .frame = @ptrCast(self),
        .source = &source,
        .type_id = conversion.root,
        .mode = zx.columns.view(@FieldType(Input, "mode"), conversion.mode),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const decision = zx.columns.invoke(requirement.executeValue, fixed.allocator(), &request) catch |err| return failure(err);

    return decision.operation != .Value;
}

pub fn build(self: *Lower, allocator: std.mem.Allocator, conversion: *const Conversion) Lower.Error!*const Plan {
    const Input = std.meta.Child(planning.Input);
    const source = borrow(std.meta.Child(@FieldType(Input, "source")), self, conversion);
    const request: Input = .{ .frame = @ptrCast(self), .source = &source };
    const result = planning.executeIn(allocator, &request) catch |err| return failure(err);

    return zx.columns.pointer(*const Plan, result);
}

fn borrow(comptime Source: type, self: *const Lower, conversion: *const Conversion) Source {
    return .{
        .source = zx.columns.pointer(@FieldType(Source, "source"), conversion),
        .states = @ptrCast(@as([]const node.ExpressionId, self.state_types)),
        .views = @ptrCast(@as([]const node.ExpressionId, self.view_types)),
    };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid view conversion plan"),
    };
}
