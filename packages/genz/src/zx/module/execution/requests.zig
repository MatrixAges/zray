const zx = @import("zx");
const Frame = @import("frame.zig");
const Lower = @import("../../lower.zig");
const Requests = @import("../../functions/requests.zig");
const emit = @import("../../functions/emit.zig");
const Api = @import("../../expressions/evaluate.zig").Api;
const generated = @import("genz_options").generated_analysis;
const Form = if (generated) Api.ModuleRequestForm else Requests.Form;
const Error = Lower.Error;

pub fn takeModuleFunction(handle: *anyopaque) Form {
    const frame = Frame.borrow(handle);
    const state = frame.requests.?;
    const request = state.queue.next(frame.lowering.program.functions.native_modules) orelse return .Done;

    state.current = request;

    return zx.columns.view(Form, request.form);
}

pub fn emitRequestedNative(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return emit.native(frame.lowering, &frame.output, frame.requests.?.current.id);
}

pub fn openRequestedFunction(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const state = frame.requests.?;

    return emit.open(frame.lowering, &state.selected, state.current.id);
}

pub fn emitRequestedStore(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../../store.zig").declaration(&frame.requests.?.selected, &frame.output);
}

pub fn emitRequestedBody(handle: *anyopaque, value: bool) Error!void {
    const frame = Frame.borrow(handle);
    const state = frame.requests.?;

    return emit.body(&state.selected, &frame.output, state.current.id, if (value) .value else .regular);
}

pub fn publishRequestedFunction(handle: *anyopaque) void {
    const frame = Frame.borrow(handle);

    emit.publish(frame.lowering, &frame.requests.?.selected);
}

pub fn drainSeed(handle: *anyopaque) Error!void {
    while (true) {
        const form = takeModuleFunction(handle);

        switch (form) {
            .Done => return,
            .Native => try emitRequestedNative(handle),
            .FirstRegular, .Regular, .FirstValue, .Value => {
                try openRequestedFunction(handle);
                if (form == .FirstRegular or form == .FirstValue) try emitRequestedStore(handle);
                try emitRequestedBody(handle, form == .Value or form == .FirstValue);

                publishRequestedFunction(handle);
            },
        }
    }
}
