const std = @import("std");
const zx = @import("zx");
const project = @import("../../../project.zig");
const Signature = @import("../../../source_signature.zig");
const exports = project.public_exports;

const Frame = struct {
    project: *project.Project,
    frame: *project.LoadFrame,
    unit: *project.Unit,
    fn read(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(state: *project.Project, frame: *project.LoadFrame, unit: *project.Unit) zx.Error!void {
    const generated = @import("generated_project_signature_publish");
    var publication: Frame = .{ .project = state, .frame = frame, .unit = unit };

    const input: std.meta.Child(generated.Input) = .{
        .signature = @ptrCast(&publication),
        .declared = !unit.signature.?.type_only,
        .members = frame.signature_members.items.len + frame.export_functions.items.len,
        .reexports = frame.export_aliases.items.len + frame.export_constants.items.len,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    generated.executeIn(empty.allocator(), &input) catch |err| return @import("../invoke.zig").errorSet(err);
}

pub fn installProjectSignatureMembers(handle: *const anyopaque, count: u64) std.mem.Allocator.Error!void {
    const state = Frame.read(handle);
    const signature = &state.unit.signature.?;
    const allocator = state.project.allocator;
    const members = try allocator.alloc(Signature.Member, @intCast(count));

    try Signature.publishMembers(allocator, signature, state.project.functions.stores.items, state.frame.signature_members.items, state.frame.export_functions.items, members);

    signature.members = members;
}

pub fn mergeProjectSignatureExports(handle: *const anyopaque) std.mem.Allocator.Error!void {
    const state = Frame.read(handle);
    const signature = &state.unit.signature.?;
    const allocator = state.project.allocator;
    signature.exports = try exports.merge(zx.ir.Export, allocator, signature.exports, state.frame.export_aliases.items);
    signature.constant_exports = try exports.merge(zx.ir.Constant, allocator, signature.constant_exports, state.frame.export_constants.items);
}

pub fn selectProjectSignatureEntry(handle: *const anyopaque) zx.Error!void {
    const state = Frame.read(handle);
    const owner = state.project;

    try exports.signatureEntry(owner.allocator, owner.arena.child_allocator, &state.unit.signature.?, owner.reporter);
}

pub fn publishProjectSignatureBindings(handle: *const anyopaque) void {
    const state = Frame.read(handle);

    publishBindings(state.unit, state.frame);
}

pub fn publishBindings(unit: *project.Unit, frame: *const project.LoadFrame) void {
    unit.signature_aliases = frame.aliases.items;
    unit.signature_imports = frame.imports.items;
    unit.signature_reexports = frame.export_functions.items;
    unit.signature_constant_imports = frame.constant_imports.items;
}
