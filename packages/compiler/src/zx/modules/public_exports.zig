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

const Action = if (generated_mode)
    @FieldType(@typeInfo(@TypeOf(@import("generated_project_public_exports").executeValue(undefined, undefined))).error_union.payload, "action")

else
    enum { None, Forward, Callable, Deferred, Intrinsic, Invalid };

const Plan = struct {
    invalid_name: ?usize = null,
    default_member: ?usize = null,
    action: Action = .None,
};

pub fn bodyEntry(allocator: std.mem.Allocator, backing: std.mem.Allocator, own: ?ir.FunctionId, types: []const ir.Export, constants: []const ir.Constant, functions: []const FunctionImport, reporter: *zx.Reporter) zx.Error!?ir.FunctionId {
    const selected = try plan(allocator, backing, types, constants, functions, own != null, reporter);

    return switch (selected.action) {
        .None => own,
        .Forward => functions[selected.default_member.?].id,
        else => unreachable,
    };
}

pub fn signatureEntry(allocator: std.mem.Allocator, backing: std.mem.Allocator, signature: *Signature.Result, reporter: *zx.Reporter) zx.Error!void {
    const members = signature.members;
    const selected = try plan(allocator, backing, signature.exports, signature.constant_exports, members, true, reporter);

    switch (selected.action) {
        .None, .Intrinsic => {},
        .Invalid => return reporter.fail(.module, .{ .start = 0, .end = 0 }, "a default re-export requires a callable source"),
        .Deferred => {
            signature.has_deferred_source = true;
            signature.deferred_source = members[selected.default_member.?].source.?;
        },
        .Callable => {
            const member = members[selected.default_member.?];

            signature.ports = member.ports.?;
            signature.has_store = member.has_store;
            signature.type_only = false;
        },
        .Forward => unreachable,
    }
}

fn plan(allocator: std.mem.Allocator, backing: std.mem.Allocator, types: []const ir.Export, constants: []const ir.Constant, functions: anytype, has_function: bool, reporter: *zx.Reporter) zx.Error!Plan {
    var arena = std.heap.ArenaAllocator.init(backing);

    defer arena.deinit();

    const first_function = types.len + constants.len;
    const selected = try select(arena.allocator(), types, constants, functions, false, has_function);

    if (selected.invalid_name) |duplicate| {
        const name = if (duplicate < types.len)
            types[duplicate].name

        else if (duplicate < first_function)
            constants[duplicate - types.len].name
        else
            functions[duplicate - first_function].name;

        return reporter.fail(.name, .{ .start = 0, .end = 0 }, try std.fmt.allocPrint(allocator, "duplicate public export: {s}", .{if (name.len == 0) "default" else name}));
    }

    return selected;
}

pub fn invalidRootName(allocator: std.mem.Allocator, roots: anytype) std.mem.Allocator.Error!?usize {
    return (try select(allocator, roots, @as([]const ir.Constant, &.{}), @as([]const FunctionImport, &.{}), true, false)).invalid_name;
}

fn select(allocator: std.mem.Allocator, first: anytype, second: []const ir.Constant, functions: anytype, roots: bool, has_function: bool) std.mem.Allocator.Error!Plan {
    const first_function = first.len + second.len;
    const count = first_function + functions.len;

    if (count == 0) return .{};
    if (comptime !generated_mode) return seedSelect(allocator, first, second, functions, roots, has_function);

    const memory = @import("zx").memory;
    const generated = @import("generated_project_public_exports");
    const Input = std.meta.Child(generated.Input);
    const Facts = std.meta.Child(@typeInfo(@FieldType(Input, "signature")).optional.child);
    const names = memory.borrowTextColumn("name", first);
    const constants = memory.borrowTextColumn("name", second);
    const members = memory.borrowTextColumn("name", functions);
    const buckets = try @import("source_index/fixed.zig").bucketsFor(allocator, count);

    defer allocator.free(buckets);

    const facts: ?Facts = if (comptime std.meta.Elem(@TypeOf(functions)) == Signature.Member) signatureFacts(Facts, functions) else null;

    const input: Input = .{
        .keys = &.{
            .first = @ptrCast(&names),
            .second = @ptrCast(&constants),
            .third = @ptrCast(&members),
            .second_start = first.len,
            .third_start = first_function,
            .count = count,
        },
        .buckets = @ptrCast(&buckets),
        .capacity = buckets.len,
        .roots = roots,
        .has_function = has_function,
        .signature = if (facts) |*value| value else null,
    };

    const output = zx.columns.invoke(generated.executeValue, allocator, &input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IndexOutOfBounds => unreachable,
    };

    return .{
        .invalid_name = if (output.names.invalid_name) |index| @intCast(index) else null,
        .default_member = if (output.names.default_member) |index| @intCast(index) else null,
        .action = output.action,
    };
}

fn signatureFacts(comptime Facts: type, functions: []const Signature.Member) ?Facts {
    for (functions) |*member| {
        if (member.name.len == 0) return .{
            .callable = member.ports != null,
            .deferred = member.source != null,
            .intrinsic = member.intrinsic != null,
        };
    }

    return null;
}

fn seedSelect(allocator: std.mem.Allocator, first: anytype, second: []const ir.Constant, functions: anytype, roots: bool, has_function: bool) std.mem.Allocator.Error!Plan {
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    defer seen.deinit(allocator);

    var result: Plan = .{};
    var index: usize = 0;

    inline for (.{ first, second, functions }, 0..) |items, section| {
        for (items, 0..) |*item, row| {
            const name = item.name;

            if ((roots and name.len == 0) or (try seen.getOrPut(allocator, name)).found_existing) return .{ .invalid_name = index };

            if (section == 2 and name.len == 0) {
                result.default_member = row;

                if (comptime @TypeOf(item.*) == Signature.Member) {
                    result.action = if (item.ports != null) .Callable else if (item.source != null)
                        .Deferred

                    else if (item.intrinsic != null)
                        .Intrinsic
                    else
                        .Invalid;
                } else if (!has_function) {
                    result.action = .Forward;
                }
            }

            index += 1;
        }
    }

    return result;
}
