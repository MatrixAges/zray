const std = @import("std");
const ir = @import("zx").ir;
const Types = @import("types.zig");
const Origins = @import("../nominal_origins.zig");
const Nodes = @import("../artifact/nodes.zig");
const native = @import("native.zig");
pub const Error = Types.Error || @import("../artifact/model.zig").Error || error{ConflictingInterface};

pub const Input = struct {
    program: ir.Program,
    nominal_types: Origins.Table,
};

pub const Destination = struct {
    allocator: std.mem.Allocator,
    temporary: std.mem.Allocator,
    types: *Types,
    functions: *ir.FunctionStorage,
    native_modules: *ir.NativeModuleStorage,
};

const generated = @import("parser_options").generated_parser;
const schedule = if (generated) @import("generated_source_merge_sequence") else void;
const Form = if (generated) schedule.Input else enum { Program, AnalyzedBody };
const Stage = if (generated) std.meta.Child(schedule.Output) else enum { ValidateProgram, RegisterTypes, MapFunctions, BindNatives, PublishFunctions };

pub const Extension = struct {
    types: usize,
    base: usize,
    total: usize,
    tail: *const ir.FunctionTable,
};

pub fn append(input: Input, destination: Destination) Error!Nodes {
    return merge(.Program, &input.program, input.nominal_types, &destination, {});
}

pub fn appendAnalyzed(program: *const ir.Program, origins: Origins.Table, destination: *const Destination, extension: *const Extension) Error!Nodes {
    return merge(.AnalyzedBody, program, origins, destination, extension);
}

fn merge(comptime form: Form, program: *const ir.Program, origins: Origins.Table, destination: *const Destination, extension: if (form == .AnalyzedBody) *const Extension else void) Error!Nodes {
    const stages: []const Stage = comptime if (generated) @import("zx").staticSequence(schedule, form) else switch (form) {
        .Program => &.{ .ValidateProgram, .RegisterTypes, .MapFunctions, .BindNatives, .PublishFunctions },
        .AnalyzedBody => &.{ .RegisterTypes, .MapFunctions, .PublishFunctions },
    };

    const temporary = destination.temporary;
    var nodes: Nodes = undefined;
    var natives: []?ir.NativeModuleId = undefined;
    nodes.allocator = destination.allocator;

    inline for (stages) |stage| switch (stage) {
        .ValidateProgram => if (try @import("../../ir/validate.zig").validate(temporary, program.*) != null) return error.InvalidIr,
        .RegisterTypes => nodes.types = .{ .mapped = if (form == .Program)
            try destination.types.appendFrom(temporary, program.types, origins, 0)
        else
            try destination.types.appendAnalyzed(temporary, temporary, program.types, origins, extension.types) },
        .MapFunctions => {
            const count = if (form == .Program) program.functions.count() else extension.total;
            const base = if (form == .Program) 0 else extension.base;
            const range = try @import("function_table.zig").range(destination.functions.count(), count, base, program.types.count(), program.native_modules.count());

            nodes.functions = .{ .range = .{ .first = range.first, .count = range.count, .prefix = range.prefix } };

            if (form == .Program) {
                natives = try temporary.alloc(?ir.NativeModuleId, program.native_modules.count());
                nodes.native_modules = .{ .indexed = natives };
            } else {
                nodes.native_modules = .{ .range = .{ .first = 0, .count = range.native_modules } };
            }
        },
        .BindNatives => try native.link(temporary, destination.native_modules, program.native_modules, natives, &nodes),
        .PublishFunctions => try nodes.appendFunctions(destination.functions, if (form == .Program) program.functions else extension.tail.*, temporary),
    };

    return nodes;
}
