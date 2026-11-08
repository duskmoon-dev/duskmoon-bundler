use std::sync::OnceLock;

use rayon::prelude::*;
use rustler::{Encoder, Env, NifResult, Term};

use crate::options::TransformInput;
use crate::parse::{binary_to_str, source_from_term, transform_source, TransformOutput};
use crate::stack::LARGE_STACK_SIZE;

// Rayon's global pool uses the default thread stack; deeply nested sources
// need the same large stack as single-file transforms.
fn transform_pool() -> Result<&'static rayon::ThreadPool, String> {
    static POOL: OnceLock<Result<rayon::ThreadPool, String>> = OnceLock::new();
    POOL.get_or_init(|| {
        rayon::ThreadPoolBuilder::new()
            .thread_name(|index| format!("oxc-transform-{index}"))
            .stack_size(LARGE_STACK_SIZE)
            .build()
            .map_err(|error| format!("Failed to start OXC transform pool: {error}"))
    })
    .as_ref()
    .map_err(Clone::clone)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn transform_many<'a>(
    env: Env<'a>,
    inputs: Vec<(Term<'a>, String)>,
    opts_term: Term<'a>,
) -> NifResult<Term<'a>> {
    let opts = TransformInput::from_term(opts_term);
    let inputs = inputs
        .into_iter()
        .map(|(source_term, filename)| {
            let source_binary = source_from_term(source_term)?;
            let source = binary_to_str(&source_binary)?.to_owned();
            Ok((source, filename))
        })
        .collect::<NifResult<Vec<_>>>()?;

    let outputs: Vec<TransformOutput> = match transform_pool() {
        Ok(pool) => pool.install(|| {
            inputs
                .par_iter()
                .map(|(source, filename)| transform_source(source, filename, &opts))
                .collect()
        }),
        Err(error) => inputs
            .iter()
            .map(|_| TransformOutput::Error(vec![error.clone()]))
            .collect(),
    };

    let terms: Vec<Term<'a>> = outputs
        .into_iter()
        .map(|output| output.to_term(env))
        .collect();

    Ok(terms.encode(env))
}
