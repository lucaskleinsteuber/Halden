//! The shared link's web page and its files, on the public listener. Only `/s/<token>` and what
//! hangs below it exist there; everything else is "not found".

use std::{
    collections::HashMap,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use axum::{
    Form, Router,
    extract::{ConnectInfo, Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::get,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::{ShareRow, album_name, by_token, shared_assets, viewed};
use crate::{
    auth::password,
    db::{Db, now_ms},
    files::{self, Caching, FileToSend},
    library::assets,
    seclog::{Event, Record},
};

/// Wrong passwords for one link before it waits.
const WRONG_LIMIT: u32 = 10;
const WRONG_WINDOW: Duration = Duration::from_secs(10 * 60);

#[derive(Clone)]
pub struct ShareState {
    db: Db,
    library: PathBuf,
    derived: PathBuf,
    server_name: String,
    wrong: Arc<Mutex<HashMap<String, (u32, Instant)>>>,
}

/// The public listener's routes.
pub fn router(db: Db, library: PathBuf, derived: PathBuf, server_name: String) -> Router {
    let state = ShareState {
        db,
        library,
        derived,
        server_name,
        wrong: Arc::new(Mutex::new(HashMap::new())),
    };
    Router::new()
        .route("/s/{token}", get(show).post(unlock))
        .route("/s/{token}/{asset}/{what}", get(file))
        .fallback(|| async { gone_page(StatusCode::NOT_FOUND, "There is nothing here.") })
        .layer(axum::middleware::map_response(protect))
        .with_state(state)
}

/// Strict headers on everything: no framing, no referrer, no indexing, nothing from elsewhere.
async fn protect(mut response: Response) -> Response {
    let headers = response.headers_mut();
    for (name, value) in [
        (
            "content-security-policy",
            "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; \
             form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        ),
        ("x-frame-options", "DENY"),
        ("referrer-policy", "no-referrer"),
        ("x-content-type-options", "nosniff"),
        ("x-robots-tag", "noindex, nofollow"),
    ] {
        headers.insert(name, HeaderValue::from_static(value));
    }
    response
}

fn gone_page(status: StatusCode, message: &str) -> Response {
    (
        status,
        Html(format!(
            "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width\">\
             <title>Halden</title><style>{STYLE}</style></head><body><main class=note><p>{}</p></main></body></html>",
            escape(message)
        )),
    )
        .into_response()
}

/// The link, if it is open now; otherwise the page to show.
async fn open_share(state: &ShareState, token: &str) -> Result<ShareRow, Box<Response>> {
    if token.len() > 64 {
        return Err(Box::new(gone_page(
            StatusCode::NOT_FOUND,
            "There is nothing here.",
        )));
    }
    match by_token(&state.db, token).await {
        Ok(Some(share)) if share.open(now_ms()) => Ok(share),
        Ok(Some(_)) => Err(Box::new(gone_page(
            StatusCode::GONE,
            "This link has ended. Ask whoever sent it for a new one.",
        ))),
        Ok(None) => Err(Box::new(gone_page(
            StatusCode::NOT_FOUND,
            "There is nothing here.",
        ))),
        Err(_) => Err(Box::new(gone_page(
            StatusCode::SERVICE_UNAVAILABLE,
            "Something went wrong; try again in a moment.",
        ))),
    }
}

/// The cookie that says the password was given: tied to the link and its password.
fn key(share: &ShareRow) -> String {
    let mut hasher = Sha256::new();
    hasher.update(share.token.as_bytes());
    hasher.update(share.password_hash.as_deref().unwrap_or("").as_bytes());
    hex::encode(&hasher.finalize()[..16])
}

fn unlocked(share: &ShareRow, headers: &HeaderMap) -> bool {
    if share.password_hash.is_none() {
        return true;
    }
    let wanted = format!("halden_share={}", key(share));
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(';'))
        .any(|cookie| cookie.trim() == wanted)
}

async fn show(
    State(state): State<ShareState>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Response {
    let share = match open_share(&state, &token).await {
        Ok(share) => share,
        Err(page) => return *page,
    };
    if !unlocked(&share, &headers) {
        return password_page(&token, false);
    }
    let Ok(items) = shared_assets(&state.db, &share).await else {
        return gone_page(
            StatusCode::SERVICE_UNAVAILABLE,
            "Something went wrong; try again in a moment.",
        );
    };
    viewed(&state.db, &share.id).await;
    let title = match (&share.title, &share.album_id) {
        (Some(title), _) => title.clone(),
        (None, Some(album)) => album_name(&state.db, album)
            .await
            .unwrap_or_else(|| "Photos".into()),
        (None, None) => "Photos".into(),
    };
    let mut grid = String::new();
    for (id, kind, _) in &items {
        let base = format!("/s/{token}/{id}");
        if kind == "video" {
            grid.push_str(&format!(
                "<figure><video controls preload=none playsinline poster=\"{base}/preview\" \
                 src=\"{base}/video\"></video>{}</figure>",
                if share.allow_originals {
                    format!("<a class=save href=\"{base}/original\">Original</a>")
                } else {
                    String::new()
                }
            ));
        } else {
            grid.push_str(&format!(
                "<figure><a href=\"{base}/preview\"><img loading=lazy alt=\"\" src=\"{base}/thumbnail\"></a>{}</figure>",
                if share.allow_originals {
                    format!("<a class=save href=\"{base}/original\">Original</a>")
                } else {
                    String::new()
                }
            ));
        }
    }
    let ends = share
        .expires_at
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map(|end| format!(" · until {}", end.format("%d.%m.%Y")))
        .unwrap_or_default();
    Html(format!(
        "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width\">\
         <meta name=robots content=noindex><title>{title}</title><style>{STYLE}</style></head>\
         <body><header><h1>{title}</h1><p>{count} {noun} · shared from {server}{ends}</p></header>\
         <main class=grid>{grid}</main>{note}</body></html>",
        title = escape(&title),
        count = items.len(),
        noun = if items.len() == 1 { "photo" } else { "photos" },
        server = escape(&state.server_name),
        note = if share.allow_originals {
            "<footer>Originals contain where the photo was taken.</footer>"
        } else {
            ""
        },
    ))
    .into_response()
}

fn password_page(token: &str, wrong: bool) -> Response {
    let status = if wrong {
        StatusCode::UNAUTHORIZED
    } else {
        StatusCode::OK
    };
    (
        status,
        Html(format!(
            "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content=\"width=device-width\">\
             <meta name=robots content=noindex><title>Halden</title><style>{STYLE}</style></head><body>\
             <main class=note><form method=post action=\"/s/{token}\"><p>{}</p>\
             <input type=password name=password autofocus autocomplete=off> <button>Open</button></form></main></body></html>",
            if wrong { "That wasn't it. The password, please:" } else { "These photos have a password:" },
            token = escape(token),
        )),
    )
        .into_response()
}

#[derive(Deserialize)]
struct Unlock {
    password: String,
}

async fn unlock(
    State(state): State<ShareState>,
    Path(token): Path<String>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Form(form): Form<Unlock>,
) -> Response {
    let share = match open_share(&state, &token).await {
        Ok(share) => share,
        Err(page) => return *page,
    };
    let Some(hash) = share.password_hash.clone() else {
        return Redirect::to(&format!("/s/{token}")).into_response();
    };
    // Guessing is slowed down per link.
    {
        let wrong = state.wrong.lock().expect("not poisoned");
        if let Some((count, since)) = wrong.get(&share.id)
            && *count >= WRONG_LIMIT
            && since.elapsed() < WRONG_WINDOW
        {
            return gone_page(
                StatusCode::TOO_MANY_REQUESTS,
                "Too many tries. Wait a few minutes.",
            );
        }
    }
    if password::verify(form.password, Some(hash)).await {
        state.wrong.lock().expect("not poisoned").remove(&share.id);
        let cookie = format!(
            "halden_share={}; Path=/s/{token}; HttpOnly; SameSite=Strict; Max-Age=86400",
            key(&share)
        );
        let mut response = Redirect::to(&format!("/s/{token}")).into_response();
        if let Ok(value) = HeaderValue::from_str(&cookie) {
            response.headers_mut().insert(header::SET_COOKIE, value);
        }
        return response;
    }
    {
        let mut wrong = state.wrong.lock().expect("not poisoned");
        let entry = wrong.entry(share.id.clone()).or_insert((0, Instant::now()));
        if entry.1.elapsed() >= WRONG_WINDOW {
            *entry = (0, Instant::now());
        }
        entry.0 += 1;
    }
    Record::new(Event::ShareWrongPassword)
        .user(&share.user_id)
        .detail(format!("shared link {} from {}", &share.id[..8], peer.ip()))
        .write(&state.db)
        .await;
    password_page(&token, true)
}

/// A shared photo's thumbnail, preview, video (the small copy) or original (only if allowed).
async fn file(
    State(state): State<ShareState>,
    Path((token, asset, what)): Path<(String, String, String)>,
    headers: HeaderMap,
) -> Response {
    let share = match open_share(&state, &token).await {
        Ok(share) => share,
        Err(page) => return *page,
    };
    if !unlocked(&share, &headers) {
        return gone_page(StatusCode::UNAUTHORIZED, "These photos have a password.");
    }
    let Ok(items) = shared_assets(&state.db, &share).await else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let Some((_, kind, _)) = items.iter().find(|(id, _, _)| *id == asset) else {
        return gone_page(StatusCode::NOT_FOUND, "There is nothing here.");
    };
    let roles: &[&str] = match what.as_str() {
        "thumbnail" => &["thumbnail", "preview"],
        "preview" => &["preview", "thumbnail"],
        "video" if kind == "video" && share.allow_originals => &["stream", "original"],
        "video" if kind == "video" => &["stream"],
        "original" if share.allow_originals => &["original"],
        _ => return gone_page(StatusCode::NOT_FOUND, "There is nothing here."),
    };
    for role in roles {
        let Ok(Some(stored)) = assets::stored_file(&state.db, &share.user_id, &asset, role).await
        else {
            continue;
        };
        let Some(path) = stored.resolve(&state.library, &state.derived) else {
            continue;
        };
        let download_name = (*role == "original")
            .then(|| stored.download_name())
            .flatten();
        return files::send(
            FileToSend {
                path,
                download_name,
                mime: stored.mime.clone(),
                sha256_hex: hex::encode(&stored.sha256),
                size: stored.size.max(0) as u64,
                caching: Caching::Revalidate,
            },
            &headers,
        )
        .await;
    }
    gone_page(
        StatusCode::NOT_FOUND,
        "This one isn't ready yet; try again later.",
    )
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

const STYLE: &str = "\
:root{color-scheme:light dark;font-family:-apple-system,system-ui,sans-serif}\
body{margin:0;background:Canvas;color:CanvasText}\
header{padding:24px 16px 8px}h1{margin:0;font-size:1.6em}header p{margin:4px 0 0;opacity:.6}\
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:4px;padding:8px}\
figure{margin:0;position:relative}img,video{width:100%;aspect-ratio:1;object-fit:cover;display:block;background:#8883}\
.save{position:absolute;right:6px;bottom:6px;font-size:12px;padding:2px 6px;border-radius:6px;\
background:#000a;color:#fff;text-decoration:none}\
footer{padding:16px;opacity:.6;font-size:.9em}\
.note{max-width:420px;margin:20vh auto;padding:16px;text-align:center}\
input,button{font-size:1em;padding:6px 10px}";
