const std = @import("std");
const Types = @import("../link/types.zig");
const ir = @import("zx").ir;
const model = @import("../compiled.zig");
pub const Error = std.mem.Allocator.Error || error{InvalidLibrary};
const LinkError = Error || error{ InvalidIr, ConflictingStore };

pub fn validate(allocator: std.mem.Allocator, library: model.Graph) Error!void {
    return check(allocator, library, false);
}

pub fn validateLinked(allocator: std.mem.Allocator, library: model.Graph) LinkError!void {
    return check(allocator, library, true);
}

fn check(allocator: std.mem.Allocator, library: model.Graph, comptime linked: bool) (if (linked) LinkError else Error)!void {
    const program = library.program;
    var temporary = std.heap.ArenaAllocator.init(allocator);

    defer temporary.deinit();

    const scratch = temporary.allocator();

    if (linked) {
        try validateStores(allocator, program.functions.stores);
        if (try @import("../../ir/validate.zig").validate(allocator, program) != null) return error.InvalidIr;
        try validateHeader(&program, library.exports.len);
    } else {
        try validateHeader(&program, library.exports.len);
        if (try @import("../../ir/validate.zig").validate(allocator, program) != null) return error.InvalidLibrary;
    }

    var types = Types.init(scratch) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return error.InvalidLibrary;
    };

    types.origins.seed(program.types, library.nominal_types) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return error.InvalidLibrary;
    };

    const declared = try scratch.alloc(bool, program.types.count());

    @memset(declared, false);

    for (0..library.nominal_types.count()) |origin_index| {
        const item = library.nominal_types.at(origin_index);

        declared[@backingInt(item.type_id)] = true;

        if (program.typeOf(item.type_id) == .native_reference) {
            const owner = ir.nativeReferenceOwner(program, item.type_id) orelse return error.InvalidLibrary;

            if (!std.mem.eql(u8, owner, item.origin.native)) return error.InvalidLibrary;
        }
    }

    for (0..program.types.count(), declared) |view_index, present| {
        const value = program.types.at(view_index);

        if (value.nominalName() != null and !present) return error.InvalidLibrary;
    }

    try @import("initializers.zig").validate(scratch, library);

    var names: std.StringHashMapUnmanaged(void) = .empty;

    for (library.exports) |exported| {
        if (!text(exported.name) or !text(exported.path)) return error.InvalidLibrary;
        if ((try names.getOrPut(scratch, exported.name)).found_existing) return error.InvalidLibrary;

        if (exported.function) |id| {
            if (@backingInt(id) >= program.functions.count()) return error.InvalidLibrary;

            const function = program.functions.at(@backingInt(id));

            if (function.external != null) return error.InvalidLibrary;
        }

        if (!@import("../../analysis/constants/input.zig").nativeValid(program.types, exported.constants)) return error.InvalidLibrary;

        var type_names: std.StringHashMapUnmanaged(void) = .empty;

        for (exported.constants) |item| {
            if (!text(item.name) or (try type_names.getOrPut(scratch, item.name)).found_existing) return error.InvalidLibrary;
        }

        for (exported.members) |member| {
            if ((!text(member.name) and !(member.name.len == 0 and member.intrinsic != null)) or member.namespace != null or !member.valid()) return error.InvalidLibrary;
            if ((try type_names.getOrPut(scratch, member.name)).found_existing) return error.InvalidLibrary;
            if (member.intrinsic != null) continue;
            if (@backingInt(member.id.?) >= program.functions.count()) return error.InvalidLibrary;

            const function = program.functions.at(@backingInt(member.id.?));

            if (member.input_type != function.input_type or member.output_type != function.output_type) return error.InvalidLibrary;
        }

        for (exported.types) |item| {
            if (!text(item.name) or @backingInt(item.type_id) >= program.types.count()) return error.InvalidLibrary;

            if (exported.function) |id| {
                const function = program.functions.at(@backingInt(id));

                if (std.mem.eql(u8, item.name, "Input") and item.type_id != function.input_type) return error.InvalidLibrary;
                if (std.mem.eql(u8, item.name, "Output") and item.type_id != function.output_type) return error.InvalidLibrary;
            }

            if ((try type_names.getOrPut(scratch, item.name)).found_existing) return error.InvalidLibrary;
        }
    }

    if (!linked) validateStores(scratch, program.functions.stores) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ConflictingStore => return error.InvalidLibrary,
    };
}

fn validateStores(allocator: std.mem.Allocator, tables: []const *const ir.StoreTable) (std.mem.Allocator.Error || error{ConflictingStore})!void {
    var seen: std.StringHashMapUnmanaged(u32) = .empty;

    defer seen.deinit(allocator);

    for (tables) |table| {
        for (table.paths, table.types) |path, type_id| {
            const entry = try seen.getOrPut(allocator, path);

            if (entry.found_existing and entry.value_ptr.* != type_id) return error.ConflictingStore;

            entry.value_ptr.* = type_id;
        }
    }
}

pub fn validateHeader(program: *const ir.Program, public_count: usize) error{InvalidLibrary}!void {
    if (!program.type_only or program.exports.len != 0 or program.constant_exports.len != 0 or program.stores.count() != 0 or public_count == 0) return error.InvalidLibrary;
}

fn text(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}
