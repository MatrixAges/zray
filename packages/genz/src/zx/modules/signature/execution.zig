const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const Output = @import("../../../node/declarations.zig").Output;
const Module = @import("../../modules.zig");
const signature = @import("../signature.zig");
const evaluation = @import("../../expressions/evaluate.zig");
const Form = evaluation.Api.SignatureForm;

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
    definition: ir.Function = undefined,
    id: ir.FunctionId = undefined,
    prototypes: signature.Prototypes = undefined,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn lower(self: *Lower, output: *Output, names: []const []const u8, units: anytype) Module.Error!void {
    const source: Units = if (std.meta.Elem(@TypeOf(units)) == Module.FunctionUnit)
        .{ .functions = units }

    else
        .{ .mixed = units };

    var frame: Frame = .{ .lowering = self, .output = output, .names = names, .units = source };
    const entry = @import("generated_lower_module_signatures");
    const input: std.meta.Child(entry.Input) = .{ .signatures = @ptrCast(&frame), .count = units.len };
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    try entry.executeIn(empty.allocator(), &input);
}

pub fn openSignatureUnit(handle: *const anyopaque, index: u64) (Lower.Error || error{InvalidFunction})!Form {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const row: usize = @intCast(index);

    const unit = switch (frame.units) {
        .mixed => |units| units[row],
        .functions => |units| units[row].unit(),
    };

    const id = switch (unit) {
        .function, .regular => |id| id,
        else => return .Skip,
    };

    const name = std.fs.path.stem(frame.names[@backingInt(id)]);

    if ((try frame.emitted.getOrPut(self.allocator, name)).found_existing) return .Skip;

    frame.selected = @import("../../functions/scope.zig").inherit(self, .Signature);
    frame.definition = try Module.selectFunction(&frame.selected, id);
    frame.id = id;
    const variants = signature.select(frame.definition.external != null, frame.selected.value_functions[@backingInt(id)], unit == .regular);

    frame.prototypes = .{ .name = name, .parameter_name = variants.parameter_name, .regular = null, .value = null };

    if (variants.regular) return if (variants.value) .Both else .Regular;

    return .Value;
}

pub fn emitRegularSignature(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.prototypes.regular = try Module.regularPrototype(&frame.selected, frame.id, frame.definition);
}

pub fn emitValueSignature(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    frame.prototypes.value = try frame.selected.valuePrototype("signature");
}

pub fn publishSignatureUnit(handle: *const anyopaque) Lower.Error!void {
    const frame = Frame.borrow(handle);

    return signature.append(&frame.selected, frame.output, frame.prototypes);
}
