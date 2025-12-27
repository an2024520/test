# AI 开发者规则与知识库
> **最后更新:** 2025/12/25
> **适用范围:** 项目专用合规性与编码标准

> ⚠️ **关键警告 (Sing-box):**
> 1. 当前最新 Sing-box 版本为 **v1.12+**。
> 2. 在修改任何 Sing-box 配置之前，你**必须**研读迁移指南：
>    **文件路径:** `singbox/docs/migration.md`

> ⚠️ **关键警告 (Xray-core):**
> 1. Xray 版本命名规则已变更为日期体系，当前最新版本为 **v25.12.8+**。

> ⚠️ **关键警告 (代码库):**
> 1. 代码库中默认安装的最新版本xray,当前为**v25.12.8**
> 2. 代码库中默认安装的最新版本singbox,当前为**v1.12.14**
---

## 1. Sing-box 合规规范 (v1.12+)

### 1.1 编码标准 (Coding Standards)
* **Systemd**: 服务以 `User=root` 身份运行，因此文件权限（日志、配置文件）**必须**设置为 `root:root`。
* **IPv6 处理**: 在进行 JSON 注入（例如在 `jq` 中）时，**始终**要给 IPv6 地址加上双引号。
* **jq 语法**: 使用健壮的初始化写法以防止 null 错误：
	```bash
	jq '.endpoints = (.endpoints // [])'
	```

### 1.2 WARP 规范 (WARP Specifics)
* **命名约定**: WireGuard endpoint 的标签 (tag) **必须** 为 `"WARP"`。
    * **禁忌**: **严禁**使用 `warp-endpoint` 并将其关联到 `WARP` 出站（此操作会导致路由或握手失败）。

### 1.3 待更新...

---

## 2. Xray-core 合规规范 (v25.12.8+)

### 2.1 VLESS 抗量子加密 (ML-KEM-768)
* **注意**：后量子加密技术在 xray 中目前只用于加密 VLESS 协议层。
* **关键词**: ENC，VLESS ENC，mlkem，ML-KEM-768，抗量子加密。
* **最低版本**: v25.8.31+ (推荐 v25.12.8+)
* **核心功能**: 利用 ML-KEM-768 算法动态生成加密（Client）和解密（Server）所需的密钥对。
* **密钥提取规范 (必须遵守)**:
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
    * 2. **具体参考示例**: (VLESS + vlessEncryption + XHTTP + Reality)
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
	        "decryption": "这里填入 mlkem_decryption"
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
	          "privateKey": "这里填入 reality_private",
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

### 2.2 待更新...
