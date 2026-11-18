const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const generated = @import("rx_options").generated_graph;
const Signature = @FieldType(frontend.project.signature_project.Module, "signature");
const Members = @FieldType(Signature, "members");

pub const MemberColumns = struct {
    names: zx.memory.ListColumn,
    ids: zx.memory.ListColumn,
    pub fn borrow(comptime path: []const []const u8, records: anytype) MemberColumns {
        return .{
            .names = zx.memory.borrowListPath([]const u8, path, &.{"name"}, records),
            .ids = zx.memory.borrowListPath(?u32, path, &.{"id"}, records),
        };
    }

    pub fn view(self: *const MemberColumns, comptime View: type) View {
        return .{ .names = @ptrCast(&self.names), .ids = @ptrCast(&self.ids) };
    }
};

const Selection = if (generated) @typeInfo(@TypeOf(@import("generated_rx_named_signature").executeValue(undefined, undefined))).error_union.payload else struct { row: ?u64, has_store: bool };

pub fn signature(members: Members, name: []const u8) Selection {
    if (comptime generated) {
        const Member = std.meta.Elem(Members);
        const names = zx.memory.borrowTextColumn("name", members);
        const kinds = zx.memory.borrowReadColumn(Member.Kind, "kind", members);
        const stores = zx.memory.borrowReadColumn(bool, "has_store", members);
        const entry = @import("generated_rx_named_signature");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(entry.Input) = .{
            .names = &.{ .rows = @ptrCast(&names), .length = members.len, .default_name = null },
            .name = name,
            .kinds = @ptrCast(&kinds),
            .stores = @ptrCast(&stores),
            .callable = @backingInt(Member.Kind.callable),
        };

        return zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;
    }

    const row = position("name", members, name) orelse return .{ .row = null, .has_store = false };
    const member = members[row];

    return .{ .row = if (member.kind == .callable) row else null, .has_store = member.has_store };
}

pub fn linked(modules: @FieldType(frontend.AnalysisResult, "modules"), path: []const u8, name: []const u8) ?zx.ir.FunctionId {
    if (comptime generated) {
        const entry = @import("generated_rx_named_record");
        const Input = std.meta.Child(entry.Input);
        const paths = zx.memory.borrowTextColumn("path", modules);
        const members = MemberColumns.borrow(&.{ "reexports", "functions" }, modules);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(entry.Input) = .{
            .paths = &.{ .rows = @ptrCast(&paths), .length = modules.len, .default_name = null },
            .path = path,
            .members = &members.view(std.meta.Child(@FieldType(Input, "members"))),
            .name = name,
        };

        const id = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        return if (id) |value| @fromBackingInt(value) else null;
    }

    const row = position("path", modules, path) orelse return null;

    return memberId(modules[row].reexports.functions, name);
}

pub fn memberId(members: []const frontend.project.FunctionImport, name: []const u8) ?zx.ir.FunctionId {
    const row = position("name", members, name) orelse return null;

    return members[row].id;
}

const Check = struct { rejected: ?u64 = null, default_call: bool = false };

pub fn inspect(calls: anytype, modules: anytype, path: []const u8) Check {
    if (calls.len == 0) return .{};

    const signed = @hasField(std.meta.Elem(@TypeOf(modules)), "signature");
    const Source = if (signed) Members else []const frontend.project.FunctionImport;
    const row = position("path", modules, path);
    const members: Source = if (row) |index| if (signed) modules[index].signature.members else modules[index].reexports.functions else &.{};

    if (comptime generated) {
        const entry = @import("generated_rx_named_requests");
        const names = zx.memory.borrowTextColumn("name", members);
        const requests = zx.memory.borrowReadColumn(?[]const u8, "member", calls);
        const kinds = if (signed) zx.memory.borrowReadColumn(std.meta.Elem(Members).Kind, "kind", members) else {};
        const stores = if (signed) zx.memory.borrowReadColumn(bool, "has_store", members) else {};
        const ids = if (signed) {} else zx.memory.borrowOptionalU32Column("id", members);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(entry.Input) = .{
            .calls = @ptrCast(&requests),
            .count = calls.len,
            .names = &.{ .rows = @ptrCast(&names), .length = members.len, .default_name = null },
            .signature = if (signed and row != null) &.{ .kinds = @ptrCast(&kinds), .stores = @ptrCast(&stores), .callable = @backingInt(std.meta.Elem(Members).Kind.callable) } else null,
            .ids = if (!signed and row != null) @ptrCast(&ids) else null,
        };

        const result = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        return .{ .default_call = result.default_call, .rejected = result.rejected };
    }

    var result: Check = .{};

    for (calls, 0..) |call, index| {
        const name = call.member orelse {
            result.default_call = true;

            continue;
        };

        if (row == null) continue;

        const valid = if (signed) valid: {
            const selected = signature(members, name);

            break :valid selected.row != null and !selected.has_store;
        } else memberId(members, name) != null;

        if (!valid) {
            result.rejected = index;

            break;
        }
    }

    return result;
}

fn position(comptime field: []const u8, rows: anytype, name: []const u8) ?usize {
    if (comptime generated) {
        const entry = @import("generated_rx_named_position");
        const names = zx.memory.borrowTextColumn(field, rows);
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(entry.Input) = .{
            .names = &.{ .rows = @ptrCast(&names), .length = rows.len, .default_name = null },
            .name = name,
        };

        const row = zx.columns.invoke(entry.executeValue, empty.allocator(), &input) catch unreachable;

        return if (row) |index| @intCast(index) else null;
    }

    for (rows, 0..) |*row, index| {
        if (std.mem.eql(u8, @field(row, field), name)) return index;
    }

    return null;
}
