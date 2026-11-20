const std = @import("std");
const zx = @import("zx");
const generated = @import("genz_options").generated_analysis;
const entry = if (generated) @import("generated_module_entry_workflow") else void;
const functions = if (generated) @import("generated_module_function_workflow") else void;
const signatures = if (generated) @import("generated_signature_module_select") else void;

const EntryStep = if (generated) std.meta.Child(entry.Output) else enum {
    Standard,
    NativeImports,
    Types,
    Exports,
    Constants,
    Shape,
    Contracts,
    Store,
    Entry,
    ValueEntry,
    RequestedFunctions,
    ParallelAllocator,
    Comparisons,
};

pub const FunctionForm = if (generated) functions.Input else enum { Native, Regular, RegularAndValue, Value };

const FunctionStep = if (generated) std.meta.Child(functions.Output) else enum {
    Standard,
    Types,
    Store,
    NativeImport,
    NativeBody,
    RegularBody,
    ValueBody,
    ParallelAllocator,
    Comparisons,
};

pub fn entrySteps(comptime type_only: bool, comptime local: bool) []const EntryStep {
    if (generated) return zx.staticSequence(entry, &.{ .type_only = type_only, .local = local });

    const imports: []const EntryStep = if (local) &.{ .Standard, .NativeImports } else &.{.Standard};
    const header: []const EntryStep = imports ++ &[_]EntryStep{ .Types, .Exports, .Constants };

    if (type_only) return header;

    const functions_to_emit: []const EntryStep = if (local) &.{.RequestedFunctions} else &.{};

    return header ++ &[_]EntryStep{ .Shape, .Contracts, .Store, .Entry, .ValueEntry } ++ functions_to_emit ++ &[_]EntryStep{ .ParallelAllocator, .Comparisons };
}

pub fn functionSteps(comptime form: FunctionForm) []const FunctionStep {
    if (generated) return zx.staticSequence(functions, form);

    const body: []const FunctionStep = switch (form) {
        .Native => &.{ .NativeImport, .NativeBody },
        .Regular => &.{.RegularBody},
        .RegularAndValue => &.{ .RegularBody, .ValueBody },
        .Value => &.{.ValueBody},
    };

    return &[_]FunctionStep{ .Standard, .Types, .Store } ++ body ++ &[_]FunctionStep{ .ParallelAllocator, .Comparisons };
}

pub fn functionForm(external: bool, value: bool, regular: bool) FunctionForm {
    if (!generated) {
        if (external) return .Native;
        if (!value) return .Regular;

        return if (regular) .RegularAndValue else .Value;
    }

    const table = comptime variants();
    const index = variantIndex(external, value, regular);

    return table[index];
}

fn variantIndex(external: bool, value: bool, regular: bool) usize {
    return @as(usize, @intFromBool(external)) << 2 | @as(usize, @intFromBool(value)) << 1 | @intFromBool(regular);
}

fn variants() [8]FunctionForm {
    var forms: [8]FunctionForm = undefined;

    for (&forms, 0..) |*form, index| {
        var fixed = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(signatures.Input) = .{
            .external = index & 4 != 0,
            .value_function = index & 2 != 0,
            .pointer_variant = index & 1 != 0,
        };

        const selection = signatures.executeValue(fixed.allocator(), &input) catch unreachable;

        form.* = @fromBackingInt(@backingInt(selection.form));
    }

    return forms;
}
