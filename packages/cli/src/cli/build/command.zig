const std = @import("std");
const source = @import("cli_source");
const columns = @import("zx").columns;
pub const constants = source.backend_command_constants.@"zx.constants";
pub const Prefix = Spec(source.backend_command_prefix);
pub const Entry = Spec(source.backend_command_entry);
pub const Module = Spec(source.backend_command_module);
pub const Translation = Spec(source.backend_translation_command);
pub const Settings = Spec(source.backend_command_settings);

allocator: std.mem.Allocator,
arguments: std.ArrayList([]const u8) = .empty,
const Command = @This();

pub fn settings(allocator: std.mem.Allocator, options: Settings) ![]const []const u8 {
    return build(source.backend_command_settings, allocator, &options);
}

pub fn prefix(self: *Command, spec: Prefix) !void {
    try self.append(source.backend_command_prefix, &spec);
}

pub fn entry(self: *Command, spec: Entry) !void {
    try self.append(source.backend_command_entry, &spec);
}

pub fn module(self: *Command, spec: Module) !void {
    try self.append(source.backend_command_module, &spec);
}

pub fn translate(self: *Command, spec: Translation) !void {
    try self.append(source.backend_translation_command, &spec);
}

fn Spec(comptime rule: type) type {
    return std.meta.Child(@FieldType(std.meta.Child(rule.Input), "spec"));
}

fn append(self: *Command, comptime rule: type, spec: *const Spec(rule)) !void {
    try self.arguments.appendSlice(self.allocator, try build(rule, self.allocator, spec));
}

fn build(comptime rule: type, allocator: std.mem.Allocator, spec: *const Spec(rule)) ![]const []const u8 {
    const request: std.meta.Child(rule.Input) = .{
        .spec = spec,
    };

    return columns.invoke(rule.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    };
}
