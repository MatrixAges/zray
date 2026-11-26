const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const emission = @import("emission.zig");
const requests = @import("requests.zig");
const Stored = @import("../../../node/stored.zig").Declarations;

pub fn lower(self: *Lower) Lower.Error!Stored {
    const type_only = self.program.type_only;
    const local = self.function_modules == null;
    var frame = Frame.init(self);

    defer frame.deinit();

    const local_functions = if (local and !type_only) self.program.functions.count() else 0;
    var queue: Frame.RequestsFrame = .{ .queue = try @import("../../functions/requests.zig").init(self.allocator, local_functions) };

    frame.requests = &queue;

    frame.install();

    try emission.standard(&frame);
    if (local) try emission.imports(&frame);
    try emission.types(&frame);
    try emission.exports(&frame);
    try emission.constants(&frame);

    if (!type_only) {
        try emission.shape(&frame);
        try emission.aliases(&frame);
        try emission.store(&frame);
        try emission.entry(&frame);
        try emission.valueEntry(&frame);
        if (local) try requests.drain(&frame);
        try emission.suffix(&frame);
    }

    return frame.finish(type_only);
}
