pub const FunctionForm = enum { Native, Regular, RegularAndValue, Value };

pub fn functionForm(external: bool, value: bool, regular: bool) FunctionForm {
    if (external) return .Native;
    if (!value) return .Regular;

    return if (regular) .RegularAndValue else .Value;
}
