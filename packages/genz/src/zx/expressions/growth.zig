const std = @import("std");
const Flags = @import("../uniqueness/root.zig").Flags;
const generated = @import("genz_options").generated_analysis;
const Mode = if (generated) @typeInfo(@typeInfo(@TypeOf(@import("generated_expression_growth").executeValue)).@"fn".return_type.?).error_union.payload else enum { Keep, Normalize, Renew };
const mode_count = 1 << @bitSizeOf(Flags);

pub inline fn select(flags: Flags) Mode {
    if (!generated) {
        if (flags.normalize) return .Normalize;
        if (flags.renew) return .Renew;

        return .Keep;
    }

    const policies = comptime table();

    return policies[@as(u8, @bitCast(flags))];
}

fn table() [mode_count]Mode {
    @setEvalBranchQuota(20_000);

    const entry = @import("generated_expression_growth");
    var result: [mode_count]Mode = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    for (&result, 0..) |*mode, flags| {
        mode.* = entry.executeValue(fixed.allocator(), flags) catch unreachable;
    }

    return result;
}
