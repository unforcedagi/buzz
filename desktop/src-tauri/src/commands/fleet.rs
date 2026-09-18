//! Direct host management over an existing SSH account or local executable.
use serde::Deserialize;
use serde_json::Value;
use std::{process::Stdio, time::Duration};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FleetHost {
    ssh_host: Option<String>,
    binary: String,
    state_dir: Option<String>,
}

fn validate_host(host: &FleetHost) -> Result<(), String> {
    if host.binary.is_empty()
        || host.binary.len() > 4096
        || !host.binary.starts_with('/')
        || host.binary.chars().any(char::is_control)
    {
        return Err("Use an absolute buzz-host executable path on the target machine".into());
    }
    if let Some(ssh) = &host.ssh_host {
        if ssh.is_empty()
            || ssh.len() > 255
            || ssh.starts_with('-')
            || !ssh
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "@._-:".contains(c))
        {
            return Err("Use an SSH config alias or user@hostname".into());
        }
    }
    if let Some(dir) = &host.state_dir {
        if !dir.starts_with('/') || dir.len() > 4096 || dir.chars().any(char::is_control) {
            return Err("State directory must be an absolute target-machine path".into());
        }
    }
    Ok(())
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// Execute one bounded request; timeout means unknown outcome, never success.
#[tauri::command]
pub async fn fleet_request(
    webview: tauri::Webview,
    host: FleetHost,
    request: Value,
) -> Result<Value, String> {
    if webview.label() != "main" {
        return Err("Fleet management is available only in the main client".into());
    }
    validate_host(&host)?;
    match request.get("op").and_then(Value::as_str) {
        Some("inventory" | "change") => (),
        _ => return Err("Unsupported management operation".into()),
    }
    let raw = serde_json::to_vec(&request).map_err(|e| e.to_string())?;
    if raw.len() > 1024 * 1024 {
        return Err("Management request too large".into());
    }
    let mut args = Vec::new();
    if let Some(dir) = &host.state_dir {
        args.extend(["--state-dir".to_string(), dir.clone()]);
    }
    args.push("manage".into());
    let mut command = if let Some(ssh) = &host.ssh_host {
        let mut command = tokio::process::Command::new("/usr/bin/ssh");
        command.args([
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "StrictHostKeyChecking=yes",
            "--",
            ssh,
        ]);
        let invocation = std::iter::once(host.binary.as_str())
            .chain(args.iter().map(String::as_str))
            .map(quote)
            .collect::<Vec<_>>()
            .join(" ");
        command.arg(invocation);
        command
    } else {
        let mut command = tokio::process::Command::new(&host.binary);
        command.args(args);
        command
    };
    // Do not leak the client's signing/session environment into a local host.
    for key in ["BUZZ_PRIVATE_KEY", "BUZZ_AUTH_TAG", "BUZZ_RELAY_URL"] {
        command.env_remove(key);
    }
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut command = process_wrap::tokio::CommandWrap::from(command);
    command.wrap(process_wrap::tokio::KillOnDrop);
    #[cfg(unix)]
    command.wrap(process_wrap::tokio::ProcessGroup::leader());
    #[cfg(windows)]
    command.wrap(process_wrap::tokio::JobObject);
    let mut child = command
        .spawn()
        .map_err(|e| format!("Cannot contact host: {e}"))?;
    let mut input = child.stdin().take().ok_or("Host stdin unavailable")?;
    let output = child.stdout().take().ok_or("Host stdout unavailable")?;
    let errors = child.stderr().take().ok_or("Host stderr unavailable")?;
    let exchange = async {
        let write = async {
            input.write_all(&raw).await?;
            input.shutdown().await
        };
        let read = async {
            let mut bytes = Vec::new();
            output
                .take(4 * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)
                .await?;
            Ok::<_, std::io::Error>(bytes)
        };
        let stderr = async {
            let mut bytes = Vec::new();
            errors.take(65537).read_to_end(&mut bytes).await?;
            Ok::<_, std::io::Error>(bytes)
        };
        let (_, bytes, errors) =
            tokio::try_join!(write, read, stderr).map_err(|e| e.to_string())?;
        if bytes.len() > 4 * 1024 * 1024 || errors.len() > 65536 {
            return Err("Host output exceeded limit".into());
        }
        let status = child.wait().await.map_err(|e| e.to_string())?;
        if !status.success() {
            return Err(format!(
                "Host command failed ({status}). Check SSH access and buzz-host installation."
            ));
        }
        let value: Value = serde_json::from_slice(&bytes)
            .map_err(|_| "Host did not return management JSON; it may need an upgrade")?;
        if value["protocol"] != 1 {
            return Err("Unsupported host management protocol".into());
        }
        Ok(value)
    };
    match tokio::time::timeout(Duration::from_secs(25), exchange).await {
        Ok(result) => {
            if result.is_err() && child.id().is_some() {
                child
                    .start_kill()
                    .map_err(|e| format!("Host request failed and process cleanup failed: {e}"))?;
            }
            result
        }
        Err(_) => {
            child
                .start_kill()
                .map_err(|e| format!("Host timed out and process cleanup failed: {e}"))?;
            Err("Host timed out. Outcome unknown: refresh inventory before retrying; no operation was queued by this client.".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_destinations_and_quotes_remote_paths() {
        let mut host = FleetHost {
            ssh_host: Some("uni".into()),
            binary: "/opt/buzz host".into(),
            state_dir: None,
        };
        assert!(validate_host(&host).is_ok());
        for target in ["-oProxyCommand=bad", "uni;bad", "uni\nbad", ""] {
            host.ssh_host = Some(target.into());
            assert!(validate_host(&host).is_err());
        }
        assert_eq!(quote("a'b"), "'a'\\''b'");
    }
}
