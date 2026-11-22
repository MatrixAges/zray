const std = @import("std");
const rx = @import("rx");
const project = @import("frontend").project;
const Diagnostic = @import("../../call/target.zig").Diagnostic;

pub const Options = struct {
    entry: []const u8,
    additional_roots: []const []const u8 = &.{},
    /// Add the registered RX modules before the explicit roots.
    include_rx_modules: bool = false,
    sources: []const project.Source,
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource = &.{},
    project: project.Options,
    parse_cache: ?*project.ParseCache = null,
    /// Optional output for the immediately following signature analysis. Requires a shared cache.
    prefetched: ?*project.ParseCache.Prefetched = null,
    scratch_allocator: ?std.mem.Allocator = null,
    /// Optional caller-owned index. Its buckets use the scratch allocator and its keys may borrow the result.
    registered_paths: ?*project.source_index.Map = null,
    retain_source_dependencies: bool = false,
};

pub const Source = union(enum) { zx: usize, rx: usize, store: usize };

pub const Sources = struct {
    zx_count: usize,
    rx_end: usize,
    pub fn at(self: Sources, row: usize) Source {
        if (row < self.zx_count) return .{ .zx = row };
        if (row < self.rx_end) return .{ .rx = row - self.zx_count };

        return .{ .store = row - self.rx_end };
    }
};

pub const Target = union(enum) { source: usize, compiled: project.compiled.Target, native: []const u8 };

pub const Reference = enum(u8) {
    dependency,
    call,
    type_import,
    store,
    pub fn fromXml(role: @FieldType(rx.dependency_reference.Entry, "role")) Reference {
        return switch (role) {
            .Dependency => .dependency,
            .Call => .call,
            .TypeImport => .type_import,
        };
    }
};

pub const Edge = struct {
    target: Target,
    /// Byte offset only for ZX edges, fully resolved for XML edges.
    location: rx.ast.Location,
    reference: Reference = .dependency,
    named: bool = false,
    pub fn locate(self: Edge, source: []const u8) rx.ast.Location {
        return @import("position.zig").locate(self.location, source);
    }
};

pub const Module = struct {
    path: []const u8,
    dependencies: []const Edge = &.{},
    compiled_dependency: bool = false,
};

pub const Modules = std.MultiArrayList(Module);
pub const References = @import("references.zig");

pub const Schedule = struct {
    order: []const usize,
    /// Exclusive end of each consecutive run of equal dependency depth.
    batch_ends: []const usize,
};

pub const Scheduled = union(enum) { schedule: Schedule, diagnostic: Diagnostic };

pub const Adjacency = struct {
    starts: []u64,
    ends: []u64,
    targets: []const u64 = &.{},
};

pub const SourceDependencies = struct {
    starts: []const u64,
    ends: []const u64,
    targets: []const u64,
    pub fn at(self: SourceDependencies, row: usize) []const u64 {
        return self.targets[@intCast(self.starts[row])..@intCast(self.ends[row])];
    }
};

pub const Graph = struct {
    modules: Modules.Slice,
    sources: Sources,
    order: []const usize,
    batch_ends: []const usize,
    entry: usize,
    additional_roots: []const usize = &.{},
    source_dependencies: ?SourceDependencies = null,
};

pub const Value = union(enum) { graph: Graph, diagnostic: Diagnostic };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn cycle(module: Module, source: Source, edge: Edge, sources: []const project.Source) Scheduled {
    return .{ .diagnostic = .{
        .path = module.path,
        .location = edge.locate(if (source == .zx) sources[source.zx].source else ""),
        .code = "module",
        .message = "source module dependencies must be acyclic across RX and ZX, including unused imports",
    } };
}
