use oxc_allocator::{Allocator, Box as OxcBox, Vec as OxcVec};
use oxc_ast::{ast::*, builder::AstBuilder};
use oxc_codegen::{Codegen, CodegenReturn};
use oxc_span::{SourceType, SPAN};
use oxc_str::{Ident, JSStr, JSStrBuilder, Str as OxcStr};
use oxc_syntax::{
    number::{BigintBase, NumberBase},
    operator::{
        AssignmentOperator, BinaryOperator, LogicalOperator, UnaryOperator, UpdateOperator,
    },
};
use rustler::{Encoder, Env, NifResult, Term};

use crate::atoms;
use crate::error::error_to_term;
use crate::stack::run_nif_with_large_stack;

mod a {
    rustler::atoms! {
        r#type = "type",
        block, body, expression, argument, arguments, left, right, operator,
        test, consequent, alternate, init, update, object, callee,
        optional, computed, name, value, raw, cooked, tail,
        declarations, kind, id, params, rest, generator,
        async_field = "async", await_field = "await",
        source, specifiers, imported, exported, local, declaration,
        properties, elements, key, shorthand, method, quasis, expressions,
        tag, quasi, prefix, delegate, label, cases, handler, param,
        finalizer, discriminant, super_class = "superClass",
        meta, property, regex, pattern, flags, bigint,
        static_field = "static",

        // node types
        program, expression_statement, block_statement, return_statement,
        variable_declaration, function_declaration, class_declaration,
        if_statement, for_statement, for_in_statement, for_of_statement,
        while_statement, do_while_statement, switch_statement, try_statement,
        throw_statement, break_statement, continue_statement,
        labeled_statement, empty_statement, debugger_statement, with_statement,
        import_declaration, export_named_declaration,
        export_default_declaration, export_all_declaration,

        identifier, identifier_reference, literal,
        numeric_literal, string_literal, boolean_literal, null_literal,
        big_int_literal, reg_exp_literal,
        binary_expression, logical_expression, unary_expression,
        update_expression, assignment_expression, conditional_expression,
        call_expression, new_expression,
        member_expression, static_member_expression, computed_member_expression,
        chain_expression, object_expression, array_expression,
        arrow_function_expression, function_expression, class_expression,
        template_literal, tagged_template_expression,
        sequence_expression, this_expression,
        super_expr = "super",
        await_expression, yield_expression, import_expression,
        meta_property, parenthesized_expression,
        spread_element, rest_element,
        object_pattern, array_pattern, assignment_pattern,
        import_specifier, import_default_specifier, import_namespace_specifier,
        export_specifier,
        method_definition, property_definition, static_block,
    }
}

type R<T> = Result<T, String>;

fn err<T>(msg: impl Into<String>) -> R<T> {
    Err(msg.into())
}

include!("generated_term_helpers.rs");
include!("generated_ast_decoders.rs");

fn oxc_s<'a>(b: &AstBuilder<'a>, s: &str) -> OxcStr<'a> {
    OxcStr::from_str_in(s, b)
}

fn ident_name<'a>(b: &AstBuilder<'a>, s: &str) -> IdentifierName<'a> {
    IdentifierName::new(SPAN, Ident::from_str_in(s, b), b)
}

fn js_string_value<'a>(b: &AstBuilder<'a>, term: Term<'_>) -> R<JSStr<'a>> {
    let binary = term
        .decode_as_binary()
        .map_err(|_| "Expected a JavaScript string binary".to_string())?;
    let mut bytes = binary.as_slice();
    let mut value = JSStrBuilder::with_capacity_in(bytes.len(), b);
    loop {
        match std::str::from_utf8(bytes) {
            Ok(suffix) => {
                value.push_str(suffix);
                return Ok(value.into_js_str());
            }
            Err(error) => {
                let prefix = std::str::from_utf8(&bytes[..error.valid_up_to()])
                    .map_err(|_| "Invalid JavaScript string bytes".to_string())?;
                value.push_str(prefix);
                bytes = &bytes[error.valid_up_to()..];
                match bytes {
                    [0xed, second @ 0xa0..=0xbf, third @ 0x80..=0xbf, rest @ ..] => {
                        let surrogate =
                            0xd000 | ((*second as u16 & 0x3f) << 6) | (*third as u16 & 0x3f);
                        value.push_code_unit(surrogate);
                        bytes = rest;
                    }
                    _ => return err("Invalid UTF-8/WTF-8 JavaScript string bytes"),
                }
            }
        }
    }
}

fn beam_str_lit<'a>(b: &AstBuilder<'a>, term: Term<'_>) -> R<StringLiteral<'a>> {
    Ok(StringLiteral::new(SPAN, js_string_value(b, term)?, None, b))
}

fn module_source_lit<'a>(b: &AstBuilder<'a>, term: Term<'_>) -> R<StringLiteral<'a>> {
    let binary = term
        .decode_as_binary()
        .map_err(|_| "Expected a module source string binary".to_string())?;
    // Preserve the module-source contract: only UTF-8 module names are supported.
    let value = std::str::from_utf8(binary.as_slice())
        .map_err(|_| "Codegen does not support non-UTF-8 module source strings".to_string())?;
    Ok(StringLiteral::new(
        SPAN,
        JSStr::from_str_in(value, b),
        None,
        b,
    ))
}

fn opt_binding_id<'a>(b: &AstBuilder<'a>, term: Term) -> Option<BindingIdentifier<'a>> {
    opt(term, a::id()).map(|t| {
        let n = str_val(t, a::name());
        BindingIdentifier::new(SPAN, Ident::from_str_in(&n, b), b)
    })
}

fn static_member<'a>(
    b: &AstBuilder<'a>,
    object: Expression<'a>,
    prop: &str,
    optional: bool,
) -> Expression<'a> {
    Expression::StaticMemberExpression(OxcBox::new_in(
        StaticMemberExpression::new(SPAN, object, ident_name(b, prop), optional, b),
        b,
    ))
}

fn computed_member<'a>(
    b: &AstBuilder<'a>,
    object: Expression<'a>,
    prop: Expression<'a>,
    optional: bool,
) -> Expression<'a> {
    Expression::ComputedMemberExpression(OxcBox::new_in(
        ComputedMemberExpression::new(SPAN, object, prop, optional, b),
        b,
    ))
}

// ── NIF entry point ──

#[rustler::nif(schedule = "DirtyCpu")]
pub fn codegen<'a>(env: Env<'a>, ast: Term<'a>) -> NifResult<Term<'a>> {
    // Decoding the AST term and printing it both recurse with AST depth.
    run_nif_with_large_stack(env, &[ast], |env, args| {
        let allocator = Allocator::default();
        let b = AstBuilder::new(&allocator);

        let input = decode_program_input(args[0])?;

        match build_program(&b, input.body) {
            Ok(program) => {
                let CodegenReturn { code, .. } = Codegen::new().build(&program);
                Ok((atoms::ok(), code).encode(env))
            }
            Err(msg) => error_to_term(env, &[msg]),
        }
    })
}

// ── Program ──

fn build_program<'a>(b: &AstBuilder<'a>, body_terms: Vec<Term>) -> R<Program<'a>> {
    let body = build_stmts(b, body_terms)?;
    Ok(Program::new(
        SPAN,
        SourceType::mjs(),
        "",
        OxcVec::new_in(b),
        None,
        OxcVec::new_in(b),
        body,
        b,
    ))
}

// ── Statements ──

