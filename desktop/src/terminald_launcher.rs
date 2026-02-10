use std::env;
#[cfg(target_os = "macos")]
use std::fs;
#[cfg(target_os = "macos")]
use std::path::Path;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use desktop::terminal_core::{read_discovery_file, terminal_discovery_path};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const ENV_TERMINALD_BIN: &str = "VIBE_TERMINALD_BIN";
const ENV_TERMINALD_SERVICE_NAME: &str = "VIBE_TERMINALD_SERVICE";
#[cfg(target_os = "linux")]
const ENV_TERMINALD_SYSTEMD_SERVICE: &str = "VIBE_TERMINALD_SYSTEMD_SERVICE";
#[cfg(target_os = "windows")]
const ENV_TERMINALD_WINDOWS_SERVICE: &str = "VIBE_TERMINALD_WINDOWS_SERVICE";
const ENV_TERMINALD_LAUNCHD_LABEL: &str = "VIBE_TERMINALD_LAUNCHD_LABEL";
const ENV_TERMINALD_LAUNCHD_PLIST: &str = "VIBE_TERMINALD_LAUNCHD_PLIST";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminaldStartMethod {
    ServiceManager,
    DirectProcess,
}

pub fn start_terminald_with_fallback() -> Result<TerminaldStartMethod, String> {
    if start_terminald_process().is_ok() {
        return Ok(TerminaldStartMethod::DirectProcess);
    }
    if try_start_via_service_manager()? {
        return Ok(TerminaldStartMethod::ServiceManager);
    }
    start_terminald_process().map(|_| TerminaldStartMethod::DirectProcess)
}

pub fn start_terminald_process() -> Result<(), String> {
    stop_discovered_terminald_process();

    let binary = resolve_terminald_binary();
    let mut command = match binary {
        Some(path) => Command::new(path),
        None => Command::new(terminald_executable_name()),
    };
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = command
        .spawn()
        .map_err(|error| format!("Failed to start terminal daemon: {error}"))?;

    thread::sleep(Duration::from_millis(150));
    match child.try_wait() {
        Ok(Some(status)) => {
            return Err(format!(
                "Terminal daemon exited immediately after start (status: {status})."
            ));
        }
        Ok(None) => {}
        Err(error) => {
            return Err(format!(
                "Failed to verify terminal daemon startup status: {error}"
            ));
        }
    }

    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

pub fn resolve_terminald_binary() -> Option<PathBuf> {
    if let Some(path) = read_env_value(ENV_TERMINALD_BIN) {
        return Some(PathBuf::from(path));
    }
    if let Ok(mut exe) = env::current_exe() {
        exe.set_file_name(terminald_executable_name());
        if exe.exists() {
            return Some(exe);
        }
    }
    None
}

fn terminald_executable_name() -> &'static str {
    if cfg!(windows) {
        "terminald.exe"
    } else {
        "terminald"
    }
}

fn try_start_via_service_manager() -> Result<bool, String> {
    #[cfg(target_os = "linux")]
    {
        return try_start_via_systemd_user();
    }
    #[cfg(target_os = "macos")]
    {
        return try_start_via_launchd();
    }
    #[cfg(target_os = "windows")]
    {
        return try_start_via_windows_service();
    }
    #[allow(unreachable_code)]
    Ok(false)
}

#[cfg(target_os = "linux")]
fn try_start_via_systemd_user() -> Result<bool, String> {
    if !command_available("systemctl") {
        return Ok(false);
    }
    let mut candidates = Vec::new();
    if let Some(name) = read_env_value(ENV_TERMINALD_SYSTEMD_SERVICE)
        .or_else(|| read_env_value(ENV_TERMINALD_SERVICE_NAME))
    {
        candidates.push(name);
    }
    candidates.push("vibe-inspect-terminald.service".to_string());
    candidates.push("terminald.service".to_string());

    for service in dedup_strings(candidates) {
        let status = Command::new("systemctl")
            .args(["--user", "start", service.as_str()])
            .status();
        match status {
            Ok(status) if status.success() => return Ok(true),
            Ok(_) => continue,
            Err(error) => {
                return Err(format!(
                    "Failed to invoke systemctl for terminald service: {error}"
                ));
            }
        }
    }

    Ok(false)
}

#[cfg(target_os = "macos")]
fn try_start_via_launchd() -> Result<bool, String> {
    if !command_available("launchctl") {
        return Ok(false);
    }

    let uid = current_uid();
    if uid.is_empty() {
        return Ok(false);
    }

    let labels = launchd_labels();
    for label in &labels {
        if kickstart_launchd_label(&uid, label)? {
            return Ok(true);
        }
    }

    for label in labels {
        if bootstrap_and_kickstart_launchd_agent(&uid, &label)? {
            return Ok(true);
        }
    }

    Ok(false)
}

