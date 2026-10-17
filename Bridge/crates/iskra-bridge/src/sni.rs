//! The server name out of a TLS ClientHello, read before any connection is made.
//!
//! The bridge checks a *host* — is it a Matrix server, is it on the list — and then carries TLS it
//! cannot read. Without this check the host checked and the server talked to could differ: open a
//! stream to a Matrix server's address and say `Host: someone-else` inside, and a virtual host
//! sharing that IP is reached through the bridge. Requiring the ClientHello's SNI to equal the
//! host from `open` is what ties the two together — **at the TLS layer, and no further.**
//!
//! Inside the TLS is an HTTP `Host` the bridge cannot see, and a front that routes on it rather than
//! on SNI — a CDN shared by many sites — will hand the connection to whichever site that header
//! names. A Matrix server behind such a CDN therefore opens the way to every site on it: domain
//! fronting. Nothing on this side of the TLS can close that; it is a limit of a blind bridge, said
//! in the README, and an operator who cannot accept it lists hosts instead of running open.
//!
//! Only as much of the ClientHello is parsed as it takes to find `server_name`, and every length
//! is checked against what is actually there: these bytes come from a stranger.
//!
//! (ECH would hide the real name inside an encrypted inner ClientHello and leave a public one
//! outside. Nothing the SDK uses sends ECH today; when something does, this is the place to look.)

/// What the first bytes of a stream turned out to be.
#[derive(Debug, PartialEq, Eq)]
pub enum Hello {
    /// A ClientHello naming this server, lower-cased and without a trailing dot.
    Named(String),
    /// A ClientHello that names no server — what a TLS client sends to an IP address.
    Unnamed,
    /// Not enough bytes yet to tell.
    Incomplete,
    /// Not a TLS ClientHello at all.
    NotTls,
}

/// The largest ClientHello waited for: one TLS record. A real one is a few hundred bytes, or about
/// 1.5 KB with a post-quantum key share; a "ClientHello" that is still arriving past this is not one.
pub const MAX_HELLO: usize = 5 + 16 * 1024;

const RECORD_HANDSHAKE: u8 = 22;
const HANDSHAKE_CLIENT_HELLO: u8 = 1;
const EXTENSION_SERVER_NAME: u16 = 0;
const NAME_TYPE_HOST: u8 = 0;

pub fn parse(bytes: &[u8]) -> Hello {
    if bytes.is_empty() {
        return Hello::Incomplete;
    }
    if bytes[0] != RECORD_HANDSHAKE {
        return Hello::NotTls;
    }
    if bytes.len() < 5 {
        return Hello::Incomplete;
    }
    // Record version: 0x0301 to 0x0303, whatever the handshake inside negotiates.
    if bytes[1] != 3 || bytes[2] > 4 {
        return Hello::NotTls;
    }
    let record_len = u16::from_be_bytes([bytes[3], bytes[4]]) as usize;
    if record_len == 0 || record_len > MAX_HELLO - 5 {
        return Hello::NotTls;
    }
    if bytes.len() < 5 + record_len {
        return Hello::Incomplete;
    }
    // A ClientHello split across two records is legal and nobody sends one; refusing it costs a
    // client nothing and saves a reassembler of TLS records here.
    match client_hello(&bytes[5..5 + record_len]) {
        Some(Some(name)) => Hello::Named(name),
        Some(None) => Hello::Unnamed,
        None => Hello::NotTls,
    }
}