fn build_stmt<'a>(b: &AstBuilder<'a>, term: Term) -> R<Statement<'a>> {
    let ty = type_atom(term).ok_or_else(|| "Missing :type on statement".to_string())?;

    if ty == a::expression_statement() {
        return Ok(Statement::new_expression_statement(
            SPAN,
            build_expr(b, get(term, a::expression()).ok_or("Missing :expression")?)?,
            b,
        ));
    }
    if ty == a::block_statement() {
        return Ok(Statement::new_block_statement(
            SPAN,
            build_stmts(b, list_val(term, a::body()))?,
            b,
        ));
    }
    if ty == a::return_statement() {
        return Ok(Statement::new_return_statement(
            SPAN,
            opt_expr(b, term, a::argument())?,
            b,
        ));
    }
    if ty == a::throw_statement() {
        return Ok(Statement::new_throw_statement(
            SPAN,
            build_expr(b, get(term, a::argument()).ok_or("Missing :argument")?)?,
            b,
        ));
    }
    if ty == a::empty_statement() {
        return Ok(Statement::new_empty_statement(SPAN, b));
    }
    if ty == a::debugger_statement() {
        return Ok(Statement::new_debugger_statement(SPAN, b));
    }

    if ty == a::variable_declaration() {
        return Ok(Statement::from(build_var_decl(b, term)?));
    }
    if ty == a::function_declaration() {
        return Ok(Statement::from(build_fn_decl(b, term)?));
    }
    if ty == a::class_declaration() {
        return Ok(Statement::from(build_class_decl(b, term)?));
    }

    if ty == a::if_statement() {
        let input = decode_if_statement_input(term)?;
        let test = build_expr(b, input.test)?;
        let cons = build_stmt(b, input.consequent)?;
        let alt = match input.alternate {
            Some(t) if !is_nil(t) => Some(build_stmt(b, t)?),
            _ => None,
        };
        return Ok(Statement::new_if_statement(SPAN, test, cons, alt, b));
    }
    if ty == a::for_statement() {
        let init = match opt(term, a::init()) {
            Some(t) if type_eq(t, a::variable_declaration()) => Some(
                ForStatementInit::VariableDeclaration(build_var_decl_boxed(b, t)?),
            ),
            Some(t) => Some(ForStatementInit::from(build_expr(b, t)?)),
            None => None,
        };
        let test = opt_expr(b, term, a::test())?;
        let update = opt_expr(b, term, a::update())?;
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        return Ok(Statement::new_for_statement(
            SPAN, init, test, update, body, b,
        ));
    }
    if ty == a::for_in_statement() {
        let left = build_for_left(b, get(term, a::left()).ok_or("Missing :left")?)?;
        let right = build_expr(b, get(term, a::right()).ok_or("Missing :right")?)?;
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        return Ok(Statement::new_for_in_statement(SPAN, left, right, body, b));
    }
    if ty == a::for_of_statement() {
        let aw = bool_val(term, a::await_field());
        let left = build_for_left(b, get(term, a::left()).ok_or("Missing :left")?)?;
        let right = build_expr(b, get(term, a::right()).ok_or("Missing :right")?)?;
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        return Ok(Statement::new_for_of_statement(
            SPAN, aw, left, right, body, b,
        ));
    }
    if ty == a::while_statement() {
        let test = build_expr(b, get(term, a::test()).ok_or("Missing :test")?)?;
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        return Ok(Statement::new_while_statement(SPAN, test, body, b));
    }
    if ty == a::do_while_statement() {
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        let test = build_expr(b, get(term, a::test()).ok_or("Missing :test")?)?;
        return Ok(Statement::new_do_while_statement(SPAN, body, test, b));
    }
    if ty == a::switch_statement() {
        let disc = build_expr(
            b,
            get(term, a::discriminant()).ok_or("Missing :discriminant")?,
        )?;
        let cases_list = list_val(term, a::cases());
        let mut cases = OxcVec::with_capacity_in(cases_list.len(), b);
        for c in &cases_list {
            let test = opt_expr(b, *c, a::test())?;
            let cons = build_stmts(b, list_val(*c, a::consequent()))?;
            cases.push(SwitchCase::new(SPAN, test, cons, b));
        }
        return Ok(Statement::new_switch_statement(SPAN, disc, cases, b));
    }
    if ty == a::try_statement() {
        let block_term = opt(term, a::block())
            .or_else(|| opt(term, a::body()))
            .ok_or("Missing try body")?;
        let block = build_block(b, block_term)?;
        let handler = match opt(term, a::handler()) {
            Some(h) => {
                let param = match opt(h, a::param()) {
                    Some(p) => Some(CatchParameter::new(SPAN, build_binding_pat(b, p)?, None, b)),
                    None => None,
                };
                let hbody = build_block(b, get(h, a::body()).ok_or("Missing catch body")?)?;
                Some(CatchClause::new(SPAN, param, OxcBox::new_in(hbody, b), b))
            }
            None => None,
        };
        let finalizer = match opt(term, a::finalizer()) {
            Some(f) => Some(build_block(b, f)?),
            None => None,
        };
        return Ok(Statement::new_try_statement(
            SPAN,
            OxcBox::new_in(block, b),
            handler.map(|h| OxcBox::new_in(h, b)),
            finalizer.map(|f| OxcBox::new_in(f, b)),
            b,
        ));
    }
    if ty == a::break_statement() {
        return Ok(Statement::new_break_statement(SPAN, opt_label(b, term), b));
    }
    if ty == a::continue_statement() {
        return Ok(Statement::new_continue_statement(
            SPAN,
            opt_label(b, term),
            b,
        ));
    }
    if ty == a::labeled_statement() {
        let lt = get(term, a::label()).ok_or("Missing :label")?;
        let label = LabelIdentifier::new(SPAN, Ident::from_str_in(&str_val(lt, a::name()), b), b);
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        return Ok(Statement::new_labeled_statement(SPAN, label, body, b));
    }
    if ty == a::with_statement() {
        let obj = build_expr(b, get(term, a::object()).ok_or("Missing :object")?)?;
        let body = build_stmt(b, get(term, a::body()).ok_or("Missing :body")?)?;
        return Ok(Statement::new_with_statement(SPAN, obj, body, b));
    }
    if ty == a::import_declaration() {
        return Ok(Statement::from(build_import(b, term)?));
    }
    if ty == a::export_named_declaration() {
        return Ok(Statement::from(build_export_named(b, term)?));
    }
    if ty == a::export_default_declaration() {
        return Ok(Statement::from(build_export_default(b, term)?));
    }
    if ty == a::export_all_declaration() {
        return Ok(Statement::from(build_export_all(b, term)?));
    }

    err(format!("Unsupported statement: {}", type_str(term)))
}

fn build_stmts<'a>(b: &AstBuilder<'a>, list: Vec<Term>) -> R<OxcVec<'a, Statement<'a>>> {
    let mut out = OxcVec::with_capacity_in(list.len(), b);
    for t in &list {
        out.push(build_stmt(b, *t)?);
    }
    Ok(out)
}

fn build_block<'a>(b: &AstBuilder<'a>, term: Term) -> R<BlockStatement<'a>> {
    Ok(BlockStatement::new(
        SPAN,
        build_stmts(b, list_val(term, a::body()))?,
        b,
    ))
}

// ── Expressions ──

