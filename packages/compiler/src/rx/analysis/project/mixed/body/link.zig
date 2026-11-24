const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const memory = @import("zx").memory;
const Finished = @import("../finished.zig");
const State = @import("../state.zig");
const generated = @import("rx_options").generated_graph;
const Source = frontend.project.artifact.source_link;
const Boundary = struct { functions: usize, types: usize };

pub fn publish(state: *State, body: *const Source.Input, prepared: Boundary, flow_location: ?rx.ast.Location, destination: Finished.Destination) State.Error!void {
    const current: Boundary = .{ .functions = state.functions.count(), .types = state.types.items.count() };
    const body_functions = body.program.functions.count();
    const source = flow_location == null;

    const link: Source.Body = .{
        .input = body,
        .destination = state.destination(),
        .output = destination.value,
        .prefix = prepared.functions,
        .verified = state.verified,
        .shared_initializers = state.initializers.items,
    };

    const location = flow_location orelse rx.ast.Location{ .offset = 0, .line = 1, .column = 1 };

    if (comptime generated) {
        const rule = @import("generated_rx_mixed_body_link");
        const present: ?[]bool = if (destination.present) |cell| @as(*[1]bool, @ptrCast(cell)) else null;

        const verified: memory.WriteColumn = .{
            .items = std.mem.asBytes(&state.verified),
            .count = 1,
            .stride = @sizeOf(usize),
            .width = @sizeOf(usize),
        };

        const input: std.meta.Child(rule.Input) = .{
            .body = @ptrCast(&link),
            .source = source,
            .initializers = std.mem.sliceAsBytes(body.store_initializers),
            .shared = std.mem.sliceAsBytes(link.shared_initializers),
            .verified = @ptrCast(&verified),
            .present = if (present) |*rows| @ptrCast(rows) else null,
            .boundary = &.{
                .prepared = &.{ .functions = prepared.functions, .types = prepared.types },
                .current = &.{ .functions = current.functions, .types = current.types },
                .body_functions = body_functions,
            },
        };

        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        const message = rule.executeIn(scratch.allocator(), &input) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };

        if (message) |text| return state.fail(location, text);

        return;
    }

    const types = if (current.functions == prepared.functions and current.types == prepared.types) null else prepared.types;
    const values = if (source) link.shared_initializers else body.store_initializers;

    state.verified = try link.link(body_functions == prepared.functions, types, values) orelse
        return state.fail(location, if (source) "source module body cannot be linked to its shared compilation context" else "RX module body cannot be linked to its shared compilation context");

    if (destination.present) |cell| cell.* = true;
}