#[cfg(target_os = "macos")]
fn launchd_labels() -> Vec<String> {
    let mut labels = Vec::new();
    if let Some(label) = read_env_value(ENV_TERMINALD_LAUNCHD_LABEL)
        .or_else(|| read_env_value(ENV_TERMINALD_SERVICE_NAME))
    {
        labels.push(label);
    }
    labels.push("com.vibeinspect.terminald".to_string());
    labels.push("com.vibe-inspect.terminald".to_string());
    dedup_strings(labels)
}

#[cfg(target_os = "macos")]
fn launchd_targets(uid: &str, label: &str) -> Vec<String> {
    vec![format!("gui/{uid}/{label}"), format!("user/{uid}/{label}")]
}

#[cfg(target_os = "macos")]
fn kickstart_launchd_label(uid: &str, label: &str) -> Result<bool, String> {
    for target in launchd_targets(uid, label) {
        let status = Command::new("launchctl")
            .args(["kickstart", "-k", target.as_str()])
            .status();
        match status {
            Ok(status) if status.success() => return Ok(true),
            Ok(_) => continue,
            Err(error) => {
                return Err(format!(
                    "Failed to invoke launchctl for terminald service: {error}"
                ));
            }
        }
    }

    Ok(false)
}

#[cfg(target_os = "macos")]
fn launchd_label_loaded(uid: &str, label: &str) -> bool {
    for target in launchd_targets(uid, label) {
        let status = Command::new("launchctl")
            .args(["print", target.as_str()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        if let Ok(status) = status {
            if status.success() {
                return true;
            }
        }
    }
    false
}

#[cfg(target_os = "macos")]
fn bootstrap_and_kickstart_launchd_agent(uid: &str, label: &str) -> Result<bool, String> {
    let binary = match resolve_terminald_binary() {
        Some(path) => path,
        None => return Ok(false),
    };
    let plist_path = match launchd_plist_path(label) {
        Some(path) => path,
        None => return Ok(false),
    };

    write_launchd_plist(&plist_path, label, &binary)?;

    let domain = format!("gui/{uid}");
    let plist_arg = plist_path.to_string_lossy().to_string();
    let status = Command::new("launchctl")
        .args(["bootstrap", domain.as_str(), plist_arg.as_str()])
        .status();
    match status {
        Ok(status) if status.success() => {}
        Ok(_) => {
            if !launchd_label_loaded(uid, label) {
                return Ok(false);
            }
        }
        Err(error) => {
            return Err(format!(
                "Failed to bootstrap launchd terminald service: {error}"
            ));
        }
    }

    kickstart_launchd_label(uid, label)
}

#[cfg(target_os = "macos")]
fn launchd_plist_path(label: &str) -> Option<PathBuf> {
    if let Some(path) = read_env_value(ENV_TERMINALD_LAUNCHD_PLIST) {
        return Some(PathBuf::from(path));
    }

    let home = read_env_value("HOME")?;
    let file_label = sanitize_launchd_file_label(label);
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("LaunchAgents")
            .join(format!("{file_label}.plist")),
    )
}

#[cfg(target_os = "macos")]
fn sanitize_launchd_file_label(label: &str) -> String {
    let mut output = String::with_capacity(label.len());
    for ch in label.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            output.push(ch);
        } else {
            output.push('_');
        }
    }
    let trimmed = output.trim_matches('_');
    if trimmed.is_empty() {
        "terminald".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(target_os = "macos")]
fn write_launchd_plist(path: &Path, label: &str, binary: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("Failed to create launchd directory: {error}"))?;
    }

    let payload = render_launchd_plist(label, binary);
    fs::write(path, payload)
        .map_err(|error| format!("Failed to write launchd plist {}: {error}", path.display()))?;

    #[cfg(unix)]
    {
        let permissions = fs::Permissions::from_mode(0o644);
        let _ = fs::set_permissions(path, permissions);
    }

    Ok(())
}

#[cfg(target_os = "macos")]
fn render_launchd_plist(label: &str, binary: &Path) -> String {
    let escaped_label = xml_escape(label);
    let escaped_binary = xml_escape(&binary.to_string_lossy());
    format!(
        concat!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" ",
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
            "<plist version=\"1.0\">\n",
            "<dict>\n",
            "  <key>Label</key>\n",
            "  <string>{}</string>\n",
            "  <key>ProgramArguments</key>\n",
            "  <array>\n",
            "    <string>{}</string>\n",
            "  </array>\n",
            "  <key>RunAtLoad</key>\n",
            "  <true/>\n",
            "  <key>KeepAlive</key>\n",
            "  <true/>\n",
            "</dict>\n",
            "</plist>\n"
        ),
        escaped_label, escaped_binary,
    )
}

