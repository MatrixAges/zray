const std = @import("std");
const builtin = @import("builtin");
const rx = @import("rx");
const zx = @import("zx");
const project = @import("frontend").project;
const model = @import("model.zig");
const position = @import("position.zig");
const Diagnostic = @import("../../call/target.zig").Diagnostic;
const generated = @import("rx_options").generated_graph;
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{InvalidGraph};

allocator: std.mem.Allocator,
backing: std.mem.Allocator,
target_allocator: std.mem.Allocator,
temporary: std.heap.ArenaAllocator,
options: project.Options,
modules: model.Modules.Slice,
sources: model.Sources,
paths: *const project.source_index.Map,
edges: std.ArrayList(model.Edge) = .empty,
targets: std.ArrayList(u64) = .empty,
owner: usize = 0,
source_text: []const u8 = "",
package_scope: ?project.ImportScope = null,
issue: ?Diagnostic = null,
fn ownerPath(self: *const Self) []const u8 {
    return self.modules.items(.path)[self.owner];
}

pub fn begin(self: *Self, owner: usize, source_text: []const u8) void {
    self.owner = owner;
    self.source_text = source_text;
    self.package_scope = null;
}

fn scope(self: *Self) project.ImportScope {
    if (self.package_scope) |previous| return previous;

    const current = project.ImportScope.init(self.options.package_scopes, self.ownerPath());

    self.package_scope = current;

    return current;
}

pub fn dependencies(self: *Self) []const project.Package {
    return self.scope().dependencies(self.options.packages);
}

pub fn store(self: *Self, path: []const u8, location: rx.ast.Location, owner: []const u8) Error!void {
    const temporary = self.temporary.allocator();
    const absolute = try std.fs.path.resolve(temporary, &.{ self.options.root_dir, path });

    defer temporary.free(absolute);

    if (comptime generated) {
        return self.admit(absolute, location, .store, null, owner);
    }

    const index = self.paths.get(absolute);

    if (index == null or self.sources.at(index.?) != .store) {
        return self.missingStore(owner, location);
    }

    try self.checkBoundary(absolute, location);
    try self.sourceEdge(index.?, location, .store);
}

pub fn fail(self: *Self, location: rx.ast.Location, message: []const u8) Error {
    self.issue = .{
        .path = self.ownerPath(),
        .location = position.locate(location, self.source_text),
        .code = "module",
        .message = try self.allocator.dupe(u8, message),
    };

    return error.InvalidGraph;
}

fn source(self: *Self, path: []const u8, location: rx.ast.Location, reference: model.Reference, selected_row: ?usize) Error!void {
    const row = if (self.options.source_index == self.paths) selected_row else null;
    const index = row orelse self.paths.get(path) orelse return self.fail(location, "source module dependency is missing from the registered input set");

    try self.sourceEdge(index, location, reference);
}

fn sourceEdge(self: *Self, index: usize, location: rx.ast.Location, reference: model.Reference) Error!void {
    try self.targets.append(self.target_allocator, index);
    try self.edges.append(self.allocator, .{ .target = .{ .source = index }, .location = location, .reference = reference });
}

pub fn local(self: *Self, path: []const u8, location: rx.ast.Location, reference: model.Reference) Error!void {
    const temporary = self.temporary.allocator();
    const absolute = try std.fs.path.resolve(temporary, &.{ self.options.root_dir, path });

    defer temporary.free(absolute);

    const resolved: project.SourceSelection = if (std.mem.endsWith(u8, absolute, ".zx"))
        try project.selectIndexedSource(temporary, absolute, self.options.source_index)
    else
        .{ .path = absolute };

    defer if (resolved.path.ptr != absolute.ptr) temporary.free(resolved.path);

    return self.localSelected(resolved, location, reference);
}

pub fn qualified(self: *Self, path: []const u8, member: []const u8, location: rx.ast.Location) Error!void {
    const temporary = self.temporary.allocator();
    const absolute = try std.fs.path.resolve(temporary, &.{ self.options.root_dir, path });

    defer temporary.free(absolute);

    var row: ?usize = null;
    const known = project.source_index.Known{ .paths = self.options.source_index.?, .matched_row = &row };
    const selected = try project.module_path.selectQualified(temporary, absolute, member, known);

    defer if (selected.path.ptr != absolute.ptr) temporary.free(selected.path);

    try self.localSelected(.{ .path = selected.path, .row = row }, location, .call);

    self.edges.items[self.edges.items.len - 1].named = selected.named;
}

