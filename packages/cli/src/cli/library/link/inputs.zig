const std = @import("std");
const compiler = @import("compiler");
const collectInitializers = @import("rx_analysis").store.collectInitializers;
const analysis = @import("../analyze.zig");
const effects = @import("../workflow/effects.zig");
const Error = effects.Error;
const rules = @import("cli_source");

const Link = struct {
    analysis: *analysis.Result,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    failure: effects.Failure = .{},
    inputs: []compiler.library.Input = &.{},
    result: compiler.library.Result = undefined,
};

pub fn run(value: *analysis.Result, allocator: std.mem.Allocator) !compiler.library.Result {
    var link: Link = .{ .analysis = value, .allocator = allocator, .arena = .init(allocator) };
    const reference = &link;

    defer link.arena.deinit();

    rules.library_link.executeIn(allocator, &.{
        .link = @ptrCast(&reference),
        .has_compiled = value.compiled != null,
        .count = value.modules.len,
    }) catch |err| return link.failure.unwrap(err);

    return link.result;
}

pub fn sources(modules: []const analysis.Module, allocator: std.mem.Allocator) !std.ArrayList(compiler.project.Source) {
    var scratch = std.heap.ArenaAllocator.init(allocator);

    defer scratch.deinit();

    const temporary = scratch.allocator();
    const counts = try temporary.alloc(u64, modules.len);

    for (modules, counts) |module, *count| count.* = module.sources.len;

    const layout = rules.library_sources.executeValue(temporary, counts) catch |err| switch (@as(anyerror, err)) {
        error.Overflow => return error.OutOfMemory,
        else => return err,
    };

    const total = std.math.cast(usize, layout.total) orelse return error.OutOfMemory;
    const items = try allocator.alloc(compiler.project.Source, total);

    for (modules, layout.offsets) |module, offset| {
        @memcpy(items[@intCast(offset)..][0..module.sources.len], module.sources);
    }

    return .fromOwnedSlice(items);
}

pub fn takeCompiledLibrary(handle: *const anyopaque) void {
    const self = effects.state(Link, handle);

    self.result = self.analysis.compiled.?;
    self.analysis.compiled = null;
}

pub fn allocateLinkInputs(handle: *const anyopaque) Error!void {
    const self = effects.state(Link, handle);

    self.inputs = self.arena.allocator().alloc(compiler.library.Input, self.analysis.modules.len) catch |err| return self.failure.save(err);
}

pub fn prepareLibraryLinkInput(handle: *const anyopaque, index: u64) Error!void {
    const self = effects.state(Link, handle);
    const row: usize = @intCast(index);
    const module = &self.analysis.modules[row];

    if (module.analysis.value != .ir) return self.failure.save(error.InvalidAnalysis);

    const initializers = collectInitializers(self.arena.allocator(), module.store_definitions, &module.analysis.value.ir, module.analysis.public_functions) catch |err| return self.failure.save(err);

    self.inputs[row] = .{ .name = module.name, .analysis = &module.analysis, .borrowed_initializers = initializers };
}

pub fn linkLibraryInputs(handle: *const anyopaque) Error!void {
    const self = effects.state(Link, handle);

    self.result = compiler.library.link(self.allocator, self.inputs) catch |err| return self.failure.save(err);
}
