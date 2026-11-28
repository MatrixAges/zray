const std = @import("std");
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const emission = @import("emission.zig");
const requests = @import("requests.zig");
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

    if (generated) {
        const entry = @import("generated_lower_entry_declarations");
        const input: std.meta.Child(entry.Input) = .{ .type_only = type_only, .local = local, .suffix = null, .request = null };

        return @import("steps.zig").execute(entry, &frame, input);
    }

    try seed(&frame, type_only, local);

    return frame.finishSeed(type_only);
}

fn seed(frame: *Frame, type_only: bool, local: bool) Lower.Error!void {
    try emission.emitModuleStandard(frame);
    if (local) try emission.emitModuleImports(frame);
    try emission.emitModuleTypes(frame);
    try emission.emitModuleExports(frame);
    try emission.emitModuleConstants(frame);
    if (type_only) return;
    try emission.emitModuleShape(frame);
    try emission.emitModuleAliases(frame);
    try emission.emitModuleStore(frame);
    try emission.emitModuleEntry(frame);
    try emission.emitModuleValueEntry(frame);
    if (local) try requests.drainSeed(frame);
    try emission.suffixSeed(frame);
}