fn build_expr<'a>(b: &AstBuilder<'a>, term: Term) -> R<Expression<'a>> {
    let ty = type_atom(term).ok_or_else(|| "Missing :type on expression".to_string())?;

    if ty == a::identifier() || ty == a::identifier_reference() {
        let n = str_val(term, a::name());
        return Ok(Expression::new_identifier(
            SPAN,
            Ident::from_str_in(&n, b),
            b,
        ));
    }
    if ty == a::literal() {
        return build_generic_lit(b, term);
    }
    if ty == a::numeric_literal() {
        return Ok(Expression::new_numeric_literal(
            SPAN,
            f64_val(term, a::value()),
            None,
            NumberBase::Decimal,
            b,
        ));
    }
    if ty == a::string_literal() {
        let value = get(term, a::value()).ok_or("Missing string literal :value")?;
        return Ok(Expression::StringLiteral(OxcBox::new_in(
            beam_str_lit(b, value)?,
            b,
        )));
    }
    if ty == a::boolean_literal() {
        return Ok(Expression::new_boolean_literal(
            SPAN,
            bool_val(term, a::value()),
            b,
        ));
    }
    if ty == a::null_literal() {
        return Ok(Expression::new_null_literal(SPAN, b));
    }
    if ty == a::big_int_literal() {
        let v = str_val(term, a::value());
        return Ok(Expression::new_big_int_literal(
            SPAN,
            oxc_s(b, &v),
            None,
            BigintBase::Decimal,
            b,
        ));
    }
    if ty == a::reg_exp_literal() {
        return build_regexp(b, term);
    }

    if ty == a::binary_expression() {
        let l = build_expr(b, get(term, a::left()).ok_or("Missing :left")?)?;
        let op = parse_bin_op(&str_val(term, a::operator()))?;
        let r = build_expr(b, get(term, a::right()).ok_or("Missing :right")?)?;
        return Ok(Expression::new_binary_expression(SPAN, l, op, r, b));
    }
    if ty == a::logical_expression() {
        let l = build_expr(b, get(term, a::left()).ok_or("Missing :left")?)?;
        let op = parse_log_op(&str_val(term, a::operator()))?;
        let r = build_expr(b, get(term, a::right()).ok_or("Missing :right")?)?;
        return Ok(Expression::new_logical_expression(SPAN, l, op, r, b));
    }
    if ty == a::unary_expression() {
        let op = parse_unary_op(&str_val(term, a::operator()))?;
        return Ok(Expression::new_unary_expression(
            SPAN,
            op,
            build_expr(b, get(term, a::argument()).ok_or("Missing :argument")?)?,
            b,
        ));
    }
    if ty == a::update_expression() {
        let op = parse_update_op(&str_val(term, a::operator()))?;
        let prefix = bool_val(term, a::prefix());
        let arg = build_simple_target(b, get(term, a::argument()).ok_or("Missing :argument")?)?;
        return Ok(Expression::new_update_expression(SPAN, op, prefix, arg, b));
    }
    if ty == a::assignment_expression() {
        let op = parse_assign_op(&str_val(term, a::operator()))?;
        let l = build_assign_target(b, get(term, a::left()).ok_or("Missing :left")?)?;
        let r = build_expr(b, get(term, a::right()).ok_or("Missing :right")?)?;
        return Ok(Expression::new_assignment_expression(SPAN, op, l, r, b));
    }
    if ty == a::conditional_expression() {
        let test = build_expr(b, get(term, a::test()).ok_or("Missing :test")?)?;
        let cons = build_expr(b, get(term, a::consequent()).ok_or("Missing :consequent")?)?;
        let alt = build_expr(b, get(term, a::alternate()).ok_or("Missing :alternate")?)?;
        return Ok(Expression::new_conditional_expression(
            SPAN, test, cons, alt, b,
        ));
    }
    if ty == a::call_expression() {
        let callee = build_expr(b, get(term, a::callee()).ok_or("Missing :callee")?)?;
        let args = build_args(b, list_val(term, a::arguments()))?;
        return Ok(Expression::new_call_expression(
            SPAN,
            callee,
            None,
            args,
            bool_val(term, a::optional()),
            b,
        ));
    }
    if ty == a::new_expression() {
        let callee = build_expr(b, get(term, a::callee()).ok_or("Missing :callee")?)?;
        let args = build_args(b, list_val(term, a::arguments()))?;
        return Ok(Expression::new_new_expression(SPAN, callee, None, args, b));
    }
    if ty == a::member_expression() || ty == a::static_member_expression() {
        return build_member(b, term);
    }
    if ty == a::computed_member_expression() {
        let obj = build_expr(b, get(term, a::object()).ok_or("Missing :object")?)?;
        let prop = build_expr(
            b,
            get(term, a::expression())
                .or_else(|| get(term, a::property()))
                .ok_or("Missing prop")?,
        )?;
        return Ok(computed_member(b, obj, prop, bool_val(term, a::optional())));
    }
    if ty == a::chain_expression() {
        let inner = get(term, a::expression()).ok_or("Missing chain :expression")?;
        return build_chain(b, inner);
    }
    if ty == a::object_expression() {
        return Ok(Expression::new_object_expression(
            SPAN,
            build_obj_props(b, list_val(term, a::properties()))?,
            b,
        ));
    }
    if ty == a::array_expression() {
        let elems_list = list_val(term, a::elements());
        let mut elems = OxcVec::with_capacity_in(elems_list.len(), b);
        for e in &elems_list {
            if is_nil(*e) {
                elems.push(ArrayExpressionElement::Elision(OxcBox::new_in(
                    Elision::new(SPAN, b),
                    b,
                )));
            } else if type_eq(*e, a::spread_element()) {
                let arg = build_expr(b, get(*e, a::argument()).ok_or("Missing spread :argument")?)?;
                elems.push(ArrayExpressionElement::SpreadElement(OxcBox::new_in(
                    SpreadElement::new(SPAN, arg, b),
                    b,
                )));
            } else {
                elems.push(ArrayExpressionElement::from(build_expr(b, *e)?));
            }
        }
        return Ok(Expression::new_array_expression(SPAN, elems, b));
    }
    if ty == a::arrow_function_expression() {
        let is_async = bool_val(term, a::async_field());
        let is_expr = bool_val(term, a::expression());
        let params = build_params(b, term)?;
        let body_term = get(term, a::body()).ok_or("Missing arrow body")?;
        let body = if is_expr && !type_eq(body_term, a::block_statement()) {
            let expr = build_expr(b, body_term)?;
            ArrowFunctionBody::from(expr)
        } else {
            ArrowFunctionBody::FunctionBody(OxcBox::new_in(build_fn_body(b, body_term)?, b))
        };
        return Ok(Expression::new_arrow_function_expression(
            SPAN,
            is_async,
            None,
            OxcBox::new_in(params, b),
            None,
            body,
            b,
        ));
    }
    if ty == a::function_expression() {
        let id = opt_binding_id(b, term);
        let params = build_params(b, term)?;
        let body = build_fn_body(b, get(term, a::body()).ok_or("Missing fn body")?)?;
        return Ok(Expression::new_function_expression(
            SPAN,
            FunctionType::FunctionExpression,
            id,
            bool_val(term, a::generator()),
            bool_val(term, a::async_field()),
            false,
            None,
            None,
            OxcBox::new_in(params, b),
            None,
            Some(OxcBox::new_in(body, b)),
            b,
        ));
    }
    if ty == a::class_expression() {
        let id = opt_binding_id(b, term);
        let sc = opt_expr(b, term, a::super_class())?;
        let body = build_class_body(b, get(term, a::body()).ok_or("Missing class body")?)?;
        return Ok(Expression::new_class_expression(
            SPAN,
            ClassType::ClassExpression,
            OxcVec::new_in(b),
            id,
            None,
            sc.map(|expression| ClassHeritage {
                expression,
                type_arguments: None,
            }),
            OxcVec::new_in(b),
            OxcBox::new_in(body, b),
            false,
            false,
            b,
        ));
    }
    if ty == a::template_literal() {
        return build_template(b, term);
    }
    if ty == a::tagged_template_expression() {
        let tag = build_expr(b, get(term, a::tag()).ok_or("Missing :tag")?)?;
        let qt = get(term, a::quasi()).ok_or("Missing :quasi")?;
        let quasis = build_quasis(b, list_val(qt, a::quasis()))?;
        let exprs = build_exprs(b, list_val(qt, a::expressions()))?;
        return Ok(Expression::new_tagged_template_expression(
            SPAN,
            tag,
            None,
            TemplateLiteral::new(SPAN, quasis, exprs, b),
            b,
        ));
    }
    if ty == a::sequence_expression() {
        return Ok(Expression::new_sequence_expression(
            SPAN,
            build_exprs(b, list_val(term, a::expressions()))?,
            b,
        ));
    }
    if ty == a::this_expression() {
        return Ok(Expression::new_this_expression(SPAN, b));
    }
    if ty == a::super_expr() {
        return Ok(Expression::Super(OxcBox::new_in(Super::new(SPAN, b), b)));
    }
    if ty == a::await_expression() {
        return Ok(Expression::new_await_expression(
            SPAN,
            build_expr(b, get(term, a::argument()).ok_or("Missing :argument")?)?,
            b,
        ));
    }
    if ty == a::yield_expression() {
        return Ok(Expression::new_yield_expression(
            SPAN,
            bool_val(term, a::delegate()),
            opt_expr(b, term, a::argument())?,
            b,
        ));
    }
    if ty == a::import_expression() {
        return Ok(Expression::new_import_expression(
            SPAN,
            build_expr(b, get(term, a::source()).ok_or("Missing :source")?)?,
            None,
            None,
            b,
        ));
    }
    if ty == a::meta_property() {
        let meta = str_val(get(term, a::meta()).unwrap_or(term), a::name());
        let property = str_val(get(term, a::property()).unwrap_or(term), a::name());
        return match (meta.as_str(), property.as_str()) {
            ("import", "meta") => Ok(Expression::new_import_meta(SPAN, b)),
            ("new", "target") => Ok(Expression::new_new_target(SPAN, b)),
            _ => err("Unsupported meta property"),
        };
    }
    if ty == a::parenthesized_expression() {
        return Ok(Expression::new_parenthesized_expression(
            SPAN,
            build_expr(b, get(term, a::expression()).ok_or("Missing :expression")?)?,
            b,
        ));
    }

    err(format!("Unsupported expression: {}", type_str(term)))
}

