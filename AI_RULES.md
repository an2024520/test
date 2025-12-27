# AI Developer Rules & Knowledge Base (Updated: 2025/12/25)

## A. Sing-box Version Compliance (Target: v1.12+)
* It is essential to study and understand the Migration guide file: singbox/docs/migration.md

## 1. Coding Standards
* **Systemd**: Service runs as `User=root`, so file permissions (logs, configs) MUST be `root:root`.
* **IPv6**: Always quote IPv6 addresses in JSON injection (jq).
* **jq**: Use robust initialization: `.endpoints = (.endpoints // [])`.

## 2. WARP Specifics
* **Naming**: The WireGuard endpoint tag MUST be `"WARP"` (not `warp-endpoint` linked to a `WARP` outbound).

## B. xray core Version Compliance (Target: v25.12.8+)
    1.ENC抗量子加密（ML-KEM-768）技术更新：从 Xray v25.8.31 版本开始，正式支持了 VLESS Post-Quantum Encryption（后量子加密）。使用了ML-KEM-768（量子安全密钥封装机制），利用 xray vlessenc 命令动态生成 decryption（解密）和 encryption（加密）所需的密钥信息。读取并学习参考示例https://raw.githubusercontent.com/yahuisme/vless-encryption/main/install.sh相关内容
    

