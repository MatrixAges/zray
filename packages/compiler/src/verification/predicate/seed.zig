const std = @import("std");
const zx = @import("zx");

pub fn unary(allocator: std.mem.Allocator, operator: []const u8, value: []const u8) zx.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "({s} {s})", .{ operator, value });
}

pub fn binary(allocator: std.mem.Allocator, operator: []const u8, left: []const u8, right: []const u8) zx.Error![]const u8 {
    if (std.mem.eql(u8, operator, "and")) {
        if (std.mem.eql(u8, left, "false") or std.mem.eql(u8, right, "false")) return "false";
        if (std.mem.eql(u8, left, "true")) return right;
        if (std.mem.eql(u8, right, "true")) return left;
    }

    return std.fmt.allocPrint(allocator, "({s} {s} {s})", .{ operator, left, right });
}

pub fn choose(allocator: std.mem.Allocator, condition: []const u8, yes: []const u8, no: []const u8) zx.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "(ite {s} {s} {s})", .{ condition, yes, no });
}

pub fn constant(allocator: std.mem.Allocator, value: u64, width: u16) zx.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "(_ bv{d} {d})", .{ value, width });
}
