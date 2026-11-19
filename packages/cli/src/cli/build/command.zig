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

pub fn settings(allocator: std.mem.Allocator, buffer: *[constants.settings_capacity][]const u8, options: Settings) ![]const []const u8 {
    return buffer[0..try write(source.backend_command_settings, allocator, buffer, &options)];
}

pub fn prefix(self: *Command, spec: Prefix) !void {
    try self.append(source.backend_command_prefix, constants.prefix_capacity + spec.libraries.len + 2 * spec.library_paths.len, &spec);
}

pub fn entry(self: *Command, spec: Entry) !void {
    try self.append(source.backend_command_entry, constants.entry_capacity + 2 * (spec.settings.len + spec.imports.len + spec.natives.len), &spec);
}

pub fn module(self: *Command, spec: Module) !void {
    const repeated = if (spec.translated != null) spec.settings.len else 0;
    const capacity = constants.module_capacity + spec.settings.len + repeated + 2 * (spec.imports.len + spec.includes.len);

    try self.append(source.backend_command_module, capacity, &spec);
}

pub fn translate(self: *Command, spec: Translation) !void {
    try self.append(source.backend_translation_command, constants.translation_capacity + spec.settings.len + 2 * spec.includes.len, &spec);
}

fn Spec(comptime rule: type) type {
    return std.meta.Child(@FieldType(std.meta.Child(rule.Input), "spec"));
}

fn append(self: *Command, comptime rule: type, capacity: usize, spec: *const Spec(rule)) !void {
    try self.arguments.ensureUnusedCapacity(self.allocator, capacity);

    self.arguments.items.len += try write(rule, self.allocator, self.arguments.unusedCapacitySlice(), spec);
}

fn write(comptime rule: type, allocator: std.mem.Allocator, target: [][]const u8, spec: *const Spec(rule)) !usize {
    var buffer = target;

    const request: std.meta.Child(rule.Input) = .{
        .out = @ptrCast(&buffer),
        .spec = spec,
    };

    return @intCast(columns.invoke(rule.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => return error.OutOfMemory,
        else => unreachable,
    });
}
