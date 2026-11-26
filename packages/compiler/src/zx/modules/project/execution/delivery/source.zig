const std = @import("std");
const zx = @import("zx");
const Project = @import("../../../project.zig").Project;
const Frame = @import("frame.zig");
const Loading = @import("../../load/host.zig");
const Action = @import("project_execution_abi").layouts.@"zig:project_host".ProjectSourceAction;
const Selection = @import("project_execution_abi").layouts.@"zig:project_host".ProjectSourceSelection;

pub fn selectProjectSource(handle: *anyopaque) *const Selection {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;

    const plan = switch (frame.item) {
        inline else => |item| Loading.source(project.options.source_index.?, project.load_states, .{
            .path = frame.resolved.target.source,
            .phase = frame.walk.phase,
            .function_import = item.kind == .function,
            .exported = item.exported,
            .depth = project.load_frames.items.len,
            .row = frame.resolved.source_row,
            .import_row = item.index,
            .cursor = &frame.active.suspended_import,
        }),
    };

    frame.selection = .{
        .action = zx.columns.view(Action, plan.action),
        .row = plan.index orelse 0,
    };

    return &frame.selection;
}

pub fn prepareProjectSource(handle: *anyopaque, row: u64) void {
    const frame = Frame.borrow(handle);
    const index: usize = @intCast(row);
    const project = frame.walk.project;
    const unit = &project.units[index];

    std.debug.assert(project.load_states[index] == .Done);

    frame.imported = Project.importedSource(unit, frame.walk.phase);
    frame.dependency = .{ .source = unit.path };
}

pub fn prepareDeferredProjectSignature(handle: *anyopaque) error{OutOfMemory}!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;
    const path = try project.allocator.dupe(u8, frame.resolved.target.source);
    frame.deferred = .{ .name = "", .kind = .deferred, .source = path };
    frame.imported = .{ .exports = &.{}, .signatures = @as(*[1]@TypeOf(frame.deferred), @ptrCast(&frame.deferred)) };
}

pub fn rejectProjectSource(handle: *anyopaque, action: Action) error{InvalidSource}!void {
    const frame = Frame.borrow(handle);
    const project = frame.walk.project;

    const span = switch (frame.item) {
        inline else => |item| item.span,
    };

    return @errorCast(switch (action) {
        .RejectRx => project.reporter.fail(.module, span, "ZX package entry must be a .zx source file"),
        .Missing => project.reporter.fail(.module, span, "import target is missing from the source set"),
        .Cycle => project.dependencyCycle(),
        .Depth => project.dependencyDepth(),
        else => unreachable,
    });
}
