const std = @import("std");
const rx = @import("rx");
const frontend = @import("frontend");
const prepare = @import("../../prepare.zig");
const Attributes = @import("../../../call/attributes.zig");
const StoreCall = @import("../../../store/call.zig");
const availability = @import("../../../call/availability.zig");
const generated = @import("rx_options").generated_graph;
const Error = prepare.Loader.Error;

pub const State = struct {
    loader: *prepare.Loader,
    node: rx.ast.Node,
    index: usize,
    attributes: Attributes = .{},
    input: ?*const frontend.ExpressionInput.Result = null,
    capability: StoreCall.Authorization = .{ .getters = &.{} },
    resolved: ?Target = null,
    const Target = struct {
        kind: prepare.CalleeKind,
        row: usize,
        callee: prepare.Callee,
    };
    pub fn bind(self: *State) Error!void {
        if (comptime generated) {
            const entry = @import("generated_rx_prepare_call");
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            return entry.executeIn(empty.allocator(), @ptrCast(self));
        }

        self.scan();

        try self.argument();
        try self.authorize();
        try self.resolve();
        try self.publish();
        try self.record();
    }
    pub fn scan(self: *State) void {
        self.attributes = Attributes.scan(self.node);
    }

    pub fn argument(self: *State) Error!void {
        if (self.attributes.argument) |attribute| {
            self.input = try self.loader.inputs.parse(attribute.*, self.loader.owner);
        }
    }

    pub fn authorize(self: *State) Error!void {
        const loader = self.loader;
        const result = try StoreCall.analyze(loader.allocator, loader.backing, loader.owner, self.attributes, loader.stores, self.input);

        if (result == .diagnostic) {
            loader.issue = result.diagnostic;

            return error.InvalidFlow;
        }

        self.capability = result.authorized;
    }
    pub fn resolve(self: *State) Error!void {
        const loader = self.loader;
        const selected = loader.references.next(.call);
        const edge = selected.edge;

        const admission = availability.check(.{
            .target = switch (edge.target) {
                .source => .Source,
                .compiled => .Compiled,
                .native => .Native,
            },
            .declared_setter = self.attributes.setter != null,
            .setter = self.capability.setter != null,
            .ambient_store = loader.project.context.stores.len != 0,
        });

        if (self.attributes.member) |member| {
            if (admission == .AuthorizedSource) return loader.fail(member.value_location, "capability", "a named Call cannot grant a Store setter");
            if (admission != .Source) return loader.fail(member.value_location, "module", "export requires a named function from a ZX source module");

            self.resolved = .{
                .kind = .NamedSource,
                .row = edge.target.source,
                .callee = try loader.namedCallee(edge.target.source, member),
            };

            return;
        }

        const callee = switch (admission) {
            .Source, .AuthorizedSource => try loader.sourceCallee(edge.target.source, edge.location, admission == .AuthorizedSource),
            .Compiled => try loader.compiledCallee(self.attributes.module.?.value_location, edge.target.compiled, self.capability.setter != null),
            .Native => return loader.fail(edge.location, "module", "native and standard imports must use the interface registry"),
            .Denied => return loader.fail(self.node.location, "capability", "Store calls require explicit per-call authorization from module declarations"),
        };

        self.resolved = .{
            .kind = switch (admission) {
                .Source => .Source,
                .AuthorizedSource => .AuthorizedSource,
                .Compiled => .Compiled,
                .Native, .Denied => unreachable,
            },
            .row = if (edge.target == .source) edge.target.source else selected.row,
            .callee = callee,
        };
    }

    pub fn publish(self: *State) Error!void {
        const loader = self.loader;
        const selected = self.resolved.?;

        try loader.calls.append(loader.allocator, .{
            .node = self.node,
            .setter = self.capability.setter,
            .getters = self.capability.getters,
            .input = self.attributes.argument,
            .name_source = self.attributes.member orelse self.attributes.function orelse self.attributes.module.?,
            .target_kind = selected.kind,
            .target = selected.row,
            .callee = selected.callee,
        });

        loader.local_calls = loader.local_calls and (selected.kind == .Source or selected.kind == .NamedSource);
    }

    pub fn record(self: *State) Error!void {
        const parsed = self.input orelse return;
        const arguments = &self.loader.arguments;
        const first = arguments.items.len;

        try arguments.resize(self.loader.inputs.arena.allocator(), self.index + 1);

        @memset(arguments.items[first..self.index], null);

        arguments.items[self.index] = parsed;
    }
};
