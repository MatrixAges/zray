const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
const signatures = if (generated) @import("generated_signature_module_select") else void;

pub const FunctionForm = if (generated)
    @import("../expressions/evaluate.zig").Api.ModuleFunctionForm

else
    enum { Native, Regular, RegularAndValue, Value };

pub fn functionForm(external: bool, value: bool, regular: bool) FunctionForm {
    if (!generated) {
        if (external) return .Native;
        if (!value) return .Regular;

        return if (regular) .RegularAndValue else .Value;
    }

    const table = comptime variants();
    const index = variantIndex(external, value, regular);

    return table[index];
}

fn variantIndex(external: bool, value: bool, regular: bool) usize {
    return @as(usize, @intFromBool(external)) << 2 | @as(usize, @intFromBool(value)) << 1 | @intFromBool(regular);
}

fn variants() [8]FunctionForm {
    var forms: [8]FunctionForm = undefined;

    for (&forms, 0..) |*form, index| {
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(signatures.Input) = .{
            .external = index & 4 != 0,
            .value_function = index & 2 != 0,
            .pointer_variant = index & 1 != 0,
        };

        const selection = signatures.executeValue(fixed.allocator(), &input) catch unreachable;

        form.* = @fromBackingInt(@backingInt(selection.form));
    }

    return forms;
}
