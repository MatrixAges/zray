const std = @import("std");
const ir = @import("zx").ir;
const Names = @import("genz").zx.modules.Names;
const Cache = @import("../cache.zig");
const Identity = @import("identity.zig");
const modules = @import("../modules.zig");

file: modules.File,
entry: modules.StoreInitializer,
pub fn emit(output: std.mem.Allocator, backing: std.mem.Allocator, identity: []const u8, version: u32, program: *const ir.Program, names: Names, cache: ?*Cache) modules.Error!@This() {
    return emitPrepared(output, backing, try Identity.create(output, .Store, identity), version, program, names, cache);
}

pub fn emitPrepared(output: std.mem.Allocator, backing: std.mem.Allocator, published: Identity, version: u32, program: *const ir.Program, names: Names, cache: ?*Cache) modules.Error!@This() {
    var view = program.*;
    view.file_name = published.module;
    const source = try modules.emitBacked(output, backing, view, names, .entry, cache);

    return .{
        .file = .{ .name = published.module, .source = source, .imports = &.{} },
        .entry = .{ .identity = published.identity, .schema_version = version, .module_name = published.module, .type_name = names.types[@backingInt(view.output_type)] },
    };
}
