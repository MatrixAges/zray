const std = @import("std");
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const emission = @import("emission.zig");
const requests = @import("requests.zig");
const evaluation = @import("../../expressions/evaluate.zig");
const Stored = @import("../../../node/stored.zig").Declarations;
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower) Lower.Error!Stored {
    const type_only = self.program.type_only;
    const local = self.function_modules == null;
    var frame = Frame.init(self);

    defer frame.deinit();

    const local_functions = if (local and !type_only) self.program.functions.count() else 0;
    var queue: Frame.RequestsFrame = .{ .queue = try @import("../../functions/requests.zig").init(self.allocator, local_functions) };

    frame.requests = &queue;

    frame.install();

    const handle: *const anyopaque = @ptrCast(&frame);

    if (generated) {
        const entry = @import("generated_lower_entry_declarations");
        const input: std.meta.Child(entry.Input) = .{ .module_frame = @ptrCast(&frame), .type_only = type_only, .local = local };

        try evaluation.execute(entry, &input);
    } else {
        try seed(handle, type_only, local);

        return frame.finishSeed(type_only);
    }

    return frame.result;
}

fn seed(handle: *const anyopaque, type_only: bool, local: bool) Lower.Error!void {
    try emission.emitModuleStandard(handle);
    if (local) try emission.emitModuleImports(handle);
    try emission.emitModuleTypes(handle);
    try emission.emitModuleExports(handle);
    try emission.emitModuleConstants(handle);
    if (type_only) return;
    try emission.emitModuleShape(handle);
    try emission.emitModuleAliases(handle);
    try emission.emitModuleStore(handle);
    try emission.emitModuleEntry(handle);
    try emission.emitModuleValueEntry(handle);
    if (local) try requests.drainSeed(handle);
    try emission.suffixSeed(handle);
}
