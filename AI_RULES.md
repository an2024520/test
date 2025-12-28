# AI 开发者规则与知识库
> **最后更新:** 2025/12/25
> **适用范围:** 项目专用合规性与编码标准

> ⚠️ **关键警告 (Sing-box):**
> 1. 当前最新稳定版本为 **v1.12.14**（pre-release 为 v1.13.0-alpha.xx 系列）。
> 2. 在修改任何 Sing-box 配置之前，你**必须**严格遵守迁移指南：
>    **文件路径:** `singbox/docs/migration.md`（关键内容已摘录在本文件末尾）。
> 3. v1.12.0 起 DNS server 格式重大变更：废弃 `address` 字段，统一使用 `type` + `server`。
> 4. geoip/geosite 已废弃（v1.8.0+ 起），v1.12.0 完全移除，必须迁移到 `rule_set`。
> 5. 所有生成的 Sing-box 配置必须建议用户运行 `sing-box check` 进行验证。

> ⚠️ **关键警告 (Xray-core):**
> 1. 当前最新版本为 **v25.12.8**（日期命名体系 vYY.MM.DD）。
> 2. 代码库中默认安装版本为拉取最新版：**v25.12.8**或更新。

> ⚠️ **关键警告 (代码库):**
> 1. 代码库中默认安装的最新版本 Sing-box 为 **v1.12.14**或更新。
> 2. 始终优先建议用户检查实际安装版本
---

## 1. Sing-box 合规规范(v1.12.14+)

### 1.1 编码标准 (Coding Standards)
* **Systemd**: 服务以 `User=root` 身份运行，因此文件权限（日志、配置文件）**必须**设置为 `root:root`。
* **IPv6 处理**: 在进行 JSON 注入（例如在 `jq` 中）时，**始终**要给 IPv6 地址加上双引号。
* **jq 语法**: 使用健壮的初始化写法以防止 null 错误：
	```bash
	jq '.endpoints = (.endpoints // [])'
	```

### 1.2 WARP 规范 (WARP Specifics)
* **命名约定**: WireGuard endpoint 的标签 (tag) **必须** 为 `"WARP"`。
    * **禁忌**: **严禁**使用 `warp-endpoint` 等非标准名称并将其关联到 `WARP` 出站（此操作会导致路由或握手失败）。

### 1.3 Rule-Set 迁移规范 (v1.12+ 强制)
* ** geoip / geosite 已完全移除，必须使用 rule_set（remote 或 local）。**
* ** 必须启用缓存**以避免重复下载：
	```json
	"experimental": {
	"cache_file": {
	"enabled": true
	 }
	}
	```
* ** 标准示例**（推荐使用 SagerNet 官方 rule-set）：
	```json
	"route": {
	  "rule_set": [
	    {
	      "tag": "geoip-cn",
	      "type": "remote",
	      "format": "binary",
	      "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
	      "download_detour": "proxy"
	    },
	    {
	      "tag": "geosite-cn",
	      "type": "remote",
	      "format": "binary",
	      "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
	      "download_detour": "proxy"
	    }
	  ],
	  "rules": [
	    { "rule_set": "geoip-cn", "outbound": "direct" },
	    { "rule_set": "geosite-cn", "outbound": "direct" },
	    { "ip_is_private": true, "outbound": "direct" }
	  ]
	}

	```

### 1.4 迁移指南关键摘录 (v1.12.0+ 必读)
以下为官方 migration.md 的核心变更摘要，AI 生成配置时必须遵守：
* **DNS Servers 重构**：废弃 address，统一使用 type + server：
	```json
	// 旧（废弃）
	{ "address": "tls://1.1.1.1" }
	// 新（必须）
	{ "type": "tls", "server": "1.1.1.1" }
	```
* **FakeIP、DHCP、RCode** 等均有专用 type。
* **Inbound sniff / domain_strategy** 迁移到 route rules：
	```json
	// 新方式
	"route": {
	  "rules": [
	    { "inbound": "mixed-in", "action": "sniff", "timeout": "1s" },
	    { "inbound": "mixed-in", "action": "resolve", "strategy": "prefer_ipv4" }
	  ]
	}
	```
* **WireGuard outbound** 已废弃，迁移到 endpoints。
* **Destination override** 迁移到 route options。
* ** 更多细节请参考**代码库**中文件：**singbox/docs/migration.md** 或 **官方文档**：https://sing-box.sagernet.org/migration/
---

## 2. Xray-core 合规规范 (v25.12.8+)

