const std = @import("std");
const ir = @import("zx").ir;

pub const Function = Columns(struct {
    *const ir.StoreTable,
    *const ir.SymbolTable,
    *const ir.ExpressionTable,
    *const ir.ControlTable,
    *const ir.ContractTable,
});

const Mode = enum { function, body, header };
const Kind = enum { words, tags, options, text };
const Counts = struct { words: usize = 0, tags: usize = 0, options: usize = 0, text: usize = 0 };

fn Columns(comptime Tables: type) type {
    const sizes = count(.function, Tables);

    return struct {
        const Self = @This();
        pub const masks = tagMasks(.function, Tables, sizes.tags);
        words: [sizes.words][]const u8,
        tags: [sizes.tags][]const u8,
        options: [sizes.options][]const ?u32,
        text: [sizes.text][]const []const u8,
        pub fn borrow(self: *Self, tables: Tables) void {
            comptime var positions: Counts = .{};

            inline for (tables) |table| {
                const Table = std.meta.Child(@TypeOf(table));

                inline for (@typeInfo(Table).@"struct".field_names) |name| {
                    if (comptime !included(.function, Table, name)) continue;

                    const field = @field(table, name);
                    const kind = comptime classify(std.meta.Elem(@TypeOf(field)));
                    const group = @tagName(kind);
                    const index = @field(positions, group);

                    @field(self, group)[index] = switch (kind) {
                        .words, .tags => std.mem.sliceAsBytes(field),
                        .options, .text => field,
                    };

                    @field(positions, group) += 1;
                }
            }
        }
        pub fn view(self: *const Self, comptime Target: type) Target {
            return .{ .words = &self.words, .tags = &self.tags, .options = &self.options, .text = &self.text };
        }
    };
}

fn count(comptime mode: Mode, comptime Tables: type) Counts {
    @setEvalBranchQuota(100_000);

    var result: Counts = .{};

    for (@typeInfo(Tables).@"struct".field_types) |Pointer| {
        const Table = std.meta.Child(Pointer);
        const fields = @typeInfo(Table).@"struct";

        for (fields.field_names, fields.field_types) |name, Slice| {
            if (!included(mode, Table, name)) continue;

            @field(result, @tagName(classify(std.meta.Elem(Slice)))) += 1;
        }
    }

    return result;
}

fn tagMasks(comptime mode: Mode, comptime Tables: type, comptime size: usize) [size]u8 {
    @setEvalBranchQuota(100_000);

    var result: [size]u8 = undefined;
    var index = 0;

    for (@typeInfo(Tables).@"struct".field_types) |Pointer| {
        const Table = std.meta.Child(Pointer);
        const fields = @typeInfo(Table).@"struct";

        for (fields.field_names, fields.field_types) |name, Slice| {
            if (!included(mode, Table, name)) continue;

            const Element = std.meta.Elem(Slice);

            if (classify(Element) != .tags) continue;

            result[index] = tagMask(Element);
            index += 1;
        }
    }

    return result;
}

pub fn referenced(comptime Target: type, comptime Table: type) *const Target {
    return view(Target, Table, .body);
}

pub fn headers(comptime Target: type) *const Target {
    return view(Target, ir.FunctionTable, .header);
}

fn view(comptime Target: type, comptime Table: type, comptime mode: Mode) *const Target {
    const Storage = std.meta.Elem(@FieldType(Target, "storage"));
    const values = comptime describe(Storage, Table, mode);

    const Static = struct {
        const layout: Target = layout: {
            var result: Target = undefined;

            for (@typeInfo(Target).@"struct".field_names) |name| {
                @field(result, name) = &@field(values, name);
            }

            break :layout result;
        };
    };

    return &Static.layout;
}

