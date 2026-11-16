use std::convert::Infallible;
use std::path::{Component, Path, PathBuf};

use lightningcss::bundler::{Bundler, FileProvider, ResolveResult, SourceProvider};
use lightningcss::printer::PrinterOptions;
use lightningcss::rules::CssRule;
use lightningcss::stylesheet::{MinifyOptions, ParserFlags, ParserOptions};
use lightningcss::targets::{Browsers, Targets};
use lightningcss::values::url::Url;
use lightningcss::visitor::{Visit, VisitTypes, Visitor};
use vize_atelier_sfc::css::CssModuleExport;
use vize_atelier_sfc::{CssCompileOptions, CssCompileResult};

struct ImportFileProvider(FileProvider);

impl SourceProvider for ImportFileProvider {
    type Error = std::io::Error;

    fn read<'a>(&'a self, file: &Path) -> Result<&'a str, Self::Error> {
        self.0.read(file)
    }

    fn resolve(
        &self,
        specifier: &str,
        originating_file: &Path,
    ) -> Result<ResolveResult, Self::Error> {
        normalize_source_path(&originating_file.with_file_name(specifier)).map(ResolveResult::File)
    }
}

/// Give equivalent import spellings one identity without resolving every
/// symlink: asset URLs must remain relative to the imported alias directory.
fn normalize_source_path(path: &Path) -> std::io::Result<PathBuf> {
    let absolute = std::path::absolute(path)?;
    let mut result = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                // A symlink's parent is its target's parent on the filesystem.
                // Collapse this traversal only after preserving that meaning.
                if result.is_symlink() {
                    result = result.canonicalize()?;
                }
                result.pop();
            }
            _ => result.push(component.as_os_str()),
        }
    }
    Ok(result)
}

/// Preserve the source directory of each URL before minification can merge
/// declarations from different files and discard that distinction.
struct RebaseUrls<'a> {
    sources: &'a [String],
    entry_dir: &'a Path,
    source_index: usize,
}

impl<'i> Visitor<'i> for RebaseUrls<'_> {
    type Error = Infallible;

    fn visit_types(&self) -> VisitTypes {
        VisitTypes::RULES | VisitTypes::URLS
    }

    fn visit_rule(&mut self, rule: &mut CssRule<'i>) -> Result<(), Self::Error> {
        let previous = self.source_index;
        self.source_index = match rule {
            CssRule::Media(rule) => rule.loc.source_index,
            CssRule::Import(rule) => rule.loc.source_index,
            CssRule::Style(rule) => rule.loc.source_index,
            CssRule::Keyframes(rule) => rule.loc.source_index,
            CssRule::FontFace(rule) => rule.loc.source_index,
            CssRule::FontPaletteValues(rule) => rule.loc.source_index,
            CssRule::FontFeatureValues(rule) => rule.loc.source_index,
            CssRule::Page(rule) => rule.loc.source_index,
            CssRule::Supports(rule) => rule.loc.source_index,
            CssRule::CounterStyle(rule) => rule.loc.source_index,
            CssRule::Namespace(rule) => rule.loc.source_index,
            CssRule::MozDocument(rule) => rule.loc.source_index,
            CssRule::Nesting(rule) => rule.loc.source_index,
            CssRule::NestedDeclarations(rule) => rule.loc.source_index,
            CssRule::Viewport(rule) => rule.loc.source_index,
            CssRule::CustomMedia(rule) => rule.loc.source_index,
            CssRule::LayerStatement(rule) => rule.loc.source_index,
            CssRule::LayerBlock(rule) => rule.loc.source_index,
            CssRule::Property(rule) => rule.loc.source_index,
            CssRule::Container(rule) => rule.loc.source_index,
            CssRule::Scope(rule) => rule.loc.source_index,
            CssRule::StartingStyle(rule) => rule.loc.source_index,
            CssRule::ViewTransition(rule) => rule.loc.source_index,
            CssRule::PositionTry(rule) => rule.loc.source_index,
            CssRule::Unknown(rule) => rule.loc.source_index,
            CssRule::Ignored | CssRule::Custom(_) => previous as u32,
        } as usize;
        rule.visit_children(self)?;
        self.source_index = previous;
        Ok(())
    }

    fn visit_url(&mut self, url: &mut Url<'i>) -> Result<(), Self::Error> {
        if url.url.is_empty() || url.is_absolute() {
            return Ok(());
        }

        let Some(source_dir) = self
            .sources
            .get(self.source_index)
            .and_then(|source| Path::new(source).parent())
        else {
            return Ok(());
        };

        let value = url.url.as_ref();
        let split = value.find(['?', '#']).unwrap_or(value.len());
        let (path, suffix) = value.split_at(split);
        if path.is_empty() {
            return Ok(());
        }

        let target = normalize(&source_dir.join(path));
        let base = normalize(self.entry_dir);
        let target: Vec<_> = target.components().collect();
        let base: Vec<_> = base.components().collect();
        let common = target.iter().zip(&base).take_while(|(a, b)| a == b).count();
        let mut relative = PathBuf::new();
        for _ in common..base.len() {
            relative.push("..");
        }
        for component in &target[common..] {
            relative.push(component.as_os_str());
        }
        url.url = format!("{}{suffix}", relative.to_string_lossy().replace('\\', "/")).into();
        Ok(())
    }
}

