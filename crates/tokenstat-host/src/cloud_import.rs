// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Read-only cloud inventory import into the shared SSH host library.

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
    let response = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?
        .get("https://api.digitalocean.com/v2/droplets?per_page=200")
        .bearer_auth(p.token)
        .send()
        .map_err(|e| format!("DigitalOcean request failed: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("DigitalOcean returned {}", response.status()));
    }
    let page: DropletPage = response
        .json()
        .map_err(|e| format!("DigitalOcean response was invalid: {e}"))?;
    save_hosts(page.droplets.into_iter().filter_map(|d| {
        let address = d.networks.v4.iter().find(|n| n.kind == "public").or_else(|| d.networks.v4.first())?.ip_address.clone();
        Some(json!({"id":"", "label":d.name, "hostname":address, "port":22, "username":p.username, "initialDirectory":"~", "credentialID":null, "tags":["digitalocean", d.region.slug], "provider":{"kind":"digitalocean", "resourceID":d.id.to_string(), "region":d.region.slug}, "hostKeys":[]}))
    }))
}

fn save_hosts(hosts: impl Iterator<Item = Value>) -> Result<Value, String> {
    let mut imported = Vec::new();
    for host in hosts {
        let answer =
            crate::ssh_records::call("ssh.host.save", &host.to_string()).expect("known method")?;
        imported.push(answer);
    }
    Ok(json!({"imported": imported.len(), "hosts": imported}))
}

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
fn ec2_user() -> String {
    "ec2-user".into()
}

fn import_aws(params: &str) -> Result<Value, String> {
    let p: AwsParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let mut command = std::process::Command::new("aws");
    command.args(["ec2", "describe-instances", "--output", "json"]);
    if let Some(profile) = &p.profile {
        command.args(["--profile", profile]);
    }
    if let Some(region) = &p.region {
        command.args(["--region", region]);
    }
    let output = command.output().map_err(|_| {
        "AWS CLI is not installed. Install it and run `aws configure` first.".to_string()
    })?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    let value: Value = serde_json::from_slice(&output.stdout)
        .map_err(|e| format!("AWS response was invalid: {e}"))?;
    save_hosts(aws_hosts(&value, &p).into_iter())
}

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
                .or_else(|| instance.get("PrivateIpAddress"))
                .and_then(Value::as_str)
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
            hosts.push(json!({"id":"", "label":name, "hostname":address, "port":22, "username":p.username, "initialDirectory":"~", "credentialID":null, "tags":["aws", "ec2"], "provider":{"kind":"aws", "resourceID":id, "region":p.region}, "hostKeys":[]}));
        }
    }
    hosts
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_droplet_inventory() {
        let page: DropletPage = serde_json::from_value(json!({"droplets":[{"id":7,"name":"web","region":{"slug":"fra1"},"networks":{"v4":[{"ip_address":"203.0.113.7","type":"public"}]}}]})).unwrap();
        assert_eq!(page.droplets.len(), 1);
        assert_eq!(page.droplets[0].name, "web");
    }
    #[test]
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
        assert_eq!(hosts[0]["provider"]["resourceID"], "i-1");
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
