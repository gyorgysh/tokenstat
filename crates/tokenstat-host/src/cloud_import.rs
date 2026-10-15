// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Read-only cloud inventory import into the shared SSH host library.

use std::io::Read;
#[cfg(feature = "local-host")]
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    match method {
        "ssh.provider.digitalOcean.import" | "ssh.provider.aws.import" => Some((|| {
            crate::request_context::refuse_remote("SSH cloud import")?;
            match method {
                "ssh.provider.digitalOcean.import" => import_digital_ocean(params),
                "ssh.provider.aws.import" => import_aws(params),
                _ => unreachable!(),
            }
        })()),
        _ => None,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DoParams {
    token: String,
    #[serde(default = "root")]
    username: String,
}
fn root() -> String {
    "root".into()
}

#[derive(Deserialize)]
struct DropletPage {
    droplets: Vec<Droplet>,
    #[serde(default)]
    links: Value,
}
#[derive(Deserialize)]
struct Droplet {
    id: u64,
    name: String,
    region: DoRegion,
    networks: DoNetworks,
}
#[derive(Deserialize)]
struct DoRegion {
    slug: String,
}
#[derive(Deserialize)]
struct DoNetworks {
    v4: Vec<DoNetwork>,
}
#[derive(Deserialize)]
struct DoNetwork {
    ip_address: String,
    #[serde(rename = "type")]
    kind: String,
}

fn import_digital_ocean(params: &str) -> Result<Value, String> {
    let p: DoParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    if p.token.trim().is_empty() {
        return Err("DigitalOcean token is required".into());
    }
    let client = tokenstat_sync::http::client_builder()
        .timeout(Duration::from_secs(20))
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;
    let mut hosts = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(120);
    for page_number in 1..=100 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("DigitalOcean inventory timed out; no hosts were imported".into());
        }
        // Follow pagination only on the fixed provider endpoint. A returned
        // link must never redirect the bearer credential to another server.
        let response = client
            .get("https://api.digitalocean.com/v2/droplets")
            .timeout(remaining.min(Duration::from_secs(20)))
            .query(&[("per_page", 200), ("page", page_number)])
            .bearer_auth(p.token.trim())
            .send()
            .map_err(|e| format!("DigitalOcean request failed: {e}"))?;
        if !response.status().is_success() {
            return Err(format!("DigitalOcean returned {}", response.status()));
        }
        let mut bytes = Vec::new();
        response
            .take(2 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > 2 * 1024 * 1024 {
            return Err("DigitalOcean inventory page is too large".into());
        }
        let page: DropletPage = serde_json::from_slice(&bytes)
            .map_err(|e| format!("DigitalOcean response was invalid: {e}"))?;
        hosts.extend(page.droplets.iter().filter_map(|d| do_host(d, &p.username)));
        if page
            .links
            .pointer("/pages/next")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
        {
            return save_hosts(hosts.into_iter());
        }
    }
    Err("DigitalOcean inventory exceeded the page limit; no hosts were imported".into())
}

fn do_host(d: &Droplet, username: &str) -> Option<Value> {
    let address = d
        .networks
        .v4
        .iter()
        .find(|n| n.kind == "public")
        .or_else(|| d.networks.v4.first())?
        .ip_address
        .clone();
    Some(
        json!({"id":"", "label":d.name, "hostname":address, "port":22, "username":username, "initialDirectory":"~", "credentialID":null, "tags":["digitalocean", d.region.slug], "provider":{"kind":"digitalocean", "resourceId":d.id.to_string(), "region":d.region.slug}, "hostKeys":[]}),
    )
}

fn save_hosts(hosts: impl Iterator<Item = Value>) -> Result<Value, String> {
    let hosts = hosts
        .map(serde_json::from_value)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    let imported = crate::ssh_records::import_hosts(hosts)?;
    Ok(json!({"imported": imported.len(), "hosts": imported}))
}

#[cfg(feature = "local-host")]
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AwsParams {
    #[serde(default)]
    profile: Option<String>,
    #[serde(default)]
    region: Option<String>,
    #[serde(default = "ec2_user")]
    username: String,
}
#[cfg(feature = "local-host")]
fn ec2_user() -> String {
    "ec2-user".into()
}

#[cfg(not(feature = "local-host"))]
fn import_aws(_params: &str) -> Result<Value, String> {
    Err("AWS CLI import requires a desktop host".into())
}

