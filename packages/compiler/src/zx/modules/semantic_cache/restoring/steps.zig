const std = @import("std");
const generated = @import("parser_options").generated_parser;
const rule = if (generated) @import("generated_semantic_restore_transaction") else void;

const Step = if (generated) std.meta.Child(rule.Output) else enum {
    Admit,
    Rebind,
    Materialize,
    StageEntry,
    Verify,
};

const seed: [5]Step = .{ .Admit, .Rebind, .Materialize, .StageEntry, .Verify };

pub fn run() @TypeOf(seed) {
    if (!generated) return seed;

    var buffer: [256]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&buffer);
    const sequence = rule.executeValue(scratch.allocator(), {}) catch unreachable;

    if (sequence.len != seed.len) @panic("invalid semantic cache restoration schedule");

    return sequence[0..seed.len].*;
}
