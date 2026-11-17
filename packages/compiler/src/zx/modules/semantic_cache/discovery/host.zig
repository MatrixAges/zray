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

        if (comptime generated) {
            if (mask != 0 or project.internal_modules.len != 0) {
                var keys: [2 * batch_size][]const u8 = undefined;
                const identities = scan(batch, mask, scoped orelse &.{}, project.internal_modules, &keys);

                for (identities) |key| try callback.loadNative(key);
            }

            offset += size;

            continue;
        }

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
    if (comptime generated) {
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        return @import("generated_semantic_cache_imports").executeValue(scratch.allocator(), paths) catch unreachable;
    }

    var mask: u64 = 0;

    for (paths, 0..) |path, index| {
        const kind = specifier.classify(path) catch continue;

        if (kind != .file and kind != .package) mask |= @as(u64, 1) << @intCast(index);
    }

    return mask;
}

const Columns = struct {
    names: zx.memory.TextColumn,
    specifiers: zx.memory.TextColumn,
    identities: zx.memory.ReadColumn,
    fn borrow(comptime field: []const u8, rows: []const interface.Native) Columns {
        const memory = zx.memory;
        const specifiers = memory.borrowTextColumn("specifier", rows);

        return .{
            .names = if (comptime std.mem.eql(u8, field, "specifier")) specifiers else memory.borrowTextColumn(field, rows),
            .specifiers = specifiers,
            .identities = memory.borrowReadColumn(?[]const u8, "identity", rows),
        };
    }
    fn view(self: *const Columns, comptime View: type) View {
        return .{
            .names = @ptrCast(&self.names),
            .length = self.names.count,
            .specifiers = @ptrCast(&self.specifiers),
            .identities = @ptrCast(&self.identities),
        };
    }
};

fn scan(paths: []const []const u8, mask: u64, scoped: []const interface.Native, internal: []const interface.Native, output: [][]const u8) []const []const u8 {
    const rule = @import("generated_semantic_cache_native_scan");
    const Input = std.meta.Child(rule.Input);
    const Registry = std.meta.Child(@FieldType(Input, "standard"));
    const standard = Columns.borrow("specifier", &interface.standard);
    const local = Columns.borrow("specifier", scoped);
    const private = Columns.borrow("module", internal);
    const standard_view = standard.view(Registry);
    const local_view = local.view(Registry);
    const private_view = private.view(Registry);

    const input: Input = .{
        .paths = paths,
        .eligible = mask,
        .standard = &standard_view,
        .scoped = &local_view,
        .internal = &private_view,
        .output = @ptrCast(&output),
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const count = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch unreachable;

    return output[0..@intCast(count)];
}
