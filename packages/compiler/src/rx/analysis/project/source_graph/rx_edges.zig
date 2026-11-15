const rx = @import("rx");
const project = @import("frontend").project;
const Reference = @import("model.zig").Reference;
const dependency = rx.dependency_reference;

pub fn collect(collector: anytype, source: rx.ModuleSource) @TypeOf(collector.*).Error!void {
    var references: dependency.Iterator = .{};
    const temporary = collector.temporary.allocator();

    defer references.deinit(temporary);
    references.reset(&source.node, source.references);

    while (try references.next(temporary, false)) |selection| try reference(collector, source.path, selection);
}

fn reference(collector: anytype, owner: []const u8, selection: dependency.Entry) @TypeOf(collector.*).Error!void {
    const value = selection.attribute orelse return collector.fail(selection.node.location, "source dependency requires an explicit target");

    const role: Reference = switch (selection.role) {
        .Dependency => .dependency,
        .Call => .call,
        .TypeImport => .type_import,
    };

    if (selection.package_allowed) {
        const packages = collector.dependencies();
        const selected = project.matchPackage(packages, value.value, true);

        if (selected.first != null) return collector.import(value.value, value.value_location, role, selected);
    }

    const temporary = collector.temporary.allocator();

    const path = switch (selection.target) {
        .Module => rx.resolveModulePath(temporary, owner, value.value),
        .Function => rx.resolveFunctionPath(temporary, owner, value.value),
        .Store => rx.resolveStorePath(temporary, owner, value.value),
    };

    const resolved = path catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return collector.fail(value.value_location, "source dependency escapes the project root or is not a valid module path");
    };

    defer temporary.free(resolved);

    if (selection.target == .Store) return collector.store(resolved, value.value_location, owner);
    try collector.local(resolved, value.value_location, role);
}
