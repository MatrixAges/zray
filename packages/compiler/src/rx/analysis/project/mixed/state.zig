const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const ir = @import("zx").ir;
const target = @import("../../call/target.zig");
const SourceGraph = @import("../source_graph.zig").Graph;
const Types = frontend.project.artifact.type_link.Table;
const Finished = @import("finished.zig");
const Self = @This();
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
retained_initializers: []const frontend.project.compiled.StoreInitializer = &.{},
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
        .types = .{ .allocator = allocator, .items = try frontend.type_table.storage(allocator, types), .origins = .{ .allocator = allocator } },
        .native_modules = try frontend.native_context.storage(allocator, options.context.native_modules),
        .finished = try Finished.init(allocator, graph.modules.len),
        .libraries = .{ .inherited = signatures.libraries },
        .signature_indices = signature_indices,
        .retained_initializers = signatures.store_initializers,
    };

    self.types.origins.seed(self.types.items.view(), options.context.nominal_types) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return error.InvalidSourceGraph;
    };

    // The signature table's descriptors live in this result arena or in the
    // retained history that owns the reused signatures. This storage is arena-bound.
    const columns = @import("../history/columns.zig");
    const lengths = columns.Lengths(ir.FunctionStorage);

    try columns.transplant(allocator, .{.{
        .storage = &self.functions,
        .source = signatures.functions,
        .start = @as(lengths, @splat(0)),
        .end = @as(lengths, @splat(signatures.functions.count())),
    }});

    try self.initializers.appendSlice(allocator, signatures.store_initializers);

    return self;
}

pub fn destination(self: *Self) frontend.project.artifact.program_link.Destination {
    return .{ .allocator = self.allocator, .temporary = self.scratch.allocator(), .types = &self.types, .functions = &self.functions, .native_modules = &self.native_modules };
}

pub fn verifiedFunctions(self: *const Self) ir.FunctionTable {
    return self.functions.view().prefix(self.verified);
}

/// A frozen view can be retained by linked modules after the import list grows.
pub fn initializersView(self: *Self) std.mem.Allocator.Error![]const frontend.project.compiled.StoreInitializer {
    if (self.retained_initializers.len != self.initializers.items.len) {
        self.retained_initializers = try self.allocator.dupe(frontend.project.compiled.StoreInitializer, self.initializers.items);
    }

    return self.retained_initializers;
}

pub fn signature(self: *const Self, index: usize) ?frontend.project.signature_project.Module {
    const row = @import("../references/signatures.zig").indexAt(self.signature_indices, index) orelse return null;

    return self.signatures.modules[row];
}

pub fn fail(self: *Self, location: rx.ast.Location, message: []const u8) Error {
    self.issue = .{ .path = self.graph.modules.items(.path)[self.owner], .location = location, .code = "module", .message = try self.allocator.dupe(u8, message) };

    return error.InvalidSourceGraph;
}
