//! Isolated remote app surfaces. Remote pages receive no signing or host IPC.
use crate::app_state::AppState;
use nostr::{EventBuilder, Kind, Tag};
use serde::Deserialize;
use tauri::{Manager, State, Webview, WebviewBuilder, WebviewUrl};
use url::Url;

fn app_label(session: &str) -> Result<String, String> {
    if session.len() != 36 || !session.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-') {
        return Err("Invalid app session".into());
    }
    Ok(format!("connected-app-{session}"))
}

pub(super) fn app_url(raw: &str) -> Result<Url, String> {
    let url = Url::parse(raw).map_err(|e| e.to_string())?;
    let local = url.scheme() == "http"
        && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if (url.scheme() != "https" && !local)
        || url.host_str().is_none()
        || url
            .host_str()
            .is_some_and(|host| host.ends_with(".localhost"))
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("Connected apps require HTTPS (or loopback HTTP) without credentials".into());
    }
    Ok(url)
}

fn main_only(view: &Webview) -> Result<(), String> {
    if view.label() != "main" {
        return Err("Only the main client can manage app surfaces".into());
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct AppBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn bounds_ok(bounds: &AppBounds) -> bool {
    [bounds.x, bounds.y, bounds.width, bounds.height]
        .iter()
        .all(|v| v.is_finite() && *v >= 0.0 && *v <= 20000.0)
        && bounds.width >= 100.0
        && bounds.height >= 100.0
}

/// Open an origin-confined, ephemeral app webview beside the conversation.
#[tauri::command]
pub async fn connected_app_open(
    webview: Webview,
    session: String,
    url: String,
    bounds: AppBounds,
) -> Result<(), String> {
    main_only(&webview)?;
    let label = app_label(&session)?;
    if !bounds_ok(&bounds) {
        return Err("Invalid app surface bounds".into());
    }
    let url = app_url(&url)?;
    if webview.url().map_err(|e| e.to_string())?.origin() == url.origin() {
        return Err("Connected apps cannot use the client's own trusted origin".into());
    }
    if webview.app_handle().get_webview(&label).is_some() {
        return Err("App session already open".into());
    }
    let origin = url.origin();
    let builder = WebviewBuilder::new(&label, WebviewUrl::External(url))
        .incognito(true)
        .on_navigation(move |next| next.origin() == origin)
        .on_new_window(|_, _| tauri::webview::NewWindowResponse::Deny);
    webview
        .window()
        .add_child(
            builder,
            tauri::LogicalPosition::new(bounds.x, bounds.y),
            tauri::LogicalSize::new(bounds.width, bounds.height),
        )
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Resize the remote surface without giving it access to the surrounding UI.
#[tauri::command]
pub async fn connected_app_bounds(
    webview: Webview,
    session: String,
    bounds: AppBounds,
) -> Result<(), String> {
    main_only(&webview)?;
    if !bounds_ok(&bounds) {
        return Err("Invalid app surface bounds".into());
    }
    if let Some(view) = webview.app_handle().get_webview(&app_label(&session)?) {
        view.set_position(tauri::LogicalPosition::new(bounds.x, bounds.y))
            .map_err(|e| e.to_string())?;
        view.set_size(tauri::LogicalSize::new(bounds.width, bounds.height))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Close the app and discard its ephemeral browser session.
#[tauri::command]
pub async fn connected_app_close(webview: Webview, session: String) -> Result<(), String> {
    main_only(&webview)?;
    if let Some(view) = webview.app_handle().get_webview(&app_label(&session)?) {
        view.close().map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Read a link for explicit insertion into a message; grants are unchanged.
#[tauri::command]
pub async fn connected_app_location(webview: Webview, session: String) -> Result<String, String> {
    main_only(&webview)?;
    let view = webview
        .app_handle()
        .get_webview(&app_label(&session)?)
        .ok_or("No app open")?;
    Ok(view.url().map_err(|e| e.to_string())?.to_string())
}

#[derive(Deserialize)]
struct Challenge {
    challenge: String,
    expires_at: String,
    event_template: Template,
}
#[derive(Deserialize)]
struct Template {
    kind: u16,
    content: String,
    tags: Vec<Vec<String>>,
}

fn login_template(origin: &str, challenge: &Challenge, now: u64) -> Result<Vec<Tag>, String> {
    let expiry = chrono::DateTime::parse_from_rfc3339(&challenge.expires_at)
        .map_err(|_| "Invalid challenge expiration")?
        .timestamp();
    let statement = format!("{origin} asks you to sign in to Parachute with your Nostr key.\n\nSigning proves you hold the private key for the public key in this event and starts a browser session for the account it is linked to, on this hub. Do not sign if you did not just ask to sign in here.");
    let expected = vec![
        vec!["u".into(), format!("{origin}/api/auth/nostr/verify")],
        vec!["method".into(), "POST".into()],
        vec!["challenge".into(), challenge.challenge.clone()],
    ];
    if challenge.event_template.kind != 27235
        || challenge.event_template.content != statement
        || challenge.event_template.tags != expected
        || challenge.challenge.len() != 64
        || !challenge.challenge.bytes().all(|c| c.is_ascii_hexdigit())
        || expiry <= now as i64
        || expiry > now.saturating_add(600) as i64
    {
        return Err("Hub returned an unexpected sign-in challenge; nothing was signed".into());
    }
    expected
        .into_iter()
        .map(|tag| Tag::parse(tag).map_err(|e| e.to_string()))
        .collect()
}

/// Explicit human-approved Parachute sign-in. Never expose the key or cookie to JS.
#[tauri::command]
pub async fn connected_parachute_sign_in(
    webview: Webview,
    session: String,
    origin: String,
    return_to: String,
    state: State<'_, AppState>,
) -> Result<String, String> {
    main_only(&webview)?;
    let origin = app_url(&origin)?.origin().ascii_serialization();
    let destination = app_url(&return_to)?;
    if destination.origin().ascii_serialization() != origin {
        return Err("Sign-in destination must stay inside this app".into());
    }
    let next = &destination[url::Position::BeforePath..];
    let view = webview
        .app_handle()
        .get_webview(&app_label(&session)?)
        .ok_or("Open Parachute first")?;
    if view
        .url()
        .map_err(|e| e.to_string())?
        .origin()
        .ascii_serialization()
        != origin
    {
        return Err("App origin changed; reopen Parachute".into());
    }
    let keys = state.signing_keys()?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(format!("{origin}/api/auth/nostr/challenge"))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err("Hub sign-in challenge unavailable".into());
    }
    let challenge: Challenge = read_json(response).await?;
    let tags = login_template(&origin, &challenge, nostr::Timestamp::now().as_secs())?;
    let event = EventBuilder::new(Kind::Custom(27235), challenge.event_template.content)
        .tags(tags)
        .sign_with_keys(&keys)
        .map_err(|e| e.to_string())?;
    let response = client
        .post(format!("{origin}/api/auth/nostr/verify"))
        .json(&serde_json::json!({"event":event,"next":next}))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(
            "Sign-in denied. Link this public key to your Parachute account in Parachute first."
                .into(),
        );
    }
    let cookies = response
        .headers()
        .get_all(reqwest::header::SET_COOKIE)
        .iter()
        .map(|v| v.to_str().map(String::from).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let result: serde_json::Value = read_json(response).await?;
    if cookies.is_empty() || (result["ok"] != true && result["requires_2fa"] != true) {
        return Err("Hub did not confirm a browser session".into());
    }
    // Async work must not install a session into a different app or identity.
    if state.signing_keys()?.public_key() != keys.public_key()
        || view
            .url()
            .map_err(|e| e.to_string())?
            .origin()
            .ascii_serialization()
            != origin
    {
        return Err("Identity or app changed during sign-in".into());
    }
    let host = app_url(&origin)?
        .host_str()
        .ok_or("Missing host")?
        .to_string();
    for raw in cookies {
        let cookie = tauri::webview::Cookie::parse(raw)
            .map_err(|e| e.to_string())?
            .into_owned();
        if !matches!(
            cookie.name(),
            "parachute_hub_session" | "parachute_hub_pending_login"
        ) || cookie.http_only() != Some(true)
        {
            return Err("Unexpected hub session cookie".into());
        }
        let cookie = tauri::webview::Cookie::build(cookie)
            .domain(host.clone())
            .secure(origin.starts_with("https:"))
            .build();
        view.set_cookie(cookie).map_err(|e| e.to_string())?;
    }
    let destination = if result["requires_2fa"] == true {
        app_url(&format!("{origin}/login/2fa"))?
    } else {
        destination
    };
    view.navigate(destination).map_err(|e| e.to_string())?;
    Ok(if result["requires_2fa"] == true {
        "Complete two-factor verification in Parachute"
    } else {
        "Signed in to Parachute"
    }
    .into())
}

async fn read_json<T: serde::de::DeserializeOwned>(
    mut response: reqwest::Response,
) -> Result<T, String> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if bytes.len() + chunk.len() > 65536 {
            return Err("Hub response too large".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refuses_privileged_schemes_and_embedded_credentials() {
        for url in [
            "file:///tmp/a",
            "http://example.com",
            "https://user:pass@example.com",
            "tauri://localhost",
            "https://tauri.localhost",
            "https://buzz-media.localhost",
        ] {
            assert!(app_url(url).is_err());
        }
        assert!(app_url("https://hub.example/v/uni/note").is_ok());
    }
    #[test]
    fn refuses_remote_signing_requests_outside_login_contract() {
        let challenge = Challenge {
            challenge: "a".repeat(64),
            expires_at: "1970-01-01T00:03:20Z".into(),
            event_template: Template {
                kind: 1,
                content: "publish this".into(),
                tags: vec![],
            },
        };
        assert!(login_template("https://hub.example", &challenge, 100).is_err());
    }

    #[test]
    fn accepts_only_fresh_origin_bound_login_templates() {
        let origin = "https://hub.example";
        let mut challenge = Challenge {
            challenge: "a".repeat(64),
            expires_at: "1970-01-01T00:03:20Z".into(),
            event_template: Template {
                kind: 27235,
                content: format!("{origin} asks you to sign in to Parachute with your Nostr key.\n\nSigning proves you hold the private key for the public key in this event and starts a browser session for the account it is linked to, on this hub. Do not sign if you did not just ask to sign in here."),
                tags: vec![
                    vec!["u".into(), format!("{origin}/api/auth/nostr/verify")],
                    vec!["method".into(), "POST".into()],
                    vec!["challenge".into(), "a".repeat(64)],
                ],
            },
        };
        assert!(login_template(origin, &challenge, 100).is_ok());
        assert!(login_template(origin, &challenge, 200).is_err());
        assert!(login_template("https://other.example", &challenge, 100).is_err());
        challenge.event_template.tags.push(vec!["extra".into()]);
        assert!(login_template(origin, &challenge, 100).is_err());
    }
}
