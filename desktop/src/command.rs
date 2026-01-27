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
struct TerminalCommandPayload {
    command: String,
    args: Option<Vec<String>>,
    working_dir: Option<String>,
    env: Option<HashMap<String, String>>,
}

#[derive(Debug, Deserialize)]
struct VncCommandPayload {
    action: String,
    session_id: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
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
        "api" => match parse_payload::<ApiCommandPayload>(
            request.payload,
            "api",
            &request.request_id,
        ) {
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
        },
        "terminal" => match parse_payload::<TerminalCommandPayload>(
            request.payload,
            "terminal",
            &request.request_id,
        ) {
            Ok(payload) => ok_response(
                &request.request_id,
                json!({
                    "type": "terminal",
                    "status": "accepted",
                    "command": payload.command,
                    "args": payload.args,
                    "working_dir": payload.working_dir,
                    "env": payload.env,
                }),
            ),
            Err(response) => response,
        },
        "vnc" => match parse_payload::<VncCommandPayload>(request.payload, "vnc", &request.request_id)
        {
            Ok(payload) => ok_response(
                &request.request_id,
                json!({
                    "type": "vnc",
                    "status": "accepted",
                    "action": payload.action,
                    "session_id": payload.session_id,
                    "width": payload.width,
                    "height": payload.height,
                }),
            ),
            Err(response) => response,
        },
        _ => error_response(
            &request.request_id,
            "unknown_command",
            format!("Unsupported command: {}", request.command),
            Some(json!({ "command": request.command })),
        ),
    }
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
