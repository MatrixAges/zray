const compiler = @import("compiler");
const c = @import("yaml.zig").c;
const model = @import("model.zig");
const Decoder = @import("decode.zig");
const Error = Decoder.Error;
const External = compiler.project.External;
const Implementation = @FieldType(External, "implementation");

pub fn decodeList(comptime T: type, decoder: *Decoder, value: *const c.yaml_node_t, comptime decode: fn (*Decoder, *const c.yaml_node_t) Error!T) Error![]const T {
    const items = try decoder.sequence(value);
    const output = try decoder.allocator.alloc(T, items.len);

    for (items, output) |item, *result| result.* = try decode(decoder, decoder.node(item));

    return output;
}

pub fn interface(decoder: *Decoder, value: *const c.yaml_node_t) Error!model.NativeInterface {
    var result: model.NativeInterface = .{ .specifier = "", .path = "", .module = "" };

    for (try decoder.mapping(value)) |entry| {
        const key = decoder.node(entry.key);
        const item = decoder.node(entry.value);

        switch (Decoder.keyField(.NativeInterface, key)) {
            .Specifier => result.specifier = try decoder.scalar(item),
            .Path => result.path = try decoder.scalar(item),
            .Module => result.module = try decoder.scalar(item),
            .Namespace => result.namespace = try decoder.strings(item),
            else => return decoder.fail(key, "unknown native interface field"),
        }
    }

    try decoder.require(value, .NativeInterface, .{
        .specifier = result.specifier.len != 0,
        .path = result.path.len != 0,
        .module = result.module.len != 0,
    });

    return result;
}

pub fn module(decoder: *Decoder, value: *const c.yaml_node_t) Error!model.NativeModule {
    var result: model.NativeModule = .{ .name = "" };

    for (try decoder.mapping(value)) |entry| {
        const key = decoder.node(entry.key);
        const item = decoder.node(entry.value);

        switch (Decoder.keyField(.NativeModule, key)) {
            .Name => result.name = try decoder.scalar(item),
            .Path => result.path = try decoder.scalar(item),
            .Header => result.header = try decoder.scalar(item),
            .Dependencies => result.dependencies = try decoder.strings(item),
            .BundleFiles => result.bundle_files = try decoder.strings(item),
            .IncludePaths => result.include_paths = try decoder.strings(item),
            .AbiAliases => result.abi_aliases = try decodeList(model.AbiAlias, decoder, item, abiAlias),
            else => return decoder.fail(key, "unknown native module field"),
        }
    }

    try decoder.require(value, .NativeModule, .{
        .name = result.name.len != 0,
        .path = result.path != null,
        .header = result.header != null,
    });

    return result;
}

fn abiAlias(decoder: *Decoder, value: *const c.yaml_node_t) Error!model.AbiAlias {
    var result: model.AbiAlias = .{ .name = "", .specifier = "" };

    for (try decoder.mapping(value)) |entry| {
        const key = decoder.node(entry.key);
        const text = try decoder.scalar(decoder.node(entry.value));

        switch (Decoder.keyField(.AbiAlias, key)) {
            .Name => result.name = text,
            .Specifier => result.specifier = text,
            else => return decoder.fail(key, "unknown native ABI alias field"),
        }
    }

    try decoder.require(value, .AbiAlias, .{
        .name = result.name.len != 0,
        .specifier = result.specifier.len != 0,
    });

    return result;
}

pub fn external(decoder: *Decoder, value: *const c.yaml_node_t) Error!External {
    var result: External = .{ .specifier = "", .signature = "", .implementation = .{ .module = "", .member = "" } };

    for (try decoder.mapping(value)) |entry| {
        const key = decoder.node(entry.key);
        const item = decoder.node(entry.value);

        switch (Decoder.keyField(.External, key)) {
            .Specifier => result.specifier = try decoder.scalar(item),
            .Signature => result.signature = try decoder.scalar(item),
            .ExportName => result.export_name = try decoder.scalar(item),
            .Implementation => result.implementation = try implementation(decoder, item),
            else => return decoder.fail(key, "unknown external interface field"),
        }
    }

    try decoder.require(value, .External, .{
        .specifier = result.specifier.len != 0,
        .signature = result.signature.len != 0,
        .module = result.implementation.module.len != 0,
        .member = result.implementation.member.len != 0,
    });

    return result;
}

fn implementation(decoder: *Decoder, value: *const c.yaml_node_t) Error!Implementation {
    var result: Implementation = .{ .module = "", .member = "" };

    for (try decoder.mapping(value)) |entry| {
        const key = decoder.node(entry.key);
        const item = decoder.node(entry.value);

        switch (Decoder.keyField(.Implementation, key)) {
            .Module => result.module = try decoder.scalar(item),
            .Member => result.member = try decoder.scalar(item),
            .AllocatorArgument => result.allocator_argument = try decoder.boolean(item),
            .IoArgument => result.io_argument = try decoder.boolean(item),
            .ProcessArgument => result.process_argument = try decoder.boolean(item),
            .ExpandTuple => result.expand_tuple = try decoder.boolean(item),
            .Errors => result.errors = try decoder.strings(item),
            .Fallible => result.fallible = try decoder.boolean(item),
            .Concurrent => result.concurrent = try decoder.boolean(item),
            else => return decoder.fail(key, "unknown external implementation field"),
        }
    }

    return result;
}
