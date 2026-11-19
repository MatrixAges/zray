const std = @import("std");
const compiled = @import("frontend").project.compiled;
const model = @import("root.zig");
pub const Error = std.mem.Allocator.Error || error{InvalidLibrary};

pub fn validate(allocator: std.mem.Allocator, library: *const model.Result) Error!void {
    return compiled.validate(allocator, view(library));
}

pub fn validateIndexed(allocator: std.mem.Allocator, library: *const model.Result, index: *compiled.ExportIndex) Error!void {
    return compiled.validateIndexed(allocator, view(library), index);
}

pub fn validateLinked(allocator: std.mem.Allocator, library: *const model.Result) (Error || error{ InvalidIr, ConflictingStore })!void {
    return compiled.validateLinked(allocator, view(library));
}

pub fn validateHeader(library: *const model.Result) error{InvalidLibrary}!void {
    return compiled.validateHeader(&library.program, library.exports.len);
}

fn view(library: *const model.Result) compiled.Graph {
    return .{ .program = library.program, .exports = library.exports, .nominal_types = library.nominal_types, .store_initializers = library.store_initializers };
}