fn opt_expr<'a>(b: &AstBuilder<'a>, term: Term, key: rustler::Atom) -> R<Option<Expression<'a>>> {
    match opt(term, key) {
        Some(t) => Ok(Some(build_expr(b, t)?)),
        None => Ok(None),
    }
}

fn build_exprs<'a>(b: &AstBuilder<'a>, list: Vec<Term>) -> R<OxcVec<'a, Expression<'a>>> {
    let mut out = OxcVec::with_capacity_in(list.len(), b);
    for t in &list {
        out.push(build_expr(b, *t)?);
    }
    Ok(out)
}

// ── Literals ──

fn build_generic_lit<'a>(b: &AstBuilder<'a>, term: Term) -> R<Expression<'a>> {
    if let Some(rx) = opt(term, a::regex()) {
        return build_regexp_from(b, rx);
    }
    if opt(term, a::bigint()).is_some() {
        let v = str_val(term, a::bigint());
        return Ok(Expression::new_big_int_literal(
            SPAN,
            oxc_s(b, &v),
            None,
            BigintBase::Decimal,
            b,
        ));
    }
    match get(term, a::value()) {
        None => Ok(Expression::new_null_literal(SPAN, b)),
        Some(t) if is_nil(t) => Ok(Expression::new_null_literal(SPAN, b)),
        Some(t) => {
            if let Ok(v) = t.decode::<bool>() {
                return Ok(Expression::new_boolean_literal(SPAN, v, b));
            }
            if let Ok(v) = t.decode::<f64>() {
                return Ok(Expression::new_numeric_literal(
                    SPAN,
                    v,
                    None,
                    NumberBase::Decimal,
                    b,
                ));
            }
            if let Ok(v) = t.decode::<i64>() {
                return Ok(Expression::new_numeric_literal(
                    SPAN,
                    v as f64,
                    None,
                    NumberBase::Decimal,
                    b,
                ));
            }
            if t.decode_as_binary().is_ok() {
                return Ok(Expression::StringLiteral(OxcBox::new_in(
                    beam_str_lit(b, t)?,
                    b,
                )));
            }
            err("Unsupported literal value")
        }
    }
}

fn build_regexp<'a>(b: &AstBuilder<'a>, term: Term) -> R<Expression<'a>> {
    build_regexp_from(b, get(term, a::regex()).unwrap_or(term))
}

fn build_regexp_from<'a>(b: &AstBuilder<'a>, rx: Term) -> R<Expression<'a>> {
    let pat = str_val(rx, a::pattern());
    let fl = str_val(rx, a::flags());
    Ok(Expression::RegExpLiteral(OxcBox::new_in(
        RegExpLiteral::new(
            SPAN,
            RegExp {
                pattern: RegExpPattern {
                    text: oxc_s(b, &pat),
                    pattern: None,
                },
                flags: parse_regex_flags(&fl),
            },
            None,
            b,
        ),
        b,
    )))
}

// ── Member / Chain ──

fn build_member<'a>(b: &AstBuilder<'a>, term: Term) -> R<Expression<'a>> {
    let obj = build_expr(b, get(term, a::object()).ok_or("Missing :object")?)?;
    let optional = bool_val(term, a::optional());
    if bool_val(term, a::computed()) {
        let prop = build_expr(b, get(term, a::property()).ok_or("Missing :property")?)?;
        Ok(computed_member(b, obj, prop, optional))
    } else {
        let pn = str_val(
            get(term, a::property()).ok_or("Missing :property")?,
            a::name(),
        );
        Ok(static_member(b, obj, &pn, optional))
    }
}

fn build_chain<'a>(b: &AstBuilder<'a>, inner: Term) -> R<Expression<'a>> {
    let inner_ty = type_atom(inner).ok_or("Missing chain inner type")?;
    let elem = if inner_ty == a::call_expression() {
        let callee = build_expr(b, get(inner, a::callee()).ok_or("Missing :callee")?)?;
        let args = build_args(b, list_val(inner, a::arguments()))?;
        ChainElement::CallExpression(OxcBox::new_in(
            CallExpression::new(SPAN, callee, None, args, bool_val(inner, a::optional()), b),
            b,
        ))
    } else {
        let obj = build_expr(b, get(inner, a::object()).ok_or("Missing :object")?)?;
        let optional = bool_val(inner, a::optional());
        if bool_val(inner, a::computed()) {
            let prop = build_expr(b, get(inner, a::property()).ok_or("Missing :property")?)?;
            ChainElement::ComputedMemberExpression(OxcBox::new_in(
                ComputedMemberExpression::new(SPAN, obj, prop, optional, b),
                b,
            ))
        } else {
            let pn = str_val(
                get(inner, a::property()).ok_or("Missing :property")?,
                a::name(),
            );
            ChainElement::StaticMemberExpression(OxcBox::new_in(
                StaticMemberExpression::new(SPAN, obj, ident_name(b, &pn), optional, b),
                b,
            ))
        }
    };
    Ok(Expression::new_chain_expression(SPAN, elem, b))
}

// ── Template literals ──

