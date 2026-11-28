const ir = @import("zx").ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");

pub fn proven(self: *const Lower, type_id: ir.TypeId, value: node.ExpressionId, selected: bool) bool {
    if (self.state_plan.referenced(type_id)) return true;
    if (selected or self.builder.nodes.get(value) != .object) return false;
    if (self.iteration_value != null or self.loop_fields != null) return false;

    const program = self.program;
    const expressions = program.expressions;
    const target = @backingInt(type_id);

    if (program.contracts.kinds.len != 0) return false;

    // Each site gets one slot in this activation. Loops and workers can reuse a site
    // while retaining an earlier result, so leave those frames on the ordinary path.
    if (expressions.iteration_initials.len != 0 or expressions.transform_kinds.len != 0) return false;

    const projected = for (expressions.projection_targets) |source| {
        if (expressions.types[source] == target) break true;
    } else false;

    if (!projected) for (expressions.call_arguments) |argument| {
        if (expressions.types[argument] == target) break;
    } else return false;

    var single = false;

    for (expressions.kinds, expressions.types) |kind, id| {
        if (id != target or kind != .Object) continue;
        if (single) return false;

        single = true;
    }

    const function = if (self.self_function) |id| @backingInt(id) else program.functions.count();

    return single and localUses(program, type_id, expressions, program.stores, program.output_type, function);
}

fn localUses(program: ir.Program, type_id: ir.TypeId, expressions: ir.ExpressionTable, stores: ir.StoreTable, output: ir.TypeId, function: usize) bool {
    if (expressions.task_bodies.len != 0 or expressions.parallel_first.len != 0) return false;
    if (contains(program, output, type_id)) return false;

    for (stores.types, stores.writable) |stored, writable| {
        if (writable and contains(program, @fromBackingInt(stored), type_id)) return false;
    }

    // A collection insertion can publish the record into a longer-lived backing buffer.
    for ([_][]const u32{ expressions.collection_arguments, expressions.update_values }) |operands| {
        for (operands) |operand| {
            if (contains(program, @fromBackingInt(expressions.types[operand]), type_id)) return false;
        }
    }

    // A synchronous ZX call can inspect the record's fields before this slot dies.
    // A native call needs its own lifetime contract to borrow the record's address.
    for (expressions.call_functions, expressions.call_arguments) |index, argument| {
        if (!contains(program, @fromBackingInt(expressions.types[argument]), type_id)) continue;
        if (index >= function or program.functions.native_modules[index] != null) return false;

        const callee = program.functions.at(index);

        if (callee.contracts.kinds.len != 0) return false;
        if (!localUses(program, type_id, callee.expressions, callee.stores, callee.output_type, index)) return false;
    }

    return true;
}

fn contains(program: ir.Program, id: ir.TypeId, target: ir.TypeId) bool {
    if (id == target) return true;

    switch (program.typeOf(id)) {
        .optional, .list => |child| return contains(program, child, target),
        .object => |fields| {
            for (0..fields.len) |index| {
                if (contains(program, fields.at(index).type_id, target)) return true;
            }
        },
        .tuple => |items| {
            for (0..items.len) |index| {
                if (contains(program, items.at(index), target)) return true;
            }
        },
        .task => |task| return contains(program, task.result, target),
        else => {},
    }

    return false;
}
