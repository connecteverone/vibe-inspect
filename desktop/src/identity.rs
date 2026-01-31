use directories::ProjectDirs;
use rand::{distributions::Alphanumeric, Rng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

const IDENTITY_FILE: &str = "agent_identity.json";
const DEVICE_ID_SALT: &str = "vibe-inspect-device";
const LONG_TOKEN_LEN: usize = 64;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentIdentity {
    pub device_id: String,
    pub auth_token: String,
    pub created_at: u64,
    #[serde(default)]
    pub frp_url: Option<String>,
    #[serde(default = "default_listen_port")]
    pub listen_port: u16,
    #[serde(default)]
    pub auth_tokens: Vec<AuthTokenRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthTokenRecord {
    pub token: String,
    pub label: Option<String>,
    pub created_at: u64,
    pub revoked_at: Option<u64>,
    pub client_id: Option<String>,
}

impl AuthTokenRecord {
    fn is_active(&self) -> bool {
        self.revoked_at.is_none()
    }

    fn matches_client(&self, client_id: Option<&str>) -> bool {
        match (self.client_id.as_deref(), client_id) {
            (None, _) => true,
            (Some(bound), Some(candidate)) => bound == candidate,
            (Some(_), None) => false,
        }
    }
}

pub fn load_or_create_identity() -> AgentIdentity {
    if let Some(path) = identity_path() {
        if let Ok(contents) = fs::read_to_string(&path) {
            if let Ok(identity) = serde_json::from_str::<AgentIdentity>(&contents) {
                if !identity.device_id.trim().is_empty()
                    && !identity.auth_token.trim().is_empty()
                {
                    let mut hydrated = identity;
                    hydrated.ensure_listen_port();
                    hydrated.ensure_primary_token();
                    let _ = save_identity(&hydrated);
                    return hydrated;
                }
            }
        }
    }

    let raw_device_id = read_raw_device_id().unwrap_or_else(generate_fallback_id);
    let mut identity = AgentIdentity {
        device_id: hash_device_id(&raw_device_id),
        auth_token: generate_token(LONG_TOKEN_LEN),
        created_at: now_ts(),
        frp_url: None,
        listen_port: default_listen_port(),
        auth_tokens: Vec::new(),
    };

    identity.ensure_listen_port();
    identity.ensure_primary_token();
    let _ = save_identity(&identity);

    identity
}

impl AgentIdentity {
    pub fn listen_port(&self) -> u16 {
        if self.listen_port == 0 {
            default_listen_port()
        } else {
            self.listen_port
        }
    }

    pub fn rotate_auth_token(&mut self) -> Result<(), std::io::Error> {
        let previous = self.auth_token.clone();
        let token = generate_token(LONG_TOKEN_LEN);
        self.auth_token = token.clone();
        self.upsert_token(AuthTokenRecord {
            token,
            label: Some("Primary token".to_string()),
            created_at: now_ts(),
            revoked_at: None,
            client_id: None,
        });
        self.revoke_token_internal(&previous);
        save_identity(self)
    }

    pub fn ensure_primary_token(&mut self) {
        if self.auth_token.trim().is_empty() {
            self.auth_token = generate_token(LONG_TOKEN_LEN);
        }
        if self.auth_tokens.is_empty() {
            self.auth_tokens.push(AuthTokenRecord {
                token: self.auth_token.clone(),
                label: Some("Primary token".to_string()),
                created_at: self.created_at,
                revoked_at: None,
                client_id: None,
            });
            return;
        }
        let has_primary = self
            .auth_tokens
            .iter()
            .any(|record| record.token == self.auth_token);
        if !has_primary {
            self.auth_tokens.push(AuthTokenRecord {
                token: self.auth_token.clone(),
                label: Some("Primary token".to_string()),
                created_at: self.created_at,
                revoked_at: None,
                client_id: None,
            });
        }
    }

    pub fn list_tokens(&self) -> Vec<AuthTokenRecord> {
        self.auth_tokens.clone()
    }

    pub fn find_token_for_client(&self, client_id: &str) -> Option<AuthTokenRecord> {
        self.auth_tokens
            .iter()
            .find(|record| {
                record.is_active() && record.client_id.as_deref() == Some(client_id)
            })
            .cloned()
    }

    pub fn set_primary_token(
        &mut self,
        token: String,
        label: Option<String>,
    ) -> Result<(), std::io::Error> {
        let trimmed = token.trim().to_string();
        if trimmed.is_empty() {
            return Ok(());
        }
        self.auth_token = trimmed.clone();
        self.upsert_token(AuthTokenRecord {
            token: trimmed,
            label,
            created_at: now_ts(),
            revoked_at: None,
            client_id: None,
        });
        save_identity(self)
    }

    pub fn set_frp_url(&mut self, url: Option<String>) -> Result<(), std::io::Error> {
        self.frp_url = url;
        save_identity(self)
    }

    pub fn set_listen_port(&mut self, port: u16) -> Result<(), std::io::Error> {
        self.listen_port = if port == 0 {
            default_listen_port()
        } else {
            port
        };
        save_identity(self)
    }

    pub fn create_long_token(
        &mut self,
        label: Option<String>,
        client_id: Option<String>,
    ) -> Result<AuthTokenRecord, std::io::Error> {
        let mut token = generate_token(LONG_TOKEN_LEN);
        while self
            .auth_tokens
            .iter()
            .any(|record| record.token == token)
        {
            token = generate_token(LONG_TOKEN_LEN);
        }
        let record = AuthTokenRecord {
            token,
            label,
            created_at: now_ts(),
            revoked_at: None,
            client_id,
        };
        self.auth_tokens.push(record.clone());
        save_identity(self)?;
        Ok(record)
    }

    pub fn add_custom_token(
        &mut self,
        token: String,
        label: Option<String>,
        client_id: Option<String>,
    ) -> Result<AuthTokenRecord, std::io::Error> {
        let trimmed = token.trim().to_string();
        if trimmed.is_empty() {
            return Ok(AuthTokenRecord {
                token: String::new(),
                label: None,
                created_at: now_ts(),
                revoked_at: Some(now_ts()),
                client_id: None,
            });
        }
        if let Some(existing) = self
            .auth_tokens
            .iter()
            .find(|record| record.token == trimmed)
        {
            return Ok(existing.clone());
        }
        let record = AuthTokenRecord {
            token: trimmed,
            label,
            created_at: now_ts(),
            revoked_at: None,
            client_id,
        };
        self.auth_tokens.push(record.clone());
        save_identity(self)?;
        Ok(record)
    }

    pub fn revoke_token(&mut self, token: &str) -> Result<(), std::io::Error> {
        self.revoke_token_internal(token);
        if self
            .auth_tokens
            .iter()
            .any(|record| record.token == self.auth_token && record.is_active())
        {
            return save_identity(self);
        }
        if let Some(next) = self
            .auth_tokens
            .iter()
            .find(|record| record.is_active())
        {
            self.auth_token = next.token.clone();
        } else {
            self.auth_token = generate_token(LONG_TOKEN_LEN);
            self.upsert_token(AuthTokenRecord {
                token: self.auth_token.clone(),
                label: Some("Primary token".to_string()),
                created_at: now_ts(),
                revoked_at: None,
                client_id: None,
            });
        }
        save_identity(self)
    }

    pub fn revoke_tokens_for_client(
        &mut self,
        client_id: &str,
    ) -> Result<usize, std::io::Error> {
        let now = now_ts();
        let mut revoked = 0;
        for record in &mut self.auth_tokens {
            if record.revoked_at.is_none()
                && record.client_id.as_deref() == Some(client_id)
            {
                record.revoked_at = Some(now);
                revoked += 1;
            }
        }
        if revoked == 0 {
            return Ok(0);
        }
        if self
            .auth_tokens
            .iter()
            .any(|record| record.token == self.auth_token && record.is_active())
        {
            save_identity(self)?;
            return Ok(revoked);
        }
        if let Some(next) = self
            .auth_tokens
            .iter()
            .find(|record| record.is_active())
        {
            self.auth_token = next.token.clone();
            save_identity(self)?;
            return Ok(revoked);
        }
        self.auth_token = generate_token(LONG_TOKEN_LEN);
        self.upsert_token(AuthTokenRecord {
            token: self.auth_token.clone(),
            label: Some("Primary token".to_string()),
            created_at: now_ts(),
            revoked_at: None,
            client_id: None,
        });
        save_identity(self)?;
        Ok(revoked)
    }

    pub fn token_for_client(
        &mut self,
        client_id: &str,
    ) -> Result<AuthTokenRecord, std::io::Error> {
        if let Some(record) = self
            .auth_tokens
            .iter()
            .find(|record| record.is_active() && record.client_id.as_deref() == Some(client_id))
        {
            return Ok(record.clone());
        }
        let short = &client_id[..client_id.len().min(6)];
        self.create_long_token(Some(format!("Client {short}")), Some(client_id.to_string()))
    }

    pub fn is_token_valid(&self, token: &str, client_id: Option<&str>) -> bool {
        if token.trim().is_empty() {
            return false;
        }
        self.auth_tokens.iter().any(|record| {
            record.token == token && record.is_active() && record.matches_client(client_id)
        })
    }

    fn revoke_token_internal(&mut self, token: &str) {
        let now = now_ts();
        for record in &mut self.auth_tokens {
            if record.token == token && record.revoked_at.is_none() {
                record.revoked_at = Some(now);
            }
        }
    }

    fn upsert_token(&mut self, record: AuthTokenRecord) {
        if let Some(existing) = self
            .auth_tokens
            .iter_mut()
            .find(|item| item.token == record.token)
        {
            if existing.label.is_none() {
                existing.label = record.label.clone();
            }
            existing.revoked_at = None;
            if existing.client_id.is_none() {
                existing.client_id = record.client_id.clone();
            }
            return;
        }
        self.auth_tokens.push(record);
    }

    fn ensure_listen_port(&mut self) {
        if self.listen_port == 0 {
            self.listen_port = default_listen_port();
        }
    }
}

fn default_listen_port() -> u16 {
    58888
}

fn identity_path() -> Option<PathBuf> {
    let dirs = ProjectDirs::from("com", "vibe", "vibe-inspect")?;
    Some(dirs.config_dir().join(IDENTITY_FILE))
}

fn generate_token(len: usize) -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(len)
        .map(char::from)
        .collect()
}

fn generate_fallback_id() -> String {
    format!("fallback-{}", generate_token(20))
}

fn hash_device_id(raw: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(DEVICE_ID_SALT.as_bytes());
    hasher.update(raw.trim().as_bytes());
    let digest = hasher.finalize();
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        output.push_str(&format!("{:02x}", byte));
    }
    output
}

