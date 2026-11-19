const std = @import("std");
const zx = @import("zx");
const identity = @import("../identity.zig");
const interface = @import("../../interface.zig");
const Modules = zx.ir.NativeModuleTable;
const generated = @import("parser_options").generated_parser;

const Origin = union(enum) {
    compiled: struct { modules: Modules, instance: []const u8 },
    source: struct { interfaces: []const interface.Native, externals: []const interface.External },
};

pub fn resolve(allocator: std.mem.Allocator, modules: Modules, instance: []const u8, comptime Alias: type, configured: ?[]const Alias) identity.DeclarationError![]const Alias {
    if (comptime !generated) return @import("aliases/seed.zig").resolve(allocator, modules, instance, Alias, configured);

    return publish(allocator, Alias, configured, .{ .compiled = .{ .modules = modules, .instance = instance } });
}

pub fn source(allocator: std.mem.Allocator, interfaces: []const interface.Native, externals: []const interface.External, comptime Alias: type, configured: ?[]const Alias) identity.DeclarationError![]const Alias {
    if (comptime !generated) return @import("aliases/source/seed.zig").resolve(allocator, interfaces, externals, Alias, configured);

    return publish(allocator, Alias, configured, .{ .source = .{ .interfaces = interfaces, .externals = externals } });
}

fn publish(allocator: std.mem.Allocator, comptime Alias: type, configured: ?[]const Alias, origin: Origin) identity.DeclarationError![]const Alias {
    const layout = @import("aliases/view.zig");
    const View = layout.View(Alias);
    var storage: View = undefined;

    storage.init(configured);

    var compiled: layout.Compiled = undefined;
    var modules: layout.Modules = undefined;
    var declarations: layout.Declarations = undefined;
    var interfaces: layout.Rows = undefined;
    var externals: layout.Rows = undefined;

    switch (origin) {
        .compiled => |raw| {
            modules = zx.columns.columns(layout.Modules, raw.modules);
            compiled = .{ .modules = &modules, .instance = raw.instance };
        },
        .source => |raw| {
            interfaces.init(raw.interfaces);
            externals.init(raw.externals);

            declarations = .{ .interfaces = &interfaces.view, .externals = &externals.view };
        },
    }

    const input: layout.Input = .{
        .compiled = if (origin == .compiled) &compiled else null,
        .source = if (origin == .source) &declarations else null,
        .configured = if (configured != null) &storage.configured else null,
        .output = &storage.output,
    };

    errdefer storage.release(allocator, origin == .compiled, configured == null);

    const status = zx.columns.invoke(layout.rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    switch (status) {
        .Done => return storage.take(allocator),
        .Conflict => return error.ConflictingNativeAbiAlias,
        .Unknown => return error.UnknownNativeAbiAlias,
        .Ready => unreachable,
    }
}
