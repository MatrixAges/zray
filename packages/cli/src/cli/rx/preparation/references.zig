const std = @import("std");
const compiler = @import("compiler");
const rx = @import("rx");
const zx = @import("zx");
const Inputs = @import("watch_inputs").Inputs;
const Text = @import("../../sources/text.zig");
const Libraries = @import("../../library/inputs.zig");
const effects = @import("../../sources/effects.zig");
const Error = effects.Error;
const abi = @import("cli_abi").native.@"zig:rx_preparation_host";
const Role = abi.Role;
const ModuleReferenceLayout = @import("cli_abi").layouts.@"zig:rx_preparation_host".ModuleReference;
const ModuleReference = @import("cli_abi").native.@"zig:rx_preparation_host".ModuleReference;
const ResolvedTarget = @import("cli_abi").layouts.@"zig:rx_preparation_host".ResolvedTarget;
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
    texts: ?*Text.Cache = null,
    type_sources: std.ArrayList(rx.TextSource) = .empty,
    failure: effects.Failure = .{},
    module: *const rx.ModuleSource = undefined,
    owner: []const u8 = undefined,
    packages: []const compiler.project.Package = undefined,
    entries: []const Entry = undefined,
    ref_items: []ModuleReferenceLayout = &.{},
    ref_ptrs: []ModuleReference = &.{},
    target: compiler.project.ImportTarget = undefined,
    resolved_view: ResolvedTarget = undefined,
    pub fn get(handle: *const anyopaque) *Cursor {
        return effects.state(Cursor, handle);
    }
    pub fn deinit(self: *Cursor) void {
        self.allocator.free(self.ref_ptrs);
        self.allocator.free(self.ref_items);

        self.ref_ptrs = &.{};
        self.ref_items = &.{};
    }

    pub fn report(self: *Cursor, index: usize, message: []const u8) Error!void {
        const location = self.entries[index].attribute.?.value_location;

        self.writer.print("{s}:{d}:{d}: module: {s}\n", .{ self.module.path, location.line, location.column, message }) catch |err| return self.failure.save(err);
    }
};

pub fn selectPreparationModule(handle: *const anyopaque, index: u64) Error![]const ModuleReference {
    const self = Cursor.get(handle);
    const row: usize = @intCast(index);
    const module = if (row < self.modules.len) &self.modules[row] else &self.stores[row - self.modules.len];
    const owner = std.fs.path.resolve(self.allocator, &.{ self.project.root_dir, module.path }) catch |err| return self.failure.save(err);

    self.module = module;
    self.owner = owner;
    self.packages = rx.module_reference.dependencies(self.project, owner);
    self.entries = module.indexedReferences() orelse unreachable;

    self.allocator.free(self.ref_ptrs);
    self.allocator.free(self.ref_items);

    self.ref_items = self.allocator.alloc(ModuleReferenceLayout, self.entries.len) catch |err| return self.failure.save(err);
    self.ref_ptrs = self.allocator.alloc(ModuleReference, self.entries.len) catch |err| return self.failure.save(err);

    for (self.entries, self.ref_items, self.ref_ptrs) |entry, *slot, *ptr| {
        const role: Role = if (entry.role == .TypeImport) .TypeImport else if (entry.role == .Call and entry.target == .Module) .ModuleCall else .Other;
        const is_package = if (role != .Other) rx.module_reference.isPackage(entry.attribute.?.value, self.packages) else false;

        slot.* = .{
            .role = role,
            .is_package = is_package,
        };

        ptr.* = slot;
    }

    return self.ref_ptrs;
}

pub fn resolvePreparationTarget(handle: *const anyopaque, index: u64, at_attribute: bool) Error!*const ResolvedTarget {
    const self = Cursor.get(handle);
    const ref_index: usize = @intCast(index);
    const attribute = self.entries[ref_index].attribute orelse unreachable;
    const offset = if (at_attribute) attribute.value_location.offset else 0;
    var reporter: zx.Reporter = .{};

    self.target = compiler.project.resolveModuleTarget(self.allocator, self.owner, attribute.value, self.project, &reporter, .{ .start = offset, .end = offset }) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);
        try self.report(ref_index, reporter.diagnostic.?.message);

        self.resolved_view = .{ .target = .Invalid, .source_path = "" };

        return &self.resolved_view;
    };

    switch (self.target) {
        .source => |source| {
            const path = std.fs.path.resolve(self.allocator, &.{ self.project.root_dir, source }) catch |err| return self.failure.save(err);

            self.resolved_view = .{ .target = .Source, .source_path = path };
        },
        .compiled => {
            self.resolved_view = .{ .target = .Compiled, .source_path = "" };
        },
    }

    return &self.resolved_view;
}

pub fn reportPreparationReference(handle: *const anyopaque, index: u64, message: []const u8) Error!void {
    try Cursor.get(handle).report(@intCast(index), message);
}

pub fn prepareCompiledReference(handle: *const anyopaque) Error!bool {
    const self = Cursor.get(handle);
    const exported = self.libraries.?.add(self.io, self.target.compiled, self.project, self.inputs) catch |err| return self.failure.save(err);

    return exported.function != null;
}
