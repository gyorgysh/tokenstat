// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Native inbox delivery, isolated from the output and Stop loops.
use super::*;
use std::collections::HashSet;
use std::sync::{
    Arc, Mutex, PoisonError,
    atomic::{AtomicBool, Ordering},
};

#[derive(Default)]
struct State {
    closed: AtomicBool,
    waiting: Mutex<HashSet<String>>,
}

pub(super) struct Steering {
    state: Arc<State>,
    worker: Option<std::thread::JoinHandle<()>>,
    directory: std::path::PathBuf,
}

impl Steering {
    pub(super) fn start(lease: &Lease, session: &str, directory: &Path) -> Result<Self, String> {
        Self::start_at(&lease.url, &lease.password, session, directory)
    }

    fn start_at(
        endpoint: &reqwest::Url,
        password: &str,
        session: &str,
        directory: &Path,
    ) -> Result<Self, String> {
        let client = tokenstat_sync::http::client_builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(1))
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(|error| error.to_string())?;
        let url = endpoint
            .join(&format!("api/session/{session}/prompt"))
            .map_err(|error| error.to_string())?;
        let password = password.to_owned();
        let directory = directory.to_owned();
        let state = Arc::new(State::default());
        let shared = Arc::clone(&state);
        let root = directory.clone();
        let header = std::env::current_dir().ok().map(|path| {
            crate::opencode_cli::directory_header(&path)
                .trim_start_matches("x-opencode-directory:")
                .to_string()
        });
        let worker = std::thread::Builder::new()
            .name("tokenstat-opencode-input".into())
            .spawn(move || {
                while !shared.closed.load(Ordering::Acquire) {
                    let Ok(entries) = std::fs::read_dir(&root) else {
                        break;
                    };
                    let mut attempts = 0;
                    for entry in entries.flatten() {
                        if shared.closed.load(Ordering::Acquire) {
                            break;
                        }
                        let name = entry.file_name().to_string_lossy().into_owned();
                        let Some(id) = name
                            .strip_prefix("request-")
                            .and_then(|name| name.strip_suffix(".json"))
                        else {
                            continue;
                        };
                        if id.len() != 32 || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                            continue;
                        }
                        if attempts == 8 {
                            break;
                        }
                        attempts += 1;
                        let result = (|| {
                            let request: Value = serde_json::from_slice(
                                &super::super::read_control_file(&entry.path())?,
                            )
                            .map_err(|error| error.to_string())?;
                            let mut body = prompt(id, &request)?;
                            if shared.closed.load(Ordering::Acquire) || root.join("stop").exists() {
                                return Err("The active turn has finished.".into());
                            }
                            let native_id = body["id"].as_str().unwrap().to_owned();
                            shared
                                .waiting
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .insert(native_id.clone());
                            // Do not start another execution if the current one ended
                            // between its last event and this request reaching the server.
                            body["resume"] = json!(false);
                            let mut post = client
                                .post(url.clone())
                                .basic_auth("opencode", Some(&password))
                                .json(&body);
                            if let Some(header) = &header {
                                post = post.header("x-opencode-directory", header);
                            }
                            // Delivery is acknowledged by the native event's
                            // session and unpredictable inbox ID, not by echoing
                            // the response body (which includes entire attachments).
                            // Even a lost HTTP response cannot undo that proof.
                            let _ = post.send();
                            let deadline = Instant::now() + Duration::from_secs(6);
                            while Instant::now() < deadline {
                                if !shared
                                    .waiting
                                    .lock()
                                    .unwrap_or_else(PoisonError::into_inner)
                                    .contains(&native_id)
                                {
                                    return Ok(json!({"ok":true}));
                                }
                                if shared.closed.load(Ordering::Acquire)
                                    || root.join("stop").exists()
                                {
                                    break;
                                }
                                std::thread::sleep(Duration::from_millis(20));
                            }
                            shared
                                .waiting
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .remove(&native_id);
                            // HTTP errors, expiry after submission and a missing
                            // delivery event cannot prove the words were rejected.
                            Ok(json!({"ok":false,"unknown":true}))
                        })()
                        .unwrap_or_else(|error: String| json!({"ok":false,"error":error}));
                        let _ = super::super::write_json(
                            &root.join(format!("response-{id}.json")),
                            &result,
                        );
                        let _ = std::fs::remove_file(entry.path());
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
            })
            .map_err(|error| error.to_string())?;
        let steering = Self {
            state,
            worker: Some(worker),
            directory,
        };
        super::super::write_json(&steering.directory.join("ready.json"), &json!(true))?;
        Ok(steering)
    }

