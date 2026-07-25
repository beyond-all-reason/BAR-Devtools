//! Loopback HTTP adapter over the filesystem contract. GET serves the
//! artifacts serve already writes; POST drops intents into the same channels
//! the game uses. No shared state with the serve loop — the regeneration
//! cycle is the confirmation, same as every other client.
//!
//!   GET  /view            -> mission_view.json
//!   GET  /status          -> status.json
//!   POST /edit            -> <editor-dir>/edits/http_<ts>_<n>.json (validated shape)
//!   POST /open            -> <editor-dir>/open_request.json
//!   POST /select_mission  -> <editor-dir>/select_mission.json

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Bind and serve on a background thread. Returns the bound port (for tests:
/// pass port 0 to get an ephemeral one).
pub fn spawn(addr: &str, editor_dir: PathBuf) -> Option<u16> {
    let listener = match TcpListener::bind(addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("http: cannot bind {addr}: {e}");
            return None;
        }
    };
    let port = listener.local_addr().ok()?.port();
    eprintln!("http: listening on http://127.0.0.1:{port}");
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let dir = editor_dir.clone();
            std::thread::spawn(move || {
                let _ = handle(stream, dir);
            });
        }
    });
    Some(port)
}

fn handle(mut stream: TcpStream, editor_dir: PathBuf) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let path = parts
        .next()
        .unwrap_or("")
        .split('?')
        .next()
        .unwrap_or("")
        .to_string();

    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 || line.trim_end().is_empty() {
            break;
        }
        if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            content_length = v.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body)?;

    match (method.as_str(), path.as_str()) {
        ("OPTIONS", _) => respond(&mut stream, 204, "text/plain", b""),
        ("GET", "/") => respond(
            &mut stream,
            200,
            "text/html; charset=utf-8",
            include_bytes!("../web/terminal.html"),
        ),
        ("GET", "/view") => respond_file(&mut stream, editor_dir.join("mission_view.json")),
        ("GET", "/status") => respond_file(&mut stream, editor_dir.join("status.json")),
        ("GET", "/state") => respond_file(&mut stream, editor_dir.join("state.json")),
        ("GET", "/open_request") => respond_file(&mut stream, editor_dir.join("open_target.json")),
        ("POST", "/edit") => respond_edit(&mut stream, &editor_dir, &body),
        ("POST", "/open") => {
            if serde_json::from_slice::<crate::serve::OpenRequest>(&body).is_err() {
                return respond(&mut stream, 400, "text/plain", b"bad open request");
            }
            std::fs::write(editor_dir.join("open_request.json"), &body)?;
            respond(&mut stream, 200, "application/json", b"{\"ok\":true}")
        }
        ("POST", "/select_mission") => {
            if serde_json::from_slice::<crate::serve::SelectMission>(&body).is_err() {
                return respond(&mut stream, 400, "text/plain", b"bad select_mission");
            }
            std::fs::write(editor_dir.join("select_mission.json"), &body)?;
            respond(&mut stream, 200, "application/json", b"{\"ok\":true}")
        }
        _ => respond(&mut stream, 404, "text/plain", b"not found"),
    }
}

/// The intent lands in edits/ for the serve loop to apply through the
/// grammar gate; 202 means accepted for validation, not applied.
fn respond_edit(stream: &mut TcpStream, editor_dir: &PathBuf, body: &[u8]) -> std::io::Result<()> {
    if serde_json::from_slice::<crate::serve::EditIntent>(body).is_err() {
        return respond(stream, 400, "text/plain", b"bad edit intent");
    }
    let edits_dir = editor_dir.join("edits");
    std::fs::create_dir_all(&edits_dir)?;
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let n = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    std::fs::write(edits_dir.join(format!("http_{millis}_{n}.json")), body)?;
    respond(stream, 202, "application/json", b"{\"ok\":true}")
}

fn respond_file(stream: &mut TcpStream, path: PathBuf) -> std::io::Result<()> {
    match std::fs::read(&path) {
        Ok(bytes) => respond(stream, 200, "application/json", &bytes),
        Err(_) => respond(stream, 404, "text/plain", b"artifact not written yet"),
    }
}

