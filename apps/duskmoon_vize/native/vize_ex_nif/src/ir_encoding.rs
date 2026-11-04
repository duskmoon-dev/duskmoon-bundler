use rustler::{Atom, Encoder, Env, Term};
use vize_atelier_vapor::ir::{
    ComponentKind, EventModifiers, IRProp, InsertionAnchor, MergedPropsSource, PropValueKind,
};

use crate::atoms;
use crate::term_encoding::nil_term;

pub(crate) fn encode_simple_expr<'a>(
    env: Env<'a>,
    expr: &vize_atelier_core::SimpleExpressionNode,
) -> Term<'a> {
    if expr.is_static {
        rustler::types::tuple::make_tuple(
            env,
            &[atoms::static_().encode(env), expr.content.encode(env)],
        )
    } else {
        expr.content.encode(env)
    }
}

pub(crate) fn encode_ir_prop<'a>(env: Env<'a>, prop: &IRProp) -> Term<'a> {
    let values: Vec<Term<'a>> = prop
        .values
        .iter()
        .map(|value| encode_simple_expr(env, value))
        .collect();

    term_map!(env, {
        atoms::key() => encode_simple_expr(env, &prop.key),
        atoms::values() => values,
        atoms::is_component() => prop.is_component,
        atoms::value_kind() => match prop.value_kind {
            PropValueKind::Expression => atoms::expression(),
            PropValueKind::ModelUpdate => atoms::model_update(),
            PropValueKind::ModelModifiers => atoms::model_modifiers(),
            PropValueKind::DisplayString => atoms::display_string(),
            PropValueKind::ForwardedSlots => atoms::forwarded_slots(),
        },
        atoms::handler_modifiers() => prop.handler_modifiers
            .map(|modifiers| encode_event_modifiers(env, modifiers))
            .unwrap_or_else(|| nil_term(env)),
    })
}

fn encode_event_modifiers<'a>(env: Env<'a>, modifiers: &EventModifiers) -> Term<'a> {
    term_map!(env, {
        atoms::keys() => modifiers.keys.iter().copied().collect::<Vec<_>>(),
        atoms::non_keys() => modifiers.non_keys.iter().copied().collect::<Vec<_>>(),
        atoms::options() => term_map!(env, {
            atoms::capture() => modifiers.options.capture,
            atoms::once() => modifiers.options.once,
            atoms::passive() => modifiers.options.passive,
        }),
    })
}

pub(crate) fn component_kind(kind: ComponentKind) -> Atom {
    match kind {
        ComponentKind::Regular => atoms::regular(),
        ComponentKind::Teleport => atoms::teleport(),
        ComponentKind::KeepAlive => atoms::keep_alive(),
        ComponentKind::Suspense => atoms::suspense(),
        ComponentKind::Transition => atoms::transition(),
        ComponentKind::TransitionGroup => atoms::transition_group(),
        ComponentKind::Dynamic => atoms::dynamic(),
    }
}

pub(crate) fn encode_merged_prop_sources<'a>(
    env: Env<'a>,
    sources: &[MergedPropsSource],
) -> Vec<Term<'a>> {
    sources
        .iter()
        .map(|source| match source {
            MergedPropsSource::Object(value) => term_map!(env, {
                atoms::kind() => atoms::object(),
                atoms::value() => encode_simple_expr(env, value),
            }),
            MergedPropsSource::Group(props) => term_map!(env, {
                atoms::kind() => atoms::group(),
                atoms::props() => props.iter().map(|prop| encode_ir_prop(env, prop)).collect::<Vec<_>>(),
            }),
        })
        .collect()
}

pub(crate) fn anchor_node(anchor: Option<InsertionAnchor>) -> Option<usize> {
    match anchor {
        Some(InsertionAnchor::Node(node)) => Some(node),
        Some(InsertionAnchor::Index(_)) | None => None,
    }
}

pub(crate) fn anchor_index(anchor: Option<InsertionAnchor>) -> Option<usize> {
    match anchor {
        Some(InsertionAnchor::Index(index)) => Some(index),
        Some(InsertionAnchor::Node(_)) | None => None,
    }
}
