const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const renewal = @import("../growth/renew.zig");
pub const Target = renewal.Target;

pub const Plan = struct {
    owner: ir.ExprId,
    first: usize = 0,
    end: usize = 0,
    delayed: bool = false,
    filters_inline: bool = false,
    skipped: []const u64 = &.{},
    pub fn needsEntries(self: Plan, lowering: *const Lower) bool {
        if (generated) return self.first != self.end;

        for (lowering.plan.renewals) |record| {
            if (record.owner == @backingInt(self.owner) and !record.value) return true;
        }

        return false;
    }
    pub fn store(self: Plan, lowering: *Lower, type_id: ir.TypeId, target: Target) Lower.Error!node.Block {
        if (generated) {
            if (self.end - self.first == self.skipped.len) return .{};

            return renewal.entry(
                lowering,
                type_id,
                target,
                lowering.plan.renewals.keys[self.first..self.end],
                lowering.plan.renewals.paths[self.first..self.end],
                self.skipped,
                !self.filters_inline and if (lowering.iteration_value) |context| context.inline_lists else false,
            );
        }

        var body: std.ArrayList(node.Statement) = .empty;

        for (lowering.plan.renewals) |record| {
            if (record.owner == @backingInt(self.owner) and !record.value) try renew(lowering, &body, type_id, target, record.path, record.writable);
        }

        return lowering.builder.statements(body.items);
    }
};

pub const Request = struct {
    owner: ir.ExprId,
    type_id: ir.TypeId,
    classify: ?ir.Iteration = null,
    inline_lists: bool = false,
};

pub fn plan(self: *const Lower, temporary: std.mem.Allocator, request: Request) Lower.Error!Plan {
    if (!generated or self.plan.renewals.keys.len == 0) return .{ .owner = request.owner };

    const entry = @import("generated_iteration_renewal_plan");
    const Parameter = @typeInfo(@TypeOf(entry.executeValue)).@"fn".param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;
    const Input = if (indirect) std.meta.Child(Parameter) else Parameter;
    const Facts = std.meta.Child(@FieldType(Input, "facts"));
    const Records = std.meta.Child(@FieldType(Input, "records"));
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    const program = &self.program;
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), program.types);
    const roots = if (request.classify) |iteration| [2]u32{ @backingInt(iteration.condition), @backingInt(iteration.body) } else undefined;

    const facts: Facts = .{
        .expressions = zx.columns.pointer(@FieldType(Facts, "expressions"), &program.expressions),
        .types = &types,
        .selected = self.state_plan.selected,
        .referenced = self.state_plan.borrowed,
        .roots = if (request.classify != null) &roots else &.{},
        .state_type = @backingInt(request.type_id),
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const records = zx.columns.view(Records, self.plan.renewals);
    var skipped: std.ArrayList(u64) = .empty;
    const destination: Destination = .{ .allocator = @ptrCast(&temporary), .skipped = @ptrCast(&skipped) };

    const input = zx.columns.view(Input, .{
        .facts = &facts,
        .records = @as(*const Records, &records),
        .destination = @as(*const Destination, &destination),
        .owner = @backingInt(request.owner),
        .classify = request.classify != null,
        .inline_lists = request.inline_lists,
    });

    const output = entry.executeValue(memory.allocator(), if (indirect) &input else input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .owner = request.owner,
        .first = @intCast(output.first),
        .end = @intCast(output.end),
        .delayed = output.delayed,
        .filters_inline = request.inline_lists,
        .skipped = skipped.items,
    };
}

fn renew(self: *Lower, body: *std.ArrayList(node.Statement), type_id: ir.TypeId, target: Target, path: []const u32, writable: bool) Lower.Error!void {
    const reference = switch (target) {
        .reference => |value| value,
        .name => |name| try self.builder.identifier(name),
    };

    return @import("../growth/renew_seed.zig").renew(self, body, type_id, reference, path, writable);
}
