# AI 开发者规则与知识库
> **最后更新:** 2025/12/25
> **适用范围:** 项目专用合规性与编码标准

> ⚠️ **关键警告 (Sing-box):**
> 1.  当前最新 Sing-box 版本为 **v1.12+**。
> 2.  在修改任何 Sing-box 配置之前，你**必须**研读迁移指南：
>     **文件路径:** `singbox/docs/migration.md`

> ⚠️ **关键警告 (Xray-core):**
> 1.  Xray 版本命名规则已变更为日期体系，当前最新版本为 **v25.12.8+**。

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
    * **严禁**使用 `warp-endpoint` 并将其关联到 `WARP` 出站（此操作会导致路由或握手失败）。

---

## 2. Xray-core 合规规范 (v25.12.8+)

### 2.1 VLESS 抗量子加密 (ML-KEM-768)
* **主要适用场景**: `VLESS + vlessEncryption+XHTTP + REALITY`
* **最低版本**: v25.8.31+
* **核心功能**: 利用 ML-KEM-768 算法动态生成加密（Client）和解密（Server）所需的密钥对。
* **密钥管理流程:
    *1.  **生成密钥**: 使用 xray 核心命令生成密钥信息：          
    ```bash
    xray vlessenc
    ```
    *2.  **解析输出 (关键)**:
          * `vlessenc` 命令（在 ML-KEM-768 模式下）输出的是包含 JSON 字段的文本，**不是** X25519 格式。
          * 提取逻辑**: 先定位包含 `Authentication: ML-KEM-768` 的段落。
          * 私钥** (服务端): 提取 `"decryption":` 字段后双引号内的字符串。
          * 公钥** (客户端): 提取 `"encryption":` 字段后双引号内的字符串。
          * 密钥提取脚本示例 (推荐写法):
    ```bash
		# 生成密钥
		vlessenc_output=$(xray vlessenc)
		# --- 提取 VLESS Encryption (ML-KEM-768) 密钥 ---
		# 逻辑：先定位到 ML-KEM 段落，再提取 decryption 和 encryption
		# 避免错误提取到 X25519 密钥
		mlkem_section=$(echo "$vlessenc_output" | awk '/Authentication: ML-KEM-768/{flag=1; next} /Authentication:/{flag=0} flag')
		mlkem_decryption=$(echo "$mlkem_section" | grep '"decryption":' | sed 's/.*"decryption": "\([^"]*\)".*/\1/')
		mlkem_encryption=$(echo "$mlkem_section" | grep '"encryption":' | sed 's/.*"encryption": "\([^"]*\)".*/\1/')

		# --- 提取 REALITY 密钥 ---
		# 使用 standard xray x25519 command
		reality_keys=$(xray x25519)
		reality_private=$(echo "$reality_keys" | awk '/Private/{print $3}')
		reality_public=$(echo "$reality_keys" | awk '/Public/{print $3}')
		reality_shortid=$(openssl rand -hex 8)
    ```

      *3.  **服务端配置 (`config.json`)**:
           将 **私钥** 注入到 `inbounds[].settings` 中：
            ```json
            {
           	"settings": {
            	   "decryption": "YOUR_PRIVATE_KEY_HERE"
             	   // 注意: 使用 XHTTP 时，'flow' 字段必须为空或直接省略
            	}
            }
            ```
           具体参考示例（VLESS + vlessEncryption+XHTTP + REALITY）：
           ```json
           {
             "inbounds": [
               {
                 "port": 443,
                 "protocol": "vless",
                 "settings": {
                   "clients": [
                     {
                       "id": "你的UUID",
                       "flow": "" 
                       // 注意：argosbx.sh 在 XHTTP 模式下也保留了 flow，但Gemini认为XHTTP下xtls-rprx-vision是无效的。
                     }
                   ],
                   // 关键点：注入抗量子解密私钥
                   "decryption": "这里填入上面提取的 mlkem_decryption"
                 },
                 "streamSettings": {
                   "network": "xhttp",
                   "security": "reality",
                   "xhttpSettings": {
                     "mode": "auto",
                     "path": "/你的路径" // 参考 argosbx.sh 的 path 设置
                   },
                   "realitySettings": {
                     "show": false,
                     "dest": "www.apple.com:443", // 示例回落域名
                     "serverNames": ["www.apple.com"],
                     "privateKey": "这里填入 reality_private",
                     "shortIds": ["这里填入 reality_shortid"]
                   }
                 }
               }
             ]
           }
           ```json


      4.  **客户端分享链接**:
          将提取的 `encryption` 值作为参数追加到链接中：
          * **参数格式**: `encryption=MLKEM_ENCRYPTION_KEY`
          * **完整示例**: `vless://UUID@IP:PORT?encryption=MLKEM_ENCRYPTION_KEY&flow=xtls-rprx-vision&security=reality&sni=SNI_DOMAIN&fp=chrome&pbk=REALITY_PUBLIC_KEY&sid=SHORT_ID&type=xhttp&path=PATH_VALUE&mode=auto#NAME`



        

    

