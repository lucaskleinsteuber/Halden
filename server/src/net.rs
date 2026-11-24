//! Who may connect: by default only the home network, link-local addresses and Tailscale.
//!
//! The check runs when a connection is accepted, before the TLS handshake, so a stranger on the
//! internet gets nothing at all: no certificate, no error page, no work for the server.

use std::{
    fmt, io,
    net::{IpAddr, Ipv4Addr},
    str::FromStr,
    sync::Arc,
};

use axum_server::accept::Accept;
use serde::{Deserialize, Serialize};
use tokio::net::TcpStream;

use crate::config::NetworkConfig;

/// An IP network such as `192.168.1.0/24` or `fd7a:115c:a1e0::/48`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Cidr {
    addr: IpAddr,
    prefix: u8,
}

/// Tailscale gives devices addresses from the carrier-grade NAT range.
pub const TAILSCALE_V4: Cidr = Cidr {
    addr: IpAddr::V4(Ipv4Addr::new(100, 64, 0, 0)),
    prefix: 10,
};

impl Cidr {
    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.addr, ip.to_canonical()) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                let mask = mask_u32(self.prefix);
                u32::from(net) & mask == u32::from(ip) & mask
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                let mask = mask_u128(self.prefix);
                u128::from(net) & mask == u128::from(ip) & mask
            }
            _ => false,
        }
    }
}

fn mask_u32(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - u32::from(prefix))
    }
}

fn mask_u128(prefix: u8) -> u128 {
    if prefix == 0 {
        0
    } else {
        u128::MAX << (128 - u32::from(prefix))
    }
}

impl FromStr for Cidr {
    type Err = String;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let text = text.trim();
        let (addr, prefix) = match text.split_once('/') {
            Some((addr, prefix)) => (addr, Some(prefix)),
            None => (text, None),
        };
        let addr: IpAddr = addr
            .parse()
            .map_err(|_| format!("{text:?} is not an IP address or network"))?;
        let max = if addr.is_ipv4() { 32 } else { 128 };
        let prefix = match prefix {
            Some(prefix) => prefix
                .parse::<u8>()
                .ok()
                .filter(|p| *p <= max)
                .ok_or_else(|| format!("{text:?} has an invalid prefix length"))?,
            None => max,
        };
        Ok(Cidr { addr, prefix })
    }
}

impl TryFrom<String> for Cidr {
    type Error = String;
    fn try_from(text: String) -> Result<Self, Self::Error> {
        text.parse()
    }
}

impl From<Cidr> for String {
    fn from(cidr: Cidr) -> Self {
        cidr.to_string()
    }
}

impl fmt::Display for Cidr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}/{}", self.addr, self.prefix)
    }
}

/// Loopback, private (192.168.x.x, 10.x.x.x, 172.16-31.x.x, IPv6 unique local), link-local, or
/// Tailscale. IPv4 addresses that arrive as IPv6 (`::ffff:192.168.1.5`) count as IPv4.
pub fn is_home_network(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || TAILSCALE_V4.contains(IpAddr::V4(v4))
        }
        IpAddr::V6(v6) => v6.is_loopback() || v6.is_unique_local() || v6.is_unicast_link_local(),
    }
}

pub fn is_tailscale(ip: IpAddr) -> bool {
    TAILSCALE_V4.contains(ip)
        || Cidr {
            addr: IpAddr::V6(std::net::Ipv6Addr::new(
                0xfd7a, 0x115c, 0xa1e0, 0, 0, 0, 0, 0,
            )),
            prefix: 48,
        }
        .contains(ip)
}

/// The rule deciding which addresses may connect.
#[derive(Debug, Clone)]
pub struct NetworkPolicy {
    allow_public: bool,
    extra: Arc<[Cidr]>,
}

impl NetworkPolicy {
    pub fn from_config(config: &NetworkConfig) -> Self {
        Self {
            allow_public: config.allow_public,
            extra: config.allowed_networks.clone().into(),
        }
    }

    pub fn allows(&self, ip: IpAddr) -> bool {
        self.allow_public || is_home_network(ip) || self.extra.iter().any(|net| net.contains(ip))
    }
}

/// Drops connections from addresses the [`NetworkPolicy`] refuses, before TLS starts.
#[derive(Debug, Clone)]
pub struct HomeNetworkAcceptor {
    policy: NetworkPolicy,
}

impl HomeNetworkAcceptor {
    pub fn new(policy: NetworkPolicy) -> Self {
        Self { policy }
    }

    /// Whether a connection from `peer` may go on to TLS.
    fn admit(&self, peer: IpAddr) -> io::Result<()> {
        if self.policy.allows(peer) {
            Ok(())
        } else {
            tracing::debug!(%peer, "refused a connection from outside the home network");
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "connection from outside the home network",
            ))
        }
    }
}

impl<S> Accept<TcpStream, S> for HomeNetworkAcceptor {
    type Stream = TcpStream;
    type Service = S;
    type Future = std::future::Ready<io::Result<(TcpStream, S)>>;

