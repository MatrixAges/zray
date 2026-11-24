const std = @import("std");
const zx = @import("zx");
const identity = @import("../identity.zig");
const interface = @import("../../interface.zig");
const Modules = zx.ir.NativeModuleTable;
const generated = @import("parser_options").generated_parser;
const layout = @import("aliases/view.zig");

pub fn resolve(allocator: std.mem.Allocator, modules: Modules, instance: []const u8, comptime Alias: type, configured: ?[]const Alias) identity.DeclarationError![]const Alias {
    if (comptime !generated) return @import("aliases/seed.zig").resolve(allocator, modules, instance, Alias, configured);

    const rows = zx.columns.columns(layout.Modules, modules);
    const library: layout.Compiled = .{ .modules = &rows, .instance = instance };

    return publish(allocator, Alias, configured, &library, null);
}

pub fn source(allocator: std.mem.Allocator, interfaces: []const interface.Native, externals: []const interface.External, comptime Alias: type, configured: ?[]const Alias) identity.DeclarationError![]const Alias {
    if (comptime !generated) return @import("aliases/source/seed.zig").resolve(allocator, interfaces, externals, Alias, configured);

    var native: layout.Rows = undefined;
    var external: layout.Rows = undefined;

    native.init(interfaces);
    external.init(externals);

    const declarations: layout.Declarations = .{ .interfaces = &native.view, .externals = &external.view };

    return publish(allocator, Alias, configured, null, &declarations);
}

fn publish(allocator: std.mem.Allocator, comptime Alias: type, configured: ?[]const Alias, compiled: ?*const layout.Compiled, declarations: ?*const layout.Declarations) identity.DeclarationError![]const Alias {
    var storage: layout.View(Alias) = undefined;

    storage.init(configured);

    const input: layout.Input = .{
        .compiled = compiled,
        .source = declarations,
        .configured = if (configured != null) &storage.configured else null,
        .output = &storage.output,
    };

    errdefer {
        const cleanup = @import("generated_native_abi_aliases_release");
        const request: std.meta.Child(cleanup.Input) = .{ .request = &input, .owner = @ptrCast(&allocator) };
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        cleanup.executeIn(scratch.allocator(), &request) catch unreachable;
        allocator.free(storage.rows.rows());
    }

    const status = zx.columns.invoke(layout.rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };

    switch (status) {
        .Done => return storage.rows.rows(),
        .Conflict => return error.ConflictingNativeAbiAlias,
        .Unknown => return error.UnknownNativeAbiAlias,
        .Ready => unreachable,
    }
}