fn normalize(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            _ => result.push(component.as_os_str()),
        }
    }
    result
}

pub(crate) fn bundle(entry_path: &str, options: &CssCompileOptions) -> CssCompileResult {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        bundle_inner(entry_path, options)
    })) {
        Ok(Ok(result)) => result,
        Ok(Err(message)) => failure(message),
        Err(_) => failure("CSS bundle error: the CSS engine panicked".to_string()),
    }
}

fn failure(message: String) -> CssCompileResult {
    CssCompileResult {
        code: "".into(),
        map: None,
        css_vars: vec![],
        errors: vec![message.into()],
        warnings: vec![],
        exports: None,
    }
}

fn bundle_inner(entry_path: &str, options: &CssCompileOptions) -> Result<CssCompileResult, String> {
    let targets = options
        .targets
        .as_ref()
        .map(|targets| {
            Targets::from(Browsers {
                chrome: targets.chrome.map(|version| version << 16),
                firefox: targets.firefox.map(|version| version << 16),
                safari: targets.safari.map(|version| version << 16),
                ..Default::default()
            })
        })
        .unwrap_or_default();
    let parser_options = ParserOptions {
        flags: ParserFlags::NESTING | ParserFlags::DEEP_SELECTOR_COMBINATOR,
        css_modules: options.css_modules.then(Default::default),
        ..Default::default()
    };
    let entry_path = normalize_source_path(Path::new(entry_path))
        .map_err(|error| format!("CSS bundle error: {error}"))?;
    let fs = ImportFileProvider(FileProvider::new());
    let mut bundler = Bundler::new(&fs, None, parser_options);
    let mut stylesheet = bundler
        .bundle(&entry_path)
        .map_err(|error| format!("CSS bundle error: {error:?}"))?;
    let sources = stylesheet.sources.clone();
    stylesheet
        .visit(&mut RebaseUrls {
            sources: &sources,
            entry_dir: entry_path.parent().unwrap_or(Path::new("")),
            source_index: 0,
        })
        .unwrap();

    if options.minify {
        stylesheet
            .minify(MinifyOptions {
                targets,
                ..Default::default()
            })
            .map_err(|error| format!("CSS minify error: {error:?}"))?;
    }

    let result = stylesheet
        .to_css(PrinterOptions {
            minify: options.minify,
            targets,
            ..Default::default()
        })
        .map_err(|error| format!("CSS print error: {error:?}"))?;
    let exports = result.exports.map(|exports| {
        exports
            .into_iter()
            .map(|(name, export)| {
                (
                    name.into(),
                    CssModuleExport {
                        name: export.name.into(),
                        is_referenced: export.is_referenced,
                    },
                )
            })
            .collect()
    });

    Ok(CssCompileResult {
        code: result.code.into(),
        map: None,
        css_vars: vec![],
        errors: vec![],
        warnings: vec![],
        exports,
    })
}
