# AI 开发者规则与知识库
> **最后更新:** 2025/12/25
> **适用范围:** 项目专用合规性与编码标准

> ⚠️ **关键警告:** 在修改任何 Sing-box 配置之前，你**必须**研读迁移指南：
> **文件路径:** `singbox/docs/migration.md`

### 1.1 编码标准 (Coding Standards)
* **Systemd**: 服务以 `User=root` 身份运行，因此文件权限（日志、配置文件）**必须**设置为 `root:root`。
* **IPv6 处理**: 在进行 JSON 注入（例如在 `jq` 中）时，**始终**要给 IPv6 地址加上双引号。
* **jq 语法**: 使用健壮的初始化写法以防止 null 错误：  
  `jq '.endpoints = (.endpoints // [])'`

### 1.2 WARP 规范 (WARP Specifics)
* **命名约定**: WireGuard endpoint 的标签 (tag) **必须** 为 `"WARP"`（**严禁**使用 `warp-endpoint` 并将其关联到 `WARP` 出站）。

---

### 2.1 VLESS 抗量子加密 (ML-KEM-768)
* **适用场景**: 应用于 `VLESS + XHTTP + REALITY` 组合（**不使用** Vision 流控）。
* **最低版本**: v25.8.31+
* **核心功能**: 为 VLESS 协议提供抗量子安全的密钥封装机制。
* **密钥管理流程**:
    1.  **生成密钥**: 
        执行核心命令以获取密钥对：
        ```bash
        xray vlessenc
        ```
    2.  **解析输出 (关键)**:
        该命令输出纯文本。你必须使用 `grep` 或 `awk` 提取密钥：
        * **私钥** (服务端): 提取 `X25519 Private Key:` 之后的值
        * **公钥** (客户端): 提取 `X25519 Public Key:` 之后的值
    3.  **服务端配置 (`config.json`)**:
        将 **私钥** 注入到 `inbounds[].settings` 中：
        ```json
        {
          "settings": {
            "decryption": "YOUR_PRIVATE_KEY_HERE" 
            // 注意: 使用 XHTTP 时，'flow' 字段必须为空或直接省略
          }
        }
        ```
    4.  **客户端分享链接**:
        将 **公钥** 追加到链接的查询参数中：
        `vless://...?encryption=YOUR_PUBLIC_KEY_HERE&mode=multi&type=xhttp...`




        
## 2. Xray-core Compliance (Target: v25.12.8+)
2.1 ENC抗量子加密（ML-KEM-768）技术更新：从 Xray v25.8.31 版本开始，正式支持了 VLESS Post-Quantum Encryption（后量子加密）。使用了ML-KEM-768（量子安全密钥封装机制），利用 xray vlessenc 命令动态生成 decryption（解密）和 encryption（加密）所需的密钥信息。读取并学习参考示例https://raw.githubusercontent.com/yahuisme/vless-encryption/main/install.sh相关内容
    

