const std = @import("std");
const Memory = @import("memory/maps");
const Bundle = std.zig.ErrorBundle;
const source = @import("backend_source");
const rule = source.validate;
const layout = source.diagnostic_constants.@"zx.constants";

comptime {
    checkLayout(Bundle.ErrorMessageList, &.{ "len", "start", "compile_log_text" }, layout.root_words);
    checkLayout(Bundle.ErrorMessage, &.{ "msg", "count", "src_loc", "notes_len" }, layout.message_words);
    checkLayout(Bundle.SourceLocation, &.{ "src_path", "line", "column", "span_start", "span_main", "span_end", "source_line", "reference_trace_len" }, layout.source_words);
    checkLayout(Bundle.ReferenceTrace, &.{ "decl_name", "src_loc" }, layout.trace_words);
}

fn checkLayout(comptime T: type, comptime names: []const []const u8, comptime width: u64) void {
    const fields = @typeInfo(T).@"struct".field_names;

    if (fields.len != width or fields.len != names.len) @compileError("Unexpected Zig diagnostic record width");

    inline for (fields, names) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) @compileError("Unexpected Zig diagnostic record field order");
    }
}

pub fn validate(allocator: std.mem.Allocator, bundle: Bundle) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var metrics: Memory.U64U32Map = .empty;
    const table = &metrics;

    const status = try rule.executeValue(arena.allocator(), &.{
        .metrics = @ptrCast(&table),
        .words = bundle.extra,
        .strings = bundle.string_bytes,
    });

    switch (status) {
        .Valid => {},
        .InvalidBackendProtocol => return error.InvalidBackendProtocol,
        .BackendDiagnosticsTooComplex => return error.BackendDiagnosticsTooComplex,
    }
}
