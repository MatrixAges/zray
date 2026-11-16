const std = @import("std");
const builtin = @import("builtin");
const zx = @import("zx");
const registry = @import("../../package_scope.zig");
const enabled = @import("parser_options").generated_parser;
const boundary = if (enabled) @import("generated_project_package_boundary") else void;
pub const Boundary = if (enabled) boundary.Output else enum { Allowed, MissingOwner, Crossed };

const Self = @This();

scopes: []const registry.Scope,
owner: ?usize,
pub fn init(scopes: []const registry.Scope, path: []const u8) Self {
    return .{ .scopes = scopes, .owner = registry.owner(scopes, path) };
}

pub fn root(self: Self, fallback: []const u8) []const u8 {
    return if (self.owner) |index| self.scopes[index].root else fallback;
}

pub fn dependencies(self: Self, fallback: []const registry.Package) []const registry.Package {
    if (self.scopes.len == 0) return fallback;

    return if (self.owner) |index| self.scopes[index].packages else &.{};
}

pub fn checkOwner(self: Self, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    if (self.scopes.len != 0 and self.owner == null) return report(.MissingOwner, reporter, span);
}

pub fn checkFile(self: Self, path: []const u8, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    if (self.scopes.len == 0) return;

    if (comptime enabled) {
        const roots = @import("zx").memory.borrowTextColumn("root", self.scopes);

        const input: std.meta.Child(boundary.Input) = .{
            .roots = &.{ .items = @ptrCast(&roots), .length = roots.count },
            .path = path,
            .owner = self.owner,
            .windows = builtin.os.tag == .windows,
        };

        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const status = zx.columns.invoke(boundary.executeValue, empty.allocator(), &input) catch unreachable;

        return report(status, reporter, span);
    }

    try self.checkOwner(reporter, span);

    if (registry.owner(self.scopes, path) != self.owner) return report(.Crossed, reporter, span);
}

pub fn report(status: Boundary, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    switch (status) {
        .Allowed => {},
        .MissingOwner => return reporter.fail(.module, span, "source file does not belong to a declared package"),
        .Crossed => return reporter.fail(.module, span, "file import crosses a package boundary; declare and import the package dependency"),
    }
}