fn localSelected(self: *Self, resolved: project.SourceSelection, location: rx.ast.Location, reference: model.Reference) Error!void {
    if (comptime generated) {
        return self.admit(resolved.path, location, reference, resolved.row, null);
    }

    try self.checkBoundary(resolved.path, location);
    try self.source(resolved.path, location, reference, resolved.row);
}

fn missingStore(self: *Self, owner: []const u8, location: rx.ast.Location) Error {
    self.issue = .{ .path = self.allocator.dupe(u8, owner) catch return error.OutOfMemory, .location = location, .code = "capability", .message = "Store definition is not registered" };

    return error.InvalidGraph;
}

fn admit(self: *Self, path: []const u8, location: rx.ast.Location, reference: model.Reference, prior_row: ?usize, store_owner: ?[]const u8) Error!void {
    const rule = @import("generated_rx_registered_target");
    const import_scope = self.scope();
    const roots = @import("zx").memory.borrowTextColumn("root", import_scope.scopes);

    const input: std.meta.Child(rule.Input) = .{
        .path = path,
        .index = &.{
            .keys = self.paths.keys,
            .buckets = @ptrCast(&self.paths.buckets),
            .capacity = self.paths.buckets.len,
        },
        .matched = if (self.options.source_index == self.paths) prior_row else null,
        .scope = &.{
            .roots = &.{ .items = @ptrCast(&roots), .length = roots.count },
            .owner = import_scope.owner,
            .windows = builtin.os.tag == .windows,
        },
        .store_start = if (store_owner != null) self.sources.rx_end else null,
    };

    const Result = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;
    const Value = if (@typeInfo(Result) == .pointer) std.meta.Child(Result) else Result;
    var bytes: [@sizeOf(Value)]u8 align(@alignOf(Value)) = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&bytes);
    const decision = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    if (decision.store_missing) return self.missingStore(store_owner.?, location);

    var reporter: zx.Reporter = .{};

    project.ImportScope.report(decision.boundary, &reporter, .{ .start = location.offset, .end = location.offset }) catch
        return self.fail(location, reporter.diagnostic.?.message);

    const row = decision.row orelse return self.fail(location, "source module dependency is missing from the registered input set");

    try self.sourceEdge(@intCast(row), location, reference);
}

fn checkBoundary(self: *Self, path: []const u8, location: rx.ast.Location) Error!void {
    var reporter: zx.Reporter = .{};

    self.scope().checkFile(path, &reporter, .{ .start = location.offset, .end = location.offset }) catch
        return self.fail(location, reporter.diagnostic.?.message);
}

pub fn import(self: *Self, reference: []const u8, location: rx.ast.Location, role: model.Reference, known: ?project.PackageMatch) Error!void {
    return self.importPlanned(reference, location, role, project.importRoute(reference), known);
}

pub fn importPlanned(self: *Self, reference: []const u8, location: rx.ast.Location, role: model.Reference, route: project.ImportRoute, known: ?project.PackageMatch) Error!void {
    switch (route) {
        .Invalid => return self.fail(location, "invalid or unknown import specifier"),
        .Intrinsic, .Interface => return self.nativeImport(reference, location, role),
        .Package => {
            if (self.options.internalModule(reference)) |entry| {
                return self.nativeImport(entry.key(), location, role);
            }
        },
        .File => {},
    }

    var reporter: zx.Reporter = .{};
    const temporary = self.temporary.allocator();

    const resolved = project.resolveIndexedTarget(.{ .source = temporary, .compiled = self.allocator }, self.ownerPath(), reference, route, self.options, self.scope(), known, &reporter, .{ .start = location.offset, .end = location.offset }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return self.fail(location, reporter.diagnostic.?.message);
    };

    switch (resolved.target) {
        .source => |path| {
            defer temporary.free(path);

            try self.source(path, location, role, resolved.source_row);
        },
        .compiled => |compiled| {
            self.modules.items(.compiled_dependency)[self.owner] = true;

            try self.edges.append(self.allocator, .{ .target = .{ .compiled = compiled }, .location = location, .reference = role });
        },
    }
}

fn nativeImport(self: *Self, name: []const u8, location: rx.ast.Location, role: model.Reference) Error!void {
    try self.edges.append(self.allocator, .{ .target = .{ .native = try self.allocator.dupe(u8, name) }, .location = location, .reference = role });
}
