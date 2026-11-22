const std = @import("std");
const zx = @import("zx");
const owner = @import("../../project.zig");
const Project = owner.Project;
const LoadFrame = owner.LoadFrame;
const Imported = owner.Imported;
const ParseCache = owner.ParseCache;
const Input = @import("../../module_input.zig");
const ModuleRecord = @import("../../module_record.zig");
const Target = @import("../target/host.zig");
const Loading = @import("host.zig");

pub fn run(self: *Project, index: usize, comptime phase: Loading.Phase) zx.Error!void {
    const frames = &self.load_frames;

    switch (Loading.admit(self.load_states, index, frames.items.len)) {
        .Skip => return,
        .Cycle => return self.dependencyCycle(),
        .Depth => return self.dependencyDepth(),
        .Push => try self.pushFrame(index),
    }

    var paths = std.heap.ArenaAllocator.init(self.arena.child_allocator);

    defer paths.deinit();

    var completed: ?usize = null;

    while (frames.items.len != 0) {
        const frame = &frames.items[frames.items.len - 1];
        self.current_source = frame.index;

        completed = switch (frame.parsed.result.*) {
            .native => |result| try loadInput(self, frame, Input.Native{ .value = result.value.parsed }, phase, completed, &paths),
            .indexed => |*result| if (ParseCache.indexed_enabled) try loadInput(self, frame, Input.Indexed{ .value = result }, phase, completed, &paths) else unreachable,
        };
    }
}

fn loadInput(self: *Project, frame: *LoadFrame, input: anytype, comptime phase: Loading.Phase, completed: ?usize, paths: *std.heap.ArenaAllocator) zx.Error!?usize {
    const header = input.header();
    const count = header.importCount();
    var row: usize = 0;

    if (completed) |child| {
        const suspended: usize = @intCast(frame.suspended_import);

        try resumeImport(self, frame, header, suspended, child, phase);

        row = suspended + 1;
    }

    while (row < count) : (row += 1) {
        if (try visitImport(self, frame, header, row, phase, paths)) |child| {
            _ = paths.reset(.free_all);

            try self.pushFrame(child);

            return null;
        }
    }

    _ = paths.reset(.free_all);

    if (phase == .signature) {
        try self.finishSignature(frame, input);
    } else try self.finishInput(frame, input);

    const parent = Loading.complete(self.load_states, frame.index, self.load_frames.items.len);

    frame.deinitScratch(self.arena.child_allocator);

    _ = self.load_frames.pop();

    return parent;
}

fn resumeImport(self: *Project, frame: *LoadFrame, header: anytype, row: usize, child: usize, phase: Loading.Phase) zx.Error!void {
    const item = owner.import_view.get(header, row);
    const loaded = &self.units[child];

    std.debug.assert(self.load_states[child] == .Done);

    try bindResolved(self, frame, item, phase, Project.importedSource(loaded, phase), .{ .source = loaded.path });
}

fn visitImport(self: *Project, frame: *LoadFrame, header: anytype, import_row: usize, phase: Loading.Phase, paths: *std.heap.ArenaAllocator) zx.Error!?usize {
    const unit = &self.units[frame.index];
    const item = owner.import_view.get(header, import_row);
    const scope = frame.packageScope(self.options.package_scopes, unit.path);
    const scoped = scope.nativeInterfaces(self.options.native_interfaces);
    const externals = scope.externals(self.options.externals);

    const route = switch (try Loading.route(self.arena.child_allocator, &frame.imported_names, self.options.internal_modules, scoped, externals, item)) {
        .duplicate => |name| return self.reporter.fail(.name, name.span, "duplicate import binding"),
        .selected => |selected| selected,
    };

    var path_buffer: [512]u8 = undefined;
    var path_memory = std.heap.BufferFirstAllocator.init(&path_buffer, paths.allocator());

    const resolved: Target.Resolved = target_block: {
        const target = switch (route) {
            .target => |target| target,
            .interface => |resolved| {
                switch (resolved) {
                    .native => |entry| {
                        try self.importNative(frame, entry.*, item);
                        if (phase == .body) try self.rememberImport(frame, item, .native, entry.key());
                    },
                    .legacy => |first| {
                        try self.importExternal(externals, first, item, &frame.imports);
                        if (phase == .body) try self.rememberImport(frame, item, .external, null);
                    },
                    .duplicate => return self.reporter.fail(.module, item.span, "duplicate native interface module"),
                    .conflict => return self.reporter.fail(.module, item.span, "native declarations conflict with legacy external signatures"),
                    .invalid_legacy => return self.reporter.fail(.module, item.span, "external interfaces require a default function import"),
                    .missing_legacy => return self.reporter.fail(.capability, item.span, "this module has no registered pure interfaces"),
                }

                return null;
            },
        };

        switch (target) {
            .Invalid => return self.reporter.fail(.module, item.span, "invalid or unknown import specifier"),
            .Intrinsic => {
                try self.importIntrinsic(frame, item);
                if (phase == .body) try self.rememberImport(frame, item, .intrinsic, null);

                return null;
            },
            .Interface => unreachable,
            .File, .Package => {
                const scratch = path_memory.allocator();

                break :target_block try Target.resolveIndexed(.{ .source = scratch, .compiled = scratch }, unit.path, item.path, target, self.options, scope, null, self.reporter, item.span);
            },
        }
    };

    defer _ = paths.reset(.retain_capacity);

    switch (resolved.target) {
        .source => |path| {
            const source_plan = Loading.source(self.options.source_index.?, self.load_states, .{
                .path = path,
                .phase = phase,
                .function_import = item.kind == .function,
                .exported = item.exported,
                .depth = self.load_frames.items.len,
                .row = resolved.source_row,
                .import_row = import_row,
                .cursor = &frame.suspended_import,
            });

            switch (source_plan.action) {
                .SkipSignature => return null,
                .DeferSignature => {
                    const retained = try self.allocator.dupe(u8, path);

                    try self.bindSignature(frame, item, .{ .exports = &.{}, .signatures = &.{.{ .name = "", .kind = .deferred, .source = retained }} });
                },
                .RejectRx => return self.reporter.fail(.module, item.span, "ZX package entry must be a .zx source file"),
                .Missing => return self.reporter.fail(.module, item.span, "import target is missing from the source set"),
                .Cycle => return self.dependencyCycle(),
                .Depth => return self.dependencyDepth(),
                .Descend => return source_plan.index,
                .Bind => {
                    const loaded = &self.units[source_plan.index.?];

                    try bindResolved(self, frame, item, phase, Project.importedSource(loaded, phase), .{ .source = loaded.path });
                },
            }
        },
        .compiled => |value| {
            const imported = try self.loadCompiled(value, item.span);

            try bindResolved(self, frame, item, phase, imported, .{ .compiled = value });
        },
    }

    return null;
}

fn bindResolved(self: *Project, frame: *LoadFrame, item: anytype, phase: Loading.Phase, imported: Imported, target: ModuleRecord.Target.Wire) zx.Error!void {
    self.current_source = frame.index;

    if (phase == .signature) return self.bindSignature(frame, item, imported);
    try self.bindBody(frame, item, imported, target);
    try self.rememberImport(frame, item, target, null);
}