pub fn groups(comptime Target: type, comptime tables: anytype) *const Target {
    const Storage = std.meta.Elem(std.meta.Elem(@FieldType(Target, "storage")));

    const Static = struct {
        const layout: Target = layout: {
            var result: Target = undefined;

            for (@typeInfo(Target).@"struct".field_names) |name| {
                const slices = table_columns: {
                    var values: [tables.len]std.meta.Elem(@FieldType(Target, name)) = undefined;

                    for (tables, 0..) |table, index| {
                        const columns = describe(Storage, table[0], .body);

                        values[index] = &@field(columns, name);
                    }

                    break :table_columns values;
                };

                @field(result, name) = &slices;
            }

            break :layout result;
        };
    };

    return &Static.layout;
}

fn Layout(comptime Storage: type, comptime Table: type, comptime mode: Mode) type {
    const size = count(mode, struct { *const Table });
    const length = size.words + size.tags + size.options + size.text;

    return struct {
        offsets: [length]u64,
        current_offsets: [if (mode == .header) length else 0]u64,
        widths: [length]u64,
        masks: [length]u8,
        storage: [length]Storage,
    };
}

fn describe(comptime Storage: type, comptime Table: type, comptime mode: Mode) Layout(Storage, Table, mode) {
    @setEvalBranchQuota(100_000);

    var result: Layout(Storage, Table, mode) = undefined;
    const order = [_]Kind{ .words, .tags, .options, .text };
    var index: usize = 0;

    for (order) |kind| {
        for (@typeInfo(Table).@"struct".field_names) |name| {
            if (!included(mode, Table, name)) continue;

            const Element = std.meta.Elem(@FieldType(Table, name));

            if (classify(Element) != kind) continue;

            result.storage[index] = switch (kind) {
                .words => .Bytes,
                .tags => .Tags,
                .options => .OptionalIds,
                .text => .Texts,
            };

            result.offsets[index] = @offsetOf(Table, name);
            result.widths[index] = @sizeOf(Element);
            result.masks[index] = if (kind == .tags) tagMask(Element) else 0;

            if (mode == .header) result.current_offsets[index] = storageOffset(name);

            index += 1;
        }
    }

    return result;
}

pub fn offsets(comptime Target: type, comptime name: []const u8) Target {
    return .{ .earlier = @offsetOf(ir.FunctionTable, name), .current = storageOffset(name) };
}

fn storageOffset(comptime name: []const u8) usize {
    const List = @FieldType(ir.FunctionStorage, name);

    comptime std.debug.assert(std.meta.Elem(@FieldType(ir.FunctionTable, name)) == std.meta.Elem(@FieldType(List, "items")));

    return @offsetOf(ir.FunctionStorage, name) + @offsetOf(List, "items");
}

fn tagMask(comptime Element: type) u8 {
    return std.math.maxInt(@Int(.unsigned, @bitSizeOf(Element)));
}

fn included(comptime mode: Mode, comptime Table: type, comptime name: []const u8) bool {
    if (mode == .header) {
        const Element = std.meta.Elem(@FieldType(Table, name));

        if (@typeInfo(Element) == .pointer and @typeInfo(Element).pointer.size == .one) return false;

        inline for (.{ "files", "roots", "native_modules", "native_members", "native_inputs", "native_errors", "native_exports" }) |typed| {
            if (std.mem.eql(u8, name, typed)) return false;
        }

        return switch (classify(Element)) {
            .words, .tags => true,
            .options, .text => @compileError("Missing typed header comparison for " ++ name),
        };
    }

    if (Table == ir.ContractTable) return !std.mem.eql(u8, name, "symbols") and !std.mem.eql(u8, name, "expressions");
    if (mode == .function and (Table == ir.SymbolTable or Table == ir.ExpressionTable)) return !std.mem.eql(u8, name, "types");

    return true;
}

fn classify(comptime Element: type) Kind {
    return switch (Element) {
        u32, u64, f64 => .words,
        ?u32 => .options,
        []const u8 => .text,
        else => switch (@typeInfo(Element)) {
            .bool, .@"enum" => if (@sizeOf(Element) == 1 and @bitSizeOf(Element) <= 8) .tags else @compileError("Unsupported tag column layout"),
            else => @compileError("Unsupported IR column type " ++ @typeName(Element)),
        },
    };
}
