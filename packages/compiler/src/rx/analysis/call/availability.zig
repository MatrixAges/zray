const std = @import("std");
const Signatures = @import("../project/references/signatures.zig");

pub const Input = struct {
    target: enum { Source, Compiled, Native },
    owner: usize,
    reference: []const u8,
    named: bool,
    declared_setter: bool,
    setter: bool,
    ambient_store: bool,
};

pub const Route = enum { Source, AuthorizedSource, NamedSource, NamedSetter, NamedTarget, Compiled, Native, Denied };
pub const Callee = enum { Unused, Module, Function, NamedFunction, MissingModule, InvalidNamedTarget, NamedStore, MissingNamedFunction, MissingSignature, MissingForward, SetterOnForward, TypeOnly, MissingStore };

const Plan = struct { callee: Callee, module: ?u64 = null, signature: ?u64 = null, member: ?u64 = null };

pub fn seed(input: Input) Route {
    if (input.named) {
        if (input.target != .Source) return .NamedTarget;

        return if (input.setter) .NamedSetter else .NamedSource;
    }

    return switch (input.target) {
        .Source => if (input.setter) .AuthorizedSource else .Source,
        .Compiled => if (input.declared_setter == input.setter and !input.ambient_store) .Compiled else .Denied,
        .Native => .Native,
    };
}

pub fn seedCallee(signatures: Signatures, route: Route, input: Input, name: []const u8) Plan {
    switch (route) {
        .Source, .AuthorizedSource, .NamedSource => {},
        else => return .{ .callee = .Unused },
    }

    const row = switch (signatures.graph.sources.at(input.owner)) {
        .rx => |module| return if (input.named) .{ .callee = .InvalidNamedTarget } else .{ .callee = .Module, .module = module },
        .store => return .{ .callee = if (input.named) .InvalidNamedTarget else .MissingModule },
        .zx => |source| Signatures.indexAt(signatures.indices, source) orelse return .{ .callee = .MissingSignature },
    };

    const signature = signatures.modules[row].signature;

    if (input.named) {
        const selected = @import("named.zig").signatureSeed(signature.members, name);

        if (selected.has_store) return .{ .callee = .NamedStore };

        return .{ .callee = if (selected.row == null) .MissingNamedFunction else .NamedFunction, .signature = row, .member = selected.row };
    }

    const forward = if (signatures.forwards.len != 0) signatures.forwards[row] else 0;

    if (forward != 0) {
        if (input.setter) return .{ .callee = .SetterOnForward };
        if (forward == std.math.maxInt(u64)) return .{ .callee = .MissingForward };

        return .{ .callee = .Module, .module = forward - 1 };
    }

    if (signature.type_only) return .{ .callee = .TypeOnly };
    if (input.setter and !signature.has_store) return .{ .callee = .MissingStore };

    return .{ .callee = .Function, .signature = row };
}
