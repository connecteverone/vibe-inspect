use super::RemoteInputPreferences;

pub fn detect_input_preferences() -> RemoteInputPreferences {
    RemoteInputPreferences {
        natural_scroll: detect_host_natural_scroll(),
    }
}

fn detect_host_natural_scroll() -> Option<bool> {
    if let Ok(value) = std::env::var("VIBE_HOST_NATURAL_SCROLL") {
        if let Some(parsed) = parse_bool_value(&value) {
            return Some(parsed);
        }
    }

    #[cfg(target_os = "macos")]
    {
        return detect_macos_natural_scroll();
    }

    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn detect_macos_natural_scroll() -> Option<bool> {
    use std::process::Command;

    let output = Command::new("defaults")
        .args(["read", "-g", "com.apple.swipescrolldirection"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    parse_bool_value(&value)
}

fn parse_bool_value(raw: &str) -> Option<bool> {
    let normalized = raw.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "1" | "true" | "yes" | "y" | "on" => Some(true),
        "0" | "false" | "no" | "n" | "off" => Some(false),
        _ => None,
    }
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
