use std::path::Path;

use oxc_allocator::Allocator;
use oxc_formatter::{
    format_program, parse_for_format, ArrowParentheses, AttributePosition, BracketSameLine,
    BracketSpacing, Expand, JsFormatOptions, OperatorPosition, QuoteProperties, QuoteStyle,
    Semicolons, SortImportsOptions, SortOrder, TrailingCommas,
};
use oxc_formatter_core::{IndentStyle, IndentWidth, LineEnding, LineWidth};
use oxc_span::SourceType;
use rustler::{Binary, Encoder, Env, Error, NifResult, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        print_width,
        tab_width,
        use_tabs,
        semi,
        single_quote,
        jsx_single_quote,
        trailing_comma,
        bracket_spacing,
        bracket_same_line,
        arrow_parens,
        end_of_line,
        quote_props,
        single_attribute_per_line,
        object_wrap,
        experimental_operator_position,
        experimental_ternaries,
        sort_imports,
        sort_tailwindcss,
        // sort_imports sub-keys
        ignore_case,
        sort_side_effects,
        order,
        newlines_between,
        partition_by_newline,
        partition_by_comment,
        internal_pattern,
        // sort_tailwindcss sub-keys
        functions,
        attributes,
        preserve_whitespace,
    }
}

fn get_bool<'a>(term: Term<'a>, key: rustler::Atom) -> Option<bool> {
    term.map_get(key).ok()?.decode::<bool>().ok()
}

fn get_int<'a>(term: Term<'a>, key: rustler::Atom) -> Option<i64> {
    term.map_get(key).ok()?.decode::<i64>().ok()
}

fn get_str<'a>(term: Term<'a>, key: rustler::Atom) -> Option<String> {
    let t = term.map_get(key).ok()?;
    t.decode::<String>()
        .ok()
        .or_else(|| t.atom_to_string().ok())
}

fn get_str_list<'a>(term: Term<'a>, key: rustler::Atom) -> Option<Vec<String>> {
    let t = term.map_get(key).ok()?;
    t.decode::<Vec<String>>().ok()
}

fn get_map<'a>(term: Term<'a>, key: rustler::Atom) -> Option<Term<'a>> {
    let t = term.map_get(key).ok()?;
    if t.is_map() {
        Some(t)
    } else {
        None
    }
}

fn decode_format_options(opts: Term) -> JsFormatOptions {
    let mut o = JsFormatOptions::default();

    if let Some(v) = get_int(opts, atoms::print_width()) {
        if let Ok(w) = LineWidth::try_from(v as u16) {
            o.line_width = w;
        }
    }

    if let Some(v) = get_int(opts, atoms::tab_width()) {
        if let Ok(w) = IndentWidth::try_from(v as u8) {
            o.indent_width = w;
        }
    }

    if let Some(v) = get_bool(opts, atoms::use_tabs()) {
        o.indent_style = if v {
            IndentStyle::Tab
        } else {
            IndentStyle::Space
        };
    }

    if let Some(v) = get_bool(opts, atoms::semi()) {
        o.semicolons = if v {
            Semicolons::Always
        } else {
            Semicolons::AsNeeded
        };
    }

    if let Some(v) = get_bool(opts, atoms::single_quote()) {
        o.quote_style = if v {
            QuoteStyle::Single
        } else {
            QuoteStyle::Double
        };
    }

    if let Some(v) = get_bool(opts, atoms::jsx_single_quote()) {
        o.jsx_quote_style = if v {
            QuoteStyle::Single
        } else {
            QuoteStyle::Double
        };
    }

    if let Some(v) = get_str(opts, atoms::trailing_comma()) {
        o.trailing_commas = match v.as_str() {
            "all" => TrailingCommas::All,
            "none" => TrailingCommas::None,
            _ => TrailingCommas::All,
        };
    }

    if let Some(v) = get_bool(opts, atoms::bracket_spacing()) {
        o.bracket_spacing = BracketSpacing::from(v);
    }

    if let Some(v) = get_bool(opts, atoms::bracket_same_line()) {
        o.bracket_same_line = BracketSameLine::from(v);
    }

    if let Some(v) = get_str(opts, atoms::arrow_parens()) {
        o.arrow_parentheses = match v.as_str() {
            "avoid" => ArrowParentheses::AsNeeded,
            _ => ArrowParentheses::Always,
        };
    }

    if let Some(v) = get_str(opts, atoms::end_of_line()) {
        o.line_ending = match v.as_str() {
            "crlf" => LineEnding::Crlf,
            "cr" => LineEnding::Cr,
            _ => LineEnding::Lf,
        };
    }

    if let Some(v) = get_str(opts, atoms::quote_props()) {
        o.quote_properties = match v.as_str() {
            "consistent" => QuoteProperties::Consistent,
            "preserve" => QuoteProperties::Preserve,
            _ => QuoteProperties::AsNeeded,
        };
    }

    if let Some(v) = get_bool(opts, atoms::single_attribute_per_line()) {
        o.attribute_position = if v {
            AttributePosition::Multiline
        } else {
            AttributePosition::Auto
        };
    }

    if let Some(v) = get_str(opts, atoms::object_wrap()) {
        o.expand = match v.as_str() {
            "preserve" => Expand::Auto,
            "collapse" => Expand::Never,
            _ => Expand::Auto,
        };
    }

    if let Some(v) = get_str(opts, atoms::experimental_operator_position()) {
        o.operator_position = match v.as_str() {
            "start" => OperatorPosition::Start,
            _ => OperatorPosition::End,
        };
    }

    if let Some(v) = get_bool(opts, atoms::experimental_ternaries()) {
        o.experimental_ternaries = v;
    }

    // Embedded formatting and Tailwind host configuration require session
    // services. This standalone NIF does not install those services, matching
    // its previous callback-free formatter behavior.

    if let Some(m) = get_map(opts, atoms::sort_imports()) {
        o.sort_imports = Some(decode_sort_imports(m));
    } else if let Some(true) = get_bool(opts, atoms::sort_imports()) {
        o.sort_imports = Some(SortImportsOptions::default());
    }

    if let Some(m) = get_map(opts, atoms::sort_tailwindcss()) {
        o.sort_tailwindcss = Some(decode_sort_tailwindcss(m));
    } else if let Some(true) = get_bool(opts, atoms::sort_tailwindcss()) {
        o.sort_tailwindcss = Some(oxc_formatter::SortTailwindcssOptions::default());
    }

    o
}

