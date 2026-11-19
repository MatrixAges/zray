const std = @import("std");
const Decoder = @import("decode.zig");
const model = @import("model.zig");
const c = @import("yaml.zig").c;

pub fn decode(decoder: *Decoder, node: *const c.yaml_node_t) Decoder.Error![]const model.Export {
    const entries = try decoder.mapping(node);

    if (entries.len == 0) return decoder.fail(node, "exports must declare at least one public module");

    const result = try decoder.allocator.alloc(model.Export, entries.len);

    for (entries, result) |entry, *item| {
        const key = decoder.node(entry.key);
        const value = decoder.node(entry.value);
        const path = Decoder.keyText(key);

        if (!Decoder.validPath(path, .Export)) return decoder.fail(key, "export paths must be . or ./ followed by explicit module path segments");

        if (value.type == c.YAML_MAPPING_NODE) {
            const fields = try decoder.mapping(value);

            if (fields.len != 1 or Decoder.keyField(.Export, decoder.node(fields[0].key)) != .Module) return decoder.fail(value, "compiled exports require exactly one module field");

            item.* = .{ .path = try decoder.allocator.dupe(u8, path), .module = try decoder.scalar(decoder.node(fields[0].value)) };

            continue;
        }

        const source = try decoder.scalar(value);

        if (!Decoder.validPath(source, .Relative)) return decoder.fail(value, "export implementation must stay inside the package");

        item.* = .{ .path = try decoder.allocator.dupe(u8, path), .source = source };
    }

    return result;
}