    fn accept(&self, stream: TcpStream, service: S) -> Self::Future {
        let result = stream
            .peer_addr()
            .and_then(|peer| self.admit(peer.ip()))
            .and_then(|()| stream.set_nodelay(true))
            .map(|()| (stream, service));
        std::future::ready(result)
    }
}

/// This computer's addresses that apps on the home network or Tailscale can use, IPv4 first.
pub fn local_addresses() -> Vec<IpAddr> {
    let mut addresses: Vec<IpAddr> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|iface| !iface.is_loopback())
        .map(|iface| iface.ip())
        .filter(|ip| is_home_network(*ip))
        .collect();
    addresses.sort_by_key(|ip| (ip.is_ipv6(), is_tailscale(*ip), *ip));
    addresses.dedup();
    addresses
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn the_door_refuses_outsiders_before_tls() {
        let acceptor =
            |config: NetworkConfig| HomeNetworkAcceptor::new(NetworkPolicy::from_config(&config));
        let home = acceptor(NetworkConfig::default());
        assert!(home.admit(ip("192.168.1.20")).is_ok());
        assert!(home.admit(ip("100.101.102.103")).is_ok(), "Tailscale");
        let refused = home.admit(ip("203.0.113.9")).unwrap_err();
        assert_eq!(refused.kind(), io::ErrorKind::PermissionDenied);
        let office = acceptor(NetworkConfig {
            allowed_networks: vec!["203.0.113.0/24".parse().unwrap()],
            ..NetworkConfig::default()
        });
        assert!(office.admit(ip("203.0.113.9")).is_ok());
        assert!(office.admit(ip("198.51.100.1")).is_err());
        let public = acceptor(NetworkConfig {
            allow_public: true,
            ..NetworkConfig::default()
        });
        assert!(public.admit(ip("198.51.100.1")).is_ok());
    }

    #[test]
    fn networks_are_written_back_as_they_are_read() {
        let net: Cidr = "203.0.113.0/24".parse().unwrap();
        assert_eq!(String::from(net), "203.0.113.0/24");
        let single: Cidr = "2001:db8::1".parse().unwrap();
        assert_eq!(String::from(single), "2001:db8::1/128");
    }

    #[test]
    fn local_addresses_are_for_others_to_reach() {
        for address in local_addresses() {
            assert!(!address.is_loopback(), "{address}");
            assert!(is_home_network(address), "{address}");
        }
    }

    #[test]
    fn home_network_addresses_are_allowed() {
        for allowed in [
            "127.0.0.1",
            "192.168.178.20",
            "10.0.0.5",
            "172.16.0.1",
            "172.31.255.255",
            "169.254.10.10",
            "100.64.0.1",
            "100.127.255.254",
            "::1",
            "fd7a:115c:a1e0::1234",
            "fe80::1",
            "::ffff:192.168.1.5",
        ] {
            assert!(is_home_network(ip(allowed)), "{allowed} should be allowed");
        }
    }

    #[test]
    fn public_addresses_are_refused() {
        for refused in [
            "8.8.8.8",
            "172.32.0.1",
            "100.128.0.1",
            "1.1.1.1",
            "2001:4860:4860::8888",
            "::ffff:8.8.8.8",
        ] {
            assert!(!is_home_network(ip(refused)), "{refused} should be refused");
        }
    }

    #[test]
    fn policy_respects_settings() {
        let closed = NetworkPolicy::from_config(&NetworkConfig::default());
        assert!(!closed.allows(ip("203.0.113.9")));

        let extra = NetworkPolicy::from_config(&NetworkConfig {
            allow_public: false,
            allowed_networks: vec!["203.0.113.0/24".parse().unwrap()],
            ..NetworkConfig::default()
        });
        assert!(extra.allows(ip("203.0.113.9")));
        assert!(!extra.allows(ip("203.0.114.9")));

        let open = NetworkPolicy::from_config(&NetworkConfig {
            allow_public: true,
            ..NetworkConfig::default()
        });
        assert!(open.allows(ip("8.8.8.8")));
    }

    #[test]
    fn cidr_parsing() {
        assert_eq!(
            "10.0.0.0/8".parse::<Cidr>().unwrap().to_string(),
            "10.0.0.0/8"
        );
        assert_eq!(
            "10.1.2.3".parse::<Cidr>().unwrap().to_string(),
            "10.1.2.3/32"
        );
        assert!("10.0.0.0/33".parse::<Cidr>().is_err());
        assert!("nonsense".parse::<Cidr>().is_err());
        assert!("0.0.0.0/0".parse::<Cidr>().unwrap().contains(ip("8.8.8.8")));
        assert!(!"10.0.0.0/8".parse::<Cidr>().unwrap().contains(ip("::1")));
    }

    #[test]
    fn tailscale_detection() {
        assert!(is_tailscale(ip("100.101.102.103")));
        assert!(is_tailscale(ip("fd7a:115c:a1e0:ab12::1")));
        assert!(!is_tailscale(ip("192.168.1.2")));
    }
}