#[cfg(target_os = "macos")]
fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[cfg(target_os = "windows")]
fn try_start_via_windows_service() -> Result<bool, String> {
    if !command_available("sc") {
        return Ok(false);
    }
    let mut candidates = Vec::new();
    if let Some(name) = read_env_value(ENV_TERMINALD_WINDOWS_SERVICE)
        .or_else(|| read_env_value(ENV_TERMINALD_SERVICE_NAME))
    {
        candidates.push(name);
    }
    candidates.push("VibeInspectTerminald".to_string());
    candidates.push("terminald".to_string());

    for service in dedup_strings(candidates) {
        let start_output = Command::new("sc")
            .args(["start", service.as_str()])
            .output();
        let output = match start_output {
            Ok(output) => output,
            Err(error) => {
                return Err(format!("Failed to invoke Windows service manager: {error}"));
            }
        };
        if output.status.success() {
            return Ok(true);
        }
        if windows_service_running(&service) {
            return Ok(true);
        }
    }

    Ok(false)
}

#[cfg(target_os = "windows")]
fn windows_service_running(service: &str) -> bool {
    let output = Command::new("sc").args(["query", service]).output();
    let Ok(output) = output else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout).to_ascii_uppercase();
    stdout.contains("RUNNING")
}

#[cfg(target_os = "macos")]
fn current_uid() -> String {
    if let Some(uid) = read_env_value("UID") {
        return uid;
    }
    let output = Command::new("id").arg("-u").output();
    let Ok(output) = output else {
        return String::new();
    };
    if !output.status.success() {
        return String::new();
    }
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn command_available(command: &str) -> bool {
    Command::new(command)
        .arg("--help")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

fn dedup_strings(values: Vec<String>) -> Vec<String> {
    let mut unique = Vec::new();
    for value in values {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        if unique.iter().any(|existing| existing == trimmed) {
            continue;
        }
        unique.push(trimmed.to_string());
    }
    unique
}

fn stop_discovered_terminald_process() {
    let Some(path) = terminal_discovery_path() else {
        return;
    };
    let Ok(discovery) = read_discovery_file(&path) else {
        return;
    };
    let pid = discovery.pid;
    if pid == 0 || pid == std::process::id() {
        return;
    }
    if !looks_like_terminald_process(pid) {
        return;
    }
    terminate_process(pid);
}

fn terminate_process(pid: u32) {
    let pid_text = pid.to_string();

    #[cfg(unix)]
    {
        let term_status = Command::new("kill")
            .args(["-TERM", pid_text.as_str()])
            .status();
        if term_status.as_ref().is_ok_and(|status| status.success()) {
            for _ in 0..5 {
                if !process_is_running(pid) {
                    return;
                }
                thread::sleep(Duration::from_millis(80));
            }
            let _ = Command::new("kill")
                .args(["-KILL", pid_text.as_str()])
                .status();
        }
    }

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", pid_text.as_str(), "/T", "/F"])
            .status();
    }
}

fn looks_like_terminald_process(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let pid_text = pid.to_string();
        let output = Command::new("ps")
            .args(["-p", pid_text.as_str(), "-o", "command="])
            .output();
        let Ok(output) = output else {
            return false;
        };
        if !output.status.success() {
            return false;
        }
        let command_line = String::from_utf8_lossy(&output.stdout).to_ascii_lowercase();
        return command_line.contains("terminald");
    }

    #[cfg(target_os = "windows")]
    {
        return true;
    }

    #[allow(unreachable_code)]
    false
}

#[cfg(unix)]
fn process_is_running(pid: u32) -> bool {
    let pid_text = pid.to_string();
    Command::new("kill")
        .args(["-0", pid_text.as_str()])
        .status()
        .is_ok_and(|status| status.success())
}

fn read_env_value(key: &str) -> Option<String> {
    match env::var(key) {
        Ok(value) => {
            let trimmed = value.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        }
        Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedup_strings_trims_and_filters_values() {
        let values = vec![
            " one ".to_string(),
            "two".to_string(),
            "".to_string(),
            "one".to_string(),
            " two".to_string(),
        ];
        let deduped = dedup_strings(values);
        assert_eq!(deduped, vec!["one".to_string(), "two".to_string()]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn sanitize_launchd_file_label_blocks_path_chars() {
        let label = sanitize_launchd_file_label("../../com.vibeinspect.terminald");
        assert_eq!(label, "com.vibeinspect.terminald");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn render_launchd_plist_escapes_xml() {
        let plist = render_launchd_plist(
            "com.vibeinspect.terminald<&>'\"",
            Path::new("/tmp/term<&>'\""),
        );
        assert!(plist.contains("com.vibeinspect.terminald&lt;&amp;&gt;&apos;&quot;"));
        assert!(plist.contains("/tmp/term&lt;&amp;&gt;&apos;&quot;"));
    }
}
