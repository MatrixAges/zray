const std = @import("std");
const Lower = @import("../lower.zig");
const generated = @import("genz_options").generated_analysis;
const allocating = @import("generated_function_context_reserve");
const resetting = if (generated) @import("generated_function_context_reset") else void;
const ResetForm = if (generated) resetting.Input else enum { Body, Adapter, StateView };

const ResetField = if (generated) std.meta.Child(resetting.Output) else enum {
    References,
    ProjectedSymbols,
    InputAliases,
    UsesAllocator,
    UsesContext,
    UsesIo,
    UsesProcess,
    AllowsAllocation,
};

pub inline fn reset(self: *Lower, comptime form: ResetForm) void {
    const fields: []const ResetField = comptime if (generated)
        @import("zx").staticSequence(resetting, form)

    else switch (form) {
        .Body => &.{ .References, .ProjectedSymbols, .InputAliases, .UsesAllocator, .UsesContext, .UsesIo, .UsesProcess },
        .Adapter => &.{ .References, .UsesAllocator, .UsesContext, .UsesIo, .UsesProcess, .AllowsAllocation },
        .StateView => &.{.References},
    };

    inline for (fields) |field| switch (field) {
        .References => self.reference_storage = .empty,
        .ProjectedSymbols => self.projected_symbols = null,
        .InputAliases => self.input_aliases = null,
        .UsesAllocator => self.uses_allocator = false,
        .UsesContext => self.uses_context = false,
        .UsesIo => self.uses_io = false,
        .UsesProcess => self.uses_process = false,
        .AllowsAllocation => self.allows_allocation = true,
    };
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
        .names = @ptrCast(&self.names),
        .used = @ptrCast(&self.used),
        .reads = @ptrCast(&self.cache_reads),
        .symbols = symbols,
        .expressions = expressions,
        .name_source = names,
    };

    @import("zx").columns.invoke(allocating.executeValue, allocator, &input) catch |err| return failure(err);
}

pub fn clear(self: *Lower) Lower.Error!void {
    const entry = @import("generated_function_context_clear");
    const used = std.mem.sliceAsBytes(self.used);
    const reads = std.mem.sliceAsBytes(self.cache_reads);

    const input: std.meta.Child(entry.Input) = .{
        .used = @ptrCast(&used),
        .used_bytes = used.len,
        .reads = @ptrCast(&reads),
        .read_bytes = reads.len,
    };

    @import("zx").columns.invoke(entry.executeValue, self.allocator, &input) catch |err| return failure(err);
}

pub fn selectPlan(self: *Lower, id: @import("zx").ir.FunctionId) void {
    const index = @backingInt(id);
    self.plan = self.plans[index];
    self.may_grow = if (index < self.growth_functions.len) self.growth_functions[index] else true;
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