fn build_template<'a>(b: &AstBuilder<'a>, term: Term) -> R<Expression<'a>> {
    let quasis = build_quasis(b, list_val(term, a::quasis()))?;
    let exprs = build_exprs(b, list_val(term, a::expressions()))?;
    Ok(Expression::new_template_literal(SPAN, quasis, exprs, b))
}

fn build_quasis<'a>(b: &AstBuilder<'a>, list: Vec<Term>) -> R<OxcVec<'a, TemplateElement<'a>>> {
    let mut out = OxcVec::with_capacity_in(list.len(), b);
    for q in &list {
        let vt = get(*q, a::value()).unwrap_or(*q);
        let raw = str_val(vt, a::raw());
        let cooked = opt(vt, a::cooked())
            .map(|t| js_string_value(b, t))
            .transpose()?;
        let tail = bool_val(*q, a::tail());
        out.push(TemplateElement::new(
            SPAN,
            TemplateElementValue {
                raw: oxc_s(b, &raw),
                cooked,
            },
            tail,
            b,
        ));
    }
    Ok(out)
}

// ── Declarations ──

fn build_var_decl<'a>(b: &AstBuilder<'a>, term: Term) -> R<Declaration<'a>> {
    let kind = match str_val(term, a::kind()).as_str() {
        "let" => VariableDeclarationKind::Let,
        "var" => VariableDeclarationKind::Var,
        "using" => VariableDeclarationKind::Using,
        "await_using" | "await using" => VariableDeclarationKind::AwaitUsing,
        _ => VariableDeclarationKind::Const,
    };
    let dl = list_val(term, a::declarations());
    let mut decls = OxcVec::with_capacity_in(dl.len(), b);
    for d in &dl {
        let id = build_binding_pat(b, get(*d, a::id()).ok_or("Missing declarator :id")?)?;
        let init = opt_expr(b, *d, a::init())?;
        decls.push(VariableDeclarator::new(SPAN, id, None, init, false, b));
    }
    Ok(Declaration::new_variable_declaration(
        SPAN, kind, decls, false, b,
    ))
}

fn build_var_decl_boxed<'a>(
    b: &AstBuilder<'a>,
    term: Term,
) -> R<OxcBox<'a, VariableDeclaration<'a>>> {
    let kind = match str_val(term, a::kind()).as_str() {
        "let" => VariableDeclarationKind::Let,
        "var" => VariableDeclarationKind::Var,
        "using" => VariableDeclarationKind::Using,
        "await_using" | "await using" => VariableDeclarationKind::AwaitUsing,
        _ => VariableDeclarationKind::Const,
    };
    let dl = list_val(term, a::declarations());
    let mut decls = OxcVec::with_capacity_in(dl.len(), b);
    for d in &dl {
        let id = build_binding_pat(b, get(*d, a::id()).ok_or("Missing declarator :id")?)?;
        let init = opt_expr(b, *d, a::init())?;
        decls.push(VariableDeclarator::new(SPAN, id, None, init, false, b));
    }
    Ok(OxcBox::new_in(
        VariableDeclaration::new(SPAN, kind, decls, false, b),
        b,
    ))
}

fn build_fn_decl<'a>(b: &AstBuilder<'a>, term: Term) -> R<Declaration<'a>> {
    let id = opt_binding_id(b, term);
    let params = build_params(b, term)?;
    let body = build_fn_body(b, get(term, a::body()).ok_or("Missing fn body")?)?;
    Ok(Declaration::new_function_declaration(
        SPAN,
        FunctionType::FunctionDeclaration,
        id,
        bool_val(term, a::generator()),
        bool_val(term, a::async_field()),
        false,
        None,
        None,
        OxcBox::new_in(params, b),
        None,
        Some(OxcBox::new_in(body, b)),
        b,
    ))
}

fn build_class_decl<'a>(b: &AstBuilder<'a>, term: Term) -> R<Declaration<'a>> {
    let id = opt_binding_id(b, term);
    let sc = opt_expr(b, term, a::super_class())?;
    let body = build_class_body(b, get(term, a::body()).ok_or("Missing class body")?)?;
    Ok(Declaration::new_class_declaration(
        SPAN,
        ClassType::ClassDeclaration,
        OxcVec::new_in(b),
        id,
        None,
        sc.map(|expression| ClassHeritage {
            expression,
            type_arguments: None,
        }),
        OxcVec::new_in(b),
        OxcBox::new_in(body, b),
        false,
        false,
        b,
    ))
}

// ── Class body ──

fn build_class_body<'a>(b: &AstBuilder<'a>, term: Term) -> R<ClassBody<'a>> {
    let bl = list_val(term, a::body());
    let mut elems = OxcVec::with_capacity_in(bl.len(), b);
    for e in &bl {
        let ty = type_atom(*e).ok_or("Missing class element type")?;
        if ty == a::method_definition() {
            let kind_s = str_val(*e, a::kind());
            let kind = match kind_s.as_str() {
                "constructor" => MethodDefinitionKind::Constructor,
                "get" => MethodDefinitionKind::Get,
                "set" => MethodDefinitionKind::Set,
                _ => MethodDefinitionKind::Method,
            };
            let key = build_prop_key(b, get(*e, a::key()).ok_or("Missing method key")?)?;
            let is_static = bool_val(*e, a::static_field());
            let is_computed = bool_val(*e, a::computed());
            let vt = get(*e, a::value()).ok_or("Missing method value")?;
            let params = build_params(b, vt)?;
            let body = build_fn_body(b, get(vt, a::body()).ok_or("Missing method body")?)?;
            let func = Function::new(
                SPAN,
                FunctionType::FunctionExpression,
                None,
                bool_val(vt, a::generator()),
                bool_val(vt, a::async_field()),
                false,
                None,
                None,
                OxcBox::new_in(params, b),
                None,
                Some(OxcBox::new_in(body, b)),
                b,
            );
            elems.push(ClassElement::MethodDefinition(OxcBox::new_in(
                MethodDefinition::new(
                    SPAN,
                    MethodDefinitionType::MethodDefinition,
                    OxcVec::new_in(b),
                    key,
                    OxcBox::new_in(func, b),
                    kind,
                    is_computed,
                    is_static,
                    false,
                    false,
                    None,
                    b,
                ),
                b,
            )));
        } else if ty == a::property_definition() {
            let key = build_prop_key(b, get(*e, a::key()).ok_or("Missing property key")?)?;
            let val = opt_expr(b, *e, a::value())?;
            elems.push(ClassElement::PropertyDefinition(OxcBox::new_in(
                PropertyDefinition::new(
                    SPAN,
                    PropertyDefinitionType::PropertyDefinition,
                    OxcVec::new_in(b),
                    key,
                    None,
                    val,
                    bool_val(*e, a::computed()),
                    bool_val(*e, a::static_field()),
                    false,
                    false,
                    false,
                    false,
                    false,
                    None,
                    b,
                ),
                b,
            )));
        } else if ty == a::static_block() {
            let body = build_stmts(b, list_val(*e, a::body()))?;
            elems.push(ClassElement::StaticBlock(OxcBox::new_in(
                StaticBlock::new(SPAN, body, b),
                b,
            )));
        } else {
            return err(format!("Unsupported class element: {}", type_str(*e)));
        }
    }
    Ok(ClassBody::new(SPAN, elems, b))
}

// ── Module declarations ──

