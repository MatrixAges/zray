const std = @import("std");
const c = @import("yaml");

const Token = struct {
    kind: i32,
    start: u64,
    end: u64,
    block_scalar: bool,
};

pub const Columns = struct {
    kinds: []const i32,
    starts: []const u64,
    ends: []const u64,
    block_scalars: []const bool,
};

pub fn read(allocator: std.mem.Allocator, source: []const u8) !Columns {
    var parser: c.yaml_parser_t = undefined;

    if (c.yaml_parser_initialize(&parser) == 0) return error.OutOfMemory;

    defer c.yaml_parser_delete(&parser);
    c.yaml_parser_set_input_string(&parser, source.ptr, source.len);

    var tokens: std.MultiArrayList(Token) = .empty;

    errdefer tokens.deinit(allocator);

    while (true) {
        var token: c.yaml_token_t = std.mem.zeroes(c.yaml_token_t);

        defer c.yaml_token_delete(&token);

        if (c.yaml_parser_scan(&parser, &token) == 0) {
            return if (parser.@"error" == c.YAML_MEMORY_ERROR) error.OutOfMemory else error.InvalidYamlLayout;
        }

        if (token.type == c.YAML_STREAM_END_TOKEN) break;

        const block = token.type == c.YAML_SCALAR_TOKEN and
            (token.data.scalar.style == c.YAML_LITERAL_SCALAR_STYLE or
                token.data.scalar.style == c.YAML_FOLDED_SCALAR_STYLE);

        try tokens.append(allocator, .{
            .kind = @intCast(token.type),
            .start = token.start_mark.index,
            .end = token.end_mark.index,
            .block_scalar = block,
        });
    }

    const columns = tokens.slice();

    return .{
        .kinds = columns.items(.kind),
        .starts = columns.items(.start),
        .ends = columns.items(.end),
        .block_scalars = columns.items(.block_scalar),
    };
}
