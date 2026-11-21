const Hash = @import("sha256_backend").Sha256;

fn destination(target: *const anyopaque) *[Hash.digest_length]u8 {
    const bytes: *const []u8 = @ptrCast(@alignCast(target));

    return bytes.*[0..Hash.digest_length];
}

pub fn into(target: *const anyopaque, input: []const u8) []const u8 {
    const output = destination(target);

    Hash.hash(input, output, .{});

    return output;
}

pub fn framedInto(target: *const anyopaque, prefix: []const u8, input: []const u8, suffix: []const u8) []const u8 {
    const output = destination(target);
    var hash = Hash.init(.{});

    hash.update(prefix);
    hash.update(input);
    hash.update(suffix);
    hash.final(output);

    return output;
}
