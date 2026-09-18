//! Explicit user-driven MCP requests; remote app pages cannot invoke this bridge.
use crate::app_state::AppState;
use base64::{engine::general_purpose::STANDARD, Engine};
use nostr::{EventBuilder, JsonUtil, Kind, Tag};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tauri::{State, Webview};

/// Call a Nostr-authenticated, stateless JSON MCP endpoint as the signed-in human.
#[tauri::command]
pub async fn connected_mcp_request(
    webview: Webview,
    endpoint: String,
    method: String,
    params: Value,
    state: State<'_, AppState>,
) -> Result<Value, String> {
    if webview.label() != "main" {
        return Err("MCP controls belong to the main client".into());
    }
    let url = super::connected_apps::app_url(&endpoint)?;
    if url.fragment().is_some() {
        return Err("MCP endpoints cannot contain a fragment".into());
    }
    if !matches!(method.as_str(), "tools/list" | "tools/call") {
        return Err("Unsupported MCP method".into());
    }
    let mut nonce = [0u8; 16];
    getrandom::getrandom(&mut nonce).map_err(|e| e.to_string())?;
    let id = hex::encode(nonce);
    let body =
        serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
            .map_err(|e| e.to_string())?;
    if body.len() > 65536 {
        return Err("MCP request exceeds 64 KiB".into());
    }
    let keys = state.signing_keys()?;
    let tags = vec![
        vec!["u".to_string(), url.to_string()],
        vec!["method".into(), "POST".into()],
        vec!["payload".into(), hex::encode(Sha256::digest(&body))],
    ];
    let tags = tags
        .into_iter()
        .map(|v| Tag::parse(v).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let event = EventBuilder::new(Kind::Custom(27235), "")
        .tags(tags)
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let mut response = client
        .post(url)
        .header(
            "Authorization",
            format!("Nostr {}", STANDARD.encode(event.as_json())),
        )
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("MCP-Protocol-Version", "2025-03-26")
        .body(body)
        .send()
        .await
        .map_err(|e| format!("MCP request failed; outcome unknown for writes: {e}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "MCP service returned {}. Access is enforced by that service.",
            response.status()
        ));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if bytes.len() + chunk.len() > 1024 * 1024 {
            return Err("MCP response exceeds 1 MiB".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let result: Value = serde_json::from_slice(&bytes).map_err(|_|"This connector requires stateless JSON MCP responses; streaming/sessionful servers are not yet supported")?;
    if result["id"] != id {
        return Err("MCP response id mismatch".into());
    }
    if state.signing_keys()?.public_key() != keys.public_key() {
        return Err("Identity changed; response discarded".into());
    }
    Ok(result)
}
