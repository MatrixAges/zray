const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const memory = @import("zx").memory;
const Finished = @import("../finished.zig");
const State = @import("../state.zig");
const generated = @import("rx_options").generated_graph;
const Source = frontend.project.artifact.source_link;
const Boundary = struct { functions: usize, types: usize };

pub fn publish(state: *State, body: *Source.Input, prepared: Boundary, flow_location: ?rx.ast.Location, destination: Finished.Destination) State.Error!void {
    const current: Boundary = .{ .functions = state.functions.count(), .types = state.types.items.count() };
    const body_functions = body.program.functions.count();
    const source = flow_location == null;
    var link: Frame = .{ .state = state, .body = body, .functions = prepared.functions, .location = flow_location orelse .{ .offset = 0, .line = 1, .column = 1 }, .output = destination.value };

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
            .initializers = state.initializers.items.len,
            .retained = state.retained_initializers.len,
            .verified = @ptrCast(&verified),
            .present = if (present) |*rows| @ptrCast(rows) else null,
            .boundary = &.{
                .prepared = &.{ .functions = prepared.functions, .types = prepared.types },
                .current = &.{ .functions = current.functions, .types = current.types },
                .body_functions = body_functions,
            },
        };

        return @import("../body.zig").run(rule, &input);
    }

    const types = if (current.functions == prepared.functions and current.types == prepared.types) null else prepared.types;

    state.verified = try link.append(body_functions == prepared.functions, types, source, state.retained_initializers.len != state.initializers.items.len) orelse
        return state.fail(link.location, if (source) "source module body cannot be linked to its shared compilation context" else "RX module body cannot be linked to its shared compilation context");

    if (destination.present) |cell| cell.* = true;
}

const Frame = struct {
    state: *State,
    body: *Source.Input,
    functions: usize,
    location: rx.ast.Location,
    output: Source.Output,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn append(self: *Frame, replace_prefix: bool, type_prefix: ?usize, use_shared_initializers: bool, refresh_initializers: bool) std.mem.Allocator.Error!?usize {
        const state = self.state;
        const body = self.body;
        const base = state.functions.view().prefix(self.functions);

        if (replace_prefix) body.program.functions = base;

        body.base_functions = base;
        body.base_types = type_prefix;
        body.verified_functions = state.verifiedFunctions();

        if (refresh_initializers) state.retained_initializers = try state.allocator.dupe(frontend.project.compiled.StoreInitializer, state.initializers.items);

        body.shared_initializers = state.retained_initializers;

        if (use_shared_initializers) body.store_initializers = body.shared_initializers;

        Source.appendBodyInto(body, state.destination(), self.output) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return null;
        };

        return state.functions.count();
    }
};

pub fn appendMixedBodyLink(handle: *const anyopaque, replace_prefix: bool, type_prefix: ?u64, use_shared_initializers: bool, refresh_initializers: bool) std.mem.Allocator.Error!?u64 {
    const verified = try Frame.borrow(handle).append(replace_prefix, if (type_prefix) |value| @intCast(value) else null, use_shared_initializers, refresh_initializers);

    return if (verified) |count| count else null;
}

pub fn rejectMixedBodyLink(handle: *const anyopaque, message: []const u8) State.Error!void {
    const frame = Frame.borrow(handle);

    return frame.state.fail(frame.location, message);
}
