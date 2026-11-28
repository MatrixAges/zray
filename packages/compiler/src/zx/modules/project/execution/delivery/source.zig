const zx = @import("zx");
const Frame = @import("frame.zig");
const Loading = @import("../../load/host.zig");

pub fn select(frame: *Frame) @typeInfo(@TypeOf(Loading.source)).@"fn".return_type.? {
    const project = frame.walk.project;

    return switch (frame.item) {
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
}

pub fn reject(frame: *Frame, action: anytype) error{InvalidSource}!void {
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
