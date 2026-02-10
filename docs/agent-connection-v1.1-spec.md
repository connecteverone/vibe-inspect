# Agent 连接架构与协议规范 v1.1

## 1. 文档目标

本规范用于统一 desktop agent 与 mobile 在以下场景的行为与边界：

- 同一内网优先连接
- 非同网通过 FRP 公网地址连接
- 后续无缝扩展到 TUN 地址连接
- 全网可达前提下的安全与稳定性保障
- terminal/vnc/roi 等能力在同一认证与路由模型下工作

本规范是实现与 UI 设计的共同约束，优先级高于临时实现约定。

---

## 2. 范围与非范围

### 2.1 范围

- QR 配对会话协议
- 静态 token + 设备绑定 token 认证模型
- LAN/FRP/TUN 路由选择策略
- mobile 自适应探测与离线判定
- desktop/mobile/terminal 的核心 UI 状态
- 全网开放下的安全基线

### 2.2 非范围

- 不实现 FRP 协议本身
- 不实现 TUN 协议本身
- 不限制源 IP 白名单
- 不引入第三方 SSO/账号体系（当前阶段）

---

## 3. 设计原则

1. **零信任优先**：不基于网络边界信任任何请求。
2. **协议先于实现**：先固定字段、状态机、错误码，再迭代代码。
3. **LAN 优先、可回退**：同网走内网；不可达自动回退公网。
4. **一次配对，长期可用**：QR 临时握手成功后下发长期凭据。
5. **能力最小授权**：token 按 scope 管控，避免全权限默认放开。
6. **可观测可排障**：每次路由与认证决策都有日志与指标。

---

## 4. 核心架构抽象

### 4.1 传输抽象

统一抽象 `TransportEndpoint`：

```json
{
  "type": "lan | frp | tun",
  "url": "https://example:58888",
  "priority": 100,
  "probe_timeout_ms": 2000,
  "enabled": true,
  "meta": {
    "ssid": "optional",
    "local_ips": ["optional"],
    "description": "optional"
  }
}
```

说明：

- `lan`：来自本地网卡地址拼装的 endpoint。
- `frp`：用户在 desktop 配置的公网地址。
- `tun`：后续新增的公网/虚拟网地址。

mobile 只面向 `TransportEndpoint[]` 做决策，不耦合具体 FRP/TUN 细节。

### 4.2 认证抽象

统一抽象 `AuthCredential`：

- `pairing_temp_token`：QR 临时握手凭据（短时效）
- `device_bound_token`：绑定 `client_id` 的长期凭据
- `static_token`：手动维护的长期凭据（可撤销）

### 4.3 能力抽象

token 必须携带 scope（当前可先逻辑实现，后续可落库）：

- `agent.read`：读 identity、状态
- `pairing.confirm`：握手确认
- `terminal.exec`：终端操作
- `vnc.control`：VNC/ROI 控制

默认建议：

- QR 下发的设备绑定 token：`agent.read + terminal.exec + vnc.control`
- 静态 token：可配置 scope，默认只给 `agent.read + pairing.confirm`

---

## 5. 协议规范 v1.1

### 5.1 QR Payload（配对会话）

```json
{
  "protocol_version": "1.1",
  "pairing": {
    "token": "TEMP_TOKEN",
    "secret": "TEMP_SECRET",
    "nonce": "RANDOM_NONCE",
    "issued_at": 1730000000,
    "expires_at": 1730000180,
    "single_use": false
  },
  "agent": {
    "device_id": "stable_device_id",
    "host_name": "optional",
    "wifi_ssid": "optional",
    "local_ips": ["192.168.1.10"]
  },
  "transports": [
    {
      "type": "lan",
      "url": "http://192.168.1.10:58888",
      "priority": 100,
      "probe_timeout_ms": 2000,
      "enabled": true
    },
    {
      "type": "frp",
      "url": "https://agent.example.com",
      "priority": 60,
      "probe_timeout_ms": 3000,
      "enabled": true
    }
  ],
  "requires_approval": true
}
```

