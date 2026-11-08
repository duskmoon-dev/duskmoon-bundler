use rustler::env::SavedTerm;
use rustler::{Encoder, Env, Error, NifResult, OwnedEnv, Term};

// Vize parses, compiles and encodes SFC, template and CSS trees recursively.
// Deeply nested input can exceed the comparatively small dirty NIF stack and
// take down the whole VM, so recursive work (including term encoding) runs on a
// dedicated thread with a large stack. The standard library reserves this
// address space without committing it upfront.
pub const LARGE_STACK_SIZE: usize = 64 * 1024 * 1024;

/// Runs `operation` on a scoped large-stack thread and waits for it.
///
/// Returns `Err` if the thread cannot be started or the operation panicked.
pub fn run_with_large_stack<T: Send>(operation: impl FnOnce() -> T + Send) -> Result<T, String> {
    std::thread::scope(|scope| {
        let worker = std::thread::Builder::new()
            .name("vize-nif".to_string())
            .stack_size(LARGE_STACK_SIZE)
            .spawn_scoped(scope, operation)
            .map_err(|error| format!("Failed to start Vize worker: {error}"))?;

        worker
            .join()
            .map_err(|_| "Vize worker panicked".to_string())
    })
}

/// A term held in a process-independent env, encodable into any other env.
struct DetachedTerm {
    env: OwnedEnv,
    term: SavedTerm,
}

impl Encoder for DetachedTerm {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        self.env.run(|owned| self.term.load(owned).in_env(env))
    }
}

enum DetachedError {
    BadArg,
    Atom(&'static str),
    RaiseAtom(&'static str),
    RaiseTerm(SavedTerm),
    Term(SavedTerm),
}

/// Runs a NIF body that needs `Env`/`Term` access on a large-stack thread.
///
/// `inputs` are copied into a process-independent env and handed to `body`,
/// whose result is copied back into the caller's env on this scheduler thread.
pub fn run_nif_with_large_stack<'a, F>(
    env: Env<'a>,
    inputs: &[Term<'a>],
    body: F,
) -> NifResult<Term<'a>>
where
    F: for<'b> FnOnce(Env<'b>, Vec<Term<'b>>) -> NifResult<Term<'b>> + Send,
{
    let owned = OwnedEnv::new();
    let saved_inputs: Vec<SavedTerm> = inputs.iter().map(|term| owned.save(*term)).collect();

    let (owned, result) = run_with_large_stack(move || {
        let result = owned.run(|worker_env| {
            let args = saved_inputs
                .iter()
                .map(|saved| saved.load(worker_env))
                .collect();
            match body(worker_env, args) {
                Ok(term) => Ok(owned.save(term)),
                Err(Error::BadArg) => Err(DetachedError::BadArg),
                Err(Error::Atom(name)) => Err(DetachedError::Atom(name)),
                Err(Error::RaiseAtom(name)) => Err(DetachedError::RaiseAtom(name)),
                Err(Error::RaiseTerm(reason)) => Err(DetachedError::RaiseTerm(
                    owned.save(reason.encode(worker_env)),
                )),
                Err(Error::Term(reason)) => {
                    Err(DetachedError::Term(owned.save(reason.encode(worker_env))))
                }
            }
        });
        (owned, result)
    })
    .map_err(|message| Error::RaiseTerm(Box::new(message)))?;

    match result {
        Ok(term) => Ok(owned.run(|owned_env| term.load(owned_env).in_env(env))),
        Err(DetachedError::BadArg) => Err(Error::BadArg),
        Err(DetachedError::Atom(name)) => Err(Error::Atom(name)),
        Err(DetachedError::RaiseAtom(name)) => Err(Error::RaiseAtom(name)),
        Err(DetachedError::RaiseTerm(term)) => Err(Error::RaiseTerm(Box::new(DetachedTerm {
            env: owned,
            term,
        }))),
        Err(DetachedError::Term(term)) => {
            Err(Error::Term(Box::new(DetachedTerm { env: owned, term })))
        }
    }
}
