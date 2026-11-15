pub const Form = enum { And, Or, Coalesce, Compare, Arithmetic, Not, NegativeLiteral, Negative, Conditional };

pub const Step = enum {
    Done,
    Boolean,
    Unknown,
    Expected,
    NegativeLiteral,
    Restrict,
    DeclareLeft,
    OptionalPayload,
    ExpectResult,
    InferLeft,
    InferRight,
    InferCondition,
    InferRightIfTrue,
    InferRightIfFalse,
    InferThirdIfFalse,
};

pub fn plan(form: Form) [5]Step {
    return switch (form) {
        .And => .{ .Boolean, .InferLeft, .InferRightIfTrue, .Done, .Done },
        .Or => .{ .Boolean, .InferLeft, .InferRightIfFalse, .Done, .Done },
        .Coalesce => .{ .DeclareLeft, .OptionalPayload, .ExpectResult, .InferRight, .Done },
        .Compare => .{ .Unknown, .Restrict, .InferLeft, .InferRight, .Boolean },
        .Arithmetic => .{ .Expected, .Restrict, .InferLeft, .InferRight, .Done },
        .Not => .{ .Boolean, .InferLeft, .Done, .Done, .Done },
        .NegativeLiteral => .{ .NegativeLiteral, .Done, .Done, .Done, .Done },
        .Negative => .{ .Unknown, .Restrict, .InferLeft, .Done, .Done },
        .Conditional => .{ .Expected, .InferCondition, .InferRightIfTrue, .InferThirdIfFalse, .Done },
    };
}
