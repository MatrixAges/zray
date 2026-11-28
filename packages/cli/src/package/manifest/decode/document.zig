const std = @import("std");
const c = @import("yaml");
const Map = @import("compiler").project.source_index.Map;
const Self = @This();
pub const Diagnostic = struct { line: usize, column: usize, message: []const u8 };

yaml: *c.yaml_document_t,
diagnostic: ?Diagnostic = null,
scratch: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
keys: Map = .empty,
pub fn borrowNodes(self: *const Self, allocator: std.mem.Allocator, comptime Node: type) std.mem.Allocator.Error![]const *const Node {
    const nodes = self.yaml.nodes;
    const count = (@intFromPtr(nodes.top) - @intFromPtr(nodes.start)) / @sizeOf(c.yaml_node_t);
    const views = try allocator.alloc(Node, count);
    const references = try allocator.alloc(*const Node, count);

    for (nodes.start[0..count], views, references) |*input, *view, *reference| {
        const scalar = input.type == c.YAML_SCALAR_NODE;
        const value = if (scalar) input.data.scalar.value[0..input.data.scalar.length] else "";
        const tag = std.mem.span(input.tag);
        const string_tag = std.mem.eql(u8, tag, "tag:yaml.org,2002:str");

        view.* = .{
            .pairs = pairs(input),
            .items = items(input),
            .scalar = if (scalar and string_tag) value else null,
            .text = value,
            .plain = scalar and input.data.scalar.style == c.YAML_PLAIN_SCALAR_STYLE,
            .boolean_tag = string_tag or std.mem.eql(u8, tag, "tag:yaml.org,2002:bool"),
            .line = input.start_mark.line + 1,
            .column = input.start_mark.column + 1,
        };

        reference.* = view;
    }

    return references;
}

fn pairs(input: *const c.yaml_node_t) ?[]const u32 {
    if (input.type != c.YAML_MAPPING_NODE) return null;

    const range = input.data.mapping.pairs;
    const length = (@intFromPtr(range.top) - @intFromPtr(range.start)) / @sizeOf(c.yaml_node_pair_t);

    if (length == 0) return &.{};

    comptime std.debug.assert(@sizeOf(c.yaml_node_pair_t) == 2 * @sizeOf(u32) and
        @offsetOf(c.yaml_node_pair_t, "key") == 0 and @offsetOf(c.yaml_node_pair_t, "value") == @sizeOf(u32));

    return @as([*]const u32, @ptrCast(range.start))[0 .. length * 2];
}

fn items(input: *const c.yaml_node_t) ?[]const u32 {
    if (input.type != c.YAML_SEQUENCE_NODE) return null;

    const range = input.data.sequence.items;
    const length = (@intFromPtr(range.top) - @intFromPtr(range.start)) / @sizeOf(c.yaml_node_item_t);

    return if (length == 0) &.{} else @as([*]const u32, @ptrCast(range.start))[0..length];
}

pub fn prepareKeys(document: *anyopaque, count: u64) std.mem.Allocator.Error!void {
    const self = get(document);

    _ = self.scratch.reset(.retain_capacity);
    self.keys = try Map.init(self.scratch.allocator(), @intCast(count));
}

pub fn claimKey(document: *anyopaque, row: u64, key: []const u8) bool {
    return get(document).keys.claim(@intCast(row), key);
}

pub fn reject(document: *anyopaque, value: anytype, message: []const u8) error{InvalidManifest}!void {
    get(document).diagnostic = .{ .line = @intCast(value.line), .column = @intCast(value.column), .message = message };

    return error.InvalidManifest;
}

pub fn packageName(value: []const u8) bool {
    return @import("pkgs").validName(value);
}

pub fn semanticVersion(value: []const u8) bool {
    _ = std.SemanticVersion.parse(value) catch return false;

    return true;
}

fn get(document: *anyopaque) *Self {
    return @ptrCast(@alignCast(document));
}
