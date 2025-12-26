1.10.0
TUN address fields are merged
inet4_address and inet6_address are merged into address, inet4_route_address and inet6_route_address are merged into route_address, inet4_route_exclude_address and inet6_route_exclude_address are merged into route_exclude_address.
References
TUN
Deprecated:
{
  "inbounds": [
    {
      "type": "tun",
      "inet4_address": "172.19.0.1/30",
      "inet6_address": "fdfe:dcba:9876::1/126",
      "inet4_route_address": [
        "0.0.0.0/1",
        "128.0.0.0/1"
      ],
      "inet6_route_address": [
        "::/1",
        "8000::/1"
      ],
      "inet4_route_exclude_address": [
        "192.168.0.0/16"
      ],
      "inet6_route_exclude_address": [
        "fc00::/7"
      ]
    }
  ]
}
New:
{
  "inbounds": [
    {
      "type": "tun",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "route_address": [
        "0.0.0.0/1",
        "128.0.0.0/1",
        "::/1",
        "8000::/1"
      ],
      "route_exclude_address": [
        "192.168.0.0/16",
        "fc00::/7"
      ]
    }
  ]
}


1.11.0
Migrate legacy special outbounds to rule actions
Legacy special outbounds are deprecated and can be replaced by rule actions.
References
Rule Action / Block / DNS
Block
Deprecated:
{
  "outbounds": [
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        ...,

        "outbound": "block"
      }
    ]
  }
}
New:
{
  "route": {
    "rules": [
      {
        ...,

        "action": "reject"
      }
    ]
  }
}

DNS
Deprecated:
{
  "inbound": [
    {
      ...,

      "sniff": true
    }
  ],
  "outbounds": [
    {
      "tag": "dns",
      "type": "dns"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns"
      }
    ]
  }
}
New:
{
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ]
  }
}

Migrate legacy inbound fields to rule actions
Inbound fields are deprecated and can be replaced by rule actions.
References
Listen Fields / Rule / Rule Action / DNS Rule / DNS Rule Action
Deprecated:
{
  "inbounds": [
    {
      "type": "mixed",
      "sniff": true,
      "sniff_timeout": "1s",
      "domain_strategy": "prefer_ipv4"
    }
  ]
}
New:
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "in"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": "in",
        "action": "resolve",
        "strategy": "prefer_ipv4"
      },
      {
        "inbound": "in",
        "action": "sniff",
        "timeout": "1s"
      }
    ]
  }
}

Migrate destination override fields to route options
Destination override fields in direct outbound are deprecated and can be replaced by route options.
References
Rule Action / Direct
Deprecated:
{
  "outbounds": [
    {
      "type": "direct",
      "override_address": "1.1.1.1",
      "override_port": 443
    }
  ]
}
New:
{
  "route": {
    "rules": [
      {
        "action": "route-options", // or route
        "override_address": "1.1.1.1",
        "override_port": 443
      }
    ]
  }

Migrate WireGuard outbound to endpoint
WireGuard outbound is deprecated and can be replaced by endpoint.
References
Deprecated:
{
  "outbounds": [
    {
      "type": "wireguard",
      "tag": "wg-out",

      "server": "127.0.0.1",
      "server_port": 10001,
      "system_interface": true,
      "gso": true,
      "interface_name": "wg0",
      "local_address": [
        "10.0.0.1/32"
      ],
      "private_key": "<private_key>",
      "peer_public_key": "<peer_public_key>",
      "pre_shared_key": "<pre_shared_key>",
      "reserved": [0, 0, 0],
      "mtu": 1408
    }
  ]
}
New:
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wg-ep",
      "system": true,
      "name": "wg0",
      "mtu": 1408,
      "address": [
        "10.0.0.2/32"
      ],
      "private_key": "<private_key>",
      "listen_port": 10000,
      "peers": [
        {
          "address": "127.0.0.1",
          "port": 10001,
          "public_key": "<peer_public_key>",
          "pre_shared_key": "<pre_shared_key>",
          "allowed_ips": [
            "0.0.0.0/0"
          ],
          "persistent_keepalive_interval": 30,
          "reserved": [0, 0, 0]
        }
      ]
    }
  ]
}


