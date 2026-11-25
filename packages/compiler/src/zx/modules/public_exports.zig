const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const generated_mode = @import("parser_options").generated_parser;
const Signature = @import("source_signature.zig");
const FunctionImport = @import("function_import.zig");

pub fn merge(comptime T: type, allocator: std.mem.Allocator, own: []const T, forwarded: []const T) std.mem.Allocator.Error![]const T {
    if (own.len == 0) return forwarded;
    if (forwarded.len == 0) return own;

    const result = try allocator.alloc(T, own.len + forwarded.len);

    @memcpy(result[0..own.len], own);
    @memcpy(result[own.len..], forwarded);

    return result;
}

pub fn prepend(comptime T: type, allocator: std.mem.Allocator, own: ?T, forwarded: []const T) std.mem.Allocator.Error![]const T {
    const value = own orelse return forwarded;
    const result = try allocator.alloc(T, forwarded.len + 1);

    result[0] = value;

    @memcpy(result[1..], forwarded);

    return result;
}

const Plan = struct {
    invalid_name: ?usize = null,
    duplicate: ?[]const u8 = null,
    entry: ?ir.FunctionId = null,
    ports: ?Signature.Ports = null,
    has_store: bool = false,
    deferred: ?[]const u8 = null,
};

pub fn bodyEntry(allocator: std.mem.Allocator, backing: std.mem.Allocator, own: ?ir.FunctionId, types: []const ir.Export, constants: []const ir.Constant, functions: []const FunctionImport, reporter: *zx.Reporter) zx.Error!?ir.FunctionId {
    return (try plan(allocator, backing, types, constants, functions, own, reporter)).entry;
}

pub fn signatureEntry(allocator: std.mem.Allocator, backing: std.mem.Allocator, signature: *Signature.Result, reporter: *zx.Reporter) zx.Error!void {
    const selected = try plan(allocator, backing, signature.exports, signature.constant_exports, signature.members, null, reporter);

    if (selected.deferred) |source| {
        signature.has_deferred_source = true;
        signature.deferred_source = source;
    }

    if (selected.ports) |ports| {
        signature.ports = ports;
        signature.has_store = selected.has_store;
        signature.type_only = false;
    }
}

fn plan(allocator: std.mem.Allocator, backing: std.mem.Allocator, types: []const ir.Export, constants: []const ir.Constant, functions: anytype, own: ?ir.FunctionId, reporter: *zx.Reporter) zx.Error!Plan {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const selected = try seedSelect(arena.allocator(), types, constants, functions, false, own);

    if (selected.duplicate) |name| {
        return reportDuplicate(allocator, reporter, name);
    }

    return selected;
}

pub fn reportDuplicate(allocator: std.mem.Allocator, reporter: *zx.Reporter, name: []const u8) zx.Error {
    const message = std.fmt.allocPrint(allocator, "duplicate public export: {s}", .{if (name.len == 0) "default" else name}) catch return error.OutOfMemory;

    return reporter.fail(.name, .{ .start = 0, .end = 0 }, message);
}

pub fn invalidRootName(allocator: std.mem.Allocator, roots: anytype) std.mem.Allocator.Error!?usize {
    if (roots.len == 0) return null;

    const empty: []const FunctionImport = &.{};

    if (comptime !generated_mode) return (try seedSelect(allocator, roots, @as([]const ir.Constant, &.{}), empty, true, null)).invalid_name;

    const memory = zx.memory;
    const generated = @import("generated_project_public_exports");
    const Input = std.meta.Child(generated.Input);
    const names = memory.borrowTextColumn("name", roots);
    const unused_names = memory.borrowTextColumn("name", empty);
    const ids = memory.borrowOptionalU32Column("id", empty);
    var buckets = try @import("source_index/fixed.zig").bucketsFor(allocator, roots.len);

    defer allocator.free(buckets);

    const keys: std.meta.Child(@FieldType(Input, "keys")) = .{
        .first = @ptrCast(&names),
        .second = @ptrCast(&unused_names),
        .third = @ptrCast(&unused_names),
        .second_start = roots.len,
        .third_start = roots.len,
        .count = roots.len,
    };

    const input: Input = .{
        .keys = &keys,
        .buckets = @ptrCast(&buckets),
        .capacity = buckets.len,
        .roots = true,
        .own = null,
        .ids = @ptrCast(&ids),
        .signature = null,
    };

    const output = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    return if (output.invalid_name) |index| @intCast(index) else null;
}

fn seedSelect(allocator: std.mem.Allocator, first: anytype, second: []const ir.Constant, functions: anytype, roots: bool, own: ?ir.FunctionId) std.mem.Allocator.Error!Plan {
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    defer seen.deinit(allocator);

    var result: Plan = .{ .entry = own };
    var index: usize = 0;

    inline for (.{ first, second, functions }, 0..) |items, section| {
        for (items) |*item| {
            const name = item.name;

            if ((roots and name.len == 0) or (try seen.getOrPut(allocator, name)).found_existing) return .{ .invalid_name = index, .duplicate = name };

            if (section == 2 and name.len == 0) {
                if (comptime @TypeOf(item.*) == Signature.Member) {
                    switch (item.kind) {
                        .callable => {
                            result.ports = item.ports;
                            result.has_store = item.has_store;
                        },
                        .deferred => result.deferred = item.source,
                        .intrinsic => {},
                    }
                } else if (own == null) {
                    result.entry = item.id;
                }
            }

            index += 1;
        }
    }

    return result;
}
