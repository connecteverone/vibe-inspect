use crate::terminal;
use base64::Engine;
use desktop::terminal_core::TerminalActionRequest;
use reqwest::blocking::Client;
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Instant;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AgentCommandRequest {
    pub request_id: String,
    pub command: String,
    pub payload: Option<Value>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AgentCommandResponse {
    pub request_id: String,
    pub status: AgentCommandStatus,
    pub payload: Option<Value>,
    pub error: Option<AgentCommandError>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "snake_case")]
pub enum AgentCommandStatus {
    Ok,
    Error,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AgentCommandError {
    pub code: String,
    pub message: String,
    pub details: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct ApiCommandPayload {
    method: String,
    url: String,
    headers: Option<HashMap<String, String>>,
    body: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
struct TerminalCommandPayload {
    action: Option<String>,
    session_id: Option<String>,
    label: Option<String>,
    input: Option<String>,
    input_b64: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
    since: Option<u64>,
    limit: Option<usize>,
    notify_since: Option<u64>,
    working_dir: Option<String>,
    env: Option<HashMap<String, String>>,
    command: Option<String>,
    args: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
struct VncCommandPayload {
    action: String,
    session_id: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    display_index: Option<usize>,
}

struct ApiExecutionResponse {
    status: u16,
    latency_ms: u128,
    headers: HashMap<String, String>,
    body: Value,
}

#[tauri::command]
pub fn handle_agent_command(request: AgentCommandRequest) -> AgentCommandResponse {
    match request.command.as_str() {
        "ping" => ok_response(&request.request_id, json!({ "message": "pong" })),
        "api" => {
            match parse_payload::<ApiCommandPayload>(request.payload, "api", &request.request_id) {
                Ok(payload) => {
                    let request_payload = json!({
                        "method": payload.method.clone(),
                        "url": payload.url.clone(),
                        "headers": payload.headers.clone(),
                        "body": payload.body.clone(),
                    });
                    match execute_api_request(&payload) {
                        Ok(response) => ok_response(
                            &request.request_id,
                            json!({
                                "type": "api",
                                "status": "complete",
                                "request": request_payload,
                                "response": {
                                    "status": response.status,
                                    "latency_ms": response.latency_ms,
                                    "headers": response.headers,
                                    "body": response.body,
                                },
                            }),
                        ),
                        Err(message) => error_response(
                            &request.request_id,
                            "api_request_failed",
                            message,
                            Some(json!({ "request": request_payload })),
                        ),
                    }
                }
                Err(response) => response,
            }
        }
        "terminal" => match parse_payload::<TerminalCommandPayload>(
            request.payload,
            "terminal",
            &request.request_id,
        ) {
            Ok(payload) => {
                let input_bytes = match resolve_terminal_input_bytes(&payload) {
                    Ok(bytes) => bytes,
                    Err(message) => {
                        return error_response(
                            &request.request_id,
                            "invalid_payload",
                            message,
                            Some(json!({ "command": "terminal" })),
                        );
                    }
                };
                let terminal_request = TerminalActionRequest {
                    action: resolve_terminal_action(&payload).to_lowercase(),
                    session_id: payload.session_id.clone(),
                    label: payload.label.clone(),
                    input: if input_bytes.is_none() {
                        resolve_terminal_input(&payload)
                    } else {
                        None
                    },
                    input_bytes,
                    cols: payload.cols,
                    rows: payload.rows,
                    since: payload.since,
                    limit: payload.limit,
                    notify_since: payload.notify_since,
                    working_dir: payload.working_dir.clone(),
                    env: payload.env.clone(),
                };
                match terminal::handle_terminal_command(terminal_request) {
                    Ok(response) => ok_response(&request.request_id, response),
                    Err(error) => error_response(
                        &request.request_id,
                        error.code,
                        error.message,
                        Some(json!({ "command": "terminal" })),
                    ),
                }
            }
            Err(response) => response,
        },
        "vnc" => {
            match parse_payload::<VncCommandPayload>(request.payload, "vnc", &request.request_id) {
                Ok(payload) => ok_response(
                    &request.request_id,
                    json!({
                        "type": "vnc",
                        "status": "accepted",
                        "action": payload.action,
                        "session_id": payload.session_id,
                        "width": payload.width,
                        "height": payload.height,
                        "display_index": payload.display_index,
                    }),
                ),
                Err(response) => response,
            }
        }
        _ => error_response(
            &request.request_id,
            "unknown_command",
            format!("Unsupported command: {}", request.command),
            Some(json!({ "command": request.command })),
        ),
    }
}

fn resolve_terminal_input_bytes(
    payload: &TerminalCommandPayload,
) -> Result<Option<Vec<u8>>, String> {
    let Some(encoded) = payload.input_b64.as_ref() else {
        return Ok(None);
    };
    if payload
        .input
        .as_ref()
        .is_some_and(|value| !value.is_empty())
        || payload
            .command
            .as_ref()
            .is_some_and(|value| !value.trim().is_empty())
    {
        return Err("Provide either input/input_b64 or command/args, not both.".to_string());
    }
    if encoded.trim().is_empty() {
        return Ok(None);
    }
    base64::engine::general_purpose::STANDARD
        .decode(encoded.trim())
        .map(Some)
        .map_err(|error| format!("Invalid input_b64 payload: {error}"))
}

fn ok_response(request_id: &str, payload: Value) -> AgentCommandResponse {
    AgentCommandResponse {
        request_id: request_id.to_string(),
        status: AgentCommandStatus::Ok,
        payload: Some(payload),
        error: None,
    }
}

fn error_response(
    request_id: &str,
    code: &str,
    message: String,
    details: Option<Value>,
) -> AgentCommandResponse {
    AgentCommandResponse {
        request_id: request_id.to_string(),
        status: AgentCommandStatus::Error,
        payload: None,
        error: Some(AgentCommandError {
            code: code.to_string(),
            message,
            details,
        }),
    }
}

fn parse_payload<T: DeserializeOwned>(
    payload: Option<Value>,
    command_name: &str,
    request_id: &str,
) -> Result<T, AgentCommandResponse> {
    let payload = payload.ok_or_else(|| {
        error_response(
            request_id,
            "missing_payload",
            format!("Missing payload for {} command.", command_name),
            Some(json!({ "command": command_name })),
        )
    })?;

    serde_json::from_value(payload).map_err(|error| {
        error_response(
            request_id,
            "invalid_payload",
            format!("Invalid payload for {} command.", command_name),
            Some(json!({ "command": command_name, "error": error.to_string() })),
        )
    })
}

fn execute_api_request(payload: &ApiCommandPayload) -> Result<ApiExecutionResponse, String> {
    let method = Method::from_bytes(payload.method.trim().as_bytes())
        .map_err(|_| "Invalid HTTP method.".to_string())?;
    let client = Client::new();
    let mut request = client.request(method, payload.url.trim());
    if let Some(headers) = payload.headers.as_ref() {
        for (key, value) in headers {
            request = request.header(key, value);
        }
    }
    if let Some(body) = payload.body.as_ref() {
        request = request.json(body);
    }
    let start = Instant::now();
    let response = request
        .send()
        .map_err(|error| format!("API request failed: {error}"))?;
    let latency_ms = start.elapsed().as_millis();
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(key, value)| {
            (
                key.to_string(),
                value.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect::<HashMap<_, _>>();
    let body_text = response
        .text()
        .map_err(|error| format!("Failed to read response body: {error}"))?;
    let body = if body_text.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&body_text).unwrap_or(Value::String(body_text))
    };
    Ok(ApiExecutionResponse {
        status,
        latency_ms,
        headers,
        body,
    })
}

fn resolve_terminal_action(payload: &TerminalCommandPayload) -> String {
    if let Some(action) = payload.action.as_ref() {
        if !action.trim().is_empty() {
            return action.trim().to_string();
        }
    }
    if payload.session_id.is_none() {
        return "start".to_string();
    }
    if payload.command.is_some() || payload.input.is_some() {
        return "input".to_string();
    }
    "start".to_string()
}

fn resolve_terminal_input(payload: &TerminalCommandPayload) -> Option<String> {
    if let Some(input) = payload.input.as_ref() {
        if !input.is_empty() {
            return Some(input.clone());
        }
    }
    let command = payload.command.as_ref()?.trim();
    if command.is_empty() {
        return None;
    }
    if let Some(args) = payload.args.as_ref() {
        if !args.is_empty() {
            let joined = args
                .iter()
                .map(|arg| arg.trim())
                .filter(|arg| !arg.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            if !joined.is_empty() {
                let mut combined = format!("{command} {joined}");
                if !combined.ends_with('\n') {
                    combined.push('\n');
                }
                return Some(combined);
            }
        }
    }
    let mut combined = command.to_string();
    if !combined.ends_with('\n') {
        combined.push('\n');
    }
    Some(combined)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_terminal_payload() -> TerminalCommandPayload {
        TerminalCommandPayload {
            action: None,
            session_id: None,
            label: None,
            input: None,
            input_b64: None,
            cols: None,
            rows: None,
            since: None,
            limit: None,
            notify_since: None,
            working_dir: None,
            env: None,
            command: None,
            args: None,
        }
    }

    #[test]
    fn resolve_terminal_input_bytes_decodes_base64_payload() {
        let expected = "中文输入✓🚀".as_bytes().to_vec();
        let mut payload = empty_terminal_payload();
        payload.input_b64 = Some(base64::engine::general_purpose::STANDARD.encode(&expected));

        let decoded = resolve_terminal_input_bytes(&payload)
            .expect("decode result")
            .expect("decoded bytes");

        assert_eq!(decoded, expected);
    }

    #[test]
    fn resolve_terminal_input_bytes_rejects_mixed_input_sources() {
        let mut payload = empty_terminal_payload();
        payload.input = Some("echo hi".to_string());
        payload.input_b64 = Some(base64::engine::general_purpose::STANDARD.encode("x"));

        let error = resolve_terminal_input_bytes(&payload).expect_err("mixed payload should fail");
        assert!(error.contains("Provide either input/input_b64"));
    }
}