1.12.0
Migrate to new DNS server formats
DNS servers are refactored for better performance and scalability.
References
DNS Server / Legacy DNS Server
Local
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "local"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "local"
      }
    ]
  }
}
TCP
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "tcp://1.1.1.1"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "tcp",
        "server": "1.1.1.1"
      }
    ]
  }
}
UDP
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "1.1.1.1"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "server": "1.1.1.1"
      }
    ]
  }
}
TLS
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "tls://1.1.1.1"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "tls",
        "server": "1.1.1.1"
      }
    ]
  }
}
HTTPS
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "https://1.1.1.1/dns-query"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "https",
        "server": "1.1.1.1"
      }
    ]
  }
}
QUIC
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "quic://1.1.1.1"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "quic",
        "server": "1.1.1.1"
      }
    ]
  }
}
HTTP3
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "h3://1.1.1.1/dns-query"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "h3",
        "server": "1.1.1.1"
      }
    ]
  }
}
DHCP
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "dhcp://auto"
      },
      {
        "address": "dhcp://en0"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "dhcp",
      },
      {
        "type": "dhcp",
        "interface": "en0"
      }
    ]
  }
}
FakeIP
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "1.1.1.1"
      },
      {
        "address": "fakeip",
        "tag": "fakeip"
      }
    ],
    "rules": [
      {
        "query_type": [
          "A",
          "AAAA"
        ],
        "server": "fakeip"
      }
    ],
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15",
      "inet6_range": "fc00::/18"
    }
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "server": "1.1.1.1"
      },
      {
        "type": "fakeip",
        "tag": "fakeip",
        "inet4_range": "198.18.0.0/15",
        "inet6_range": "fc00::/18"
      }
    ],
    "rules": [
      {
        "query_type": [
          "A",
          "AAAA"
        ],
        "server": "fakeip"
      }
    ]
  }
}
RCode
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "rcode://refused"
      }
    ]
  }
}
New:
{
  "dns": {
    "rules": [
      {
        "domain": [
          "example.com"
        ],
        // other rules

        "action": "predefined",
        "rcode": "REFUSED"
      }
    ]
  }
}
Servers with domain address
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "https://dns.google/dns-query",
        "address_resolver": "google"
      },
      {
        "tag": "google",
        "address": "1.1.1.1"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "https",
        "server": "dns.google",
        "domain_resolver": "google"
      },
      {
        "type": "udp",
        "tag": "google",
        "server": "1.1.1.1"
      }
    ]
  }
}
Servers with strategy
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "1.1.1.1",
        "strategy": "ipv4_only"
      },
      {
        "tag": "google",
        "address": "8.8.8.8",
        "strategy": "prefer_ipv6"
      }
    ],
    "rules": [
      {
        "domain": "google.com",
        "server": "google"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "server": "1.1.1.1"
      },
      {
        "type": "udp",
        "tag": "google",
        "server": "8.8.8.8"
      }
    ],
    "rules": [
      {
        "domain": "google.com",
        "server": "google",
        "strategy": "prefer_ipv6"
      }
    ],
    "strategy": "ipv4_only"
  }
}
Servers with client subnet
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "1.1.1.1"
      },
      {
        "tag": "google",
        "address": "8.8.8.8",
        "client_subnet": "1.1.1.1"
      }
    ]
  }
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "udp",
        "server": "1.1.1.1"
      },
      {
        "type": "udp",
        "tag": "google",
        "server": "8.8.8.8"
      }
    ],
    "rules": [
      {
        "domain": "google.com",
        "server": "google",
        "client_subnet": "1.1.1.1"
      }
    ]
  }
}

Migrate outbound DNS rule items to domain resolver
The legacy outbound DNS rules are deprecated and can be replaced by new domain resolver options.
References
DNS rule / Dial Fields / Route
Deprecated:
{
  "dns": {
    "servers": [
      {
        "address": "local",
        "tag": "local"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "local"
      }
    ]
  },
  "outbounds": [
    {
      "type": "socks",
      "server": "example.org",
      "server_port": 2080
    }
  ]
}
New:
{
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local"
      }
    ]
  },
  "outbounds": [
    {
      "type": "socks",
      "server": "example.org",
      "server_port": 2080,
      "domain_resolver": {
        "server": "local",
        "rewrite_ttl": 60,
        "client_subnet": "1.1.1.1"
      },
      // or "domain_resolver": "local",
    }
  ],

  // or

  "route": {
    "default_domain_resolver": {
      "server": "local",
      "rewrite_ttl": 60,
      "client_subnet": "1.1.1.1"
    }
  }
}

Migrate outbound domain strategy option to domain resolver
References
Dial Fields
The domain_strategy option in Dial Fields has been deprecated and can be replaced with the new domain resolver option.
Note that due to the use of Dial Fields by some of the new DNS servers introduced in sing-box 1.12, some people mistakenly believe that domain_strategy is the same feature as in the legacy DNS servers.
Deprecated:
{
  "outbounds": [
    {
      "type": "socks",
      "server": "example.org",
      "server_port": 2080,
      "domain_strategy": "prefer_ipv4",
    }
  ]
}
New:
 {
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local"
      }
    ]
  },
  "outbounds": [
    {
      "type": "socks",
      "server": "example.org",
      "server_port": 2080,
      "domain_resolver": {
        "server": "local",
        "strategy": "prefer_ipv4"
      }
    }
  ]
}
























































































































































