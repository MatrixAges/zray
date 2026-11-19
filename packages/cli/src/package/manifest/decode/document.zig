const std = @import("std");
const c = @import("yaml");
const Map = @import("compiler").project.source_index.Map;
const Self = @This();
pub const Diagnostic = struct { line: usize, column: usize, message: []const u8 };

yaml: *c.yaml_document_t,
diagnostic: ?Diagnostic = null,
scratch: std.heap.ArenaAllocator = .init(std.heap.smp_allocator),
keys: Map = .empty,
pub fn node(document: *const anyopaque, id: i32, shape: anytype) std.meta.Child(@TypeOf(shape)) {
    return @ptrCast(c.yaml_document_get_node(get(document).yaml, id));
}

pub fn pairs(value: *const anyopaque) ?[]const i32 {
    const input = asNode(value);

    if (input.type != c.YAML_MAPPING_NODE) return null;

    const range = input.data.mapping.pairs;
    const length = (@intFromPtr(range.top) - @intFromPtr(range.start)) / @sizeOf(c.yaml_node_pair_t);

    if (length == 0) return &.{};

    comptime std.debug.assert(@sizeOf(c.yaml_node_pair_t) == 2 * @sizeOf(i32) and
        @offsetOf(c.yaml_node_pair_t, "key") == 0 and @offsetOf(c.yaml_node_pair_t, "value") == @sizeOf(i32));

    return @as([*]const i32, @ptrCast(range.start))[0 .. length * 2];
}

pub fn items(value: *const anyopaque) ?[]const i32 {
    const input = asNode(value);

    if (input.type != c.YAML_SEQUENCE_NODE) return null;

    const range = input.data.sequence.items;
    const length = (@intFromPtr(range.top) - @intFromPtr(range.start)) / @sizeOf(c.yaml_node_item_t);

    return if (length == 0) &.{} else range.start[0..length];
}

pub fn text(value: *const anyopaque) []const u8 {
    const scalar = asNode(value).data.scalar;

    return scalar.value[0..scalar.length];
}

pub fn stringScalar(value: *const anyopaque) ?[]const u8 {
    const input = asNode(value);

    return if (input.type == c.YAML_SCALAR_NODE and isTag(input, "tag:yaml.org,2002:str")) text(value) else null;
}

pub fn plain(value: *const anyopaque) bool {
    const input = asNode(value);

    return input.type == c.YAML_SCALAR_NODE and input.data.scalar.style == c.YAML_PLAIN_SCALAR_STYLE;
}

pub fn booleanTag(value: *const anyopaque) bool {
    const input = asNode(value);

    return isTag(input, "tag:yaml.org,2002:str") or isTag(input, "tag:yaml.org,2002:bool");
}

pub fn prepareKeys(document: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const self = get(document);

    _ = self.scratch.reset(.retain_capacity);
    self.keys = try Map.init(self.scratch.allocator(), @intCast(count));
}

pub fn claimKey(document: *const anyopaque, row: u64, key: []const u8) bool {
    return get(document).keys.claim(@intCast(row), key);
}

pub fn reject(document: *const anyopaque, value: *const anyopaque, message: []const u8) error{InvalidManifest}!void {
    const position = asNode(value).start_mark;

    get(document).diagnostic = .{ .line = position.line + 1, .column = position.column + 1, .message = message };

    return error.InvalidManifest;
}

pub fn packageName(value: []const u8) bool {
    return @import("pkgs").validName(value);
}

pub fn semanticVersion(value: []const u8) bool {
    _ = std.SemanticVersion.parse(value) catch return false;

    return true;
}

fn isTag(value: *const c.yaml_node_t, tag: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(value.tag), tag);
}

fn asNode(value: *const anyopaque) *const c.yaml_node_t {
    return @ptrCast(@alignCast(value));
}

fn get(document: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(document)));
}