fn decode_sort_imports(m: Term) -> SortImportsOptions {
    let mut s = SortImportsOptions::default();

    if let Some(v) = get_bool(m, atoms::ignore_case()) {
        s.ignore_case = v;
    }
    if let Some(v) = get_bool(m, atoms::sort_side_effects()) {
        s.sort_side_effects = v;
    }
    if let Some(v) = get_str(m, atoms::order()) {
        s.order = match v.as_str() {
            "desc" => SortOrder::Desc,
            _ => SortOrder::Asc,
        };
    }
    if let Some(v) = get_bool(m, atoms::newlines_between()) {
        s.newlines_between = v;
    }
    if let Some(v) = get_bool(m, atoms::partition_by_newline()) {
        s.partition_by_newline = v;
    }
    if let Some(v) = get_bool(m, atoms::partition_by_comment()) {
        s.partition_by_comment = v;
    }
    if let Some(v) = get_str_list(m, atoms::internal_pattern()) {
        s.internal_pattern = v;
    }

    s
}

fn decode_sort_tailwindcss(m: Term) -> oxc_formatter::SortTailwindcssOptions {
    let mut s = oxc_formatter::SortTailwindcssOptions::default();

    if let Some(v) = get_str_list(m, atoms::functions()) {
        s.functions = v;
    }
    if let Some(v) = get_str_list(m, atoms::attributes()) {
        s.attributes = v;
    }
    if let Some(v) = get_bool(m, atoms::preserve_whitespace()) {
        s.preserve_whitespace = v;
    }

    s
}

// The formatter/linter parse and walk ASTs recursively. Deeply nested input can
// exceed the comparatively small dirty NIF stack and take down the whole VM, so
// that work runs on a dedicated thread with a large stack. The standard library
// reserves this address space without committing it upfront.
const LARGE_STACK_SIZE: usize = 64 * 1024 * 1024;

fn run_with_large_stack<T: Send>(operation: impl FnOnce() -> T + Send) -> Result<T, String> {
    std::thread::scope(|scope| {
        let worker = std::thread::Builder::new()
            .name("oxc-format".to_string())
            .stack_size(LARGE_STACK_SIZE)
            .spawn_scoped(scope, operation)
            .map_err(|error| format!("Failed to start formatter worker: {error}"))?;

        worker
            .join()
            .map_err(|_| "formatter worker panicked".to_string())
    })
}

fn source_from_term<'a>(term: Term<'a>) -> NifResult<Binary<'a>> {
    term.decode_as_binary()
}

fn binary_to_str<'a, 'b>(binary: &'b Binary<'a>) -> NifResult<&'b str> {
    std::str::from_utf8(binary).map_err(|_| Error::BadArg)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn format<'a>(
    env: Env<'a>,
    source_term: Term<'a>,
    filename: &str,
    opts: Term<'a>,
) -> NifResult<Term<'a>> {
    let source_binary = source_from_term(source_term)?;
    let source = binary_to_str(&source_binary)?;
    let path = Path::new(filename);
    let source_type = SourceType::from_path(path).unwrap_or_default();

    let options = decode_format_options(opts);
    let formatted = run_with_large_stack(|| {
        let allocator = Allocator::default();
        let ret = parse_for_format(&allocator, source, source_type);

        if !ret.diagnostics.is_empty() {
            let errors: Vec<String> = ret
                .diagnostics
                .iter()
                .map(|e| e.message.to_string())
                .collect();
            return Err(errors);
        }

        format_program(&allocator, &ret.program, options)
            .print()
            .map(|formatted| formatted.into_code())
            .map_err(|error| vec![error.to_string()])
    })
    .unwrap_or_else(|error| Err(vec![error]));

    match formatted {
        Ok(code) => Ok((atoms::ok(), code).encode(env)),
        Err(errors) => Ok((atoms::error(), errors).encode(env)),
    }
}

rustler::init!("Elixir.OXC.Format.Native");
