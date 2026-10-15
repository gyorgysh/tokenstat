// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Shared HTTP TLS policy for native clients, including Android without a JVM.

use std::sync::LazyLock;

pub fn client_builder() -> reqwest::blocking::ClientBuilder {
    // reqwest 0.13 otherwise switches to platform certificate verification,
    // which requires Java initialization on Android. Keep the Mozilla trust
    // store and ring provider used before the upgrade on every native target.
    static ROOTS: LazyLock<Vec<reqwest::Certificate>> = LazyLock::new(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
        webpki_root_certs::TLS_SERVER_ROOT_CERTS
            .iter()
            .map(|cert| {
                reqwest::Certificate::from_der(cert.as_ref())
                    .expect("Mozilla root certificates contain valid DER")
            })
            .collect()
    });
    reqwest::blocking::Client::builder().tls_certs_only(ROOTS.iter().cloned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::time::Duration;

    // Synthetic localhost identity, used only by this loopback TLS fixture.
    const CERT: &str = r#"-----BEGIN CERTIFICATE-----
MIIBnDCCAUGgAwIBAgIUMo4CZBB6Qun12sfUR6dIoaSF+zEwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAxNTEzNTEyOFoYDzIxMjYwOTIx
MTM1MTI4WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAAQRcadB2QVo8sHQMHPHpSgkXahz8Q0p1Oe4rT7ZolM710JLb8rG/npx
tsnewaX4Hj7B5R0dmPeS85IDdoRQeOMdo28wbTAdBgNVHQ4EFgQUoD50wRagKXM3
v3/+3aREEyiNvkgwHwYDVR0jBBgwFoAUoD50wRagKXM3v3/+3aREEyiNvkgwDwYD
VR0TAQH/BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwCgYIKoZI
zj0EAwIDSQAwRgIhANEnE59lD4JewrC8J6t9RDOurSJuo83Bb92QiDdPouKBAiEA
pu9ARpZ69yEChDeUwA/7Ct6LHbCwpv8y9Yj7dWTEkAs=
-----END CERTIFICATE-----
"#;
    const KEY: &[u8] = &[
        48, 129, 135, 2, 1, 0, 48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134, 72, 206,
        61, 3, 1, 7, 4, 109, 48, 107, 2, 1, 1, 4, 32, 162, 2, 37, 212, 248, 116, 209, 100, 111, 58,
        244, 83, 223, 28, 251, 188, 141, 251, 244, 159, 152, 125, 215, 35, 66, 13, 39, 78, 60, 137,
        91, 152, 161, 68, 3, 66, 0, 4, 17, 113, 167, 65, 217, 5, 104, 242, 193, 208, 48, 115, 199,
        165, 40, 36, 93, 168, 115, 241, 13, 41, 212, 231, 184, 173, 62, 217, 162, 83, 59, 215, 66,
        75, 111, 202, 198, 254, 122, 113, 182, 201, 222, 193, 165, 248, 30, 62, 193, 229, 29, 29,
        152, 247, 146, 243, 146, 3, 118, 132, 80, 120, 227, 29,
    ];

    fn server() -> (String, std::thread::JoinHandle<()>) {
        let config = rustls::ServerConfig::builder_with_provider(std::sync::Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from_pem_slice(CERT.as_bytes()).unwrap()],
            PrivateKeyDer::Pkcs8(KEY.to_vec().into()),
        )
        .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("https://{}", listener.local_addr().unwrap());
        let thread = std::thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            socket
                .set_write_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            let connection = rustls::ServerConnection::new(std::sync::Arc::new(config)).unwrap();
            let mut stream = rustls::StreamOwned::new(connection, socket);
            let mut request = [0; 4096];
            if stream.read(&mut request).is_ok() {
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                );
            }
        });
        (url, thread)
    }

    #[test]
    fn verifies_https_and_preserves_explicit_loopback_certificate_override() {
        let (url, thread) = server();
        let response = client_builder()
            .no_proxy()
            .timeout(Duration::from_secs(10))
            .build()
            .unwrap()
            .get(&url)
            .send();
        assert!(
            response.unwrap_err().is_connect(),
            "Untrusted TLS must be rejected."
        );
        thread.join().unwrap();

        // Antigravity's local language server uses this explicit override.
        let (url, thread) = server();
        let response = client_builder()
            .no_proxy()
            .timeout(Duration::from_secs(10))
            .danger_accept_invalid_certs(true)
            .build()
            .unwrap()
            .get(&url)
            .send()
            .unwrap();
        assert_eq!(response.text().unwrap(), "ok");
        thread.join().unwrap();
    }
}
