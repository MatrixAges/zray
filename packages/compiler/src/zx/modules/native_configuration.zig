const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const registry = @import("project/target/registry.zig");
const interfaces = @import("generated_native_configuration_interface");
const externals = @import("generated_native_configuration_externals");
const modules = @import("generated_native_configuration_modules");
const backend = @import("generated_native_configuration_backend_name");
const names = @import("generated_native_configuration_names");
const registered = @import("generated_native_configuration_registered_name");
const dependency = @import("generated_native_configuration_dependencies");
const declaration_name = @import("generated_native_configuration_declaration");
const Backend = std.meta.Child(backend.Input);
pub const Scope = std.meta.Child(@FieldType(Backend, "scope"));
const name_workspace_size = 1024;

pub const AdmissionError = error{
    InvalidSpecifier,
    InvalidExternalSpecifier,
    InvalidNativeInterfacePath,
    InvalidNativeModule,
    ReservedNativeModule,
    DuplicateNativeModule,
};

pub fn validateExternals(rows: anytype) AdmissionError!void {
    if (rows.len == 0) return;

    const view = memory.borrowTextColumn("specifier", rows);
    const request: std.meta.Child(externals.Input) = .{ .items = @ptrCast(&view), .length = rows.len };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return admitted(zx.columns.invoke(externals.executeValue, scratch.allocator(), &request) catch unreachable);
}

pub fn validateInterface(specifier: []const u8, path: []const u8) AdmissionError!void {
    const request: std.meta.Child(interfaces.Input) = .{ .specifier = specifier, .path = path };
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return admitted(zx.columns.invoke(interfaces.executeValue, scratch.allocator(), &request) catch unreachable);
}

pub fn validateModules(rows: anytype) AdmissionError!void {
    if (rows.len == 0) return;

    const local = memory.borrowTextColumn("name", rows);
    const paths = memory.borrowReadColumn(?[]const u8, "path", rows);
    const headers = memory.borrowReadColumn(?[]const u8, "header", rows);

    const request: std.meta.Child(modules.Input) = .{
        .names = &.{ .items = @ptrCast(&local), .length = rows.len },
        .paths = @ptrCast(&paths),
        .headers = @ptrCast(&headers),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return admitted(zx.columns.invoke(modules.executeValue, scratch.allocator(), &request) catch unreachable);
}

fn admitted(status: anytype) AdmissionError!void {
    return switch (status) {
        .Valid => {},
        .InvalidSpecifier => error.InvalidSpecifier,
        .InvalidExternalSpecifier => error.InvalidExternalSpecifier,
        .InvalidNativeInterfacePath => error.InvalidNativeInterfacePath,
        .InvalidNativeModule => error.InvalidNativeModule,
        .ReservedNativeModule => error.ReservedNativeModule,
        .DuplicateNativeModule => error.DuplicateNativeModule,
    };
}

pub fn hasModule(rows: anytype, name: []const u8) bool {
    return registry.select(rows, "name", name, false).first != null;
}

pub const Names = struct {
    scope: Scope,
    local: memory.TextColumn,
    resolved: [][]const u8,
    pub fn name(self: *const Names, allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
        if (self.resolved.len != 0) {
            const Input = std.meta.Child(registered.Input);
            const View = std.meta.Child(@FieldType(Input, "registry"));
            const local = self.rows(std.meta.Child(@FieldType(View, "local")));
            const request: Input = .{ .registry = &.{ .local = &local, .names = self.resolved }, .value = value };
            var empty = std.heap.FixedBufferAllocator.init(&.{});

            if (zx.columns.invoke(registered.executeValue, empty.allocator(), &request) catch unreachable) |found| return found;
        }

        var buffer: [name_workspace_size]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
        var arena = std.heap.ArenaAllocator.init(scratch.allocator());

        defer arena.deinit();

        const request: Backend = .{ .scope = &self.scope, .value = value };
        const scoped = zx.columns.invoke(backend.executeValue, arena.allocator(), &request) catch return error.OutOfMemory;

        return allocator.dupe(u8, scoped);
    }
    pub fn dependencies(self: *const Names, allocator: std.mem.Allocator, values: []const []const u8) (std.mem.Allocator.Error || error{UnknownNativeDependency})![]const []const u8 {
        if (values.len == 0) return &.{};

        const output = try allocator.alloc([]const u8, values.len);
        const Input = std.meta.Child(dependency.Input);
        const View = std.meta.Child(@FieldType(Input, "registry"));
        const local = self.rows(std.meta.Child(@FieldType(View, "local")));

        const request: Input = .{
            .registry = &.{ .local = &local, .names = self.resolved },
            .dependencies = values,
            .output = @ptrCast(&output),
        };

        const bound = zx.columns.invoke(dependency.executeValue, allocator, &request) catch return error.OutOfMemory;

        if (!bound) return error.UnknownNativeDependency;

        return output;
    }
    fn rows(self: *const Names, comptime Local: type) Local {
        return .{ .items = @ptrCast(&self.local), .length = self.resolved.len };
    }
};

pub fn bindNames(allocator: std.mem.Allocator, temporary: std.mem.Allocator, rows: anytype, scope: Scope) std.mem.Allocator.Error!Names {
    const local = memory.borrowTextColumn("name", rows);
    const output = try temporary.alloc([]const u8, rows.len);

    errdefer temporary.free(output);

    if (rows.len != 0) {
        var buffer: [name_workspace_size]u8 = undefined;
        var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
        var arena = std.heap.ArenaAllocator.init(scratch.allocator());

        defer arena.deinit();

        const Input = std.meta.Child(names.Input);

        const request: Input = .{
            .scope = &scope,
            .local = &.{ .items = @ptrCast(&local), .length = rows.len },
            .names = @ptrCast(&output),
            .resource = @ptrCast(&allocator),
            .scratch = @ptrCast(&arena),
        };

        zx.columns.invoke(names.executeValue, arena.allocator(), &request) catch return error.OutOfMemory;
    }

    return .{ .scope = scope, .local = local, .resolved = output };
}

pub fn declaration(allocator: std.mem.Allocator, owner: []const u8, value: []const u8) (std.mem.Allocator.Error || error{InvalidExternalSpecifier})![]const u8 {
    var buffer: [name_workspace_size]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());

    defer arena.deinit();

    const input: std.meta.Child(declaration_name.Input) = .{ .owner = owner, .value = value };
    const scoped = (zx.columns.invoke(declaration_name.executeValue, arena.allocator(), &input) catch return error.OutOfMemory) orelse return error.InvalidExternalSpecifier;

    return allocator.dupe(u8, scoped);
}
