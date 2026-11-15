const std = @import("std");
const zx = @import("zx");
const Module = @import("../../artifact/model.zig").Module;
const rule = @import("generated_artifact_signature_structure");

pub fn valid(module: *const Module) bool {
    const Input = std.meta.Child(rule.Input);
    const Native = std.meta.Child(@FieldType(Input, "native_modules"));
    const Signatures = std.meta.Child(@FieldType(Input, "signatures"));
    const native = zx.columns.columns(Native, module.native_modules);
    const signatures = zx.columns.columns(Signatures, module.functions);

    const input: Input = .{
        .native_modules = &native,
        .signatures = &signatures,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch false;
}
