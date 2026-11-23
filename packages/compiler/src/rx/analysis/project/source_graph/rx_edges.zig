const rx = @import("rx");
const project = @import("frontend").project;
const Reference = @import("model.zig").Reference;
const dependency = rx.dependency_reference;
pub const collectZx = @import("zx_edges.zig").collect;
pub const collect = if (@import("rx_options").generated_graph) @import("references/scan.zig").collect else collectSeed;

pub fn collectSeed(collector: anytype, source: rx.ModuleSource) @TypeOf(collector.*).Error!void {
    var references: dependency.Iterator = .{};
    const temporary = collector.temporary.allocator();

    defer references.deinit(temporary);
    references.reset(&source.node, source.references);

    while (try references.next(temporary, false)) |selection| {
        const value = selection.attribute orelse return collector.fail(selection.node.location, "source dependency requires an explicit target");

        try referenceSeed(collector, source.path, selection, value, Reference.fromXml(selection.role));
    }
}

fn referenceSeed(collector: anytype, owner: []const u8, selection: dependency.Entry, value: *const rx.ast.Attribute, role: Reference) @TypeOf(collector.*).Error!void {
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

        return invalidPath(collector, value.value_location);
    };

    defer temporary.free(resolved);

    if (selection.target == .Store) return collector.store(resolved, value.value_location, owner);
    try local(collector, resolved, selection);
}

pub fn local(collector: anytype, path: []const u8, entry: dependency.Entry) @TypeOf(collector.*).Error!void {
    const attribute = entry.attribute.?;

    if (entry.role == .Call and entry.target == .Function) {
        if (project.module_path.callMember(attribute.value)) |member| {
            return collector.qualified(path, member, attribute.value_location);
        }
    }

    try collector.local(path, attribute.value_location, Reference.fromXml(entry.role));
}

fn invalidPath(collector: anytype, location: rx.ast.Location) @TypeOf(collector.*).Error {
    return collector.fail(location, "source dependency escapes the project root or is not a valid module path");
}