    pub(super) fn delivered(&self, event: &Value, session: &str) {
        if event["type"] == "session.inbox.delivered"
            && event["data"]["sessionID"] == session
            && let Some(id) = event["data"]["inboxID"].as_str()
        {
            self.state
                .waiting
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(id);
        }
    }

    pub(super) fn close(&self) {
        self.state.closed.store(true, Ordering::Release);
        let _ = std::fs::remove_file(self.directory.join("ready.json"));
    }
}

impl Drop for Steering {
    fn drop(&mut self) {
        self.close();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn prompt(id: &str, request: &Value) -> Result<Value, String> {
    if request["id"] != id
        || request["expires"]
            .as_u64()
            .is_none_or(|expires| expires <= super::super::now_ms())
    {
        return Err("The agent input request expired. Try again.".into());
    }
    let text = request["steer"]
        .as_str()
        .filter(|text| !text.trim().is_empty())
        .ok_or("This turn accepts steering messages only.")?;
    let paths = request["images"]
        .as_array()
        .ok_or("Invalid steering attachments.")?;
    if paths.len() > 20 {
        return Err("Too many steering attachments.".into());
    }
    let files = paths
        .iter()
        .map(|path| {
            let path = path.as_str().ok_or("Invalid steering attachment.")?;
            let url = reqwest::Url::from_file_path(path)
                .map_err(|()| "Invalid steering attachment path.")?;
            Ok(json!({"uri":url.as_str()}))
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(json!({"id":format!("msg_tokenstat_{id}"),"text":text,"delivery":"steer","files":files}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn delivery_requires_the_owned_session_and_inbox_id() {
        let root = tempfile::tempdir().unwrap();
        let steering = Steering {
            state: Arc::new(State::default()),
            worker: None,
            directory: root.path().to_owned(),
        };
        steering
            .state
            .waiting
            .lock()
            .unwrap()
            .insert("msg_owned".into());
        for (session, id) in [("ses_other", "msg_owned"), ("ses_current", "msg_other")] {
            steering.delivered(&json!({"type":"session.inbox.delivered","data":{"sessionID":session,"inboxID":id}}),"ses_current");
            assert!(steering.state.waiting.lock().unwrap().contains("msg_owned"));
        }
        steering.delivered(&json!({"type":"session.inbox.delivered","data":{"sessionID":"ses_current","inboxID":"msg_owned"}}),"ses_current");
        assert!(steering.state.waiting.lock().unwrap().is_empty());
    }
    #[test]
    fn invalid_or_expired_requests_do_not_reach_the_server() {
        let path = if cfg!(windows) {
            "C:/tmp/café picture.png"
        } else {
            "/tmp/café picture.png"
        };
        let request = json!({"id":"abc","expires":super::super::super::now_ms()+10000,"steer":"update","images":[path]});
        let valid = prompt("abc", &request).unwrap();
        assert_eq!(
            valid["files"][0]["uri"],
            if cfg!(windows) {
                "file:///C:/tmp/caf%C3%A9%20picture.png"
            } else {
                "file:///tmp/caf%C3%A9%20picture.png"
            }
        );
        assert!(prompt("other", &request).is_err());
        let mut expired = request.clone();
        expired["expires"] = json!(1);
        assert!(prompt("abc", &expired).is_err());
        let mut relative = request;
        relative["images"] = json!(["relative.png"]);
        assert!(prompt("abc", &relative).is_err());
    }
}
