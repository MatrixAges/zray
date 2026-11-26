const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../../lower.zig");
const Output = @import("../../../node/declarations.zig").Output;
const Module = @import("../../modules.zig");
const signature = @import("../signature.zig");
const workflow = @import("../../module/workflow.zig");

pub fn lower(self: *Lower, output: *Output, names: []const []const u8, units: anytype) Module.Error!void {
    var emitted: std.StringHashMapUnmanaged(void) = .empty;

    for (units) |raw| {
        const unit = if (std.meta.Elem(@TypeOf(units)) == Module.FunctionUnit) raw.unit() else raw;

        const id = switch (unit) {
            .function, .regular => |id| id,
            else => continue,
        };

        const function_row = @backingInt(id);

        if (function_row >= self.program.functions.count()) return error.InvalidFunction;

        const name = std.fs.path.stem(names[function_row]);

        if ((try emitted.getOrPut(self.allocator, name)).found_existing) continue;

        var selected = @import("../../functions/scope.zig").inherit(self, .Signature);
        var prototypes: signature.Prototypes = .{ .name = name, .regular = null, .value = null };

        const form = workflow.functionForm(
            self.program.functions.native_modules[function_row] != null,
            self.value_functions[function_row],
            unit == .regular,
        );

        if (form == .Native) {
            const declaration = ir.SignatureTable.read(&selected.program.functions, function_row);

            prototypes.regular = try @import("../../external.zig").prototype(&selected, &declaration, function_row);
        } else {
            try selected.selectFunction(id);
            if (form != .Value) prototypes.regular = try selected.prototype("signature", false);
            if (form != .Regular) prototypes.value = try selected.valuePrototype("signature");
        }

        try signature.append(&selected, output, prototypes, "_");
    }
}