/// `None` for anything malformed, `Some(None)` for a well-formed hello with no host name in it.
fn client_hello(record: &[u8]) -> Option<Option<String>> {
    let mut r = Reader(record);
    if r.u8()? != HANDSHAKE_CLIENT_HELLO {
        return None;
    }
    let body_len = r.u24()?;
    let mut body = Reader(r.take(body_len)?);

    body.take(2)?; // legacy_version
    body.take(32)?; // random
    let session = body.u8()? as usize;
    body.take(session)?;
    let suites = body.u16()? as usize;
    body.take(suites)?;
    let compression = body.u8()? as usize;
    body.take(compression)?;
    if body.0.is_empty() {
        return Some(None);
    }
    let extensions = body.u16()? as usize;
    let mut extensions = Reader(body.take(extensions)?);

    while !extensions.0.is_empty() {
        let kind = extensions.u16()?;
        let len = extensions.u16()? as usize;
        let data = extensions.take(len)?;
        if kind != EXTENSION_SERVER_NAME {
            continue;
        }
        let mut list = Reader(data);
        let list_len = list.u16()? as usize;
        let mut list = Reader(list.take(list_len)?);
        while !list.0.is_empty() {
            let name_type = list.u8()?;
            let len = list.u16()? as usize;
            let name = list.take(len)?;
            if name_type == NAME_TYPE_HOST {
                let name = std::str::from_utf8(name).ok()?;
                return Some(Some(normalise(name)));
            }
        }
        return Some(None);
    }
    Some(None)
}

/// How a host name is compared: case does not matter in DNS, and neither does the root's dot.
pub fn normalise(host: &str) -> String {
    host.trim_end_matches('.').to_ascii_lowercase()
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.0.len() < n {
            return None;
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Some(head)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|b| b[0])
    }
    fn u16(&mut self) -> Option<u16> {
        self.take(2).map(|b| u16::from_be_bytes([b[0], b[1]]))
    }
    fn u24(&mut self) -> Option<usize> {
        self.take(3)
            .map(|b| ((b[0] as usize) << 16) | ((b[1] as usize) << 8) | b[2] as usize)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use rustls::pki_types::ServerName;
    use rustls::{ClientConfig, ClientConnection, RootCertStore};

    use super::*;

    /// What rustls — the TLS the SDK speaks — actually sends, rather than a hand-made imitation.
    fn hello_for(name: &str) -> Vec<u8> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let config = ClientConfig::builder()
            .with_root_certificates(RootCertStore::empty())
            .with_no_client_auth();
        let server = ServerName::try_from(name.to_string()).unwrap();
        let mut connection = ClientConnection::new(Arc::new(config), server).unwrap();
        let mut out = Vec::new();
        connection.write_tls(&mut out).unwrap();
        out
    }

    #[test]
    fn the_name_comes_out_of_a_real_client_hello() {
        assert_eq!(
            parse(&hello_for("matrix-client.matrix.org")),
            Hello::Named("matrix-client.matrix.org".into())
        );
    }

    /// rustls sends no SNI to an IP address, and a bridge that only knows names refuses that.
    #[test]
    fn a_hello_to_an_ip_address_names_nobody() {
        assert_eq!(parse(&hello_for("192.0.2.1")), Hello::Unnamed);
    }

    #[test]
    fn half_a_hello_is_incomplete_at_every_length() {
        let hello = hello_for("matrix.org");
        for cut in 0..hello.len() {
            assert_eq!(parse(&hello[..cut]), Hello::Incomplete, "cut at {cut}");
        }
    }

    #[test]
    fn plain_http_is_not_tls() {
        assert_eq!(
            parse(b"GET / HTTP/1.1\r\nHost: matrix.org\r\n\r\n"),
            Hello::NotTls
        );
        assert_eq!(parse(b"SSH-2.0-OpenSSH_9.6\r\n"), Hello::NotTls);
    }

    /// Every length field is a stranger's claim. One that points past the end is malformed, never
    /// a panic and never a read of whatever is next in memory.
    #[test]
    fn lying_lengths_are_refused_not_followed() {
        let hello = hello_for("matrix.org");
        for index in 5..hello.len() {
            let mut broken = hello.clone();
            broken[index] = 0xff;
            let _ = parse(&broken);
        }
        let mut short = hello.clone();
        // The record claims four bytes, and four bytes of a hello parse as nothing.
        short[3] = 0;
        short[4] = 4;
        assert_eq!(parse(&short), Hello::NotTls);
    }

    #[test]
    fn names_compare_without_case_or_the_roots_dot() {
        assert_eq!(normalise("Matrix.ORG."), "matrix.org");
    }
}
