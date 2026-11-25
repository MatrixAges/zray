const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const project = @import("../../../project.zig");
const Module = @import("../../../module.zig");
const Inputs = @import("../../call_inputs.zig");
const target = @import("../../../call/target.zig");
const Frame = @import("../../history.zig").Frame;
const registry = @import("../../../store/registry.zig");
const workflow = @import("../errors.zig");
const Error = zx.Error;
const generated = @import("rx_options").generated_graph;

pub const State = struct {
    allocator: std.mem.Allocator,
    backing: std.mem.Allocator,
    options: project.Options,
    cache: *frontend.project.ParseCache,
    inputs: *Inputs,
    frame: Frame = undefined,
    result: ?Module.Value = null,
    issue: ?target.Diagnostic = null,
    pub fn run(self: *State) std.mem.Allocator.Error!Module.Value {
        self.execute() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSource => {
                if (self.result) |result| return result;

                return project.remap(self.allocator, self.options, self.issue.?);
            },
        };

        return self.result.?;
    }
    fn execute(self: *State) Error!void {
        const history = self.options.history;
        const previous = if (history) |record| record.previous != null else false;
        const bodies_only = if (history) |record| record.bodies_only else false;
        const stores = self.options.stores.len;

        if (comptime generated) {
            const entry = @import("generated_rx_execute_inference");

            const input: std.meta.Child(entry.Input) = .{
                .state = @ptrCast(self),
                .history = &.{ .previous = previous, .bodies_only = bodies_only, .stores = stores },
            };

            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), &input) catch |err| workflow.errorSet(err);
        }

        const retained = previous and bodies_only;

        try self.normalize();
        if (retained) self.restore() else try self.derive(previous and stores == 0);
        try self.compile();
        try self.publishStores(retained);
    }

    fn restore(self: *State) void {
        self.frame = self.options.history.?.previous.?.derived;
    }

    fn derive(self: *State, signatures: bool) Error!void {
        return @import("../derive/host.zig").run(self.allocator, self.backing, &self.options, self.cache, self.inputs, &self.frame, &self.issue, signatures);
    }
    fn publishStores(self: *State, retained: bool) Error!void {
        const contract = &self.result.?.contract;

        contract.store_definitions = try registry.publish(self.allocator, self.frame.definitions, contract, retained);
    }

    fn normalize(self: *State) Error!void {
        self.options.sources = switch (try frontend.project.prepareSources(self.allocator, self.options.sources, self.options.project)) {
            .sources => |items| items,
            .diagnostic => |issue| {
                const source = self.options.sources[issue.source_index.?];
                const location = zx.source.locate(source.source, issue.span.start);

                self.result = try project.failure(self.allocator, .{
                    .path = source.path,
                    .location = .{ .offset = issue.span.start, .line = location.line, .column = location.column },
                    .code = @tagName(issue.code),
                    .message = issue.message,
                });

                return error.InvalidSource;
            },
        };
    }
    fn compile(self: *State) Error!void {
        const result = try @import("../../mixed.zig").compile(self.allocator, self.backing, self.frame, self.options.modules, self.options.sources, self.options.exports, self.cache, self.options.history, self.inputs);

        if (result == .diagnostic) {
            self.issue = result.diagnostic;

            return error.InvalidSource;
        }

        self.result = result;
    }
};

fn state(handle: *anyopaque) *State {
    return @ptrCast(@alignCast(handle));
}

pub fn normalizeProjectSources(handle: *anyopaque) Error!void {
    return state(handle).normalize();
}

pub fn restoreDerivedFrame(handle: *anyopaque) void {
    state(handle).restore();
}

pub fn deriveProjectFrame(handle: *anyopaque, signatures: bool) Error!void {
    return state(handle).derive(signatures);
}

pub fn compileProjectBodies(handle: *anyopaque) Error!void {
    return state(handle).compile();
}

pub fn publishInferredStores(handle: *anyopaque, retained: bool) Error!void {
    return state(handle).publishStores(retained);
}
