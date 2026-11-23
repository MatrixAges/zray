const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const memory = @import("zx").memory;
const Finished = @import("../finished.zig");
const State = @import("../state.zig");
const generated = @import("rx_options").generated_graph;
const Source = frontend.project.artifact.source_link;
const Boundary = struct { functions: usize, types: usize };

pub const Origin = union(enum) { source, flow: rx.ast.Location };

pub fn publish(state: *State, body: *Source.Input, prepared: Boundary, origin: Origin, destination: Finished.Destination) State.Error!void {
    const current: Boundary = .{ .functions = state.functions.count(), .types = state.types.items.count() };
    const body_functions = body.program.functions.count();
    var link: Frame = .{ .state = state, .body = body, .functions = prepared.functions, .origin = origin, .output = destination.value };

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
            .source = origin == .source,
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

    state.verified = try link.append(body_functions == prepared.functions, types) orelse return link.reject(switch (origin) {
        .source => "source module body cannot be linked to its shared compilation context",
        .flow => "RX module body cannot be linked to its shared compilation context",
    });

    if (destination.present) |cell| cell.* = true;
}

const Frame = struct {
    state: *State,
    body: *Source.Input,
    functions: usize,
    origin: Origin,
    output: Source.Output,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
    fn append(self: *Frame, replace_prefix: bool, type_prefix: ?usize) std.mem.Allocator.Error!?usize {
        const state = self.state;
        const body = self.body;
        const base = state.functions.view().prefix(self.functions);

        if (replace_prefix) body.program.functions = base;

        body.base_functions = base;
        body.base_types = type_prefix;
        body.verified_functions = state.verifiedFunctions();
        body.shared_initializers = try state.initializersView();

        if (self.origin == .source) body.store_initializers = body.shared_initializers;

        Source.appendBodyInto(body, state.destination(), self.output) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return null;
        };

        return state.functions.count();
    }
    fn reject(self: *const Frame, message: []const u8) State.Error {
        const location: rx.ast.Location = switch (self.origin) {
            .source => .{ .offset = 0, .line = 1, .column = 1 },
            .flow => |location| location,
        };

        return self.state.fail(location, message);
    }
};

pub fn appendMixedBodyLink(handle: *const anyopaque, replace_prefix: bool, type_prefix: ?u64) std.mem.Allocator.Error!?u64 {
    const verified = try Frame.borrow(handle).append(replace_prefix, if (type_prefix) |value| @intCast(value) else null);

    return if (verified) |count| count else null;
}

pub fn rejectMixedBodyLink(handle: *const anyopaque, message: []const u8) State.Error!void {
    return Frame.borrow(handle).reject(message);
}
