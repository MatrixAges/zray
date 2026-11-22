const std = @import("std");
const rx = @import("rx");
const frontend = @import("frontend");
const prepare = @import("../../prepare.zig");
const Attributes = @import("../../../call/attributes.zig");
const target = @import("../../../call/target.zig");
const StoreCall = @import("../../../store/call.zig");
const availability = @import("../../../call/availability.zig");
const schedule = @import("../schedule.zig");
const Error = prepare.Loader.Error;

const Target = struct {
    kind: prepare.CalleeKind,
    row: usize,
    callee: prepare.Callee,
    local: bool,
};

pub fn bind(loader: *prepare.Loader, source: rx.ast.Node, previous_end: u32) Error!usize {
    const loop = std.mem.eql(u8, source.name, "Loop");
    const node = if (loop) source.children[0] else source;
    const index = loader.calls.len;
    var attributes: Attributes = undefined;
    var input: ?*const frontend.ExpressionInput.Result = null;
    var capability: StoreCall.Authorization = undefined;
    var selected: Target = undefined;

    inline for (comptime schedule.steps(.Call)) |step| switch (step) {
        .ScanCall => attributes = Attributes.scan(node),
        .ParseArgument => if (attributes.argument) |attribute| {
            input = try loader.inputs.parse(attribute.*, loader.owner);
        },
        .AuthorizeCall => {
            const result = try StoreCall.analyze(loader.allocator, loader.backing, loader.owner, attributes, loader.stores, input);

            capability = switch (result) {
                .authorized => |value| value,
                .diagnostic => |issue| {
                    loader.issue = issue;

                    return error.InvalidFlow;
                },
            };
        },
        .ResolveCallee => selected = try resolve(loader, node.location, attributes, capability),
        .PublishCall => {
            try loader.calls.append(loader.allocator, .{
                .node = node,
                .setter = capability.setter,
                .getters = capability.getters,
                .input = attributes.argument,
                .loop_condition = if (loop) target.borrowAttribute(source, "on") else null,
                .name_source = attributes.function orelse attributes.module.?,
                .target_kind = selected.kind,
                .target = selected.row,
                .callee = selected.callee,
            });

            loader.local_calls = loader.local_calls and selected.local;
        },
        .RecordArgument => if (input) |parsed| try loader.recordArgument(index, parsed),
        .BindPrevious => if (previous_end != 0) try @import("../previous_input.zig").bind(loader, index, previous_end - 1),
        else => unreachable,
    };

    return index;
}

fn resolve(loader: *prepare.Loader, location: rx.ast.Location, attributes: Attributes, capability: StoreCall.Authorization) Error!Target {
    const selected = loader.references.next(.call);
    const edge = selected.edge;

    const admission = availability.check(.{
        .target = switch (edge.target) {
            .source => .Source,
            .compiled => .Compiled,
            .native => .Native,
        },
        .named = edge.named,
        .declared_setter = attributes.setter != null,
        .setter = capability.setter != null,
        .ambient_store = loader.project.context.stores.len != 0,
    });

    const callee = switch (admission.route) {
        .Source, .AuthorizedSource => try loader.sourceCallee(edge.target.source, edge.location, admission.route == .AuthorizedSource),
        .NamedSource => try loader.namedCallee(edge.target.source, attributes.function.?),
        .Compiled => try loader.compiledCallee(attributes.module.?.value_location, edge.target.compiled, capability.setter != null),
        .NamedSetter => return loader.fail(attributes.function.?.value_location, "capability", "a named Call cannot grant a Store setter"),
        .NamedTarget => return loader.fail(attributes.function.?.value_location, "module", "a qualified Call.fn requires a ZX source module"),
        .Native => return loader.fail(edge.location, "module", "native and standard imports must use the interface registry"),
        .Denied => return loader.fail(location, "capability", "Store calls require explicit per-call authorization from module declarations"),
    };

    return .{
        .kind = switch (admission.route) {
            inline .Source, .NamedSource, .AuthorizedSource, .Compiled => |route| @field(prepare.CalleeKind, @tagName(route)),
            else => unreachable,
        },
        .row = if (edge.target == .source) edge.target.source else selected.row,
        .callee = callee,
        .local = admission.local,
    };
}
