const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const Library = @import("../compiled.zig").Library;

pub fn scope(allocator: std.mem.Allocator, instance: []const u8, value: []const u8) std.mem.Allocator.Error![]const u8 {
    if (comptime generated) {
        const entry = @import("generated_compiled_scope_identity");
        const input: std.meta.Child(entry.Input) = .{ .instance = instance, .value = value };

        return zx.columns.invoke(entry.executeValue, allocator, &input) catch return error.OutOfMemory;
    }

    return std.fmt.allocPrint(allocator, "library:{d}:{s}:{s}", .{ instance.len, instance, value });
}

pub fn store(allocator: std.mem.Allocator, instance: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "$store.library:{d}:{s}:{s}", .{ instance.len, instance, path["$store.".len..] });
}

pub fn nativeKey(allocator: std.mem.Allocator, library: Library, key: []const u8) std.mem.Allocator.Error![]const u8 {
    for (0..library.program.native_modules.count()) |module_row| {
        const module = library.program.native_modules.at(module_row);

        if (std.mem.eql(u8, module.key(), key) and std.mem.startsWith(u8, module.specifier, "std:")) return key;
    }

    return scope(allocator, library.instance, key);
}

pub fn nativeName(allocator: std.mem.Allocator, instance: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    const key = try scope(allocator, instance, name);

    defer allocator.free(key);

    var digest: [32]u8 = undefined;

    zx.Sha256.hash(key, &digest, .{});

    const prefix = if (generated) @import("generated_compiled_identity_constants").@"zx.constants".library_native_prefix else "library_native_";
    const encoded = std.fmt.bytesToHex(digest, .lower);

    return std.mem.concat(allocator, u8, &.{ prefix, &encoded });
}