兼容要求：

- 保留旧字段 `token/secret/pairing_token/pairing_secret/frp_url/local_urls`。
- 新版 mobile 优先读 `transports[]`，旧版按旧字段回退。

### 5.2 Pairing Confirm 请求

`POST /pairing/confirm`

请求：

```json
{
  "protocol_version": "1.1",
  "token": "TEMP_TOKEN",
  "secret": "TEMP_SECRET",
  "nonce": "RANDOM_NONCE",
  "client_id": "stable_mobile_id",
  "client_name": "iOS | Android | ..."
}
```

响应：

- `connected`：直接返回长期 token（若设备已存在则复用）
- `pending`：等待 desktop 审批
- `error`：返回标准错误码

校验规则：

- 当 `protocol_version=1.1` 时，`nonce` 必填；缺失返回 `missing_nonce`
- 当请求带 `nonce` 时，server 必须校验与会话一致，不一致返回 `nonce_mismatch`
- 当请求不带 `nonce` 且 `protocol_version` 为空时，按旧协议兼容处理

错误码最小集：

- `token_expired`
- `invalid_token_length`
- `invalid_token_format`
- `token_mismatch`
- `secret_mismatch`
- `nonce_mismatch`
- `missing_nonce`
- `unsupported_protocol`
- `approval_pending`
- `approval_timeout`
- `client_blocked`
- `rate_limited`
- `unauthorized`

### 5.3 Identity 返回

`command=identity` 或同等 API 返回应包含：

- `device_id`
- `wifi_ssid`
- `local_ips`
- `transports[]`
- `listen_port`
- `roi_quic_port`
- `remote_capabilities`

用于 mobile 连接后刷新本地缓存与路由偏好。

### 5.4 WebSocket 短期票据（`ws_ticket`）

为了减少长期 token 在 WS URL 上暴露窗口，新增命令：

- 请求：`command=ws_ticket`
- payload：
  - `scope`：`terminal_ws | vnc_ws | ...`
  - `session_id`：当 `scope` 为会话型通道（`terminal_ws/vnc_ws`）时必填
- 响应：
  - `token`：一次性短期票据
  - `expires_at`：Unix 秒级过期时间

约束：

- 票据默认 `30s` 过期，单次消费后立即失效（防重放）。
- 票据绑定 `scope + session_id + client_id`（有值时必须一致）。
- 验证优先级：长期 `auth_token` > `ws_ticket`。
- 兼容回退：若 agent 不支持 `ws_ticket`，mobile 使用既有 `auth_token` 方案。

---

## 6. 路由选择与自适应策略

### 6.1 配对阶段（扫码后）

1. 校验 QR 是否过期。
2. 根据 SSID + 网段判断是否可能同网。
3. 并发探测可用 endpoint：
   - `lan` 默认 2s
   - `frp/tun` 默认 3s
4. 选择顺序：
   - 同网且 LAN 可达：优先 LAN
   - LAN 不可达但公网可达：走 FRP/TUN
   - 全不可达：失败并展示失败原因
5. 调用 `/pairing/confirm`。

### 6.2 日常重连阶段（app 启动/切前台）

1. 读取本地连接记录。
2. 获取当前 SSID + 本地 IP。
3. 并发探测 LAN 与公网 endpoint。
4. 至少一个可达：标记 `connected` 并刷新 identity。
5. 全不可达：标记 `offline`。

### 6.3 终端模块路由

terminal/vnc/roi 使用同一“当前激活 endpoint”。

- endpoint 失效时，先重建路由再重连会话。
- 如果 token 无效，不自动无限重试，直接进入认证错误态。

---

## 7. 状态机规范

### 7.1 Desktop QR 状态机

- `idle`：无二维码
- `active`：二维码有效期内
- `expired`：二维码失效，UI 隐藏二维码并提示重新生成
- `pending_approval`：收到待审批请求
- `paired`：配对成功

