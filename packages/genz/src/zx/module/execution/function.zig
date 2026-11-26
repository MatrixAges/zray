const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const Form = @import("../workflow.zig").FunctionForm;
const publication = @import("emission.zig");
const evaluation = @import("../../expressions/evaluate.zig");
const Stored = @import("../../../node/stored.zig").Declarations;
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, id: ir.FunctionId, form: Form) Lower.Error!Stored {
    var frame = Frame.init(self);

    defer frame.deinit();

    frame.function = id;

    frame.install();

    self.local_regular_function = form != .Value;

    const handle: *anyopaque = @ptrCast(&frame);

    if (generated) {
        const entry = @import("generated_lower_function_declarations");
        const input: std.meta.Child(entry.Input) = .{ .module_frame = @ptrCast(&frame), .form = form };

        try evaluation.executeWith(self, entry, &input);
    } else {
        try seed(handle, form);

        return frame.finishSeed(false);
    }

    return frame.result;
}

pub fn openFunctionModule(handle: *anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const id = frame.function.?;
    const context = @import("../../functions/context.zig");

    try self.selectFunction(id);

    context.selectPlan(self, id);

    try context.reserve(self);
}

pub fn openNativeFunctionModule(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);
    @import("../../functions/scope.zig").installFunction(&frame.lowering.program, @backingInt(frame.function.?), .Native);
}

fn seed(handle: *anyopaque, form: Form) Lower.Error!void {
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

pub fn emitFunctionModuleBody(handle: *anyopaque, form: Form) Lower.Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const id = frame.function.?;

    var declaration = switch (form) {
        .Native => native: {
            const index = @backingInt(id);
            const signature = ir.SignatureTable.read(&self.program.functions, index);

            break :native try @import("../../external.zig").lower(self, &signature, index);
        },
        .Regular => if (try @import("../../functions/adapter.zig").build(self, id)) |adapter| adapter else try self.function("call", false),
        .Value => try self.functionValue("callValue"),
        .RegularAndValue => unreachable,
    };

    if (form != .Value) declaration.function.name = "call";

    declaration.function.exported = true;

    try frame.output.append(self.allocator, declaration);
}
