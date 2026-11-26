const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const Form = @import("../workflow.zig").FunctionForm;
const publication = @import("emission.zig");
const Stored = @import("../../../node/stored.zig").Declarations;
const generated = @import("genz_options").generated_analysis;

pub fn lower(self: *Lower, id: ir.FunctionId, form: Form) Lower.Error!Stored {
    var frame = Frame.init(self);

    defer frame.deinit();

    frame.function = id;

    frame.install();

    self.local_regular_function = form != .Value;

    if (generated) {
        if (form == .Native) {
            @import("../../functions/scope.zig").installFunction(&self.program, @backingInt(id), .Native);
        } else {
            const context = @import("../../functions/context.zig");

            try self.selectFunction(id);

            context.selectPlan(self, id);

            try context.reserve(self);
        }
    }

    try publication.standard(&frame);
    try publication.types(&frame);
    try publication.store(&frame);

    if (form == .Native) {
        try publication.imports(&frame);
        try emitBody(&frame, .Native);
    } else {
        if (form != .Value) try emitBody(&frame, .Regular);
        if (form != .Regular) try emitBody(&frame, .Value);
    }

    try publication.suffix(&frame);

    return frame.finish(false);
}

fn emitBody(frame: *Frame, form: Form) Lower.Error!void {
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