fn build_import<'a>(b: &AstBuilder<'a>, term: Term) -> R<ModuleDeclaration<'a>> {
    let source = get(term, a::source()).ok_or("Missing import :source")?;
    let sl = module_source_lit(
        b,
        get(source, a::value()).ok_or("Missing import source :value")?,
    )?;
    let specs_list = list_val(term, a::specifiers());
    let specifiers = if specs_list.is_empty() {
        if get(term, a::specifiers()).is_none_or(|t| is_nil(t)) {
            None
        } else {
            Some(OxcVec::new_in(b))
        }
    } else {
        let mut specs = OxcVec::with_capacity_in(specs_list.len(), b);
        for s in &specs_list {
            let ty = type_atom(*s).ok_or("Missing specifier type")?;
            if ty == a::import_specifier() {
                let imp_name = str_val(get(*s, a::imported()).unwrap_or(*s), a::name());
                let loc_name = str_val(get(*s, a::local()).unwrap_or(*s), a::name());
                let imported = ModuleExportName::IdentifierName(ident_name(b, &imp_name));
                let local = BindingIdentifier::new(SPAN, Ident::from_str_in(&loc_name, b), b);
                specs.push(ImportDeclarationSpecifier::ImportSpecifier(OxcBox::new_in(
                    ImportSpecifier::new(SPAN, imported, local, ImportOrExportKind::Value, b),
                    b,
                )));
            } else if ty == a::import_default_specifier() {
                let loc_name = str_val(get(*s, a::local()).unwrap_or(*s), a::name());
                specs.push(ImportDeclarationSpecifier::ImportDefaultSpecifier(
                    OxcBox::new_in(
                        ImportDefaultSpecifier::new(
                            SPAN,
                            BindingIdentifier::new(SPAN, Ident::from_str_in(&loc_name, b), b),
                            b,
                        ),
                        b,
                    ),
                ));
            } else if ty == a::import_namespace_specifier() {
                let loc_name = str_val(get(*s, a::local()).unwrap_or(*s), a::name());
                specs.push(ImportDeclarationSpecifier::ImportNamespaceSpecifier(
                    OxcBox::new_in(
                        ImportNamespaceSpecifier::new(
                            SPAN,
                            BindingIdentifier::new(SPAN, Ident::from_str_in(&loc_name, b), b),
                            b,
                        ),
                        b,
                    ),
                ));
            } else {
                return err(format!("Unsupported import specifier: {}", type_str(*s)));
            }
        }
        Some(specs)
    };
    Ok(ModuleDeclaration::ImportDeclaration(OxcBox::new_in(
        ImportDeclaration::new(
            SPAN,
            specifiers,
            sl,
            None,
            None,
            ImportOrExportKind::Value,
            b,
        ),
        b,
    )))
}

fn build_export_named<'a>(b: &AstBuilder<'a>, term: Term) -> R<ModuleDeclaration<'a>> {
    let declaration = match opt(term, a::declaration()) {
        Some(t) => {
            let ty = type_atom(t).ok_or("Missing export decl type")?;
            Some(if ty == a::variable_declaration() {
                build_var_decl(b, t)?
            } else if ty == a::function_declaration() {
                build_fn_decl(b, t)?
            } else if ty == a::class_declaration() {
                build_class_decl(b, t)?
            } else {
                return err(format!("Unsupported export declaration: {}", type_str(t)));
            })
        }
        None => None,
    };
    let sl = list_val(term, a::specifiers());
    let mut specifiers = OxcVec::with_capacity_in(sl.len(), b);
    for s in &sl {
        let loc = str_val(get(*s, a::local()).unwrap_or(*s), a::name());
        let exp = str_val(get(*s, a::exported()).unwrap_or(*s), a::name());
        specifiers.push(ExportSpecifier::new(
            SPAN,
            ModuleExportName::IdentifierName(ident_name(b, &loc)),
            ModuleExportName::IdentifierName(ident_name(b, &exp)),
            ImportOrExportKind::Value,
            b,
        ));
    }
    let source = opt(term, a::source())
        .map(|t| module_source_lit(b, get(t, a::value()).ok_or("Missing export source :value")?))
        .transpose()?;
    if let Some(declaration) = declaration {
        return Ok(ModuleDeclaration::ExportDeclaration(
            ExportDeclaration::boxed(SPAN, declaration, b),
        ));
    }
    if let Some(source) = source {
        return Ok(ModuleDeclaration::ExportFromDeclaration(
            ExportFromDeclaration::boxed(
                SPAN,
                specifiers,
                source,
                ImportOrExportKind::Value,
                None,
                b,
            ),
        ));
    }
    Ok(ModuleDeclaration::ExportNamedDeclaration(
        ExportNamedDeclaration::boxed(SPAN, specifiers, ImportOrExportKind::Value, b),
    ))
}

fn build_export_default<'a>(b: &AstBuilder<'a>, term: Term) -> R<ModuleDeclaration<'a>> {
    let dt = get(term, a::declaration()).ok_or("Missing default export declaration")?;
    let ty = type_atom(dt).ok_or("Missing declaration type")?;
    let kind = if ty == a::function_declaration() {
        let id = opt_binding_id(b, dt);
        let params = build_params(b, dt)?;
        let body = build_fn_body(b, get(dt, a::body()).ok_or("Missing fn body")?)?;
        let func = Function::new(
            SPAN,
            FunctionType::FunctionDeclaration,
            id,
            bool_val(dt, a::generator()),
            bool_val(dt, a::async_field()),
            false,
            None,
            None,
            OxcBox::new_in(params, b),
            None,
            Some(OxcBox::new_in(body, b)),
            b,
        );
        ExportDefaultDeclarationKind::FunctionDeclaration(OxcBox::new_in(func, b))
    } else if ty == a::class_declaration() {
        let id = opt_binding_id(b, dt);
        let sc = opt_expr(b, dt, a::super_class())?;
        let body = build_class_body(b, get(dt, a::body()).ok_or("Missing class body")?)?;
        let class = Class::new(
            SPAN,
            ClassType::ClassDeclaration,
            OxcVec::new_in(b),
            id,
            None,
            sc.map(|expression| ClassHeritage {
                expression,
                type_arguments: None,
            }),
            OxcVec::new_in(b),
            OxcBox::new_in(body, b),
            false,
            false,
            b,
        );
        ExportDefaultDeclarationKind::ClassDeclaration(OxcBox::new_in(class, b))
    } else {
        ExportDefaultDeclarationKind::from(build_expr(b, dt)?)
    };
    Ok(ModuleDeclaration::ExportDefaultDeclaration(OxcBox::new_in(
        ExportDefaultDeclaration::new(SPAN, kind, b),
        b,
    )))
}

fn build_export_all<'a>(b: &AstBuilder<'a>, term: Term) -> R<ModuleDeclaration<'a>> {
    let source = get(term, a::source()).ok_or("Missing export :source")?;
    let source = module_source_lit(
        b,
        get(source, a::value()).ok_or("Missing export source :value")?,
    )?;
    let exported = opt(term, a::exported())
        .map(|t| ModuleExportName::IdentifierName(ident_name(b, &str_val(t, a::name()))));
    Ok(ModuleDeclaration::ExportAllDeclaration(OxcBox::new_in(
        ExportAllDeclaration::new(SPAN, exported, source, None, ImportOrExportKind::Value, b),
        b,
    )))
}

// ── Patterns ──

