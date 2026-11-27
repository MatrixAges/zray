const std = @import("std");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const allocating = @import("generated_function_context_reserve");
const ResetForm = enum { Body, Adapter, StateView };

pub inline fn reset(self: *Lower, comptime form: ResetForm) void {
    self.reference_storage = .empty;

    if (form == .StateView) return;

    if (form == .Body) {
        self.projected_symbols = null;
        self.input_aliases = null;
    }

    self.uses_allocator = false;
    self.uses_context = false;
    self.uses_io = false;
    self.uses_process = false;

    if (form == .Adapter) self.allows_allocation = true;
}

pub fn reserve(self: *Lower) Lower.Error!void {
    const symbols = self.program.symbols.count();
    const expressions = self.program.expressions.count();

    if (!generated) {
        self.names = try self.allocator.alloc([]const u8, symbols);
        self.used = try self.allocator.alloc(bool, symbols);
        self.cache_reads = try self.allocator.alloc(u64, expressions);

        return;
    }

    return allocate(self, self.allocator, .Own, symbols, expressions);
}

pub fn allocate(self: *Lower, allocator: std.mem.Allocator, names: @FieldType(std.meta.Child(allocating.Input), "name_source"), symbols: usize, expressions: usize) Lower.Error!void {
    const input: std.meta.Child(allocating.Input) = .{
        .symbols = symbols,
        .expressions = expressions,
        .name_source = names,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const plan = allocating.executeValue(fixed.allocator(), &input) catch |err| return failure(err);

    if (plan.names_count != 0) {
        self.names = try allocator.alloc([]const u8, @intCast(plan.names_count));

        if (plan.initial_name) |first| self.names[0] = first;
    }

    self.used = try allocator.alloc(bool, @intCast(plan.used_count));
    self.cache_reads = try allocator.alloc(u64, @intCast(plan.reads_count));
}

pub fn clear(self: *Lower) Lower.Error!void {
    const entry = @import("generated_function_context_clear");
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const result = entry.executeValue(fixed.allocator(), .{
        .used_count = self.used.len,
        .read_count = self.cache_reads.len,
    }) catch |err| return failure(err);

    @memset(self.used, result.used_fill);
    @memset(self.cache_reads, result.read_fill);
}

pub fn selectPlan(self: *Lower, id: @import("zx").ir.FunctionId) void {
    const index = @backingInt(id);
    self.plan = self.plans[index];
    self.may_grow = if (index < self.growth_functions.len) self.growth_functions[index] else true;
}

pub fn prepare(self: *Lower, errors: ?[]const []const u8) Lower.Error!void {
    if (!generated) return seed(self, errors);

    const entry = @import("generated_function_context_prepare");

    const input: std.meta.Child(entry.Input) = .{
        .errors = errors,
        .count = self.names.len,
        .used_count = self.used.len,
        .read_count = self.cache_reads.len,
    };

    const result = entry.executeValue(self.allocator, &input) catch |err| return failure(err);

    @memcpy(self.names, result.names);
    @memset(self.used, result.used_fill);
    @memset(self.cache_reads, result.read_fill);

    self.allows_allocation = result.allows_allocation;
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