fn now_ts() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn save_identity(identity: &AgentIdentity) -> Result<(), std::io::Error> {
    if let Some(path) = identity_path() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let payload = serde_json::to_string_pretty(identity)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::Other, error))?;
        fs::write(&path, payload)?;
    }
    Ok(())
}

fn read_raw_device_id() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        return read_macos_platform_uuid();
    }
    #[cfg(target_os = "windows")]
    {
        return read_windows_machine_guid();
    }
    #[cfg(target_os = "linux")]
    {
        return read_linux_machine_id();
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn read_macos_platform_uuid() -> Option<String> {
    let output = std::process::Command::new("ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if line.contains("IOPlatformUUID") {
            if let Some(start) = line.find('"') {
                let rest = &line[start + 1..];
                if let Some(end) = rest.find('"') {
                    return Some(rest[..end].to_string());
                }
            }
            if let Some(eq) = line.find('=') {
                let value = line[eq + 1..].trim().trim_matches('"');
                if !value.is_empty() {
                    return Some(value.to_string());
                }
            }
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn read_linux_machine_id() -> Option<String> {
    let primary = fs::read_to_string("/etc/machine-id").ok();
    if let Some(contents) = primary {
        let value = contents.lines().next().unwrap_or_default().trim();
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }
    let fallback = fs::read_to_string("/var/lib/dbus/machine-id").ok();
    if let Some(contents) = fallback {
        let value = contents.lines().next().unwrap_or_default().trim();
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn read_windows_machine_guid() -> Option<String> {
    use std::ptr::null_mut;
    use windows_sys::Win32::System::Registry::{
        RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ,
    };

    let subkey = to_wide("SOFTWARE\\Microsoft\\Cryptography");
    let value = to_wide("MachineGuid");
    let mut size: u32 = 0;
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ,
            null_mut(),
            null_mut(),
            &mut size,
        )
    };
    if status != 0 || size == 0 {
        return None;
    }
    let mut buffer: Vec<u16> = vec![0; (size / 2) as usize];
    let status = unsafe {
        RegGetValueW(
            HKEY_LOCAL_MACHINE,
            subkey.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_SZ,
            null_mut(),
            buffer.as_mut_ptr() as *mut _,
            &mut size,
        )
    };
    if status != 0 {
        return None;
    }
    let mut guid = String::from_utf16_lossy(&buffer);
    guid = guid.trim_end_matches('\u{0}').trim().to_string();
    if guid.is_empty() {
        None
    } else {
        Some(guid)
    }
}

#[cfg(target_os = "windows")]
fn to_wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
