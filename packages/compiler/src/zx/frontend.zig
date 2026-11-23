pub const ir = @import("zx").ir;
pub const grammar = @import("frontend/combinators.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @This(),
    @import("analysis/analyzer/host/publish.zig"),
    @import("analysis/publication/entry/host.zig"),
    @import("modules/artifact/prepared/root.zig"),
    @import("modules/compiled/imports.zig"),
    @import("modules/entry_body/host.zig"),
    @import("modules/link.zig"),
    @import("modules/parse_cache.zig"),
    @import("modules/project/execution/body.zig"),
    @import("modules/project/execution/delivery/bind.zig"),
    @import("modules/project/execution/delivery/route.zig"),
    @import("modules/project/execution/delivery/source.zig"),
    @import("modules/project/execution/entry.zig"),
    @import("modules/project/execution/legacy.zig"),
    @import("modules/project/execution/load.zig"),
    @import("modules/project/execution/native.zig"),
    @import("modules/project/execution/signatures/host.zig"),
    @import("modules/project/state/host.zig"),
    @import("modules/semantic_cache/entries.zig"),
    @import("modules/semantic_cache/native.zig"),
}).resolve;

pub const Parser = @import("frontend/parser.zig");
pub const parse = @import("frontend/parse.zig").parse;
pub const parseModule = @import("frontend/parse.zig").parseModule;
pub const parseAnalysisModule = @import("frontend/parse.zig").parseAnalysisModule;
pub const analyzeResolvedIn = @import("analysis/analyze.zig").analyzeResolvedIn;
pub const analyzeSharedBody = @import("analysis/analyze.zig").analyzeSharedBody;
pub const ResolvedResult = @import("analysis/analyze.zig").ResolvedResult;
pub const ResolvedImports = @import("modules/resolved.zig").Input;
pub const analyzeModule = @import("analysis/analyze.zig").analyzeModule;
pub const ParseResult = @import("frontend/parse.zig").Result;
pub const ExpressionInput = @import("frontend/expression_result.zig");
pub const parseExpressionInput = @import("frontend/parse_expression.zig").parseInput;
pub const parseBorrowedExpressionInput = @import("frontend/parse_expression.zig").parseBorrowedInput;
pub const parseExpression = @import("frontend/parse_expression.zig").parse;
pub const formatXml = @import("frontend/format_xml.zig").format;
pub const formatXmlText = @import("frontend/format_xml.zig").formatText;
pub const formatNative = @import("frontend/native_layout.zig").format;
pub const parseExpressionXml = @import("frontend/attribute.zig").parseXml;
pub const xml_document = @import("frontend/format_xml.zig");
pub const parseIndexedXml = @import("frontend/attribute.zig").parseIndexedXml;
pub const parseBorrowedIndexedXml = @import("frontend/attribute.zig").parseBorrowedIndexedXml;
pub const IndexedXml = @import("frontend/attribute.zig").IndexedXml;
pub const xml_references = @import("frontend/attribute.zig").references;
pub const stringExpression = @import("frontend/attribute.zig").string;
pub const object_selection = @import("frontend/object_selection.zig");
pub const ExpressionParseResult = @import("frontend/parse_expression.zig").Result;
pub const expressions = @import("analysis/expression.zig");
pub const analyze = @import("analysis/analyze.zig").analyze;
pub const AnalysisResult = @import("analysis/analyze.zig").Result;
pub const NominalType = @import("modules/nominal_origins.zig").Item;
pub const ir_validation_input = @import("ir/canonical/validation/input.zig");
pub const validateIr = @import("ir/validate.zig").validate;
pub const compare_ir = @import("ir/compare/function.zig");
pub const validateIrExtending = @import("ir/validate.zig").validateExtending;
pub const checks_internal_ir = @import("ir/validate.zig").internal;
pub const isParallelSafe = @import("ir/parallel.zig").programPure;
pub const isParallelSafeWithSuffix = @import("ir/parallel.zig").programPureWithSuffix;
pub const analyzeWithContext = @import("analysis/analyze.zig").analyzeWithContext;
pub const Context = @import("analysis/analyze.zig").Context;
pub const project = @import("modules/project.zig");
pub const publishSyntaxOrder = @import("frontend/retention/order.zig").publishSyntaxOrder;
pub const publishInterfaceTypes = @import("analysis/semantic/merging/commit.zig").publishInterfaceTypes;
pub const refreshResolvedNames = @import("analysis/semantic/resolving/host/names.zig").refreshResolvedNames;
pub const SourceIndex = @import("modules/source_index/growing.zig").Map;
pub const cache_retention = @import("modules/cache_retention.zig");
pub const types = @import("analysis/types.zig");
pub const reportTypeConstruction = @import("analysis/semantic/construction.zig").report;
pub const type_publication_view = @import("analysis/semantic/merging/publication/view.zig");
pub const type_views = @import("type_views");
pub const type_table = @import("analysis/type_table.zig");
pub const type_batch = @import("analysis/semantic/resolving/batch/host.zig");
pub const parseInteger = @import("analysis/integer.zig").parse;
pub const validateTypes = @import("ir/type_rules.zig").validate;
pub const validateNominalTypes = @import("analysis/semantic/origins.zig").valid;
pub const binding_path = @import("analysis/binding_path.zig");
pub const native_context = @import("modules/native_context.zig");
pub const native_link = @import("modules/link/native.zig");
pub const ArtifactNodes = @import("modules/artifact/nodes.zig");
pub const applyFunctionBody = @import("modules/entry_body/host.zig").applyBody;
pub const applyForwardedBody = @import("modules/entry_body/host.zig").applyForward;
pub const writeForwardEntry = @import("modules/forward_entry/host.zig").write;
pub const writeExternalEntry = @import("modules/function_body.zig").externalEntry;
pub const functionImportColumns = @import("analysis/analyzer/host/bindings.zig").imports;

pub const artifact_json = struct {
    pub const parse = @import("artifact_codec/json_scanner.zig").parse;
    pub const write = @import("artifact_codec/json_writer.zig").write;
};

pub const analyzeOwnership = @import("ownership/check.zig").analyze;
pub const analyzeOwnershipWithSuffix = @import("ownership/check.zig").analyzeWithSuffix;
pub const storesOwnValues = @import("ownership/stores.zig").check;
pub const constants = @import("analysis/constants/host.zig");
pub const copyConstant = @import("analysis/constants/copy.zig").copy;
pub const borrowConstant = @import("analysis/constants/input.zig").borrow;
pub const ConstantRows = @import("analysis/constants/columns.zig").Rows;
