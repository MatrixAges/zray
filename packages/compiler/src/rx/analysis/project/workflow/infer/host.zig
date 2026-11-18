const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const project = @import("../../../project.zig");
const Module = @import("../../../module.zig");
const Inputs = @import("../../call_inputs.zig");
const target = @import("../../../call/target.zig");
const Frame = @import("../../history.zig").Frame;
const registry = @import("../../../store/registry.zig");
const generated = @import("rx_options").generated_graph;
const Error = zx.Error;

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
        if (comptime generated) {
            const entry = @import("generated_rx_project_infer");
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), @ptrCast(self));
        }

        try self.normalize();

        const reused = self.reuse();

        if (!reused) try self.derive();
        try self.compile();
        if (reused) try self.retain() else try self.publish();
    }
    pub fn normalize(self: *State) Error!void {
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

    pub fn reuse(self: *State) bool {
        const record = self.options.history orelse return false;

        if (!record.bodies_only) return false;

        const previous = if (record.previous) |*value| value else return false;

        self.frame = previous.derived;

        return true;
    }
    pub fn derive(self: *State) Error!void {
        try @import("../derive/host.zig").run(self.allocator, self.backing, &self.options, self.cache, self.inputs, &self.frame, &self.issue);
    }
    pub fn compile(self: *State) Error!void {
        const result = try @import("../../mixed.zig").compile(self.allocator, self.backing, self.frame, self.options.modules, self.options.sources, self.options.exports, self.cache, self.options.history, self.inputs);

        if (result == .diagnostic) {
            self.issue = result.diagnostic;

            return error.InvalidSource;
        }

        self.result = result;
    }

    pub fn retain(self: *State) Error!void {
        const contract = &self.result.?.contract;

        contract.store_definitions = try registry.publish(self.allocator, self.frame.definitions, contract, .Retained);
    }

    pub fn publish(self: *State) Error!void {
        const contract = &self.result.?.contract;

        contract.store_definitions = try registry.publish(self.allocator, self.frame.definitions, contract, .Owned);
    }
};
