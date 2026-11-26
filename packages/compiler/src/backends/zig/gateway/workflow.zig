const std = @import("std");
const generating = @import("genz");
const Library = @import("../../../library/root.zig").Result;
const Bundle = @import("../library.zig").Bundle;
const File = @import("../modules.zig").File;
const State = @import("state.zig");
const imports_writer = @import("imports.zig");
const Self = @This();
pub const Options = struct { routes: []const generating.gateway.Route, listen: []const u8, max_header_bytes: u32, max_body_bytes: u32 };

allocator: std.mem.Allocator,
options: Options,
library: ?*const Library = null,
bundle: ?*const Bundle = null,
mapped: State.Result = .{},
files: std.ArrayList(File) = .empty,
state_imports: []const []const u8 = undefined,

entry: File = undefined,
pub fn build(self: *Self) !void {
    const bundle = self.bundle;
    const modules = if (bundle) |value| value.modules.len else 0;
    const facades = if (bundle) |value| value.public_modules.len else 0;

    if (bundle != null) try self.bindState();

    const files = std.math.add(usize, modules, facades) catch return error.OutOfMemory;
    const capacity = std.math.add(usize, files, 2) catch return error.OutOfMemory;

    try self.files.ensureTotalCapacityPrecise(self.allocator, capacity);

    if (bundle) |value| {
        self.files.appendSliceAssumeCapacity(value.modules);

        for (value.public_modules) |module| self.files.appendAssumeCapacity(module.file);
    }

    try self.publishContract();
    try self.publishState();
    try self.publishApplication();
}

fn bindState(self: *Self) State.Error!void {
    self.mapped = try State.create(self.allocator, self.library.?, self.bundle.?.*);
}

fn publishContract(self: *Self) std.mem.Allocator.Error!void {
    const prefix = "application=gateway_storage_contract";

    const state_imports = if (self.mapped.object_columns != null)
        try imports_writer.prefixedColumns(self.allocator, prefix, self.mapped.object_columns.?.modules, self.mapped.object_columns.?.count)

    else
        try imports_writer.prefixed(self.allocator, prefix, "module_name", self.mapped.objects);

    const initial_imports = state_imports[1..];
    const source = try generating.gateway.storage.render(self.allocator, initial_imports);

    self.state_imports = state_imports;

    self.files.appendAssumeCapacity(.{ .name = "gateway_storage_contract", .source = source, .imports = initial_imports });
}

fn publishState(self: *Self) std.mem.Allocator.Error!void {
    const state = generating.zx.state;

    const source = if (state.generated and self.mapped.object_columns != null)
        try state.renderColumns(self.allocator, self.mapped.object_columns.?, .{}, false)
    else
        try state.renderStorage(self.allocator, self.mapped.objects);

    self.files.appendAssumeCapacity(.{ .name = "zxc_gateway_state", .source = source, .imports = self.state_imports });
}

fn publishApplication(self: *Self) std.mem.Allocator.Error!void {
    const service_files = if (self.bundle) |bundle| self.files.items[bundle.modules.len..][0..bundle.public_modules.len] else &.{};
    const imports = try imports_writer.prefixed(self.allocator, "zxc_gateway_state", "name", service_files);
    const renderer = generating.gateway.entry;

    const input: renderer.Options = .{
        .services = self.mapped.services,
        .service_modules = imports[1..],
        .routes = self.options.routes,
        .listen = self.options.listen,
        .max_header_bytes = self.options.max_header_bytes,
        .max_body_bytes = self.options.max_body_bytes,
    };

    const source = if (self.mapped.bound) |bound|
        try renderer.renderBound(self.allocator, input, bound)

    else
        try renderer.render(self.allocator, input);

    self.entry = .{ .name = "application", .imports = imports, .source = source };
}
