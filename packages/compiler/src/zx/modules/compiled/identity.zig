const std = @import("std");
const zx = @import("zx");
const generated = @import("parser_options").generated_parser;
const Library = @import("../compiled.zig").Library;
pub const DeclarationError = std.mem.Allocator.Error || error{ ConflictingNativeAbiAlias, UnknownNativeAbiAlias };
pub const aliases = @import("identity/aliases.zig").resolve;
pub const sourceAliases = @import("identity/aliases.zig").source;

pub fn scope(allocator: std.mem.Allocator, instance: []const u8, value: []const u8) std.mem.Allocator.Error![]const u8 {
    if (comptime generated) {
        const entry = @import("generated_compiled_scope_identity");
        const input: std.meta.Child(entry.Input) = .{ .instance = instance, .value = value };

        return zx.columns.invoke(entry.executeValue, allocator, &input) catch return error.OutOfMemory;
    }

    return std.fmt.allocPrint(allocator, "library:{d}:{s}:{s}", .{ instance.len, instance, value });
}

pub fn declaration(allocator: std.mem.Allocator, modules: zx.ir.NativeModuleTable, instance: []const u8, requested: []const u8) DeclarationError![]const u8 {
    if (comptime generated) {
        const entry = @import("generated_compiled_native_declaration");
        const Input = std.meta.Child(entry.Input);
        const view = zx.columns.columns(std.meta.Child(@FieldType(Input, "modules")), modules);
        const input: Input = .{ .modules = &view, .requested = requested };
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const selected = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        if (selected.conflict) return error.ConflictingNativeAbiAlias;

        const identity = selected.identity orelse return error.UnknownNativeAbiAlias;

        return ownDeclaration(allocator, instance, identity, selected.shared);
    }

    return seedDeclaration(allocator, modules, instance, requested);
}

fn seedDeclaration(allocator: std.mem.Allocator, modules: zx.ir.NativeModuleTable, instance: []const u8, requested: []const u8) DeclarationError![]const u8 {
    var identity: ?[]const u8 = null;
    var shared = false;

    for (0..modules.count()) |row| {
        const module = modules.at(row);
        const key = module.key();

        if (!zx.bytes.equal(module.specifier, requested) and !zx.bytes.equal(key, requested)) continue;
        if (identity) |previous| if (!zx.bytes.equal(previous, key)) return error.ConflictingNativeAbiAlias;

        identity = key;
        shared = std.mem.startsWith(u8, module.specifier, "std:");
    }

    const original = identity orelse return error.UnknownNativeAbiAlias;

    return ownDeclaration(allocator, instance, original, shared);
}

pub fn ownDeclaration(allocator: std.mem.Allocator, instance: []const u8, identity: []const u8, shared: bool) std.mem.Allocator.Error![]const u8 {
    return if (shared) allocator.dupe(u8, identity) else scope(allocator, instance, identity);
}

pub fn store(allocator: std.mem.Allocator, instance: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "store.library:{d}:{s}:{s}", .{ instance.len, instance, path["store.".len..] });
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
