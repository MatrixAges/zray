const std = @import("std");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;

pub fn reserve(self: *Lower) Lower.Error!void {
    const symbols = self.program.symbols.count();
    const expressions = self.program.expressions.count();

    if (!generated) {
        self.names = try self.allocator.alloc([]const u8, symbols);
        self.used = try self.allocator.alloc(bool, symbols);
        self.cache_reads = try self.allocator.alloc(u64, expressions);

        return;
    }

    const entry = @import("generated_function_context_reserve");

    const input: std.meta.Child(entry.Input) = .{
        .names = @ptrCast(&self.names),
        .used = @ptrCast(&self.used),
        .reads = @ptrCast(&self.cache_reads),
        .symbols = symbols,
        .expressions = expressions,
    };

    @import("zx").columns.invoke(entry.executeValue, self.allocator, &input) catch |err| return failure(err);
}

pub fn prepare(self: *Lower, errors: ?[]const []const u8) Lower.Error!void {
    if (!generated) return seed(self, errors);

    const entry = @import("generated_function_context_prepare");
    const names = self.names;
    const used = std.mem.sliceAsBytes(self.used);
    const reads = std.mem.sliceAsBytes(self.cache_reads);

    const input: std.meta.Child(entry.Input) = .{
        .errors = errors,
        .count = names.len,
        .target = @ptrCast(&names),
        .used = @ptrCast(&used),
        .used_bytes = used.len,
        .reads = @ptrCast(&reads),
        .read_bytes = reads.len,
    };

    self.allows_allocation = @import("zx").columns.invoke(entry.executeValue, self.allocator, &input) catch |err| return failure(err);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.Overflow, error.IntegerOverflow => error.OutOfMemory,
        else => unreachable,
    };
}

fn seed(self: *Lower, errors: ?[]const []const u8) Lower.Error!void {
    self.allows_allocation = @import("policy.zig").allowsAllocation(errors);

    for (self.names, 0..) |*name, index| name.* = if (index == 0) "in" else try std.fmt.allocPrint(self.allocator, "value_{d}", .{index});

    @memset(self.used, false);
    @memset(self.cache_reads, 0);
}
