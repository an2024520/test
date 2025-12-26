# AI Developer Rules & Knowledge Base (Updated: 2025)

## 1. Sing-box Version Compliance (Target: v1.12+)
* **No Bridge Outbounds**: strictly FORBIDDEN to use `type: direct` with `detour`.
* **Endpoint Routing**: Endpoints MUST have a `tag` (e.g., "WARP") and strictly act as routing targets directly.
* **Structure**: Use `endpoints` array for WireGuard/WARP, not `outbounds`.
* **Fields**: 
    * Use `address` / `port` inside `peers` (New Standard).
    * DO NOT use `server` / `server_port`.

## 2. Coding Standards
* **Systemd**: Service runs as `User=root`, so file permissions (logs, configs) MUST be `root:root`.
* **IPv6**: Always quote IPv6 addresses in JSON injection (jq).
* **jq**: Use robust initialization: `.endpoints = (.endpoints // [])`.

## 3. WARP Specifics
* **Naming**: The WireGuard endpoint tag MUST be `"WARP"` (not `warp-endpoint` linked to a `WARP` outbound).
* **Connection**: Prefer IPv4 IP (`162.159...`) over domain names to avoid DNS loops during `check`.
