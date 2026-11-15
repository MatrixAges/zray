const zx = @import("zx");
const registry = @import("../../package_scope.zig");
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
    if (self.scopes.len != 0 and self.owner == null) return reporter.fail(.module, span, "source file does not belong to a declared package");
}

pub fn checkFile(self: Self, path: []const u8, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    if (self.scopes.len == 0) return;
    try self.checkOwner(reporter, span);

    if (registry.owner(self.scopes, path) != self.owner) return reporter.fail(.module, span, "file import crosses a package boundary; declare and import the package dependency");
}
