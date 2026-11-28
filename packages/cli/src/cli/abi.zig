const std = @import("std");
const compiler = @import("compiler");
const input = @import("abi/input.zig");
const view = compiler.zig.abi_view;
const Loaded = @import("project.zig").Loaded;
const rule = @import("cli_source").render_bundle_abi;
const host = @import("cli_abi").native.@"zig:bundle_abi_host";
pub const File = struct { module: []const u8, name: []const u8, path: []const u8, source: []const u8 };
pub const Result = struct { source: []const u8, views: []const File = &.{} };

pub fn create(allocator: std.mem.Allocator, bundle: anytype, loaded: *const Loaded) !Result {
    var borrowed: input.Borrowed = undefined;
    const plan = borrowed.init(bundle.native_modules, bundle.modules, loaded);

    const rendered = rule.executeIn(allocator, &.{
        .names = bundle.type_names,
        .source = bundle.types,
        .identities = bundle.native_modules.identities,
        .plan = &plan,
    }) catch |err| return switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };

    switch (rendered.status) {
        .Valid => {},
        .ConflictingAlias => return error.ConflictingNativeAbiAlias,
        .NameConflict => return error.NativeModuleNameConflict,
    }

    const views = try allocator.alloc(File, rendered.views.len);

    for (rendered.views, views) |item, *slot| {
        slot.* = .{
            .module = item.module,
            .name = item.name,
            .path = item.path,
            .source = item.source,
        };
    }

    return .{ .source = rendered.source, .views = views };
}

pub fn renderAbiFile(allocator: std.mem.Allocator, names: []const []const u8, aliases: []const host.AbiAlias) std.mem.Allocator.Error![]const u8 {
    return view.renderBorrowed(allocator, names, aliases, true);
}

pub fn renderAbiRoot(allocator: std.mem.Allocator, canonical: []const u8, aliases: []const host.AbiAlias) std.mem.Allocator.Error![]const u8 {
    return view.renderRootBorrowed(allocator, canonical, aliases);
}
