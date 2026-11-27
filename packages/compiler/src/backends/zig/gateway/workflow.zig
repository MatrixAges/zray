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
    const entrypoint = @import("generated_gateway_bundle");

    const input: std.meta.Child(entrypoint.Input) = .{
        .has_library = bundle != null,
        .modules = if (bundle) |value| value.modules.len else 0,
        .public_modules = if (bundle) |value| value.public_modules.len else 0,
    };

    var scratch = std.heap.ArenaAllocator.init(self.allocator);

    defer scratch.deinit();

    const plan = @import("zx").columns.invoke(entrypoint.executeValue, scratch.allocator(), &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };

    for (plan.steps) |step| switch (step) {
        .BindState => self.mapped = try State.create(self.allocator, self.library.?, bundle.?.*),
        .ReserveFiles => try self.reserveFiles(plan.capacity),
        .AppendModules => self.files.appendSliceAssumeCapacity(bundle.?.modules),
        .AppendFacades => for (bundle.?.public_modules) |module| self.files.appendAssumeCapacity(module.file),
        .PublishContract => try self.publishContract(),
        .PublishState => try self.publishState(),
        .PublishApplication => try self.publishApplication(),
    };
}

fn reserveFiles(self: *Self, count: u64) std.mem.Allocator.Error!void {
    const capacity = std.math.cast(usize, count) orelse return error.OutOfMemory;

    try self.files.ensureTotalCapacityPrecise(self.allocator, capacity);
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
