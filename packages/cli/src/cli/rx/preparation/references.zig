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
const CompiledTarget = @import("cli_abi").layouts.@"zig:rx_preparation_host".CompiledTarget;

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
    ref_items: []ModuleReferenceLayout = &.{},
    ref_ptrs: []ModuleReference = &.{},
    pub fn get(handle: *const anyopaque) *Cursor {
        return effects.state(Cursor, handle);
    }
    pub fn deinit(self: *Cursor) void {
        self.allocator.free(self.ref_ptrs);
        self.allocator.free(self.ref_items);

        self.ref_ptrs = &.{};
        self.ref_items = &.{};
    }

    pub fn report(self: *Cursor, reference: ModuleReference, message: []const u8) Error!void {
        self.writer.print("{s}:{d}:{d}: module: {s}\n", .{ reference.path, reference.line, reference.column, message }) catch |err| return self.failure.save(err);
    }
};

pub fn selectPreparationModule(handle: *const anyopaque, index: u64) Error![]const ModuleReference {
    const self = Cursor.get(handle);
    const row: usize = @intCast(index);
    const module = if (row < self.modules.len) &self.modules[row] else &self.stores[row - self.modules.len];
    const owner = std.fs.path.resolve(self.allocator, &.{ self.project.root_dir, module.path }) catch |err| return self.failure.save(err);
    const packages = rx.module_reference.dependencies(self.project, owner);
    const entries = module.indexedReferences() orelse unreachable;

    self.ref_items = self.allocator.realloc(self.ref_items, entries.len) catch |err| return self.failure.save(err);
    self.ref_ptrs = self.allocator.realloc(self.ref_ptrs, entries.len) catch |err| return self.failure.save(err);

    for (entries, self.ref_items, self.ref_ptrs) |entry, *slot, *ptr| {
        const role: Role = if (entry.role == .TypeImport) .TypeImport else if (entry.role == .Call and entry.target == .Module) .ModuleCall else .Other;
        const attribute = entry.attribute;
        const value = if (attribute) |item| item.value else "";
        const location: rx.ast.Location = if (attribute) |item| item.value_location else .{ .line = 0, .column = 0, .offset = 0 };

        slot.* = .{
            .role = role,
            .is_package = role != .Other and rx.module_reference.isPackage(value, packages),
            .owner = owner,
            .path = module.path,
            .value = value,
            .offset = location.offset,
            .line = location.line,
            .column = location.column,
        };

        ptr.* = slot;
    }

    return self.ref_ptrs;
}

pub fn resolvePreparationTarget(
    allocator: std.mem.Allocator,
    handle: *const anyopaque,
    reference: ModuleReference,
    at_attribute: bool,
) (Error || std.mem.Allocator.Error)!*const ResolvedTarget {
    const self = Cursor.get(handle);
    const offset: usize = if (at_attribute) @intCast(reference.offset) else 0;
    const result = try allocator.create(ResolvedTarget);
    var reporter: zx.Reporter = .{};

    const target = compiler.project.resolveModuleTarget(self.allocator, reference.owner, reference.value, self.project, &reporter, .{ .start = offset, .end = offset }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        try self.report(reference, reporter.diagnostic.?.message);

        result.* = .{ .target = .Invalid, .source_path = "", .compiled = null };

        return result;
    };

    switch (target) {
        .source => |source| {
            const path = try std.fs.path.resolve(self.allocator, &.{ self.project.root_dir, source });

            result.* = .{ .target = .Source, .source_path = path, .compiled = null };
        },
        .compiled => |compiled| {
            const view = try allocator.create(CompiledTarget);
            view.* = .{ .name = compiled.name, .instance = compiled.instance, .artifact = compiled.artifact };
            result.* = .{ .target = .Compiled, .source_path = "", .compiled = view };
        },
    }

    return result;
}

pub fn prepareCompiledReference(handle: *const anyopaque, target: *const CompiledTarget) Error!bool {
    const self = Cursor.get(handle);
    const exported = self.libraries.?.add(self.io, .{ .name = target.name, .instance = target.instance, .artifact = target.artifact }, self.project, self.inputs) catch |err| return self.failure.save(err);

    return exported.function != null;
}
