# Issues #113-#130 兼容性分析与修复总结

> 分析日期：2026-08-31
> 分析基线：`main`（含 PR #128 / `216dd2a`）
> Issue 来源：<https://github.com/yuaotian/antigravity-proxy/issues>

## 1. 结论摘要

本轮 16 个 open issue 不是同一个根因，可归并为四条主线：

1. **IDE 崩溃/无响应**：CLI 专用 `dbghelp.dll` 与 IDE 的 `version.dll` 被打进同一部署目录，用户混装后遮蔽系统 DbgHelp；旧 shim 还在 `DllMain` 内调用 `LoadLibraryW`。
2. **Loading/TLS/语言服务器异常**：v2.2 对 Electron host 安装了完整网络 Hook；PR #128 曾把 host 限制为 CreateProcess Hook。2026-09-01 为恢复 OAuth 与宿主业务流量接管，当前工作区默认重新启用全量网络 Hook，需在目标 IDE 版本上复测本地 TLS/UI。
3. **图片对话、登录与 UDP/443 失败**：默认 `udp_mode=block` 直接对 UDP/443 返回 `WSAEACCES=10013`，而新版本并不总会回退 TCP。
4. **Eligibility/location 拒绝**：附件日志已证明 SOCKS5 隧道成功，失败发生在上游资格或出口 IP 判定；项目缺少默认配置可见的诊断入口。

## 2. Issue 证据分组

| 分组 | Issue | 证据强度 | 结论 |
|---|---|---:|---|
| IDE 崩溃/卡死 | #115、#116、#121、#127、#129 | 高 | #115/#116/#121 均有移除 `dbghelp.dll` 后恢复的现场证据 |
| Host 网络 Hook | #113、#122，#117 部分症状 | 中高 | 与 PR #128 已复现并修复的 TLS/timeout 行为一致；单条 issue 的应用日志不完整 |
| UDP/QUIC | #124、#125，#117 附件 | 高 | 日志直接记录 `udp_mode=block`、UDP/443、10013；#124 配置矩阵也把 UDP 识别为决定性变量 |
| Eligibility/location | #130，#126 部分反馈 | 高/中 | #130 已证明注入、DNS 和多个 SOCKS5 隧道成功，随后由 Antigravity 返回 location unavailable |
| 证据不足/正常生命周期 | #114、#119、#120、#123 | 低 | #119 的“DLL 已卸载”来自正常 detach 日志；其它条目缺少决定性 connect/app 日志 |

## 3. 原代码问题定位

### 3.1 DbgHelp 与发布结构

- `src/proxy/DbgHelpShim.cpp::DllMain`：旧实现直接加载 `version.dll`，违反 DllMain 最小化原则。
- `src/proxy/DbgHelpShim.cpp::LoadSystemDbgHelp`：旧实现只为 `SymFromAddr` 提供动态转发。
- `build.ps1` 的“步骤 7”：旧实现把 `version.dll` 与 `dbghelp.dll` 复制到同一个 `output` 根目录。
- `.github/workflows/release.yml` 的“打包产物”：会完整压缩 `output/*`，因此发布包延续混装入口。

Microsoft 官方文档明确说明 DllMain 在 loader lock 下执行，应延迟初始化，且不应在其中调用 LoadLibrary：
<https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-best-practices>

### 3.2 UDP 默认策略

- `src/core/Config.hpp::ProxyRules::udp_mode`：旧默认值为 `block`。
- `src/hooks/Hooks.cpp::PerformProxyConnect` 与 `DetourConnectEx`：旧实现对非 loopback/53 的 UDP 返回 `WSAEACCES`。
- `src/hooks/Hooks.cpp::EnsureUdpProxyReady`：项目已经具备 SOCKS5 UDP Associate，无需新增协议栈。
- `resources/config-web/index.html::defaultForm`：旧配置页继续导出 `udp_mode=block`。

### 3.3 IPv6 地址族

- `src/hooks/Hooks.cpp::AppendProxyEndpoint`：IPv6 socket 遇到 IPv4 代理时构造 v4-mapped IPv6 地址。
- 旧代码未设置 `IPV6_V6ONLY`；Windows Vista 及以后默认值为 1，v6-only socket 使用 v4-mapped 地址会失败。
- `src/hooks/Hooks.cpp::BuildProxyAddrV6`、`BuildUdpRelayAddrForSocketFamily`：TCP 与 UDP relay 都受该约束影响。

Microsoft 官方 dual-stack 说明：
<https://learn.microsoft.com/en-us/windows/win32/winsock/dual-stack-sockets>

### 3.4 地域诊断契约

- `src/hooks/Hooks.cpp::ProbeProxyExitIpEvidence` 与 `CollectLatestAntLocationEvidence`：诊断能力已经存在。
- `src/core/Config.hpp::diagnosticsAgentIpProbe`：默认 false，符合显式联网原则。
- 旧 `build.ps1` 与配置页没有导出/编辑 `diagnostics.agent_ip_probe`，README 却描述成当前版本会自动输出。

## 4. 已实施修复

### 4.1 CLI shim 与部署隔离

- `src/proxy/DbgHelpShim.cpp`
  - DllMain 只保存模块句柄并关闭线程通知。
  - 仅在导出函数首次调用时加载系统 DbgHelp。
  - CLI 代理主体改名为 `antigravity_proxy.dll`，避开系统 `version.dll` 同名模块。
  - 对常用符号、栈回溯、模块枚举和 minidump API 做透明转发。
