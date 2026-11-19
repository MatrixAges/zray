const std = @import("std");
const ir = @import("zx").ir;

pub const Function = Columns(.function, struct {
    *const ir.StoreTable,
    *const ir.SymbolTable,
    *const ir.ExpressionTable,
    *const ir.ControlTable,
    *const ir.ContractTable,
});

pub const Header = Columns(.header, struct { *const ir.FunctionTable });
const Mode = enum { function, body, header };
const Kind = enum { words, tags, options, text };
const Counts = struct { words: usize = 0, tags: usize = 0, options: usize = 0, text: usize = 0 };

fn Columns(comptime mode: Mode, comptime Tables: type) type {
    const sizes = count(mode, Tables);

    return struct {
        const Self = @This();
        pub const masks = tagMasks(mode, Tables, sizes.tags);
        words: [sizes.words][]const u8,
        tags: [sizes.tags][]const u8,
        options: [sizes.options][]const ?u32,
        text: [sizes.text][]const []const u8,
        pub fn borrow(self: *Self, tables: Tables) void {
            self.borrowRange(tables, 0, null);
        }
        pub fn borrowRange(self: *Self, tables: Tables, start: usize, end: ?usize) void {
            comptime var offsets: Counts = .{};

            inline for (tables) |table| {
                const Table = std.meta.Child(@TypeOf(table));

                inline for (@typeInfo(Table).@"struct".field_names) |name| {
                    if (comptime !included(mode, Table, name)) continue;

                    const column = @field(table, name);
                    const field = column[start .. end orelse column.len];
                    const kind = comptime classify(std.meta.Elem(@TypeOf(field)));
                    const group = @tagName(kind);
                    const index = @field(offsets, group);

                    @field(self, group)[index] = switch (kind) {
                        .words, .tags => std.mem.sliceAsBytes(field),
                        .options, .text => field,
                    };

                    @field(offsets, group) += 1;
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

pub fn referenced(comptime Spec: type, comptime Table: type) []const *const Spec {
    @setEvalBranchQuota(100_000);

    const descriptors = comptime rows(Spec, Table);

    const pointers = comptime blk: {
        var result: [descriptors.len]*const Spec = undefined;

        for (&result, &descriptors) |*slot, *column| slot.* = column;

        break :blk result;
    };

    return &pointers;
}

fn rows(comptime Spec: type, comptime Table: type) [rowCount(Table)]Spec {
    var result: [rowCount(Table)]Spec = undefined;
    const order = [_]Kind{ .words, .tags, .options, .text };
    var index: usize = 0;

    for (order) |kind| {
        for (@typeInfo(Table).@"struct".field_names) |name| {
            if (!included(.body, Table, name)) continue;

            const Element = std.meta.Elem(@FieldType(Table, name));

            if (classify(Element) != kind) continue;

            result[index] = .{
                .storage = switch (kind) {
                    .words => .Bytes,
                    .tags => .Tags,
                    .options => .OptionalIds,
                    .text => .Texts,
                },
                .offset = @offsetOf(Table, name),
                .width = @sizeOf(Element),
                .mask = if (kind == .tags) tagMask(Element) else 0,
            };

            index += 1;
        }
    }

    return result;
}

fn rowCount(comptime Table: type) usize {
    const size = count(.body, struct { *const Table });

    return size.words + size.tags + size.options + size.text;
}

fn tagMask(comptime Element: type) u8 {
    return std.math.maxInt(@Int(.unsigned, @bitSizeOf(Element)));
}

fn included(comptime mode: Mode, comptime Table: type, comptime name: []const u8) bool {
    if (mode == .header) {
        const Element = std.meta.Elem(@FieldType(Table, name));

        if (@typeInfo(Element) == .pointer and @typeInfo(Element).pointer.size == .one) return false;

        return !std.mem.eql(u8, name, "native_members") and !std.mem.eql(u8, name, "native_inputs") and !std.mem.eql(u8, name, "native_errors") and !std.mem.eql(u8, name, "native_exports");
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
