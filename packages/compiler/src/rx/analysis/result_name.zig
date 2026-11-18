const std = @import("std");
const rx = @import("rx");
const zx = @import("zx");
const target = @import("call/target.zig");
pub const Result = struct { name: []const u8, attribute: rx.ast.Attribute };
pub const Binding = union(enum) { name: []const u8, invalid, reserved };

pub fn bind(allocator: std.mem.Allocator, name: []const u8, task: bool) std.mem.Allocator.Error!Binding {
    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_result_binding");
        const input: std.meta.Child(rule.Input) = .{ .name = name, .task = task };

        const output = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
            error.InvalidUtf8 => return .invalid,
            error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
            else => unreachable,
        };

        return if (output.issue) |issue| switch (issue) {
            .Invalid => .invalid,
            .Reserved => .reserved,
        } else .{ .name = output.path };
    }

    if (!@import("frontend").binding_path.valid(name) or std.mem.indexOfScalar(u8, name, '.') != null) return .invalid;
    if (!task and std.mem.eql(u8, name, "task")) return .reserved;

    return .{ .name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ if (task) "$ctx.task" else "$ctx", name }) };
}

pub fn resolve(node: rx.ast.Node) Result {
    if (std.mem.eql(u8, node.name, "Task")) {
        const attribute = target.attribute(node, "name");

        return .{ .name = attribute.value, .attribute = attribute };
    }

    return resolveCall(target.optionalAttribute(node, "fn") orelse target.attribute(node, "module"));
}

pub fn resolveCall(attribute: rx.ast.Attribute) Result {
    const function_target = std.mem.eql(u8, attribute.name, "fn");

    if (comptime @import("rx_options").generated_graph) {
        const rule = @import("generated_rx_result_name");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const name = rule.executeValue(empty.allocator(), .{ .reference = attribute.value, .function_target = function_target }) catch unreachable;

        return .{ .name = name, .attribute = attribute };
    }

    const file = seed(attribute.value);
    const name = if (function_target) @import("frontend").project.module_path.callMember(file) orelse file else file;

    return .{ .name = name, .attribute = attribute };
}

fn seed(value: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfAny(u8, value, "/\\");
    var name = value[if (separator) |index| index + 1 else 0..];

    for ([_][]const u8{ ".zx", ".rx", ".zig" }) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) {
            name = name[0 .. name.len - suffix.len];

            break;
        }
    }

    return name;
}
