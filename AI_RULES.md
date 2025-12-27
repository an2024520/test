# AI Developer Rules & Knowledge Base (Updated: 2025)

## 1. Sing-box Version Compliance (Target: v1.12+)
* It is essential to study and understand the Migration guide file: singbox/docs/migration.md


## 2. Coding Standards
* **Systemd**: Service runs as `User=root`, so file permissions (logs, configs) MUST be `root:root`.
* **IPv6**: Always quote IPv6 addresses in JSON injection (jq).
* **jq**: Use robust initialization: `.endpoints = (.endpoints // [])`.

## 3. WARP Specifics
* **Naming**: The WireGuard endpoint tag MUST be `"WARP"` (not `warp-endpoint` linked to a `WARP` outbound).