#[cfg(feature = "local-host")]
fn import_aws(params: &str) -> Result<Value, String> {
    let p: AwsParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let mut command =
        Command::new(crate::launcher::resolve_command("aws").unwrap_or_else(|| "aws".into()));
    command.args(["ec2", "describe-instances", "--output", "json"]);
    if let Some(profile) = &p.profile {
        command.args(["--profile", profile]);
    }
    if let Some(region) = &p.region {
        command.args(["--region", region]);
    }
    command
        .env("AWS_PAGER", "")
        .env("AWS_CLI_AUTO_PROMPT", "off");
    let output = aws_output(&mut command, Duration::from_secs(60))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    let value: Value = serde_json::from_slice(&output.stdout)
        .map_err(|e| format!("AWS response was invalid: {e}"))?;
    save_hosts(aws_hosts(&value, &p).into_iter())
}

/// Bound both the process lifetime and its two pipes. AWS configuration can
/// invoke credential helpers, so retire descendants as well on timeout.
#[cfg(feature = "local-host")]
fn aws_output(command: &mut Command, timeout: Duration) -> Result<std::process::Output, String> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|e| {
        format!("Cannot start AWS CLI: {e}. Install it and run `aws configure` first.")
    })?;
    let stdout = child.stdout.take().ok_or("AWS CLI stdout is unavailable")?;
    let stderr = child.stderr.take().ok_or("AWS CLI stderr is unavailable")?;
    fn reader(
        pipe: impl Read + Send + 'static,
        cap: usize,
    ) -> std::sync::mpsc::Receiver<Result<Vec<u8>, String>> {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let answer = pipe
                .take(cap as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|e| e.to_string())
                .and_then(|_| {
                    if bytes.len() > cap {
                        Err("AWS CLI output exceeded its limit".into())
                    } else {
                        Ok(bytes)
                    }
                });
            let _ = tx.send(answer);
        });
        rx
    }
    let out = reader(stdout, 16 * 1024 * 1024);
    let err = reader(stderr, 64 * 1024);
    let deadline = Instant::now() + timeout;
    let mut stdout = None;
    let mut stderr = None;
    let result = (|| {
        loop {
            if stdout.is_none() {
                match out.try_recv() {
                    Ok(value) => stdout = Some(value?),
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                        return Err("Cannot read AWS CLI output".into());
                    }
                    Err(_) => {}
                }
            }
            if stderr.is_none() {
                match err.try_recv() {
                    Ok(value) => stderr = Some(value?),
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                        return Err("Cannot read AWS CLI errors".into());
                    }
                    Err(_) => {}
                }
            }
            if stdout.is_some()
                && stderr.is_some()
                && let Some(status) = child.try_wait().map_err(|e| e.to_string())?
            {
                return Ok(std::process::Output {
                    status,
                    stdout: stdout.take().unwrap(),
                    stderr: stderr.take().unwrap(),
                });
            }
            if Instant::now() >= deadline {
                return Err("AWS CLI timed out; no hosts were imported".into());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    })();
    if result.is_err() {
        #[cfg(unix)]
        if let Ok(pid) = i32::try_from(child.id()) {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
        #[cfg(windows)]
        tokenstat_pty::kill_windows_process_tree(child.id());
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

#[cfg(feature = "local-host")]
fn aws_hosts(value: &Value, p: &AwsParams) -> Vec<Value> {
    let mut hosts = Vec::new();
    for reservation in value
        .get("Reservations")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        for instance in reservation
            .get("Instances")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if instance.pointer("/State/Name").and_then(Value::as_str) == Some("terminated") {
                continue;
            }
            let Some(address) = instance
                .get("PublicIpAddress")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .or_else(|| {
                    instance
                        .get("PrivateIpAddress")
                        .and_then(Value::as_str)
                        .filter(|s| !s.trim().is_empty())
                })
            else {
                continue;
            };
            let id = instance
                .get("InstanceId")
                .and_then(Value::as_str)
                .unwrap_or(address);
            let name = instance
                .get("Tags")
                .and_then(Value::as_array)
                .and_then(|tags| {
                    tags.iter()
                        .find(|t| t.get("Key").and_then(Value::as_str) == Some("Name"))
                })
                .and_then(|t| t.get("Value"))
                .and_then(Value::as_str)
                .unwrap_or(id);
            hosts.push(json!({"id":"", "label":name, "hostname":address, "port":22, "username":p.username, "initialDirectory":"~", "credentialID":null, "tags":["aws", "ec2"], "provider":{"kind":"aws", "resourceId":id, "region":p.region}, "hostKeys":[]}));
        }
    }
    hosts
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(feature = "local-host")]
    #[test]
    fn aws_null_or_empty_public_address_falls_back_to_private() {
        let value = json!({"Reservations":[{"Instances":[
            {"InstanceId":"one","PublicIpAddress":null,"PrivateIpAddress":"10.0.0.1"},
            {"InstanceId":"two","PublicIpAddress":"","PrivateIpAddress":"10.0.0.2"}
        ]}]});
        let hosts = aws_hosts(
            &value,
            &AwsParams {
                profile: None,
                region: None,
                username: ec2_user(),
            },
        );
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0]["hostname"], "10.0.0.1");
        assert_eq!(hosts[1]["hostname"], "10.0.0.2");
    }

    #[test]
    #[cfg(all(unix, feature = "local-host"))]
    fn aws_capture_bounds_wait_and_stderr_without_a_provider_account() {
        let mut command = Command::new("sh");
        command.args(["-c", "printf '{\"Reservations\":[]}'; printf warning >&2"]);
        let output = aws_output(&mut command, Duration::from_secs(2)).unwrap();
        assert!(output.status.success());
        assert_eq!(output.stderr, b"warning");
        let mut command = Command::new("sh");
        command.args(["-c", "sleep 10"]);
        let start = Instant::now();
        assert!(
            aws_output(&mut command, Duration::from_millis(50))
                .unwrap_err()
                .contains("timed out")
        );
        assert!(start.elapsed() < Duration::from_secs(2));
        let mut command = Command::new("sh");
        command.args(["-c", "head -c 100000 /dev/zero >&2"]);
        assert!(
            aws_output(&mut command, Duration::from_secs(2))
                .unwrap_err()
                .contains("limit")
        );
    }

    #[test]
    fn parses_droplet_inventory() {
        let page: DropletPage = serde_json::from_value(json!({"droplets":[{"id":7,"name":"web","region":{"slug":"fra1"},"networks":{"v4":[{"ip_address":"203.0.113.7","type":"public"}]}}]})).unwrap();
        assert_eq!(page.droplets.len(), 1);
        assert_eq!(page.droplets[0].name, "web");
    }
    #[test]
    fn imported_hosts_carry_a_provider_the_records_accept() {
        let page: DropletPage = serde_json::from_value(json!({"droplets":[{"id":7,"name":"web","region":{"slug":"fra1"},"networks":{"v4":[{"ip_address":"203.0.113.7","type":"public"}]}}]})).unwrap();
        let host =
            do_host(&page.droplets[0], "root").expect("droplet with a public address imports");
        let provider: crate::ssh_records::ProviderRef =
            serde_json::from_value(host["provider"].clone()).expect("provider ref deserializes");
        assert_eq!(provider.resource_id, "7");
    }
    #[test]
    #[cfg(feature = "local-host")]
    fn normalizes_running_ec2_instances() {
        let value = json!({"Reservations":[{"Instances":[{"InstanceId":"i-1","PublicIpAddress":"203.0.113.9","State":{"Name":"running"},"Tags":[{"Key":"Name","Value":"web"}]},{"InstanceId":"i-2","State":{"Name":"terminated"}}]}]});
        let hosts = aws_hosts(
            &value,
            &AwsParams {
                profile: None,
                region: Some("eu-west-1".into()),
                username: ec2_user(),
            },
        );
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0]["label"], "web");
        assert_eq!(hosts[0]["provider"]["resourceId"], "i-1");
        serde_json::from_value::<crate::ssh_records::ProviderRef>(hosts[0]["provider"].clone())
            .expect("provider ref deserializes");
    }

    #[test]
    fn a_remote_peer_cannot_import_cloud_hosts() {
        crate::request_context::with_remote_peer("phone", || {
            assert!(
                call(
                    "ssh.provider.digitalOcean.import",
                    r#"{"token":"dop_v1_x"}"#
                )
                .unwrap()
                .is_err()
            );
        });
    }
}