### 2.1 VLESS 抗量子加密 (ML-KEM-768)
* **注意**：后量子加密目前仅用于 VLESS 协议层。
* **关键词**: ENC，VLESS ENC，mlkem，ML-KEM-768，抗量子加密。
* **最低版本**: v25.8.31+ (推荐 v25.12.8+)
* **核心功能**: 利用 ML-KEM-768 算法动态生成加密（Client）和解密（Server）所需的密钥对。
* **密钥提取规范 (必须严格遵守)**:
    * **原则**: 由于 `vlessenc` 和 `x25519` 命令的输出可能包含日志干扰或格式变动，**严禁**依赖行号或复杂的段落匹配。
    * **Reality 密钥**: 必须使用 `grep` 定位特征词 + `tr` 强制清洗空白符。
    * **ENC 密钥**: 必须利用 JSON 字段的双引号特征提取。

    * **标准提取脚本示例**:
	```bash
	# --- 1. 提取 Reality 密钥 (X25519) ---
	# 逻辑：定位 "Private"/"Public" -> 冒号分割 -> 强制删除回车和空格
	raw_reality=$(xray x25519)
	reality_private=$(echo "$raw_reality" | grep "Private" | awk -F ":" '{print $2}' | tr -d ' \r\n')
	reality_public=$(echo "$raw_reality" | grep -E "Password|Public" | awk -F ":" '{print $2}' | tr -d ' \r\n')
	reality_shortid=$(openssl rand -hex 8)

	# --- 2. 提取 VLESS ENC 密钥 (ML-KEM-768) ---
	# 逻辑：vlessenc 输出包含 JSON 片段。直接 grep 字段名 -> 以双引号(")为分隔符提取第4列 -> 确保无杂质
	raw_enc=$(xray vlessenc)
	mlkem_decryption=$(echo "$raw_enc" | grep '"decryption":' | head -n1 | awk -F '"' '{print $4}')
	mlkem_encryption=$(echo "$raw_enc" | grep '"encryption":' | head -n1 | awk -F '"' '{print $4}')
	
	# --- 3. 熔断检查 (必选) ---
	if [[ -z "$reality_private" ]] || [[ -z "$mlkem_decryption" ]]; then
	    echo "错误：密钥生成失败，请检查 Xray 版本或输出格式。"
	    exit 1
	fi
	```

* **服务端配置 (`config.json`)**:
    * 1. **私钥注入**: 注入至 `inbounds[].settings`：
	```json
	{
	  "settings": {
	    "decryption": "这里填入 mlkem_decryption"
	  }
	}
	```
    * 2. **服务端配置示例**: (VLESS + ENC + XHTTP + Reality)
	```json
	{
	  "inbounds": [
	    {
	      "port": 443,
	      "protocol": "vless",
	      "settings": {
	        "clients": [
	          { "id": "你的UUID", "flow": "" }
	        ],
	        "decryption": "这里填入 mlkem_decryption密钥"
	      },
	      "streamSettings": {
	        "network": "xhttp",
	        "security": "reality",
	        "xhttpSettings": {
	          "mode": "auto",
	          "path": "/你的路径",
	          "host": "你的SNI"
	        },
	        "realitySettings": {
	          "show": false,
	          "dest": "[www.apple.com:443](https://www.apple.com:443)", 
	          "serverNames": ["[www.apple.com](https://www.apple.com)"],
	          "privateKey": "这里填入 reality_private密钥",
	          "shortIds": ["这里填入 reality_shortid"]
	        }
	      }
	    }
	  ]
	}
	```

* **客户端分享链接**:
    * **参数**: `encryption=MLKEM_ENCRYPTION_KEY` (注意：这是客户端加密公钥)
    * **完整示例**: `vless://UUID@IP:PORT?encryption=MLKEM_KEY&security=reality&sni=SNI&fp=chrome&pbk=REALITY_PUB&sid=SID&type=xhttp&path=PATH&mode=auto#NAME`

### 2.2 ECH 支持 (Encrypted Client Hello)
* ** 最低版本：v25.7.26+。
* ** 功能：隐藏真实 SNI，常用于强制 Cloudflare CDN 的 ECH 直连。
* ** 配置位置：tlsSettings.ech 对象。
* ** 关键参数：
	```json
	"tlsSettings": {
	  "ech": {
	    "enabled": true,
	    "echConfig": "从公共源获取的 ECH 配置",
	    "echForceQuery": "full"  // 或 "half"/"none"
	  }
	}
	```
* ** 注意：需配合 Reality 或独立 TLS 使用，客户端需支持 ECH。

### 2.3 待更新...
