use rustler::{NifResult, NifStruct, ResourceArc};
use std::sync::{Mutex, MutexGuard};
use tailwindcss_oxide::{ChangedContent, GlobEntry, PublicSourceEntry, Scanner};

struct ScannerResource(Mutex<Scanner>);

#[rustler::resource_impl]
impl rustler::Resource for ScannerResource {}

#[derive(NifStruct)]
#[module = "Oxide.Source"]
struct ExSourceEntry {
    base: String,
    pattern: String,
    negated: bool,
}

#[derive(NifStruct)]
#[module = "Oxide.Glob"]
struct ExGlobEntry {
    base: String,
    pattern: String,
}

#[derive(NifStruct)]
#[module = "Oxide.Changed"]
struct ExChangedContent {
    file: Option<String>,
    content: Option<String>,
    extension: String,
}

#[derive(NifStruct)]
#[module = "Oxide.Candidate"]
struct ExCandidate {
    value: String,
    position: usize,
}

impl From<ExSourceEntry> for PublicSourceEntry {
    fn from(s: ExSourceEntry) -> Self {
        PublicSourceEntry {
            base: s.base,
            pattern: s.pattern,
            negated: s.negated,
        }
    }
}

impl From<GlobEntry> for ExGlobEntry {
    fn from(g: GlobEntry) -> Self {
        ExGlobEntry {
            base: g.base,
            pattern: g.pattern,
        }
    }
}

impl TryFrom<ExChangedContent> for ChangedContent {
    type Error = rustler::Error;

    fn try_from(c: ExChangedContent) -> Result<Self, Self::Error> {
        if let Some(file) = c.file {
            return Ok(ChangedContent::File(file.into(), c.extension));
        }
        if let Some(content) = c.content {
            return Ok(ChangedContent::Content(content, c.extension));
        }
        // Neither :file nor :content — surfaces as ArgumentError in Elixir.
        Err(rustler::Error::BadArg)
    }
}

impl ScannerResource {
    /// Lock the scanner, recovering from a poisoned mutex so one failed call
    /// cannot permanently break the resource.
    fn lock(&self) -> MutexGuard<'_, Scanner> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new_scanner(sources: Vec<ExSourceEntry>) -> ResourceArc<ScannerResource> {
    let sources: Vec<PublicSourceEntry> = sources.into_iter().map(Into::into).collect();
    let scanner = Scanner::new(sources);
    ResourceArc::new(ScannerResource(Mutex::new(scanner)))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn scan(resource: ResourceArc<ScannerResource>) -> Vec<String> {
    let mut scanner = resource.lock();
    scanner.scan()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn scan_files(
    resource: ResourceArc<ScannerResource>,
    changed: Vec<ExChangedContent>,
) -> NifResult<Vec<String>> {
    let changed = changed
        .into_iter()
        .map(ChangedContent::try_from)
        .collect::<NifResult<Vec<_>>>()?;
    Ok(resource.lock().scan_content(changed))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn get_candidates(content: String, extension: String) -> Vec<ExCandidate> {
    let mut scanner = Scanner::new(vec![]);
    let changed = ChangedContent::Content(content.clone(), extension);
    scanner
        .get_candidates_with_positions(changed)
        .into_iter()
        .map(|(value, position)| ExCandidate { value, position })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn get_files(resource: ResourceArc<ScannerResource>) -> Vec<String> {
    let mut scanner = resource.lock();
    scanner.get_files()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn get_globs(resource: ResourceArc<ScannerResource>) -> Vec<ExGlobEntry> {
    let mut scanner = resource.lock();
    scanner.get_globs().into_iter().map(Into::into).collect()
}

rustler::init!("Elixir.Oxide.Native");
