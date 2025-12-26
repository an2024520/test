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


















