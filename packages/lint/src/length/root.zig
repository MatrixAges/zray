const config = @import("lint_config");
pub const default_maximum: usize = 240;
pub const Exceeded = struct { lines: usize, maximum: usize };

pub fn check(text: []const u8, maximum: usize) ?Exceeded {
    const lines = config.checkLength(text, maximum) orelse return null;

    return .{ .lines = lines, .maximum = maximum };
}

pub fn count(text: []const u8) usize {
    return config.checkLength(text, null).?;
}