转换规则：

- 仅点击“生成”可进入 `active`
- 到达 `expires_at` 必须进入 `expired`
- `expired` 不允许继续确认握手
- `requires_approval` 可在 UI 中开启或关闭，立即生效

### 7.2 Mobile 配对状态机

- `scanned`
- `probing`
- `pairing`
- `pending_approval`
- `connected`
- `failed`

必须显示失败归因：

- LAN 不可达
- 公网不可达
- token 失效
- 被限流/封禁

### 7.3 Agent 在线状态

- `connected`
- `degraded`（仅公网可达或仅内网可达）
- `offline`

---

## 8. UI/交互规范

### 8.1 Desktop

必须具备：

- QR 卡片（仅按钮生成，过期自动隐藏）
- 连接方式配置（LAN 展示 / FRP 输入 / 预留 TUN 输入）
- Token 管理（新增、复制、撤销、scope 展示）
- 已配对设备列表（在线状态、最后活跃时间、禁用/踢出）
- 审批面板（同意/拒绝）

### 8.2 Mobile

必须具备：

- Agent 列表展示当前通道：`LAN | FRP | TUN`
- 失败详情可展开（探测失败原因）
- 手动指定 endpoint 的高级入口
- 自动与手动切换模式

### 8.3 Terminal

必须区分展示：

- `route_unreachable`：路由不可达
- `auth_failed`：token 认证失败
- `session_expired`：会话过期

并提供：

- 一键重连（先路由探测再会话恢复）
- 复制错误详情

---

## 9. 安全基线（全网开放前提）

不做白名单时，以下为 P0 强制项：

1. TLS（FRP/TUN endpoint 强制 https/wss）
2. token 失败限流（按 client_id + 全局）
3. 握手重放防护（nonce + 有效期 + 一次性判定策略）
4. endpoint 连接数与速率上限
5. 错误响应最小泄露（不返回内部堆栈）
6. 审计日志（握手、拒绝、撤销、踢出、封禁）
7. 本地 token 安全存储（mobile 迁移到平台安全存储）

---

## 10. 兼容与迁移

1. `protocol_version` 缺失视为 `1.0`。
2. v1.1 server 对 v1.0 QR 字段保持兼容。
3. mobile 优先解析 `transports[]`，解析失败回退旧字段。
4. 发布顺序：desktop 先发（兼容旧 mobile），再发 mobile。

---

## 11. 可观测性与验收

### 11.1 指标

- `pairing_success_rate`
- `pairing_pending_rate`
- `lan_preferred_rate`
- `public_fallback_rate`
- `offline_rate`
- `auth_401_rate`
- `auth_429_rate`
- `probe_latency_p50/p95`

### 11.2 最小验收清单

- QR 仅点击生成，180s 后隐藏
- 同网时优先 LAN，失败自动回退公网
- 公网可达时 terminal/vnc 可正常鉴权访问
- 同一 `client_id` 重扫复用历史设备 token
- token 撤销后连接立即失效
- LAN/FRP/TUN 任一可达时 agent 不应显示 offline
- 错误码与 UI 文案映射一致

### 11.3 测试矩阵

- 平台：iOS / Android / macOS / Windows
- 网络：同网 / 异网 / 无网 / VPN / 多网卡
- 通道：LAN / FRP / TUN(预留)
- 鉴权：正常 / 过期 / 撤销 / 限流 / client blocked

---

## 12. 实施优先级（建议）

### P0

- `transports[]` 协议落地（保持旧字段兼容）
- 错误码统一与 UI 映射
- terminal 路由错误态与重连链路统一
- 安全基线中的 TLS/限流/审计/安全存储

### P1

- token scope 管控与 UI 展示
- TUN 配置入口与路由接入（不实现协议）
- 可观测指标面板

### P2

- 智能路由策略优化（历史成功率、RTT 权重）
- 更细粒度权限与组织化管理
