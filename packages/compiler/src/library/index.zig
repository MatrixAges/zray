const std = @import("std");
const generated = @import("parser_options").generated_parser;
const Self = @This();
const Owned = @import("frontend").project.source_index.Owned;
const Error = std.mem.Allocator.Error || error{ InvalidModule, DuplicateExport, InvalidAnalysis };

names: Owned = .{},
pub fn admit(self: *Self, allocator: std.mem.Allocator, name: []const u8, row: usize, analyzed: bool) Error!void {
    if (!generated) {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidModule;
        if (try self.names.register(allocator, name, row) != null) return error.DuplicateExport;
        if (!analyzed) return error.InvalidAnalysis;

        return;
    }

    const Admission = StateCall(@import("generated_library_export_admission").executeState);

    const result = Admission.run(allocator, .{
        .index = self.names.state,
        .name = name,
        .row = std.math.cast(u32, row) orelse return error.OutOfMemory,
        .analyzed = analyzed,
    }) catch |err| return failure(err);

    self.names.state = result.index;

    return switch (result.status) {
        .Accepted => {},
        .InvalidName => error.InvalidModule,
        .Duplicate => error.DuplicateExport,
        .InvalidAnalysis => error.InvalidAnalysis,
    };
}

fn StateCall(comptime execute: anytype) type {
    const function = @typeInfo(@TypeOf(execute)).@"fn";
    const Parameter = function.param_types[1].?;
    const indirect = @typeInfo(Parameter) == .pointer;

    return struct {
        pub const Input = if (indirect) std.meta.Child(Parameter) else Parameter;

        pub fn run(allocator: std.mem.Allocator, input: Input) function.return_type.? {
            return execute(allocator, if (indirect) &input else input);
        }
    };
}

fn failure(err: anyerror) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