fn build_binding_pat<'a>(b: &AstBuilder<'a>, term: Term) -> R<BindingPattern<'a>> {
    let ty = type_atom(term).ok_or("Missing pattern type")?;
    if ty == a::identifier() {
        let n = str_val(term, a::name());
        return Ok(BindingPattern::new_binding_identifier(
            SPAN,
            Ident::from_str_in(&n, b),
            b,
        ));
    }
    if ty == a::object_pattern() {
        let pl = list_val(term, a::properties());
        let mut props = OxcVec::with_capacity_in(pl.len(), b);
        let mut rest = None;
        for p in &pl {
            if type_eq(*p, a::rest_element()) {
                let arg =
                    build_binding_pat(b, get(*p, a::argument()).ok_or("Missing rest :argument")?)?;
                rest = Some(OxcBox::new_in(BindingRestElement::new(SPAN, arg, b), b));
            } else {
                let key = build_prop_key(b, get(*p, a::key()).ok_or("Missing property :key")?)?;
                let val =
                    build_binding_pat(b, get(*p, a::value()).ok_or("Missing property :value")?)?;
                props.push(BindingProperty::new(
                    SPAN,
                    key,
                    val,
                    bool_val(*p, a::shorthand()),
                    bool_val(*p, a::computed()),
                    b,
                ));
            }
        }
        return Ok(BindingPattern::new_object_pattern(SPAN, props, rest, b));
    }
    if ty == a::array_pattern() {
        let el = list_val(term, a::elements());
        let mut elems = OxcVec::with_capacity_in(el.len(), b);
        let mut rest = None;
        for e in &el {
            if is_nil(*e) {
                elems.push(None);
            } else if type_eq(*e, a::rest_element()) {
                let arg =
                    build_binding_pat(b, get(*e, a::argument()).ok_or("Missing rest :argument")?)?;
                rest = Some(OxcBox::new_in(BindingRestElement::new(SPAN, arg, b), b));
            } else {
                elems.push(Some(build_binding_pat(b, *e)?));
            }
        }
        return Ok(BindingPattern::new_array_pattern(SPAN, elems, rest, b));
    }
    if ty == a::assignment_pattern() {
        let left = build_binding_pat(b, get(term, a::left()).ok_or("Missing :left")?)?;
        let right = build_expr(b, get(term, a::right()).ok_or("Missing :right")?)?;
        return Ok(BindingPattern::new_assignment_pattern(SPAN, left, right, b));
    }
    err(format!("Unsupported binding pattern: {}", type_str(term)))
}

fn build_assign_target<'a>(b: &AstBuilder<'a>, term: Term) -> R<AssignmentTarget<'a>> {
    let ty = type_atom(term).ok_or("Missing target type")?;
    if ty == a::identifier() || ty == a::identifier_reference() {
        let n = str_val(term, a::name());
        return Ok(AssignmentTarget::AssignmentTargetIdentifier(
            OxcBox::new_in(
                IdentifierReference::new(SPAN, Ident::from_str_in(&n, b), b),
                b,
            ),
        ));
    }
    if ty == a::member_expression()
        || ty == a::static_member_expression()
        || ty == a::computed_member_expression()
    {
        let obj = build_expr(b, get(term, a::object()).ok_or("Missing :object")?)?;
        let optional = bool_val(term, a::optional());
        if bool_val(term, a::computed()) || ty == a::computed_member_expression() {
            let prop = build_expr(
                b,
                get(term, a::property())
                    .or_else(|| get(term, a::expression()))
                    .ok_or("Missing prop")?,
            )?;
            return Ok(AssignmentTarget::ComputedMemberExpression(OxcBox::new_in(
                ComputedMemberExpression::new(SPAN, obj, prop, optional, b),
                b,
            )));
        }
        let pn = str_val(
            get(term, a::property()).ok_or("Missing :property")?,
            a::name(),
        );
        return Ok(AssignmentTarget::StaticMemberExpression(OxcBox::new_in(
            StaticMemberExpression::new(SPAN, obj, ident_name(b, &pn), optional, b),
            b,
        )));
    }
    err(format!("Unsupported assignment target: {}", type_str(term)))
}

fn build_simple_target<'a>(b: &AstBuilder<'a>, term: Term) -> R<SimpleAssignmentTarget<'a>> {
    let ty = type_atom(term).ok_or("Missing target type")?;
    if ty == a::identifier() || ty == a::identifier_reference() {
        let n = str_val(term, a::name());
        return Ok(SimpleAssignmentTarget::AssignmentTargetIdentifier(
            OxcBox::new_in(
                IdentifierReference::new(SPAN, Ident::from_str_in(&n, b), b),
                b,
            ),
        ));
    }
    if ty == a::member_expression()
        || ty == a::static_member_expression()
        || ty == a::computed_member_expression()
    {
        let obj = build_expr(b, get(term, a::object()).ok_or("Missing :object")?)?;
        let optional = bool_val(term, a::optional());
        if bool_val(term, a::computed()) || ty == a::computed_member_expression() {
            let prop = build_expr(
                b,
                get(term, a::property())
                    .or_else(|| get(term, a::expression()))
                    .ok_or("Missing prop")?,
            )?;
            return Ok(SimpleAssignmentTarget::ComputedMemberExpression(
                OxcBox::new_in(
                    ComputedMemberExpression::new(SPAN, obj, prop, optional, b),
                    b,
                ),
            ));
        }
        let pn = str_val(
            get(term, a::property()).ok_or("Missing :property")?,
            a::name(),
        );
        return Ok(SimpleAssignmentTarget::StaticMemberExpression(
            OxcBox::new_in(
                StaticMemberExpression::new(SPAN, obj, ident_name(b, &pn), optional, b),
                b,
            ),
        ));
    }
    err(format!("Unsupported simple target: {}", type_str(term)))
}

// ── Helpers ──

fn build_params<'a>(b: &AstBuilder<'a>, term: Term) -> R<FormalParameters<'a>> {
    let pl = list_val(term, a::params());
    let mut items = OxcVec::with_capacity_in(pl.len(), b);
    let mut rest = None;
    for p in &pl {
        if type_eq(*p, a::rest_element()) {
            let arg =
                build_binding_pat(b, get(*p, a::argument()).ok_or("Missing rest :argument")?)?;
            let rest_elem = BindingRestElement::new(SPAN, arg, b);
            rest = Some(OxcBox::new_in(
                FormalParameterRest::new(SPAN, OxcVec::new_in(b), rest_elem, None, b),
                b,
            ));
        } else {
            let pat = build_binding_pat(b, *p)?;
            items.push(FormalParameter::new(
                SPAN,
                OxcVec::new_in(b),
                pat,
                None,
                None,
                false,
                None,
                false,
                false,
                b,
            ));
        }
    }
    Ok(FormalParameters::new(
        SPAN,
        FormalParameterKind::FormalParameter,
        items,
        rest,
        b,
    ))
}

fn build_fn_body<'a>(b: &AstBuilder<'a>, term: Term) -> R<FunctionBody<'a>> {
    Ok(FunctionBody::new(
        SPAN,
        OxcVec::new_in(b),
        build_stmts(b, list_val(term, a::body()))?,
        b,
    ))
}

fn build_for_left<'a>(b: &AstBuilder<'a>, term: Term) -> R<ForStatementLeft<'a>> {
    if type_eq(term, a::variable_declaration()) {
        Ok(ForStatementLeft::VariableDeclaration(build_var_decl_boxed(
            b, term,
        )?))
    } else {
        Ok(ForStatementLeft::from(build_assign_target(b, term)?))
    }
}

fn opt_label<'a>(b: &AstBuilder<'a>, term: Term) -> Option<LabelIdentifier<'a>> {
    opt(term, a::label()).map(|t| {
        let n = str_val(t, a::name());
        LabelIdentifier::new(SPAN, Ident::from_str_in(&n, b), b)
    })
}