fn respond(stream: &mut TcpStream, code: u16, content_type: &str, body: &[u8]) -> std::io::Result<()> {
    let reason = match code {
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        _ => "Not Found",
    };
    // CORS: the VS Code webview origin is vscode-webview://, browsers send
    // preflights; loopback-only bind is the actual security boundary.
    let head = format!(
        "HTTP/1.1 {code} {reason}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         Access-Control-Allow-Origin: *\r\n\
         Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n\
         Access-Control-Allow-Headers: content-type\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(port: u16, raw: &str) -> String {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream.write_all(raw.as_bytes()).unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        response
    }

    fn tmpdir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("bar-mission-kit-http-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn view_is_served_and_edits_land_in_the_channel() {
        let dir = tmpdir("roundtrip");
        std::fs::write(dir.join("mission_view.json"), "{\"generation\":3}").unwrap();
        let port = spawn("127.0.0.1:0", dir.clone()).unwrap();

        let response = request(port, "GET /view HTTP/1.1\r\n\r\n");
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert!(response.contains("{\"generation\":3}"));
        assert!(response.contains("Access-Control-Allow-Origin: *"));

        let intent = "{\"file\":\"t.lua\",\"start\":0,\"end\":1,\"new_text\":\"x\"}";
        let response = request(
            port,
            &format!("POST /edit HTTP/1.1\r\nContent-Length: {}\r\n\r\n{intent}", intent.len()),
        );
        assert!(response.starts_with("HTTP/1.1 202"), "{response}");
        let edits: Vec<_> = std::fs::read_dir(dir.join("edits")).unwrap().flatten().collect();
        assert_eq!(edits.len(), 1);
        assert_eq!(std::fs::read_to_string(edits[0].path()).unwrap(), intent);
    }

    #[test]
    fn garbage_intents_are_refused_before_the_channel() {
        let dir = tmpdir("garbage");
        let port = spawn("127.0.0.1:0", dir.clone()).unwrap();
        let response = request(port, "POST /edit HTTP/1.1\r\nContent-Length: 4\r\n\r\nnope");
        assert!(response.starts_with("HTTP/1.1 400"), "{response}");
        assert!(!dir.join("edits").exists() || std::fs::read_dir(dir.join("edits")).unwrap().count() == 0);
    }

    #[test]
    fn the_browser_terminal_is_served_at_the_root() {
        let dir = tmpdir("terminal");
        let port = spawn("127.0.0.1:0", dir).unwrap();
        let response = request(port, "GET / HTTP/1.1\r\n\r\n");
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert!(response.contains("text/html"));
        assert!(response.contains("Campaign Editor"));
        // query strings must not defeat the router (the sidebar loads /?embed=1)
        let response = request(port, "GET /?embed=1 HTTP/1.1\r\n\r\n");
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    }

    #[test]
    fn mission_selections_land_in_the_channel() {
        let dir = tmpdir("select");
        let port = spawn("127.0.0.1:0", dir.clone()).unwrap();
        let body = "{\"name\":\"cm8_ashfall\"}";
        let response = request(
            port,
            &format!("POST /select_mission HTTP/1.1\r\nContent-Length: {}\r\n\r\n{body}", body.len()),
        );
        assert!(response.starts_with("HTTP/1.1 200"), "{response}");
        assert_eq!(std::fs::read_to_string(dir.join("select_mission.json")).unwrap(), body);
        let response = request(port, "POST /select_mission HTTP/1.1\r\nContent-Length: 4\r\n\r\nnope");
        assert!(response.starts_with("HTTP/1.1 400"), "{response}");
    }

    #[test]
    fn missing_artifacts_are_a_clean_404() {
        let dir = tmpdir("missing");
        let port = spawn("127.0.0.1:0", dir).unwrap();
        let response = request(port, "GET /view HTTP/1.1\r\n\r\n");
        assert!(response.starts_with("HTTP/1.1 404"), "{response}");
    }
}
