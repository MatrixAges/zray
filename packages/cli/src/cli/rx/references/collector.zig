const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const compiler = @import("compiler");
const Reference = @import("rx_analysis").project.source_graph.Reference;
const Self = @This();
pub const Error = anyerror;

allocator: std.mem.Allocator,
temporary: *std.heap.ArenaAllocator,
options: compiler.project.Options,
owner: []const u8,
package_scope: ?compiler.project.ImportScope = null,
queue: *std.ArrayList([]const u8),
queued: *std.StringHashMapUnmanaged(void),
io: std.Io,
inputs: ?*@import("watch_inputs").Inputs,
libraries: ?*@import("../../library/inputs.zig"),
writer: *std.Io.Writer,
fn scope(self: *Self) compiler.project.ImportScope {
    if (self.package_scope) |previous| return previous;

    const current = compiler.project.ImportScope.init(self.options.package_scopes, self.owner);

    self.package_scope = current;

    return current;
}

pub fn dependencies(self: *Self) []const compiler.project.Package {
    return self.scope().dependencies(self.options.packages);
}

pub fn fail(self: *Self, location: rx.ast.Location, message: []const u8) Error {
    try self.writer.print("{s}:{d}:{d}: module: {s}\n", .{ self.owner, location.line, location.column, message });

    return error.InvalidSourceGraph;
}

pub fn local(self: *Self, path: []const u8, _: rx.ast.Location, _: Reference) Error!void {
    return self.enqueue(path);
}

pub fn enqueue(self: *Self, path: []const u8) Error!void {
    const absolute = try std.fs.path.resolve(self.allocator, &.{ self.options.root_dir, path });
    const found = try self.queued.getOrPut(self.allocator, absolute);

    if (found.found_existing) {
        self.allocator.free(absolute);

        return;
    }

    try self.queue.append(self.allocator, absolute);
}

pub fn qualified(self: *Self, path: []const u8, member: []const u8, location: rx.ast.Location) Error!void {
    const temporary = self.temporary.allocator();
    const candidate = try std.fs.path.resolve(temporary, &.{ self.options.root_dir, path });
    const selected = try @import("../../sources/module_path.zig").qualified(self.io, temporary, candidate, member, self.inputs);

    try self.local(selected.path, location, .call);
}

pub fn store(self: *Self, path: []const u8, location: rx.ast.Location, _: []const u8) Error!void {
    return self.local(path, location, .dependency);
}

pub fn import(self: *Self, reference: []const u8, location: rx.ast.Location, role: Reference, known: ?compiler.project.PackageMatch) Error!void {
    const route = compiler.project.importRoute(reference);

    switch (route) {
        .Invalid => return self.fail(location, "invalid module reference"),
        .Intrinsic, .Interface => return,
        .File, .Package => {},
    }

    var reporter: zx.Reporter = .{};
    const temporary = self.temporary.allocator();

    const target = compiler.project.resolveScopedTarget(.{ .source = temporary, .compiled = self.allocator }, self.owner, reference, route, self.options, self.scope(), known, &reporter, .{ .start = location.offset, .end = location.offset }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return self.fail(location, reporter.diagnostic.?.message);
    };

    switch (target) {
        .source => |path| {
            defer temporary.free(path);

            try self.local(path, location, role);
        },
        .compiled => |compiled| if (self.libraries) |libraries| {
            _ = try libraries.add(self.io, compiled, self.options, self.inputs);
        },
    }
}
