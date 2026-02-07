use super::RemoteInputPreferences;

pub fn detect_input_preferences() -> RemoteInputPreferences {
    RemoteInputPreferences {
        natural_scroll: detect_host_natural_scroll(),
    }
}

fn detect_host_natural_scroll() -> Option<bool> {
    if let Ok(value) = std::env::var("VIBE_HOST_NATURAL_SCROLL") {
        if let Some(parsed) = parse_bool_value(&value) {
            log_detect_result("env", Some(parsed));
            return Some(parsed);
        }
    }

    #[cfg(target_os = "macos")]
    {
        let detected = detect_macos_natural_scroll();
        if detected.is_none() {
            // macOS ships with natural scroll enabled by default. If we fail to
            // read persisted preferences (for example in a restricted session),
            // keep UX aligned with system defaults.
            log_detect_result("fallback", Some(true));
            return Some(true);
        }
        return detected;
    }

    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn detect_macos_natural_scroll() -> Option<bool> {
    if let Some(value) = read_defaults_bool(&["read", "-g", "com.apple.swipescrolldirection"]) {
        log_detect_result("defaults:-g:swipescrolldirection", Some(value));
        return Some(value);
    }

    if let Some(value) = read_defaults_bool(&[
        "-currentHost",
        "read",
        "-g",
        "com.apple.swipescrolldirection",
    ]) {
        log_detect_result("defaults:currentHost:swipescrolldirection", Some(value));
        return Some(value);
    }

    if let Some(value) = read_defaults_int(&[
        "-currentHost",
        "read",
        "-g",
        "com.apple.trackpad.scrollBehavior",
    ]) {
        // Observed values on recent macOS:
        // - 2: natural scroll behavior
        // - 0/1: classic behavior
        let natural = value == 2;
        log_detect_result(
            "defaults:currentHost:trackpad.scrollBehavior",
            Some(natural),
        );
        return Some(natural);
    }

    log_detect_result("defaults", None);
    None
}

#[cfg(target_os = "macos")]
fn read_defaults_bool(args: &[&str]) -> Option<bool> {
    let value = read_defaults_raw(args)?;
    parse_bool_value(&value)
}

#[cfg(target_os = "macos")]
fn read_defaults_int(args: &[&str]) -> Option<i32> {
    let value = read_defaults_raw(args)?;
    value.trim().parse::<i32>().ok()
}

#[cfg(target_os = "macos")]
fn read_defaults_raw(args: &[&str]) -> Option<String> {
    use std::process::Command;

    let output = Command::new("defaults").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

fn parse_bool_value(raw: &str) -> Option<bool> {
    let normalized = raw.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "1" | "true" | "yes" | "y" | "on" => Some(true),
        "0" | "false" | "no" | "n" | "off" => Some(false),
        _ => None,
    }
}

fn log_detect_result(source: &str, value: Option<bool>) {
    if !debug_input_pref_enabled() {
        return;
    }
    eprintln!(
        "remote input prefs: natural_scroll source={} value={:?}",
        source, value
    );
}

fn debug_input_pref_enabled() -> bool {
    std::env::var("VIBE_DEBUG_INPUT_PREFS")
        .map(|value| {
            let normalized = value.trim().to_ascii_lowercase();
            matches!(normalized.as_str(), "1" | "true" | "yes" | "y" | "on")
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::parse_bool_value;

    #[test]
    fn parse_bool_values() {
        assert_eq!(parse_bool_value("1"), Some(true));
        assert_eq!(parse_bool_value("true"), Some(true));
        assert_eq!(parse_bool_value("on"), Some(true));
        assert_eq!(parse_bool_value("0"), Some(false));
        assert_eq!(parse_bool_value("false"), Some(false));
        assert_eq!(parse_bool_value("off"), Some(false));
        assert_eq!(parse_bool_value("unknown"), None);
    }
}
