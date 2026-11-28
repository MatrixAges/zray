const std = @import("std");
const Program = @import("zx").ir.Program;
const Source = @import("frontend").project.Source;
const Binding = @import("../../../conditions.zig").Input;
const native = @import("output_execution_abi").layouts.@"zig:verification_report_host";
const Allocating = std.Io.Writer.Allocating;
const Error = std.mem.Allocator.Error;
const Self = @This();

bytes: *Allocating,
json: std.json.Stringify,
pub fn init(bytes: *Allocating) Self {
    return .{ .bytes = bytes, .json = .{ .writer = &bytes.writer, .options = .{ .whitespace = .indent_2 } } };
}

pub fn begin(handle: *anyopaque) Error!void {
    borrow(handle).json.beginObject() catch return error.OutOfMemory;
}

pub fn finish(handle: *anyopaque) Error![]const u8 {
    const self = borrow(handle);

    self.json.endObject() catch return error.OutOfMemory;

    return self.bytes.written();
}

pub fn write(allocator: std.mem.Allocator, sources: *const anyopaque, entry: []const u8, version: u32, inputs: *const anyopaque, program_handle: *const anyopaque, fields: []const *const native.EvidenceField) Error![]const u8 {
    var bytes: Allocating = .init(allocator);

    defer bytes.deinit();

    var output = Self.init(&bytes);
    const source_rows: *const []const Source = @ptrCast(@alignCast(sources));
    const input_rows: *const []const Binding = @ptrCast(@alignCast(inputs));
    const program: *const Program = @ptrCast(@alignCast(program_handle));

    try begin(&output);

    for (fields) |member| {
        const name = member.name;

        switch (member.kind) {
            .Sources => try output.writeField(name, source_rows),
            .Entry => try output.writeField(name, entry),
            .Version => try output.writeField(name, version),
            .Types => try output.writeField(name, &program.types),
            .Inputs => try output.writeField(name, input_rows),
            .Program => try output.writeField(name, program),
        }
    }

    _ = try finish(&output);

    return bytes.toOwnedSlice();
}

pub fn field(comptime Value: type, comptime indirect: bool) fn (*anyopaque, []const u8, if (indirect) *const anyopaque else Value) Error!void {
    const Input = if (indirect) *const anyopaque else Value;

    return struct {
        fn write(handle: *anyopaque, name: []const u8, input: Input) Error!void {
            const value = if (indirect) @as(*const Value, @ptrCast(@alignCast(input))) else input;

            try borrow(handle).writeField(name, value);
        }
    }.write;
}

fn writeField(self: *Self, name: []const u8, value: anytype) Error!void {
    self.json.objectField(name) catch return error.OutOfMemory;
    self.json.write(value) catch return error.OutOfMemory;
}

fn borrow(handle: *anyopaque) *Self {
    return @ptrCast(@alignCast(handle));
}
