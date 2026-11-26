const Frame = @import("frame.zig");
const Lower = @import("../../lower.zig");
const emit = @import("../../functions/emit.zig");
const Error = Lower.Error;

pub fn drain(frame: *Frame) Error!void {
    const state = frame.requests.?;

    while (state.queue.next(frame.lowering.program.functions.native_modules)) |request| {
        switch (request.form) {
            .Done => unreachable,
            .Native => try emit.native(frame.lowering, &frame.output, request.id),
            .FirstRegular, .Regular, .FirstValue, .Value => {
                try emit.open(frame.lowering, &state.selected, request.id);

                if (request.form == .FirstRegular or request.form == .FirstValue) {
                    try @import("../../store.zig").declaration(&state.selected, &frame.output);
                }

                try emit.body(
                    &state.selected,
                    &frame.output,
                    request.id,
                    if (request.form == .Value or request.form == .FirstValue) .value else .regular,
                );

                emit.publish(frame.lowering, &state.selected);
            },
        }
    }
}
