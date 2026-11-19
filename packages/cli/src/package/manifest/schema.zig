const std = @import("std");
const zx = @import("zx");
const rules = @import("cli_source");
const Manifest = @import("model.zig").Manifest;
const FieldInput = std.meta.Child(rules.manifest_field.Input);
pub const Mapping = @FieldType(FieldInput, "mapping");
pub const Field = rules.manifest_field.Output;
pub const Required = std.meta.Child(rules.manifest_required.Input);

pub fn field(mapping: Mapping, key: []const u8) Field {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rules.manifest_field.executeValue, empty.allocator(), &FieldInput{
        .mapping = mapping,
        .key = key,
    }) catch unreachable;
}

pub fn complete(manifest: *const Manifest) ?[]const u8 {
    const modules = zx.memory.borrowReadColumn(?[]const u8, "module", manifest.exports);
    const Input = std.meta.Child(rules.manifest_root.Input);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return zx.columns.invoke(rules.manifest_root.executeValue, empty.allocator(), &Input{
        .entry = manifest.entry != null,
        .library = manifest.library != null,
        .exports = manifest.exports.len,
        .modules = @ptrCast(&modules),
        .name = manifest.name.len != 0,
        .version = manifest.version.len != 0,
    }) catch unreachable;
}
