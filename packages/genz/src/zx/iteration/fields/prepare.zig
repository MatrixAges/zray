const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../../node.zig");
const Lower = @import("../../lower.zig");
const Context = @import("root.zig");

pub fn prepare(self: *Lower, iteration: ir.Iteration, type_id: ir.TypeId, body: anytype, seed: node.ExpressionId) Lower.Error!?Context {
    if (!@import("genz_options").generated_analysis) return @import("prepare_seed.zig").prepare(self, iteration, type_id, body, seed);
    if (self.loop_fields != null or self.iteration_value != null or self.capture != null) return null;
    if (self.program.typeOf(type_id) != .object) return null;

    const fields = self.program.typeOf(type_id).object;

    if (fields.len < 2) return null;

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const entry = @import("generated_loop_fields_prepare");
    const Input = std.meta.Child(entry.Input);
    const Loop = std.meta.Child(@FieldType(Input, "loop"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Input, "types")), self.program.types);
    const cached = self.cache.view(std.meta.Child(@FieldType(Input, "cached")));
    const program: *const ir.Program = &self.program;

    const loop: Loop = .{
        .expressions = zx.columns.pointer(@FieldType(Loop, "expressions"), &program.expressions),
        .symbol_types = zx.columns.slice(@FieldType(Loop, "symbol_types"), program.symbols.types),
        .parameter = @backingInt(iteration.parameter),
        .condition_parameter = @backingInt(iteration.condition_parameter),
        .initial = @backingInt(iteration.initial),
        .body = @backingInt(iteration.body),
        .condition = @backingInt(iteration.condition),
        .state_type = @backingInt(type_id),
        .field_count = fields.len,
        .candidates = &.{},
    };

    const input: Input = .{
        .loop = &loop,
        .types = &types,
        .selected = self.state_plan.selected,
        .cached = &cached,
        .flags = std.mem.sliceAsBytes(self.plan.flags),
    };

    const plan = entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    if (!plan.valid) return null;

    const resolver = @import("generated_resolve_loop_field_types");
    const Resolve = std.meta.Child(resolver.Input);
    const first = types.first[@backingInt(type_id)];

    const resolution: Resolve = .{
        .frame = @ptrCast(self),
        .types = types.field_types[first..][0..fields.len],
    };

    const field_types = resolver.executeIn(memory.allocator(), &resolution) catch |err| return failure(err);
    const abi_type = try @import("../../types.zig").get(self, self.abi_types, type_id);

    const layout = try @import("layout.zig").build(self, body, .{
        .types = self.program.types,
        .type_id = type_id,
        .borrowed = plan.borrowed,
        .field_types = field_types,
        .abi_type = abi_type,
    });

    return .{
        .states = try self.allocator.dupe(bool, plan.states),
        .symbols = try self.allocator.dupe(bool, plan.symbols),
        .borrowed = try self.allocator.dupe(bool, plan.borrowed),
        .type_id = type_id,
        .layout = layout,
        .seed = seed,
        .capacity = if (!iteration.postcondition) if (plan.capacity) |capacity| .{ .operation = @fromBackingInt(capacity.operation), .source = capacity.source } else null else null,
    };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
