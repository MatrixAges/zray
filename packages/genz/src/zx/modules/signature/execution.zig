const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const Output = @import("../../../node/declarations.zig").Output;
const Module = @import("../../modules.zig");
const signature = @import("../signature.zig");
const workflow = @import("../../module/workflow.zig");

const Units = union(enum) {
    mixed: []const Module.Unit,
    functions: []const Module.FunctionUnit,
};

const Frame = struct {
    lowering: *Lower,
    output: *Output,
    names: []const []const u8,
    units: Units,
    emitted: std.StringHashMapUnmanaged(void) = .empty,
    selected: Lower = undefined,
    id: ir.FunctionId = undefined,
    prototypes: signature.Prototypes = undefined,
};

pub fn lower(self: *Lower, output: *Output, names: []const []const u8, units: anytype) Module.Error!void {
    const source: Units = if (std.meta.Elem(@TypeOf(units)) == Module.FunctionUnit)
        .{ .functions = units }

    else
        .{ .mixed = units };

    var frame: Frame = .{ .lowering = self, .output = output, .names = names, .units = source };
    const entry = @import("generated_lower_module_signatures");
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    for (0..units.len) |row| {
        const form = (try open(&frame, row)) orelse continue;
        const plan = try entry.executeValue(empty.allocator(), form);

        if (plan.native) {
            try emitNative(&frame);
        } else {
            try frame.selected.selectFunction(frame.id);
            if (plan.regular) frame.prototypes.regular = try frame.selected.prototype("signature", false);
            if (plan.value) frame.prototypes.value = try frame.selected.valuePrototype("signature");
        }

        try signature.append(&frame.selected, frame.output, frame.prototypes, plan.parameter_name);
    }
}

fn open(frame: *Frame, row: usize) (Lower.Error || error{InvalidFunction})!?workflow.FunctionForm {
    const self = frame.lowering;

    const unit = switch (frame.units) {
        .mixed => |units| units[row],
        .functions => |units| units[row].unit(),
    };

    const id = switch (unit) {
        .function, .regular => |id| id,
        else => return null,
    };

    const function_row = @backingInt(id);

    if (function_row >= self.program.functions.count()) return error.InvalidFunction;

    const name = std.fs.path.stem(frame.names[function_row]);

    if ((try frame.emitted.getOrPut(self.allocator, name)).found_existing) return null;

    frame.selected = @import("../../functions/scope.zig").inherit(self, .Signature);
    frame.id = id;
    frame.prototypes = .{ .name = name, .regular = null, .value = null };

    return workflow.functionForm(
        self.program.functions.native_modules[function_row] != null,
        self.value_functions[function_row],
        unit == .regular,
    );
}

fn emitNative(frame: *Frame) Lower.Error!void {
    const row = @backingInt(frame.id);
    const declaration = ir.SignatureTable.read(&frame.selected.program.functions, row);

    frame.prototypes.regular = try @import("../../external.zig").prototype(&frame.selected, &declaration, row);
}
