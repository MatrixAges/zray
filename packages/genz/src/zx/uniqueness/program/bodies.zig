const std = @import("std");
const ir = @import("zx").ir;
const Function = @import("../function.zig");
const Growth = @import("../growth.zig");
const Memo = @import("../memo.zig");
const Order = @import("../order/seed.zig");
const Sites = @import("../sites/seed.zig");
const Slots = @import("../slots.zig");
const Summaries = @import("../summaries.zig");
const Digest = @import("../trace.zig").Digest;
const Error = std.mem.Allocator.Error;
const Self = @This();

program: *const ir.Program,
callees: []const []const u32,
identities: []const Digest,
units: []Unit,
pub fn init(allocator: std.mem.Allocator, program: *const ir.Program, callees: []const []const u32, identities: []const Digest) Error!Self {
    const units = try allocator.alloc(Unit, callees.len);

    @memset(units, Unit.init(allocator));

    return .{ .program = program, .callees = callees, .identities = identities, .units = units };
}

pub fn state(self: *const Self, summaries: *const Summaries, index: usize) Memo.State {
    const digest = if (self.identities.len != 0) self.identities[index] else @as(Digest, @splat(0));

    return .{ .identity = digest, .index = index, .input = input(summaries, index), .callees = self.callees[index], .growth = &self.units[index].growth };
}

pub fn analyze(self: *const Self, allocator: std.mem.Allocator, lasting: std.mem.Allocator, slots: Slots, summaries: *Summaries, index: usize, growth: ?*Growth.Store, record_reads: bool) Error!Function {
    return self.units[index].analyze(allocator, lasting, View.at(self.program, index), slots, summaries, growth, record_reads);
}

fn input(summaries: *const Summaries, index: usize) []const @import("../level.zig").Level {
    return if (index < summaries.input.len) summaries.input[index] else &.{};
}

pub const Unit = struct {
    passes: ?Function.PassesRef = null,
    growth: Growth.Store,
    pub fn init(allocator: std.mem.Allocator) Unit {
        return .{ .growth = Growth.init(allocator) };
    }

    pub fn analyze(self: *Unit, allocator: std.mem.Allocator, lasting: std.mem.Allocator, view: View, slots: Slots, summaries: *Summaries, growth: ?*Growth.Store, record_reads: bool) Error!Function {
        const unit: Function.Unit = .{
            .symbols = view.symbols,
            .expressions = view.expressions,
            .function = view.function,
            .input = if (view.function) |index| input(summaries, index) else &.{},
            .growth = growth orelse &self.growth,
        };

        const passes = self.passes orelse try self.prepare(lasting, allocator, &unit, view.control.block(), slots, summaries);

        return Function.initialize(allocator, unit, passes, slots, summaries, record_reads);
    }

    /// The owner outlives all later visits. Only the visiting thread or its claimed worker builds the facts.
    fn prepare(self: *Unit, owner: std.mem.Allocator, workspace: std.mem.Allocator, unit: *const Function.Unit, body: ir.Block, slots: Slots, summaries: *Summaries) Error!Function.PassesRef {
        const passes = if (@import("genz_options").generated_analysis)
            try @import("../function/prepared.zig").build(owner, workspace, unit, body, slots, summaries)
        else seed: {
            const kept = try owner.create(Function.Passes);

            kept.order = try Order.create(owner, unit.symbols.*, unit.expressions.*, body);
            kept.sites = try Sites.create(owner, &kept.order, slots, unit.symbols.*, unit.expressions.*, summaries);
            kept.operations = try Function.collectOperations(owner, &kept.order, unit.expressions.*);
            kept.rows = try Function.readRows(owner, unit.expressions.*);

            break :seed kept;
        };

        self.passes = passes;

        return passes;
    }
};

pub const View = struct {
    symbols: *const ir.SymbolTable,
    expressions: *const ir.ExpressionTable,
    control: ir.ControlBody,
    input_type: ir.TypeId,
    output_type: ir.TypeId,
    function: ?usize,
    pub fn at(program: *const ir.Program, index: usize) View {
        if (index == program.functions.count()) return .{
            .symbols = &program.symbols,
            .expressions = &program.expressions,
            .control = program.body,
            .input_type = program.input_type,
            .output_type = program.output_type,
            .function = null,
        };

        const functions = &program.functions;

        return .{
            .symbols = functions.symbols[index],
            .expressions = functions.expressions[index],
            .control = functions.controlAt(index),
            .input_type = @fromBackingInt(functions.input_types[index]),
            .output_type = @fromBackingInt(functions.output_types[index]),
            .function = index,
        };
    }
};
