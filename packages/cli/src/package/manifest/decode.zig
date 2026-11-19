const std = @import("std");
const zx = @import("zx");
const compiler = @import("compiler");
const rules = @import("cli_source");
const path_rule = rules.manifest_path;
const c = @import("yaml.zig").c;
const model = @import("model.zig");
const schema = @import("schema.zig");
const native = @import("native.zig");
const Decoder = @This();
pub const Error = error{ OutOfMemory, InvalidManifest };

allocator: std.mem.Allocator,
document: *c.yaml_document_t,
diagnostic: ?model.Diagnostic = null,
scratch: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
pub fn decode(self: *Decoder, root: *const c.yaml_node_t) Error!model.Manifest {
    const entries = try self.mapping(root);
    var result: model.Manifest = .{ .name = "", .version = "" };

    for (entries) |entry| {
        const key = self.node(entry.key);
        const value = self.node(entry.value);

        switch (keyField(.Manifest, key)) {
            .Name => result.name = try self.packageName(value),
            .Version => {
                result.version = try self.scalar(value);
                _ = std.SemanticVersion.parse(result.version) catch return self.fail(value, "version must be a semantic version");
            },
            .Entry => {
                result.entry = try self.scalar(value);

                if (!validPath(result.entry.?, .Entry)) return self.fail(value, "entry must be a package-relative .zx or .rx file path");
            },
            .Library => {
                result.library = try self.scalar(value);

                if (!validPath(result.library.?, .Relative)) return self.fail(value, "library must be a package-relative artifact path");
            },
            .Exports => result.exports = try @import("exports.zig").decode(self, value),
            .Private => result.private = try self.boolean(value),
            .Dependencies => result.dependencies = try self.dependencies(value),
            .DevDependencies => result.dev_dependencies = try self.dependencies(value),
            .Workspace => result.workspace = try self.workspace(value),
            .NativeInterfaces => result.native_interfaces = try native.decodeList(model.NativeInterface, self, value, native.interface),
            .NativeModules => result.native_modules = try native.decodeList(model.NativeModule, self, value, native.module),
            .Externals => result.externals = try native.decodeList(compiler.project.External, self, value, native.external),
            .Libraries => result.libraries = try self.strings(value),
            .IncludePaths => result.include_paths = try self.strings(value),
            .LibraryPaths => result.library_paths = try self.strings(value),
            else => return self.fail(key, "unknown pkg.yaml field"),
        }
    }

    if (schema.complete(&result)) |message| return self.fail(root, message);

    return result;
}

fn dependencies(self: *Decoder, value: *const c.yaml_node_t) Error![]const model.Dependency {
    const entries = try self.mapping(value);
    const result = try self.allocator.alloc(model.Dependency, entries.len);

    for (entries, result) |entry, *dependency| {
        dependency.* = .{
            .name = try self.packageName(self.node(entry.key)),
            .requirement = try self.scalar(self.node(entry.value)),
        };
    }

    return result;
}

fn workspace(self: *Decoder, value: *const c.yaml_node_t) Error!model.Workspace {
    const entries = try self.mapping(value);
    var packages: ?[]const []const u8 = null;

    for (entries) |entry| {
        const key = self.node(entry.key);

        if (keyField(.Workspace, key) != .Packages) return self.fail(key, "unknown workspace field");

        const list = self.node(entry.value);

        if (list.type != c.YAML_SEQUENCE_NODE) return self.fail(list, "workspace.packages must be a sequence");

        const items = list.data.sequence.items;
        const count = (@intFromPtr(items.top) - @intFromPtr(items.start)) / @sizeOf(c.yaml_node_item_t);
        const paths = try self.allocator.alloc([]const u8, count);

        for (paths, 0..) |*path, index| {
            const item = self.node(items.start[index]);

            path.* = try self.scalar(item);

            if (!validPath(path.*, .Workspace)) return self.fail(item, "workspace package patterns must stay inside the workspace");
        }

        packages = paths;
    }

    return .{ .packages = packages orelse return self.fail(value, "workspace requires packages") };
}

pub fn mapping(self: *Decoder, value: *const c.yaml_node_t) Error![]const c.yaml_node_pair_t {
    if (value.type != c.YAML_MAPPING_NODE) return self.fail(value, "expected a YAML mapping");

    const pairs = value.data.mapping.pairs;
    const count = (@intFromPtr(pairs.top) - @intFromPtr(pairs.start)) / @sizeOf(c.yaml_node_pair_t);
    const entries = if (count == 0) &.{} else pairs.start[0..count];

    if (entries.len < 2) {
        if (entries.len == 1) _ = try self.borrowScalar(self.node(entries[0].key));

        return entries;
    }

    const temporary = self.scratch.allocator();
    defer _ = self.scratch.reset(.retain_capacity);
    var seen = try compiler.project.source_index.Map.init(temporary, entries.len);

    for (entries, 0..) |entry, index| {
        const key_node = self.node(entry.key);
        const key = try self.borrowScalar(key_node);

        if (!seen.claim(index, key)) return self.fail(key_node, "duplicate YAML mapping key");
    }

    return entries;
}

