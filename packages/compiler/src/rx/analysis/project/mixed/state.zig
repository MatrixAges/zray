const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const ir = @import("zx").ir;
const target = @import("../../call/target.zig");
const SourceGraph = @import("../source_graph.zig").Graph;
const Types = frontend.project.artifact.type_link.Table;
const Finished = @import("finished.zig");
const Self = @This();
const generated = @import("rx_options").generated_graph;
pub const Error = std.mem.Allocator.Error || error{InvalidSourceGraph};

allocator: std.mem.Allocator,
scratch: std.heap.ArenaAllocator,
options: frontend.project.Options,
graph: SourceGraph,
signatures: frontend.project.signature_project.Data,
types: Types,
functions: ir.FunctionStorage = .{},
verified: usize = 0,
native_modules: ir.NativeModuleStorage = .{},
initializers: std.ArrayList(frontend.project.compiled.StoreInitializer) = .empty,
libraries: frontend.project.compiled.imports.Cache = .empty,
finished: Finished,
signature_indices: []const i64,
owner: usize = 0,
issue: ?target.Diagnostic = null,
pub fn init(allocator: std.mem.Allocator, backing: std.mem.Allocator, graph: SourceGraph, signatures: frontend.project.signature_project.Data, signature_indices: []const i64, types: ir.TypeTable, options: frontend.project.Options) Error!Self {
    var self = Self{
        .allocator = allocator,
        .scratch = std.heap.ArenaAllocator.init(backing),
        .options = options,
        .graph = graph,
        .signatures = signatures,
        .types = .{ .allocator = allocator, .items = .{}, .origins = .{ .allocator = allocator } },
        .finished = .{},
        .libraries = .{ .inherited = signatures.libraries },
        .signature_indices = signature_indices,
    };

    try self.initializers.appendSlice(allocator, signatures.store_initializers);

    const opening: Opening = .{ .state = &self, .types = &types };

    if (comptime generated) {
        const rule = @import("generated_rx_open_mixed_state");
        const Command = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

        const Host = struct {
            opening: *const Opening,
            store_0: *Command,
            pub fn commit(host: *@This(), pending: rule.zx_pending) Error!void {
                const command = pending.store_0 orelse return;
                const state = host.opening;

                switch (command.step) {
                    .Types => try state.installTypes(),
                    .Natives => try state.installNatives(),
                    .Results => try state.openResults(),
                    .Origins => try state.installOrigins(),
                    .Signatures => try state.installSignatures(),
                }
            }
        };

        const initial: std.meta.Child(Command) = .{ .step = .Types };
        var command: Command = &initial;
        var host: Host = .{ .opening = &opening, .store_0 = &command };
        var buffer: [512]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, self.scratch.allocator());

        rule.executeIn(scratch.allocator(), {}, &host) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSourceGraph => error.InvalidSourceGraph,
            else => unreachable,
        };
    } else {
        try opening.installTypes();
        try opening.installNatives();
        try opening.openResults();
        try opening.installOrigins();
        try opening.installSignatures();
    }

    return self;
}

const Opening = struct {
    state: *Self,
    types: *const ir.TypeTable,
    fn installTypes(self: *const Opening) std.mem.Allocator.Error!void {
        self.state.types.items = try frontend.type_table.storage(self.state.allocator, self.types.*);
    }
    fn installNatives(self: *const Opening) std.mem.Allocator.Error!void {
        self.state.native_modules = try frontend.native_context.storage(self.state.allocator, self.state.options.context.native_modules);
    }

    fn openResults(self: *const Opening) std.mem.Allocator.Error!void {
        self.state.finished = try Finished.init(self.state.allocator, self.state.graph.modules.len);
    }

    fn installOrigins(self: *const Opening) Error!void {
        const state = self.state;

        state.types.origins.seed(state.types.items.view(), state.options.context.nominal_types) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;

            return error.InvalidSourceGraph;
        };
    }
    fn installSignatures(self: *const Opening) std.mem.Allocator.Error!void {
        // The signature descriptors already belong to the result or retained history.
        const state = self.state;
        const columns = @import("../history/columns.zig");
        const lengths = columns.Lengths(ir.FunctionStorage);
        const functions = state.signatures.functions;

        try columns.transplant(state.allocator, .{.{
            .storage = &state.functions,
            .source = functions,
            .start = @as(lengths, @splat(0)),
            .end = @as(lengths, @splat(functions.count())),
        }});
    }
};

pub fn destination(self: *Self) frontend.project.artifact.program_link.Destination {
    return .{ .allocator = self.allocator, .temporary = self.scratch.allocator(), .types = &self.types, .functions = &self.functions, .native_modules = &self.native_modules };
}

pub fn verifiedFunctions(self: *const Self) ir.FunctionTable {
    return self.functions.view().prefix(self.verified);
}

pub fn signature(self: *const Self, index: usize) ?frontend.project.signature_project.Module {
    const row = @import("../references/signatures.zig").indexAt(self.signature_indices, index) orelse return null;

    return self.signatures.modules[row];
}

pub fn fail(self: *Self, location: rx.ast.Location, message: []const u8) Error {
    self.issue = .{ .path = self.graph.modules.items(.path)[self.owner], .location = location, .code = "module", .message = try self.allocator.dupe(u8, message) };

    return error.InvalidSourceGraph;
}
