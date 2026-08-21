// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Read-only cloud inventory import into the shared SSH host library.

use serde::Deserialize;
use serde_json::{Value, json};

pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    match method {
        "ssh.provider.digitalOcean.import" => Some(import_digital_ocean(params)),
        _ => None,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DoParams {
    token: String,
    #[serde(default = "root")]
    username: String,
    #[serde(default)]
    endpoint: Option<String>,
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
    let endpoint = p
        .endpoint
        .unwrap_or_else(|| "https://api.digitalocean.com/v2/droplets?per_page=200".into());
    let response = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|e| e.to_string())?
        .get(endpoint)
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
        Some(json!({"id":"", "label":d.name, "hostname":address, "port":22, "username":p.username, "tags":["digitalocean", d.region.slug], "provider":{"kind":"digitalocean", "resourceID":d.id.to_string(), "region":d.region.slug}, "hostKeys":[]}))
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_droplet_inventory() {
        let page: DropletPage = serde_json::from_value(json!({"droplets":[{"id":7,"name":"web","region":{"slug":"fra1"},"networks":{"v4":[{"ip_address":"203.0.113.7","type":"public"}]}}]})).unwrap();
        assert_eq!(page.droplets.len(), 1);
        assert_eq!(page.droplets[0].name, "web");
    }
}
