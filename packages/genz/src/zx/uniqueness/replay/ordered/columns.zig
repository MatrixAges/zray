const std = @import("std");
const memory = @import("zx").memory;
const Level = @import("../../level.zig").Level;
const Normalized = @import("../../growth.zig").Normalized;

pub const Settled = struct {
    callees: memory.ListColumn,
    levels: memory.ListColumn,
    output: memory.ListColumn,
    pub fn init(comptime prefix: []const []const u8, rows: anytype) Settled {
        const passed = prefix ++ [_][]const u8{"passed"};

        return .{
            .callees = memory.borrowListPath(u32, passed, &.{"callee"}, rows),
            .levels = memory.borrowListPath([]const Level, passed, &.{"levels"}, rows),
            .output = memory.borrowSliceColumn(prefix ++ [_][]const u8{"output"}, rows),
        };
    }

    pub fn view(self: *const Settled, comptime View: type) View {
        return .{ .callees = @ptrCast(&self.callees), .levels = @ptrCast(&self.levels), .output = @ptrCast(&self.output) };
    }
};

pub const Demanded = struct {
    marks: Marks,
    normalized: Growth,
    renewed: Growth,
    grew: memory.ReadColumn,
    pub fn init(comptime prefix: []const []const u8, rows: anytype) Demanded {
        const marks = prefix ++ [_][]const u8{"marks"};

        return .{
            .marks = .{
                .output = memory.borrowListPath(bool, marks, &.{"output"}, rows),
                .functions = memory.borrowListPath(u32, marks, &.{"function"}, rows),
                .slots = memory.borrowListPath(u32, marks, &.{"slot"}, rows),
                .wants = memory.borrowListPath(Level, marks, &.{"want"}, rows),
            },
            .normalized = Growth.init(@FieldType(Normalized, "id"), "id", prefix ++ [_][]const u8{"normalized"}, rows),
            .renewed = Growth.init(u64, "key", prefix ++ [_][]const u8{"renewed"}, rows),
            .grew = memory.borrowNestedColumn(bool, prefix ++ [_][]const u8{"grew"}, rows),
        };
    }
    pub fn Binding(comptime View: type) type {
        return struct {
            marks: std.meta.Child(@FieldType(View, "marks")),
            normalized: std.meta.Child(@FieldType(View, "normalized")),
            renewed: std.meta.Child(@FieldType(View, "renewed")),
            pub fn init(self: *@This(), source: *const Demanded) View {
                self.marks = .{
                    .output = @ptrCast(&source.marks.output),
                    .functions = @ptrCast(&source.marks.functions),
                    .slots = @ptrCast(&source.marks.slots),
                    .wants = @ptrCast(&source.marks.wants),
                };

                self.normalized = source.normalized.view(@FieldType(@This(), "normalized"), false);
                self.renewed = source.renewed.view(@FieldType(@This(), "renewed"), true);

                return .{
                    .marks = &self.marks,
                    .normalized = &self.normalized,
                    .renewed = &self.renewed,
                    .grew = @ptrCast(&source.grew),
                };
            }
        };
    }
};

const Marks = struct {
    output: memory.ListColumn,
    functions: memory.ListColumn,
    slots: memory.ListColumn,
    wants: memory.ListColumn,
};

const Growth = struct {
    keys: memory.ListColumn,
    wants: memory.ListColumn,
    fn init(comptime Key: type, comptime member: []const u8, comptime path: []const []const u8, rows: anytype) Growth {
        return .{
            .keys = memory.borrowListPath(Key, path, &.{member}, rows),
            .wants = memory.borrowListPath(Level, path, &.{"want"}, rows),
        };
    }

    fn view(self: *const Growth, comptime View: type, wide: bool) View {
        return .{ .keys = @ptrCast(&self.keys), .wants = @ptrCast(&self.wants), .wide = wide };
    }
};