fn build_prop_key<'a>(b: &AstBuilder<'a>, term: Term) -> R<PropertyKey<'a>> {
    let ty = type_atom(term).ok_or("Missing key type")?;
    if ty == a::identifier() {
        return Ok(PropertyKey::StaticIdentifier(OxcBox::new_in(
            ident_name(b, &str_val(term, a::name())),
            b,
        )));
    }
    if ty == a::literal() || ty == a::string_literal() {
        let vt = get(term, a::value());
        if let Some(t) = vt {
            if t.decode_as_binary().is_ok() {
                return Ok(PropertyKey::StringLiteral(OxcBox::new_in(
                    beam_str_lit(b, t)?,
                    b,
                )));
            }
            if let Ok(n) = t.decode::<f64>() {
                return Ok(PropertyKey::NumericLiteral(OxcBox::new_in(
                    NumericLiteral::new(SPAN, n, None, NumberBase::Decimal, b),
                    b,
                )));
            }
            if let Ok(n) = t.decode::<i64>() {
                return Ok(PropertyKey::NumericLiteral(OxcBox::new_in(
                    NumericLiteral::new(SPAN, n as f64, None, NumberBase::Decimal, b),
                    b,
                )));
            }
        }
    }
    if ty == a::numeric_literal() {
        return Ok(PropertyKey::NumericLiteral(OxcBox::new_in(
            NumericLiteral::new(
                SPAN,
                f64_val(term, a::value()),
                None,
                NumberBase::Decimal,
                b,
            ),
            b,
        )));
    }
    Ok(PropertyKey::from(build_expr(b, term)?))
}

fn build_obj_props<'a>(
    b: &AstBuilder<'a>,
    list: Vec<Term>,
) -> R<OxcVec<'a, ObjectPropertyKind<'a>>> {
    let mut out = OxcVec::with_capacity_in(list.len(), b);
    for p in &list {
        if type_eq(*p, a::spread_element()) {
            let arg = build_expr(b, get(*p, a::argument()).ok_or("Missing spread :argument")?)?;
            out.push(ObjectPropertyKind::SpreadProperty(OxcBox::new_in(
                SpreadElement::new(SPAN, arg, b),
                b,
            )));
        } else {
            let key = build_prop_key(b, get(*p, a::key()).ok_or("Missing :key")?)?;
            let val = build_expr(b, get(*p, a::value()).ok_or("Missing :value")?)?;
            let kind_s = str_val(*p, a::kind());
            let kind = match kind_s.as_str() {
                "get" => PropertyKind::Get,
                "set" => PropertyKind::Set,
                _ => PropertyKind::Init,
            };
            out.push(ObjectPropertyKind::ObjectProperty(OxcBox::new_in(
                ObjectProperty::new(
                    SPAN,
                    kind,
                    key,
                    val,
                    bool_val(*p, a::method()),
                    bool_val(*p, a::shorthand()),
                    bool_val(*p, a::computed()),
                    b,
                ),
                b,
            )));
        }
    }
    Ok(out)
}

fn build_args<'a>(b: &AstBuilder<'a>, list: Vec<Term>) -> R<OxcVec<'a, Argument<'a>>> {
    let mut out = OxcVec::with_capacity_in(list.len(), b);
    for a_term in &list {
        if type_eq(*a_term, a::spread_element()) {
            let arg = build_expr(
                b,
                get(*a_term, a::argument()).ok_or("Missing spread :argument")?,
            )?;
            out.push(Argument::SpreadElement(OxcBox::new_in(
                SpreadElement::new(SPAN, arg, b),
                b,
            )));
        } else {
            out.push(Argument::from(build_expr(b, *a_term)?));
        }
    }
    Ok(out)
}

// ── Operators ──

fn parse_bin_op(op: &str) -> R<BinaryOperator> {
    Ok(match op {
        "==" => BinaryOperator::Equality,
        "!=" => BinaryOperator::Inequality,
        "===" => BinaryOperator::StrictEquality,
        "!==" => BinaryOperator::StrictInequality,
        "<" => BinaryOperator::LessThan,
        "<=" => BinaryOperator::LessEqualThan,
        ">" => BinaryOperator::GreaterThan,
        ">=" => BinaryOperator::GreaterEqualThan,
        "+" => BinaryOperator::Addition,
        "-" => BinaryOperator::Subtraction,
        "*" => BinaryOperator::Multiplication,
        "/" => BinaryOperator::Division,
        "%" => BinaryOperator::Remainder,
        "**" => BinaryOperator::Exponential,
        "<<" => BinaryOperator::ShiftLeft,
        ">>" => BinaryOperator::ShiftRight,
        ">>>" => BinaryOperator::ShiftRightZeroFill,
        "|" => BinaryOperator::BitwiseOR,
        "^" => BinaryOperator::BitwiseXOR,
        "&" => BinaryOperator::BitwiseAnd,
        "in" => BinaryOperator::In,
        "instanceof" => BinaryOperator::Instanceof,
        _ => return err(format!("Unknown binary operator: {op}")),
    })
}

fn parse_log_op(op: &str) -> R<LogicalOperator> {
    Ok(match op {
        "||" => LogicalOperator::Or,
        "&&" => LogicalOperator::And,
        "??" => LogicalOperator::Coalesce,
        _ => return err(format!("Unknown logical operator: {op}")),
    })
}

fn parse_unary_op(op: &str) -> R<UnaryOperator> {
    Ok(match op {
        "+" => UnaryOperator::UnaryPlus,
        "-" => UnaryOperator::UnaryNegation,
        "!" => UnaryOperator::LogicalNot,
        "~" => UnaryOperator::BitwiseNot,
        "typeof" => UnaryOperator::Typeof,
        "void" => UnaryOperator::Void,
        "delete" => UnaryOperator::Delete,
        _ => return err(format!("Unknown unary operator: {op}")),
    })
}

fn parse_update_op(op: &str) -> R<UpdateOperator> {
    Ok(match op {
        "++" => UpdateOperator::Increment,
        "--" => UpdateOperator::Decrement,
        _ => return err(format!("Unknown update operator: {op}")),
    })
}

fn parse_assign_op(op: &str) -> R<AssignmentOperator> {
    Ok(match op {
        "=" => AssignmentOperator::Assign,
        "+=" => AssignmentOperator::Addition,
        "-=" => AssignmentOperator::Subtraction,
        "*=" => AssignmentOperator::Multiplication,
        "/=" => AssignmentOperator::Division,
        "%=" => AssignmentOperator::Remainder,
        "**=" => AssignmentOperator::Exponential,
        "<<=" => AssignmentOperator::ShiftLeft,
        ">>=" => AssignmentOperator::ShiftRight,
        ">>>=" => AssignmentOperator::ShiftRightZeroFill,
        "|=" => AssignmentOperator::BitwiseOR,
        "^=" => AssignmentOperator::BitwiseXOR,
        "&=" => AssignmentOperator::BitwiseAnd,
        "||=" => AssignmentOperator::LogicalOr,
        "&&=" => AssignmentOperator::LogicalAnd,
        "??=" => AssignmentOperator::LogicalNullish,
        _ => return err(format!("Unknown assignment operator: {op}")),
    })
}

fn parse_regex_flags(flags: &str) -> RegExpFlags {
    let mut r = RegExpFlags::empty();
    for ch in flags.chars() {
        r |= match ch {
            'g' => RegExpFlags::G,
            'i' => RegExpFlags::I,
            'm' => RegExpFlags::M,
            's' => RegExpFlags::S,
            'u' => RegExpFlags::U,
            'y' => RegExpFlags::Y,
            'd' => RegExpFlags::D,
            'v' => RegExpFlags::V,
            _ => RegExpFlags::empty(),
        };
    }
    r
}
