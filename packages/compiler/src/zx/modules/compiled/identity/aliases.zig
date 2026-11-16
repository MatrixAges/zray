const std = @import("std");
const zx = @import("zx");
const memory = @import("zxc_standard").memory;
const identity = @import("../identity.zig");
const Modules = zx.ir.NativeModuleTable;

pub fn resolve(allocator: std.mem.Allocator, modules: Modules, instance: []const u8, comptime Alias: type, configured: ?[]const Alias) identity.DeclarationError![]const Alias {
    var aliases: std.ArrayList(Alias) = .empty;

    errdefer {
        for (aliases.items) |alias| {
            if (configured == null) allocator.free(alias.name);

            allocator.free(alias.specifier);
        }

        aliases.deinit(allocator);
    }

    if (comptime @import("parser_options").generated_parser) {
        const generated = @import("generated_compiled_native_alias_step");
        const Input = std.meta.Child(generated.Input);
        const Configured = std.meta.Child(@typeInfo(@FieldType(Input, "configured")).optional.child);
        const view = zx.columns.columns(std.meta.Child(@FieldType(Input, "modules")), modules);
        var names: memory.TextColumn = undefined;
        var requests: memory.TextColumn = undefined;
        var choices: Configured = undefined;

        if (configured) |rows| {
            names = memory.borrowTextColumn("name", rows);
            requests = memory.borrowTextColumn("specifier", rows);
            choices = .{ .names = @ptrCast(&names), .requests = @ptrCast(&requests), .count = rows.len };
        }

        var cursor: Input = .{ .modules = &view, .configured = if (configured != null) &choices else null, .row = 0 };
        var scratch = std.heap.FixedBufferAllocator.init(&.{});

        while (true) {
            const next = zx.columns.invoke(generated.executeValue, scratch.allocator(), @as(*const Input, &cursor)) catch unreachable;

            switch (next.status) {
                .Done => break,
                .Conflict => return error.ConflictingNativeAbiAlias,
                .Unknown => return error.UnknownNativeAbiAlias,
                .Ready => {
                    const target = try identity.ownDeclaration(allocator, instance, next.identity.?, next.shared);

                    errdefer allocator.free(target);

                    try append(allocator, &aliases, next.name.?, target, configured == null);

                    cursor.row = next.next;
                },
            }
        }
    } else if (configured) |entries| {
        for (entries) |entry| {
            const target = try identity.declaration(allocator, modules, instance, entry.specifier);

            errdefer allocator.free(target);

            try append(allocator, &aliases, entry.name, target, false);
        }
    } else {
        for (0..modules.count()) |row| {
            const module = modules.at(row);

            if (std.mem.startsWith(u8, module.specifier, "std:")) continue;

            for (aliases.items) |previous| {
                if (zx.bytes.equal(previous.name, module.specifier)) return error.ConflictingNativeAbiAlias;
            }

            const target = try identity.declaration(allocator, modules, instance, module.key());

            errdefer allocator.free(target);

            try append(allocator, &aliases, module.specifier, target, true);
        }
    }

    return aliases.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, aliases: anytype, name: []const u8, target: []const u8, own_name: bool) std.mem.Allocator.Error!void {
    try aliases.ensureUnusedCapacity(allocator, 1);

    const stable = if (own_name) try allocator.dupe(u8, name) else name;

    aliases.appendAssumeCapacity(.{ .name = stable, .specifier = target });
}
