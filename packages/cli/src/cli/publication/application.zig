const std = @import("std");
const watch = @import("watch_inputs");
const output = @import("../watch/output.zig");
const effects = @import("effects.zig");
const Self = @This();

io: std.Io,
allocator: std.mem.Allocator,
failure: *effects.Failure,
inputs: ?*const watch.Inputs = null,
binary: Artifact,
assembly: Artifact,

bindings: ?Bindings = null,
checked_binary: ?[:0]u8 = null,
checked_assembly: ?[:0]u8 = null,
pub const Artifact = struct { source: ?[]const u8, destination: ?[]const u8 };

pub fn deinit(self: *Self) void {
    if (self.checked_assembly) |path| self.allocator.free(path);
    if (self.checked_binary) |path| self.allocator.free(path);
}

pub fn copyAssembly(handle: *anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);

    return self.copy(self.assembly);
}

pub fn copyBinary(handle: *anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);

    return self.copy(self.binary);
}

fn copy(self: *Self, item: Artifact) effects.Error!void {
    std.Io.Dir.cwd().copyFile(item.source.?, .cwd(), item.destination.?, self.io, .{ .make_path = true }) catch |err| return self.failure.save(err);
}

pub fn checkBinary(handle: *anyopaque) effects.Error![]const u8 {
    const self = effects.borrow(Self, handle);
    const path = output.check(self.io, self.allocator, self.inputs.?, self.binary.destination.?) catch |err| return self.failure.save(err);

    self.checked_binary = path;

    return path;
}

pub fn checkAssembly(handle: *anyopaque) effects.Error![]const u8 {
    const self = effects.borrow(Self, handle);
    const path = output.check(self.io, self.allocator, self.inputs.?, self.assembly.destination.?) catch |err| return self.failure.save(err);

    self.checked_assembly = path;

    return path;
}

pub fn checkBindings(handle: *anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);
    const files = self.bindings.?;

    files.check(self.io, self.allocator, self.assembly.destination) catch |err| return self.failure.save(err);

    for ([_][]const u8{ files.module_path, files.declaration_path }) |path| {
        const checked = output.check(self.io, self.allocator, self.inputs.?, path) catch |err| return self.failure.save(err);

        self.allocator.free(checked);
    }
}

pub fn writeBindings(handle: *anyopaque) effects.Error!void {
    const self = effects.borrow(Self, handle);

    self.bindings.?.publish(self.io) catch |err| return self.failure.save(err);
}

pub const Bindings = @import("bindings.zig");
