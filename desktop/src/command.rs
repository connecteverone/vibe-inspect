use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;

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

#[tauri::command]
pub fn handle_agent_command(request: AgentCommandRequest) -> AgentCommandResponse {
    match request.command.as_str() {
        "ping" => ok_response(&request.request_id, json!({ "message": "pong" })),
        "api" => match parse_payload::<ApiCommandPayload>(
            request.payload,
            "api",
            &request.request_id,
        ) {
            Ok(payload) => ok_response(
                &request.request_id,
                json!({
                    "type": "api",
                    "status": "accepted",
                    "request": {
                        "method": payload.method,
                        "url": payload.url,
                        "headers": payload.headers,
                        "body": payload.body,
                    }
                }),
            ),
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
