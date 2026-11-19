const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
pub const codec = @import("codec.zig");
pub const PublicReference = @import("load.zig").Export;
pub const load = @import("load.zig").load;
pub const link = @import("link.zig").link;
pub const Initializer = frontend.project.SourceStoreInitializer;

pub const Input = struct {
    name: []const u8,
    analysis: *const frontend.AnalysisResult,
    initializers: []const Initializer = &.{},
    borrowed_initializers: []const Initializer.Borrowed = &.{},
};

pub const Export = frontend.project.compiled.Export;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    program: ir.Program,
    exports: []const Export,
    nominal_types: @FieldType(frontend.AnalysisResult, "nominal_types"),
    store_initializers: []const frontend.project.compiled.StoreInitializer = &.{},
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }

    pub fn module(self: *const Result, index: usize) error{InvalidModule}!ir.Program {
        if (index >= self.exports.len) return error.InvalidModule;

        const exported = self.exports[index];
        var result = self.program;
        result.file_name = exported.path;
        result.exports = exported.types;
        result.constant_exports = exported.constants;

        @import("entry_view.zig").apply(&result, exported.function, false);

        return result;
    }
};
