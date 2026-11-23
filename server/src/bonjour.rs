//! Bonjour (mDNS): the server announces itself in the home network as `_halden._tcp`, so the
//! apps find it without typing an address. The announcement carries the server's ID, its
//! certificate fingerprint (public anyway, see `GET /server`), the API version and the name.
//! Finding the server is not trusting it: a device still pairs or signs in, and pins the
//! fingerprint it was shown.
//!
//! It is sent only on interfaces with a home-network address, never on public or Tailscale
//! addresses (Tailscale carries no multicast). `[network] bonjour = false` turns it off.

use std::{net::IpAddr, time::Duration};

use mdns_sd::{IfKind, IfPredicate, ServiceDaemon, ServiceInfo};
use uuid::Uuid;

use crate::{API_VERSION, VERSION, net, tls::Fingerprint};

pub const SERVICE_TYPE: &str = "_halden._tcp.local.";

/// The running announcement. [`Announcement::stop`] says goodbye on the network.
pub struct Announcement {
    daemon: ServiceDaemon,
    fullname: String,
}

/// Announce on this address? Home network yes; loopback, Tailscale and public addresses no.
pub fn announce_on(ip: IpAddr) -> bool {
    let ip = ip.to_canonical();
    !ip.is_loopback() && net::is_home_network(ip) && !net::is_tailscale(ip)
}

/// A host name mDNS accepts: letters, digits and dashes, ending in `.local.`.
fn host_name() -> String {
    let host: String = gethostname::gethostname()
        .to_string_lossy()
        .split('.')
        .next()
        .unwrap_or_default()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    let host = host.trim_matches('-');
    format!("{}.local.", if host.is_empty() { "halden" } else { host })
}

/// Starts announcing. Failures are logged, never fatal: the apps can still connect by address.
pub fn announce(
    name: &str,
    server_id: Uuid,
    fingerprint: &Fingerprint,
    port: u16,
) -> Option<Announcement> {
    let started = (|| -> Result<Announcement, mdns_sd::Error> {
        let daemon = ServiceDaemon::new()?;
        daemon.disable_interface(IfKind::All)?;
        daemon.enable_interface(IfKind::Predicate(IfPredicate::new(|interface| {
            announce_on(interface.ip())
        })))?;
        // A stable instance name that can't clash with another Halden server's; the app shows
        // the `name` from the text record.
        let instance = format!("halden-{}", &server_id.simple().to_string()[..8]);
        let display: String = name.chars().take(60).collect();
        let id = server_id.to_string();
        let api = API_VERSION.to_string();
        let fingerprint = fingerprint.hex();
        let properties = [
            ("id", id.as_str()),
            ("fp", fingerprint.as_str()),
            ("api", api.as_str()),
            ("v", VERSION),
            ("name", display.as_str()),
        ];
        let service = ServiceInfo::new(
            SERVICE_TYPE,
            &instance,
            &host_name(),
            "",
            port,
            &properties[..],
        )?
        .enable_addr_auto();
        let fullname = service.get_fullname().to_string();
        daemon.register(service)?;
        Ok(Announcement { daemon, fullname })
    })();
    match started {
        Ok(announcement) => {
            tracing::info!("announced in the home network (Bonjour)");
            Some(announcement)
        }
        Err(error) => {
            tracing::warn!(%error, "could not announce the server in the home network");
            None
        }
    }
}

impl Announcement {
    /// Withdraws the announcement and stops the mDNS thread. Blocks for at most a second.
    pub fn stop(self) {
        if let Ok(done) = self.daemon.unregister(&self.fullname) {
            let _ = done.recv_timeout(Duration::from_secs(1));
        }
        if let Ok(done) = self.daemon.shutdown() {
            let _ = done.recv_timeout(Duration::from_secs(1));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_home_network_addresses() {
        for (ip, expected) in [
            ("192.168.1.20", true),
            ("10.0.0.5", true),
            ("fd12:3456::1", true),
            ("fe80::1", true),
            ("127.0.0.1", false),
            ("::1", false),
            ("100.101.102.103", false),
            ("203.0.113.9", false),
        ] {
            assert_eq!(announce_on(ip.parse().unwrap()), expected, "{ip}");
        }
        assert!(host_name().ends_with(".local."));
    }
}
