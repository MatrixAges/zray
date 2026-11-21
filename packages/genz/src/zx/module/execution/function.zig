const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const Form = @import("../workflow.zig").FunctionForm;
const publication = @import("emission.zig");
const evaluation = @import("../../expressions/evaluate.zig");
const Stored = @import("../../../node/stored.zig").Declarations;
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, definition: ir.Function, id: ir.FunctionId, form: Form) Lower.Error!Stored {
    var frame = Frame.init(self);

    defer frame.deinit();

    const selected: Frame.Function = .{ .id = id, .definition = definition };

    frame.function = &selected;

    frame.install();

    self.local_regular_function = form != .Value;

    const handle: *const anyopaque = @ptrCast(&frame);

    if (generated) {
        const entry = @import("generated_lower_function_declarations");
        const input: std.meta.Child(entry.Input) = .{ .module_frame = @ptrCast(&frame), .form = form };

        try evaluation.execute(entry, &input);
    } else {
        try seed(handle, form);
    }

    return frame.finish(false);
}

fn seed(handle: *const anyopaque, form: Form) Lower.Error!void {
    try publication.emitModuleStandard(handle);
    try publication.emitModuleTypes(handle);
    try publication.emitModuleStore(handle);

    if (form == .Native) {
        try publication.emitModuleImports(handle);
        try emitFunctionModuleBody(handle, .Native);
    } else {
        if (form != .Value) try emitFunctionModuleBody(handle, .Regular);
        if (form != .Regular) try emitFunctionModuleBody(handle, .Value);
    }

    try publication.suffixSeed(handle);
}

pub fn emitFunctionModuleBody(handle: *const anyopaque, form: Form) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const selected = frame.function.?;

    var declaration = switch (form) {
        .Native => try @import("../../external.zig").lower(self, selected.definition, @backingInt(selected.id)),
        .Regular => if (try @import("../../functions/adapter.zig").build(self, selected.id)) |adapter| adapter else try self.function("call", false),
        .Value => try self.functionValue("callValue"),
        .RegularAndValue => unreachable,
    };

    if (form != .Value) declaration.function.name = "call";

    declaration.function.exported = true;

    try frame.output.append(self.allocator, declaration);
}
