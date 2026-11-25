const std = @import("std");
const WriteError = std.Io.Writer.Error;
const Self = @This();

target: *std.Io.Writer,
json: std.json.Stringify = undefined,
pub fn raw(target: *anyopaque, text: []const u8) WriteError!void {
    try get(target).target.writeAll(text);
}

pub fn quoted(target: *anyopaque, value: []const u8) WriteError!void {
    try std.json.Stringify.value(value, .{}, get(target).target);
}

pub fn strings(target: *anyopaque, values: []const []const u8) WriteError!void {
    try std.json.Stringify.value(values, .{}, get(target).target);
}

pub fn beginRecord(target: *anyopaque) WriteError!void {
    const self = get(target);

    self.json = .{ .writer = self.target };

    try self.json.beginObject();
}

pub fn beginObject(target: *anyopaque) WriteError!void {
    try get(target).json.beginObject();
}

pub fn endObject(target: *anyopaque) WriteError!void {
    try get(target).json.endObject();
}

pub fn beginArray(target: *anyopaque) WriteError!void {
    try get(target).json.beginArray();
}

pub fn endArray(target: *anyopaque) WriteError!void {
    try get(target).json.endArray();
}

pub fn member(target: *anyopaque, key: []const u8) WriteError!void {
    try get(target).json.objectField(key);
}

pub fn textField(target: *anyopaque, key: []const u8, value: []const u8) WriteError!void {
    const json = &get(target).json;

    try json.objectField(key);
    try json.write(value);
}

pub fn boolField(target: *anyopaque, key: []const u8, value: bool) WriteError!void {
    const json = &get(target).json;

    try json.objectField(key);
    try json.write(value);
}

pub fn stringsField(target: *anyopaque, key: []const u8, values: []const []const u8) WriteError!void {
    const json = &get(target).json;

    try json.objectField(key);
    try json.write(values);
}

fn get(target: *anyopaque) *Self {
    return @ptrCast(@alignCast(target));
}
