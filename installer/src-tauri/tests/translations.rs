//! The window's texts: every text it names exists in English, and French
//! has the same texts, with the same {{values}}, links and platforms. A
//! missing one shows as its key in the window (en.json, fr.json).

use std::{collections::BTreeMap, path::Path};

use serde_json::Value;

fn locale(language: &str) -> BTreeMap<String, Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../src/locales/{language}.json"));
    let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).expect("locale")).expect("JSON");
    let mut flat = BTreeMap::new();
    flatten("", &value, &mut flat);
    flat
}

fn flatten(prefix: &str, value: &Value, out: &mut BTreeMap<String, Value>) {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                let key = if prefix.is_empty() { key.clone() } else { format!("{prefix}.{key}") };
                flatten(&key, value, out);
            }
        }
        other => {
            out.insert(prefix.to_string(), other.clone());
        }
    }
}

/// The {{values}} of a text, sorted.
fn values(text: &str) -> Vec<&str> {
    let mut found: Vec<&str> = text.split("{{").skip(1).filter_map(|rest| rest.split("}}").next()).collect();
    found.sort();
    found
}

/// What must stay the same between languages in a text.
fn shape(text: &str) -> (Vec<&str>, usize, Option<&str>) {
    let platform = text.strip_prefix("[platform::").and_then(|rest| rest.split(']').next());
    (values(text), text.matches("((link:").count(), platform)
}

#[test]
fn french_has_every_english_text_with_the_same_values() {
    let en = locale("en");
    let fr = locale("fr");
    let missing: Vec<&String> = en.keys().filter(|k| !fr.contains_key(*k)).collect();
    let extra: Vec<&String> = fr.keys().filter(|k| !en.contains_key(*k)).collect();
    assert!(missing.is_empty(), "French lacks {missing:?}");
    assert!(extra.is_empty(), "French has texts English has not: {extra:?}");
    for (key, english) in &en {
        let french = &fr[key];
        match (english, french) {
            (Value::String(e), Value::String(f)) => {
                assert_eq!(shape(e), shape(f), "{key}: {e:?} / {f:?}");
                assert!(!f.trim().is_empty(), "{key} is empty in French");
            }
            (Value::Array(e), Value::Array(f)) => {
                assert_eq!(e.len(), f.len(), "{key}: not as many suggestions");
                for (e, f) in e.iter().zip(f) {
                    let (e, f) = (e.as_str().unwrap(), f.as_str().unwrap());
                    assert_eq!(shape(e), shape(f), "{key}: {e:?} / {f:?}");
                }
            }
            _ => panic!("{key}: not the same kind of text in both"),
        }
    }
}

/// Every key the frontend names literally: t("…"), the operations' keys,
/// and the errors' suggestions.
fn keys_used() -> Vec<(String, String)> {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("../src");
    let mut found = Vec::new();
    let mut stack = vec![src];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).expect("src").flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            if !(name.ends_with(".ts") || name.ends_with(".tsx")) {
                continue;
            }
            let text = std::fs::read_to_string(&path).expect("source");
            for (opening, after) in [
                ("t(\"", ""),
                ("Key: \"", ""),
                ("\"error.suggestions.", "error.suggestions."),
            ] {
                for (at, _) in text.match_indices(opening) {
                    // t( alone, not split( or emit(.
                    if opening.starts_with('t')
                        && text[..at].chars().last().is_some_and(|c| c.is_alphanumeric() || c == '_' || c == '.')
                    {
                        continue;
                    }
                    let rest = &text[at + opening.len()..];
                    let key: String = rest.chars().take_while(|c| *c != '"').collect();
                    if key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '.') {
                        found.push((format!("{after}{key}"), name.clone()));
                    }
                }
            }
        }
    }
    found
}

#[test]
fn every_text_the_window_names_exists() {
    let en = locale("en");
    let used = keys_used();
    assert!(used.len() > 100, "found only {} keys: the scan is broken", used.len());
    let missing: Vec<&(String, String)> = used
        .iter()
        .filter(|(key, _)| !en.contains_key(key) && !en.keys().any(|k| k.starts_with(&format!("{key}."))))
        .collect();
    assert!(missing.is_empty(), "named in the window, missing from en.json: {missing:?}");
}