fn packageName(self: *Decoder, value: *const c.yaml_node_t) Error![]const u8 {
    const name = try self.scalar(value);

    if (!@import("pkgs").validName(name)) return self.fail(value, "invalid package name; use lowercase name or @scope/name");

    return name;
}

pub fn scalar(self: *Decoder, value: *const c.yaml_node_t) Error![]const u8 {
    return self.allocator.dupe(u8, try self.borrowScalar(value));
}

fn borrowScalar(self: *Decoder, value: *const c.yaml_node_t) Error![]const u8 {
    const text = if (value.type == c.YAML_SCALAR_NODE and std.mem.eql(u8, std.mem.span(value.tag), "tag:yaml.org,2002:str")) scalarText(value) else null;
    const Input = std.meta.Child(rules.manifest_scalar.Input);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    if (zx.columns.invoke(rules.manifest_scalar.executeValue, empty.allocator(), &Input{ .text = text }) catch unreachable) |message| return self.fail(value, message);

    return text.?;
}

pub fn keyField(shape: schema.Mapping, key: *const c.yaml_node_t) schema.Field {
    return schema.field(shape, scalarText(key));
}

pub fn keyText(key: *const c.yaml_node_t) []const u8 {
    return scalarText(key);
}

fn scalarText(value: *const c.yaml_node_t) []const u8 {
    const scalar_value = value.data.scalar;

    return scalar_value.value[0..scalar_value.length];
}

pub fn boolean(self: *Decoder, value: *const c.yaml_node_t) Error!bool {
    const is_scalar = value.type == c.YAML_SCALAR_NODE;
    const plain = is_scalar and value.data.scalar.style == c.YAML_PLAIN_SCALAR_STYLE;
    const tag = if (plain) std.mem.span(value.tag) else "";
    const Input = std.meta.Child(rules.manifest_boolean.Input);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    const result = zx.columns.invoke(rules.manifest_boolean.executeValue, empty.allocator(), &Input{
        .plain = plain,
        .allowed_tag = std.mem.eql(u8, tag, "tag:yaml.org,2002:str") or std.mem.eql(u8, tag, "tag:yaml.org,2002:bool"),
        .text = if (plain) scalarText(value) else "",
    }) catch unreachable;

    if (result.diagnostic) |message| return self.fail(value, message);

    return result.value;
}

pub fn require(self: *Decoder, node_value: *const c.yaml_node_t, shape: schema.Mapping, fields: anytype) Error!void {
    var input: schema.Required = std.mem.zeroes(schema.Required);
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    input.mapping = shape;

    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| {
        @field(input, name) = @field(fields, name);
    }

    const request: *const schema.Required = &input;

    if (zx.columns.invoke(rules.manifest_required.executeValue, empty.allocator(), request) catch unreachable) |message| return self.fail(node_value, message);
}

pub fn strings(self: *Decoder, value: *const c.yaml_node_t) Error![]const []const u8 {
    const items = try self.sequence(value);
    const result = try self.allocator.alloc([]const u8, items.len);

    for (items, result) |item, *text| text.* = try self.scalar(self.node(item));

    return result;
}

pub fn sequence(self: *Decoder, value: *const c.yaml_node_t) Error![]const c.yaml_node_item_t {
    if (value.type != c.YAML_SEQUENCE_NODE) return self.fail(value, "expected a sequence");

    const items = value.data.sequence.items;
    const count = (@intFromPtr(items.top) - @intFromPtr(items.start)) / @sizeOf(c.yaml_node_item_t);

    return if (count == 0) &.{} else items.start[0..count];
}

pub fn node(self: Decoder, index: c_int) *const c.yaml_node_t {
    return c.yaml_document_get_node(self.document, index);
}

pub fn fail(self: *Decoder, value: *const c.yaml_node_t, message: []const u8) Error {
    self.diagnostic = .{ .line = value.start_mark.line + 1, .column = value.start_mark.column + 1, .message = message };

    return error.InvalidManifest;
}

pub fn validPath(text: []const u8, kind: @FieldType(@typeInfo(path_rule.Input).pointer.child, "kind")) bool {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    return path_rule.executeValue(empty.allocator(), &.{ .text = text, .kind = kind }) catch unreachable;
}
