const zx = @import("zx");
const Frame = @import("frame.zig");
const Lower = @import("../../lower.zig");
const Requests = @import("../../functions/requests.zig");
const emit = @import("../../functions/emit.zig");
const Api = @import("../../expressions/evaluate.zig").Api;
const generated = @import("genz_options").generated_analysis;
const Form = if (generated) Api.ModuleRequestForm else Requests.Form;
const Error = Lower.Error;

pub fn takeModuleFunction(frame: *Frame) Form {
    const state = frame.requests.?;
    const request = state.queue.next(frame.lowering.program.functions.native_modules) orelse return .Done;

    state.current = request;

    return zx.columns.view(Form, request.form);
}

pub fn emitRequestedNative(frame: *Frame) Error!void {
    return emit.native(frame.lowering, &frame.output, frame.requests.?.current.id);
}

pub fn openRequestedFunction(frame: *Frame) Error!void {
    const state = frame.requests.?;

    return emit.open(frame.lowering, &state.selected, state.current.id);
}

pub fn emitRequestedStore(frame: *Frame) Error!void {
    return @import("../../store.zig").declaration(&frame.requests.?.selected, &frame.output);
}

pub fn emitRequestedBody(frame: *Frame, value: bool) Error!void {
    const state = frame.requests.?;

    return emit.body(&state.selected, &frame.output, state.current.id, if (value) .value else .regular);
}

pub fn publishRequestedFunction(frame: *Frame) void {
    emit.publish(frame.lowering, &frame.requests.?.selected);
}

pub fn drainSeed(frame: *Frame) Error!void {
    while (true) {
        const form = takeModuleFunction(frame);

        switch (form) {
            .Done => return,
            .Native => try emitRequestedNative(frame),
            .FirstRegular, .Regular, .FirstValue, .Value => {
                try openRequestedFunction(frame);
                if (form == .FirstRegular or form == .FirstValue) try emitRequestedStore(frame);
                try emitRequestedBody(frame, form == .Value or form == .FirstValue);

                publishRequestedFunction(frame);
            },
        }
    }
}
