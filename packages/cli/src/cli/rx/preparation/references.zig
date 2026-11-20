const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const zx = @import("zx");
const Inputs = @import("watch_inputs").Inputs;
const Libraries = @import("../../library/inputs.zig");
const effects = @import("../../sources/effects.zig");
const Error = effects.Error;
const abi = @import("rx_preparation_abi").native.@"zig:rx_preparation_host";
const Role = abi.Role;
const Target = abi.Target;
const Entry = rx.dependency_reference.Entry;

pub const Cursor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project: compiler.project.Options,
    modules: []const rx.ModuleSource,
    stores: []const rx.ModuleSource = &.{},
    writer: *std.Io.Writer,
    inputs: ?*Inputs,
    libraries: ?*Libraries = null,
    failure: effects.Failure = .{},
    module: *const rx.ModuleSource = undefined,
    owner: []const u8 = undefined,
    packages: []const compiler.project.Package = undefined,
    entries: []const Entry = undefined,
    entry: *const Entry = undefined,
    attribute: *const rx.ast.Attribute = undefined,
    target: compiler.project.ImportTarget = undefined,
    pub fn get(handle: *const anyopaque) *Cursor {
        return effects.state(Cursor, handle);
    }
    pub fn report(self: *Cursor, message: []const u8) Error!void {
        const location = self.attribute.value_location;

        self.writer.print("{s}:{d}:{d}: module: {s}\n", .{ self.module.path, location.line, location.column, message }) catch |err| return self.failure.save(err);
    }
};

pub fn preparationModuleCount(handle: *const anyopaque) u64 {
    const self = Cursor.get(handle);

    return self.modules.len + self.stores.len;
}

pub fn selectPreparationModule(handle: *const anyopaque, index: u64) Error!u64 {
    const self = Cursor.get(handle);
    const row: usize = @intCast(index);
    const module = if (row < self.modules.len) &self.modules[row] else &self.stores[row - self.modules.len];
    const owner = std.fs.path.resolve(self.allocator, &.{ self.project.root_dir, module.path }) catch |err| return self.failure.save(err);

    self.module = module;
    self.owner = owner;
    self.packages = rx.module_reference.dependencies(self.project, owner);
    self.entries = module.indexedReferences() orelse unreachable;

    return self.entries.len;
}

pub fn preparationReferenceRole(handle: *const anyopaque, index: u64) Role {
    const self = Cursor.get(handle);
    const entry = &self.entries[@intCast(index)];
    const role: Role = if (entry.role == .TypeImport) .TypeImport else if (entry.role == .Call and entry.target == .Module) .ModuleCall else return .Other;
    self.entry = entry;

    return role;
}

pub fn isPreparationPackage(handle: *const anyopaque) bool {
    const self = Cursor.get(handle);

    self.attribute = self.entry.attribute orelse unreachable;

    return rx.module_reference.isPackage(self.attribute.value, self.packages);
}

pub fn resolvePreparationTarget(handle: *const anyopaque, at_attribute: bool) Error!Target {
    const self = Cursor.get(handle);
    const attribute = self.attribute;
    const offset = if (at_attribute) attribute.value_location.offset else 0;
    var reporter: zx.Reporter = .{};

    self.target = compiler.project.resolveModuleTarget(self.allocator, self.owner, attribute.value, self.project, &reporter, .{ .start = offset, .end = offset }) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);
        try self.report(reporter.diagnostic.?.message);

        return .Invalid;
    };

    return switch (self.target) {
        .source => .Source,
        .compiled => .Compiled,
    };
}

pub fn preparationSourcePath(handle: *const anyopaque) []const u8 {
    return Cursor.get(handle).target.source;
}

pub fn reportPreparationReference(handle: *const anyopaque, message: []const u8) Error!void {
    try Cursor.get(handle).report(message);
}

pub fn prepareCompiledReference(handle: *const anyopaque) Error!bool {
    const self = Cursor.get(handle);
    const exported = self.libraries.?.add(self.io, self.target.compiled, self.project, self.inputs) catch |err| return self.failure.save(err);

    return exported.function != null;
}