- `src/proxy/dbghelp.def`：固定导出未修饰 API 名称。
- `build.ps1`
  - `output/ide`：只含 `version.dll + config.json`。
  - `output/cli`：只含 `dbghelp.dll + antigravity_proxy.dll + config.json`。
  - output 根目录不再放 DLL。
- `scripts/package-release.ps1`：集中断言两套目录必需文件与禁止混装项，分别生成 IDE/CLI 压缩包。
- `.github/workflows/build.yml`、`.github/workflows/release.yml`：每个架构只编译一次，CI artifact 与 Release 资产均按 IDE/CLI 拆分。

### 4.2 UDP auto

- `src/core/UdpPolicy.hpp::ResolveUdpAction` 定义单一决策：
  - `auto + socks5 -> proxy`
  - `auto + http -> udp_fallback`
  - 显式 `block/direct/proxy` 保持原意。
- `src/hooks/Hooks.cpp::GetEffectiveUdpAction` 被 connect、ConnectEx、send/recv、sendto/WSASendTo 共用。
- 默认配置改为 `udp_mode=auto`，`udp_fallback=block`，不会静默直连。

### 4.3 IPv6 dual-stack

- `src/network/SocketFamily.hpp::EnsureIpv6DualStack` 统一读取并关闭 `IPV6_V6ONLY`。
- `src/hooks/Hooks.cpp::DetourSocket/DetourWSASocketA/DetourWSASocketW` 在 bind 前配置 IPv6 socket。
- TCP、UDP relay 和 ConnectEx 在连接 v4-mapped 代理端点前再次校验；失败时保留具体 WSA 错误码。

### 4.4 配置与诊断

- `resources/config-web/index.html` 新增 `diagnostics.agent_ip_probe` 开关。
- 配置页支持 `udp_mode=auto`，并对 HTTP + auto/proxy 显示兼容提示。
- `build.ps1`、`README.md`、`docs/config-web*.md` 与后端默认值保持一致。

### 4.5 宿主 Hook 默认策略（2026-09-01）

- `src/main.cpp::DllMain` 当前将 `enableNetworkHooks` 固定为 `true`，宿主和子进程统一安装网络、IOCP、流量监控与进程创建 Hook。
- 该调整针对跨机日志中宿主进程外联范围缩小的回归；部署验收需同时检查宿主 PID 的 `使用全量模式`、目标域名重定向和 OAuth `signedIn`。
- PR #128 记录的宿主本地自签名 TLS 风险仍是已知观察项；若出现 UI 或 language server 异常，应保留现场日志后再单独收敛范围。

## 5. 配置迁移

推荐新配置：

```json
{
  "proxy": {
    "host": "127.0.0.1",
    "port": 7890,
    "type": "socks5"
  },
  "diagnostics": {
    "agent_ip_probe": false
  },
  "proxy_rules": {
    "ipv6_mode": "proxy",
    "udp_mode": "auto",
    "udp_fallback": "block"
  }
}
```

- 旧配置显式写了 `udp_mode=block` 时仍保持阻断；需要 UDP/443 时改成 `auto`。
- HTTP 代理在 `auto` 下按 `udp_fallback` 处理；默认 block。
- 排查 `location unavailable` 时临时开启 `diagnostics.agent_ip_probe`，完成后关闭。

## 6. 验证记录

回归入口：`scripts/test-compatibility.ps1`

| 验证项 | 状态 | 证据 |
|---|---|---|
| UDP 策略矩阵 | 通过 | `tests/test_udp_policy.cpp`，x64/x86 各通过 5/5 CTest 中对应测试 |
| Windows dual-stack | 通过 | `tests/test_socket_family.cpp`，x64/x86 均通过 |
| DbgHelp 导出与动态转发 | 通过 | `tests/test_dbghelp_shim.cpp`，x64/x86 均通过 |
| 进程分类与 IPv6 CIDR 旧回归 | 通过 | 既有 CTest，x64/x86 均通过 |
| IDE/CLI 发布目录与压缩包隔离 | 通过 | `scripts/test-compatibility.ps1` 对两架构目录及四种 ZIP 文件清单执行必需项与禁止混装断言 |
| CI/Release x64/x86 编译与测试 | 通过 | `build.ps1 -Clean -Config Release -Arch x64/x86 -RunTests`，每个架构均通过 5/5 CTest |
| 配置页渲染与默认值 | 通过 | 内置浏览器 1280×720 实测；诊断开关默认关闭、UDP 为 auto、无横向溢出或脚本错误 |

执行记录：2026-08-31 分别运行 `scripts/test-compatibility.ps1 -Config Release -Arch x64` 与 `-Arch x86`，随后按 CI/Release 入口运行两架构的 `build.ps1 -Clean -Config Release -RunTests`，全部以退出码 0 完成。全部测试源在 Release 下显式保留断言；DbgHelp 测试以 `agy.exe` 作为输出名，并确认首次调用系统导出时已加载 `antigravity_proxy.dll`。

## 7. 剩余人工验收

- Antigravity IDE：启动、登录、普通对话、含图片对话、语言服务器状态。
- Antigravity CLI：`agy.exe` 加载 shim、子进程注入、SOCKS5 TCP/UDP。
- SOCKS5 上游不支持 UDP Associate 时：确认 fallback=block 的日志可定位。
- HTTP 代理：确认配置页提示与运行时有效策略一致。
- Eligibility/location：确认开启诊断后能同时看到出口 IP 与 `ls-main.log` 证据。
- GitHub Actions：发布步骤已加入目录隔离断言，仍需下一次 tag 或手动工作流验证 runner 端打包结果。
