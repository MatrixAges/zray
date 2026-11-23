const std = @import("std");
const zx = @import("zx");
const interface = @import("../../interface.zig");
const scopes = @import("../../package_scope.zig");
const Options = @import("../../project.zig").Options;
const registry = @import("../../project/target/registry.zig");
const specifier = @import("../../specifier.zig");
const batch_size = scopes.lookup_batch_size;
const generated = @import("parser_options").generated_parser;

pub fn prefetch(header: anytype, path: []const u8, project: *const Options, callback: anytype) !void {
    comptime std.debug.assert(batch_size <= @bitSizeOf(u64));

    const Header = @TypeOf(header);
    const indexed_header = @hasField(Header, "storage");

    if (comptime !generated or (!indexed_header and Header != zx.syntax.header.Native)) {
        return prefetchSeed(header, path, project, callback);
    }

    const total = header.importCount();

    if (total == 0) return;

    const rule = @import("generated_semantic_cache_discovery");
    const Input = std.meta.Child(rule.Input);
    const Batch = std.meta.Child(@FieldType(Input, "batch"));
    const Paths = std.meta.Child(@FieldType(Batch, "paths"));
    const Registry = std.meta.Child(@FieldType(Input, "standard"));
    const Indexed = std.meta.Child(@typeInfo(@FieldType(Paths, "indexed")).optional.child);
    const native = if (!indexed_header) zx.memory.borrowTextColumn("path", header.program.imports) else undefined;
    const indexed: Indexed = if (indexed_header) .{ .source = header.source, .imports = zx.columns.slice(@FieldType(Indexed, "imports"), header.storage.imports) } else undefined;
    const paths: Paths = .{ .indexed = if (indexed_header) &indexed else null, .native = if (indexed_header) null else @ptrCast(&native) };
    const standard = columns("specifier", &interface.standard);
    const internal = columns("module", project.internal_modules);
    var scope: @TypeOf(standard) = undefined;
    var scope_view: Registry = undefined;
    var keys: [2 * batch_size][]const u8 = undefined;
    const output: [][]const u8 = &keys;
    var batch: Batch = .{ .paths = &paths, .first = 0, .count = 0 };

    var request: Input = .{
        .batch = &batch,
        .eligible = null,
        .standard = &registryView(Registry, &standard),
        .scoped = null,
        .internal = &registryView(Registry, &internal),
        .output = @ptrCast(&output),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    while (batch.first < total) {
        batch.count = @min(batch_size, total - batch.first);
        const scanned = zx.columns.invoke(rule.executeValue, scratch.allocator(), @as(*const Input, &request)) catch unreachable;

        const count = if (scanned.needs_scope) |mask| resolved: {
            const interfaces = scopes.nativeInterfaces(project.package_scopes, path, project.native_interfaces);

            scope = columns("specifier", interfaces);
            scope_view = registryView(Registry, &scope);
            request.scoped = &scope_view;
            request.eligible = mask;

            const resumed = zx.columns.invoke(rule.executeValue, scratch.allocator(), @as(*const Input, &request)) catch unreachable;

            request.eligible = null;

            break :resolved resumed.count;
        } else scanned.count;

        for (keys[0..@intCast(count)]) |key| try callback.loadNative(key);

        batch.first += batch.count;
    }
}

fn prefetchSeed(header: anytype, path: []const u8, project: *const Options, callback: anytype) !void {
    var paths: [batch_size][]const u8 = undefined;
    var offset: usize = 0;
    var scoped: ?[]const interface.Native = null;
    const count = header.importCount();

    while (offset < count) {
        const size = @min(paths.len, count - offset);
        const batch = paths[0..size];

        for (batch, offset..) |*specifier_path, index| specifier_path.* = header.importAt(index).path;

        const mask = eligible(batch);

        if (mask != 0 and scoped == null) scoped = scopes.nativeInterfaces(project.package_scopes, path, project.native_interfaces);

        var remaining = mask;

        while (remaining != 0) {
            const index = @ctz(remaining);

            remaining &= remaining - 1;

            switch (registry.native(scoped.?, batch[index], false)) {
                .found => |entry| try callback.loadNative(entry.key()),
                .missing => {},
                .duplicate => unreachable,
            }
        }

        if (project.internal_modules.len != 0) {
            for (batch) |name| {
                if (project.internalModule(name)) |entry| try callback.loadNative(entry.key());
            }
        }

        offset += size;
    }
}

fn eligible(paths: []const []const u8) u64 {
    var mask: u64 = 0;

    for (paths, 0..) |path, index| {
        const kind = specifier.classify(path) catch continue;

        if (kind != .file and kind != .package) mask |= @as(u64, 1) << @intCast(index);
    }

    return mask;
}

inline fn columns(comptime field: []const u8, rows: []const interface.Native) @TypeOf(zx.memory.borrowReadFields(.{ .names = field, .specifiers = "specifier", .identities = "identity" }, rows)) {
    return zx.memory.borrowReadFields(.{ .names = field, .specifiers = "specifier", .identities = "identity" }, rows);
}

inline fn registryView(comptime Registry: type, views: anytype) Registry {
    var result: Registry = undefined;

    views.fill(&result);

    result.length = views.count;

    return result;
}
