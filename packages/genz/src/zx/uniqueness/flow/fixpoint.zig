const std = @import("std");
const zx = @import("zx");
const Flow = @import("../flow.zig");
const Slots = @import("../slots.zig");
const Body = @import("body.zig");
const Walk = @import("walk.zig");
const create = @import("generated_uniqueness_flow_queue");
const advance = @import("generated_uniqueness_flow_advance");

pub fn settle(flow: Flow, owner: std.mem.Allocator, workspace: std.mem.Allocator, functions: zx.ir.FunctionTable, slots: Slots) std.mem.Allocator.Error!void {
    const size = functions.count();
    const indices = try owner.alloc(u32, size);
    const queued = try owner.alloc(u8, size);
    const first = try owner.alloc(u64, size + 1);

    @memset(first, 0);

    var items: []u32 = &.{};
    const Input = std.meta.Child(create.Input);

    const input: Input = .{
        .expressions = zx.columns.slice(@FieldType(Input, "expressions"), functions.expressions),
        .native_modules = functions.native_modules,
        .held = flow.held,
        .first = @ptrCast(&first),
        .items = @ptrCast(&items),
        .owner = @ptrCast(&owner),
        .indices = @ptrCast(&indices),
        .queued = @ptrCast(&queued),
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    var count = zx.columns.invoke(create.executeValue, empty.allocator(), &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    const bodies = try owner.alloc(?Body, size);

    @memset(bodies, null);

    var temporary = std.heap.ArenaAllocator.init(workspace);

    defer temporary.deinit();

    var walk = Walk{ .allocator = workspace, .flow = flow, .slots = slots };

    defer walk.deinit();

    var changed: ?u32 = null;

    while (true) {
        const next_input: std.meta.Child(advance.Input) = .{
            .indices = @ptrCast(&indices),
            .queued = @ptrCast(&queued),
            .first = first,
            .items = items,
            .count = count,
            .changed = changed,
        };

        const next = zx.columns.invoke(advance.executeValue, empty.allocator(), &next_input) catch unreachable;
        const index = next.index orelse return;
        count = next.count;

        const function = functions.at(index);

        if (bodies[index] == null) {
            bodies[index] = try Body.keep(owner, temporary.allocator(), &function, slots);
            _ = temporary.reset(.retain_capacity);
        }

        changed = if (try walk.visit(index, &function, &bodies[index].?)) index else null;
    }
}
