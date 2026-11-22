const std = @import("std");
const generating = @import("genz");
const Library = @import("../../../library/root.zig").Result;
const Bundle = @import("../library.zig").Bundle;
const File = @import("../modules.zig").File;
const State = @import("state.zig");
const prefixed = @import("imports.zig").prefixed;
const generated = @import("parser_options").generated_parser;
const Self = @This();
pub const Options = struct { routes: []const generating.gateway.Route, listen: []const u8, max_header_bytes: u32, max_body_bytes: u32 };

allocator: std.mem.Allocator,
options: Options,
library: ?*const Library = null,
bundle: ?*const Bundle = null,
mapped: State.Result = .{ .objects = &.{} },
files: std.ArrayList(File) = .empty,
state_imports: []const []const u8 = undefined,

entry: File = undefined,
pub fn build(self: *Self) !void {
    const bundle = self.bundle;
    const modules = if (bundle) |value| value.modules.len else 0;
    const facades = if (bundle) |value| value.public_modules.len else 0;

    if (!generated) {
        if (bundle != null) try self.bindState();

        const count = std.math.add(usize, modules, facades) catch return error.OutOfMemory;
        const capacity = std.math.add(usize, count, 2) catch return error.OutOfMemory;

        try self.files.ensureTotalCapacityPrecise(self.allocator, capacity);

        if (bundle) |value| {
            self.files.appendSliceAssumeCapacity(value.modules);

            for (value.public_modules) |*facade| self.files.appendAssumeCapacity(facade.file);
        }

        try self.publishContract();
        try self.publishState();
        try self.publishApplication();

        return;
    }

    const entrypoint = @import("generated_gateway_bundle");

    const input: std.meta.Child(entrypoint.Input) = .{
        .frame = @ptrCast(self),
        .has_library = bundle != null,
        .modules = modules,
        .public_modules = facades,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    entrypoint.executeIn(fixed.allocator(), &input) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => err,
    };
}

fn borrow(handle: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn bindState(self: *Self) State.Error!void {
    self.mapped = try State.create(self.allocator, self.library.?, self.bundle.?.*);
}

pub fn bindGatewayState(handle: *const anyopaque) State.Error!void {
    return borrow(handle).bindState();
}

pub fn reserveGatewayFiles(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const self = borrow(handle);
    const capacity = std.math.cast(usize, count) orelse return error.OutOfMemory;

    try self.files.ensureTotalCapacityPrecise(self.allocator, capacity);
}

pub fn appendGatewayModules(handle: *const anyopaque) void {
    const self = borrow(handle);

    self.files.appendSliceAssumeCapacity(self.bundle.?.modules);
}

pub fn appendGatewayFacade(handle: *const anyopaque, index: u64) void {
    const self = borrow(handle);

    self.files.appendAssumeCapacity(self.bundle.?.public_modules[@intCast(index)].file);
}

fn publishContract(self: *Self) std.mem.Allocator.Error!void {
    const state_imports = try prefixed(self.allocator, "application=gateway_storage_contract", "module_name", self.mapped.objects);
    const initial_imports = state_imports[1..];
    const source = try generating.gateway.storage.render(self.allocator, initial_imports);

    self.state_imports = state_imports;

    self.files.appendAssumeCapacity(.{ .name = "gateway_storage_contract", .source = source, .imports = initial_imports });
}

pub fn publishGatewayContract(handle: *const anyopaque) std.mem.Allocator.Error!void {
    return borrow(handle).publishContract();
}

fn publishState(self: *Self) std.mem.Allocator.Error!void {
    const source = try generating.zx.state.renderStorage(self.allocator, self.mapped.objects);

    self.files.appendAssumeCapacity(.{ .name = "zxc_gateway_state", .source = source, .imports = self.state_imports });
}

pub fn publishGatewayState(handle: *const anyopaque) std.mem.Allocator.Error!void {
    return borrow(handle).publishState();
}

fn publishApplication(self: *Self) std.mem.Allocator.Error!void {
    const service_files = if (self.bundle) |bundle| self.files.items[bundle.modules.len..][0..bundle.public_modules.len] else &.{};
    const imports = try prefixed(self.allocator, "zxc_gateway_state", "name", service_files);
    const renderer = generating.gateway.entry;

    const input: renderer.Options = .{
        .services = self.mapped.services,
        .service_modules = imports[1..],
        .routes = self.options.routes,
        .listen = self.options.listen,
        .max_header_bytes = self.options.max_header_bytes,
        .max_body_bytes = self.options.max_body_bytes,
    };

    const source = if (!generated)
        try renderer.render(self.allocator, input)

    else if (self.mapped.bound) |bound|
        try renderer.renderBound(self.allocator, input, bound)
    else
        try renderer.render(self.allocator, input);

    self.entry = .{ .name = "application", .imports = imports, .source = source };
}

pub fn publishGatewayApplication(handle: *const anyopaque) std.mem.Allocator.Error!void {
    return borrow(handle).publishApplication();
}
