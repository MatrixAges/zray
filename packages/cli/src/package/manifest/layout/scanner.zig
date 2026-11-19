const std = @import("std");
const c = @import("yaml");
const Self = @This();

parser: *c.yaml_parser_t,
token: c.yaml_token_t = std.mem.zeroes(c.yaml_token_t),
pub fn deinit(self: *Self) void {
    c.yaml_token_delete(&self.token);
}

pub fn next(source: *const anyopaque) error{ OutOfMemory, InvalidYamlLayout }!i32 {
    const self = get(source);

    c.yaml_token_delete(&self.token);

    if (c.yaml_parser_scan(self.parser, &self.token) == 0) {
        return if (self.parser.@"error" == c.YAML_MEMORY_ERROR) error.OutOfMemory else error.InvalidYamlLayout;
    }

    return @intCast(self.token.type);
}

pub fn start(source: *const anyopaque) u64 {
    return get(source).token.start_mark.index;
}

pub fn end(source: *const anyopaque) u64 {
    return get(source).token.end_mark.index;
}

pub fn blockScalar(source: *const anyopaque) bool {
    const token = &get(source).token;

    return token.data.scalar.style == c.YAML_LITERAL_SCALAR_STYLE or token.data.scalar.style == c.YAML_FOLDED_SCALAR_STYLE;
}

fn get(source: *const anyopaque) *Self {
    return @ptrCast(@alignCast(@constCast(source)));
}
