const std = @import("std");
const sources = @import("sources.zig");
const collection = @import("../rx/collection.zig");
const gateway = @import("../rx/gateway/analyze.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const State = @import("semantic.zig").State;
const LintGateway = @import("cli_abi").layouts.@"zig:lint_workflow_host".LintGateway;

pub fn checkSpecialSource(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    var context = self.context.*;
    const path = self.loaded.project.entry;
    const source = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.allocator, .limited(16 * 1024 * 1024)) catch |err| return self.failure.save(err);

    defer context.allocator.free(source);

    context.options.input = path;

    const status = @import("source.zig").check(context, source) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn collectLintStore(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const path = self.loaded.project.entry;
    const root = std.fs.path.resolve(context.allocator, &.{self.loaded.project.root_dir}) catch |err| return self.failure.save(err);
    const entry = std.fs.path.relative(context.allocator, root, null, root, path) catch |err| return self.failure.save(err);

    self.collection = collection.load(context.allocator, .{
        .io = context.io,
        .root = root,
        .entry = entry,
        .writer = context.stderr,
        .project = self.loaded.project,
    }) catch |err| return self.failure.save(err);

    return self.collection != null;
}

pub fn collectLintStoreTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;
    const loaded = &self.collection.?.data;

    self.functions = (@import("../rx/type_sources.zig").collect(context.allocator, .{
        .io = context.io,
        .project = self.loaded.project,
        .modules = loaded.modules,
        .stores = loaded.stores,
        .functions = loaded.functions,
        .writer = context.stderr,
    }) catch |err| return self.failure.save(err)) orelse return false;

    return true;
}

pub fn checkLintStoreTypes(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return @import("../rx/store_types.zig").validate(context.io, context.allocator, self.collection.?.data, self.functions, self.loaded.project, context.stderr) catch |err| self.failure.save(err);
}

pub fn analyzeLintGateway(handle: *const anyopaque) Error!*const LintGateway {
    const self = State.get(handle);
    const context = self.context;

    self.gateway = gateway.run(context.allocator, .{
        .io = context.io,
        .loaded = self.loaded,
        .writer = context.stderr,
    }) catch |err| return self.failure.save(err);

    self.gateway_view = .{ .valid = self.gateway != null, .services = null };

    if (self.gateway) |*analyzed| {
        if (analyzed.services) |*services| {
            self.gateway_view.services = sources.collectItems(context.allocator, services.modules, self.loaded.project.root_dir) catch |err| return self.failure.save(err);
        }
    }

    return &self.gateway_view;
}
