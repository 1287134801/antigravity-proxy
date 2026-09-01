# OAuth 回跳与 DLL 卸载日志诊断记录

## 当前状态

这份记录用于区分以下三个不同事件：

1. 浏览器完成 Google 身份验证；
2. `antigravity-ide://oauth-success` 被 Windows 协议处理器接收并交给 IDE；
3. IDE 进程退出、第二实例交接，或 DLL 被动态卸载。

当前证据已经形成“浏览器成功 -> Windows 启动协议进程 -> IDE 主实例没有记录 callback -> 登录态仍为 `signedOut`”的失败链路。`child_injection=false` 控制实验复现了同一失败，因此本次代理子进程注入路径已从根因中排除；IDE 登录问题本身仍未解决。

## 2026-09-01 宿主网络 Hook 范围回归

针对另一台测试机提供的旧/新 DLL 日志，结合本机短时 A/B 得到以下对照：

- 旧组合的宿主与子进程均记录 `所有 API Hook 安装成功 (Phase 1-3)`，宿主 PID `14768` 实际重定向 `daily-cloudcode-pa.googleapis.com:443` 并建立 SOCKS5 隧道。
- 新组合中 10 个 `Antigravity IDE.exe` 进程记录 `仅安装进程创建 Hook，跳过网络 Hook`，只有 PID `13828`、`24676` 安装完整网络 Hook；仍有少量隧道建立，说明代理端口和 SOCKS5 服务有响应，但宿主外联范围缩小。
- 本机以安装目录旧组合和 `output/ide` 新组合复现了同一分类差异；新组合出现 8 个宿主跳过、语言服务/Node 完整 Hook。临时用户目录未进入真实 OAuth，因此本机尚未形成 callback/token exchange 的功能结论。
- 源码对应 `src/main.cpp:261-269`、`src/hooks/ProcessName.hpp:87-90`、`src/hooks/Hooks.cpp:4528`。本次修复已将 `src/main.cpp:265` 的默认值恢复为全量网络 Hook，宿主启动日志应出现 `使用全量模式`。
- 全量组合与旧组合的短启动对照都出现一次 Chromium `Network service crashed, restarting service`；该单行 stderr 不是两组策略的区分证据，OAuth 回调、token exchange 和 `signedIn` 才是功能验收点。

部署时需将同一次构建、同一架构生成的 `version.dll` 与 `config.json` 成对复制到实际启动目录。`output/ide` 生成物与安装目录中的历史文件应保持成对，避免交叉拼接；替换前后应记录 SHA-256，复测结束后再恢复备份。

## 已有证据

用户提供的浏览器截图显示 `You have successfully authenticated.`，并提示将跳回产品；IDE 截图仍停留在 `Continue with Google` 欢迎页。它们能证明浏览器侧授权页成功，不能单独证明自定义协议已由预期 IDE 进程处理，也不能证明 IDE 已接收并持久化登录态。

用户提供的 2026-09-01 日志显示：

- `17:06:08`，PID `21804` 加载代理 DLL，并创建、注入 PID `28772` 与 `2440`；
- `17:06:09`，PID `2440` 记录 `Antigravity-Proxy DLL 已卸载`；
- `17:06:11`，PID `21804` 与 `28772` 记录同一条卸载文本。

旧日志文本只表示执行到了 DLL detach 分支。旧实现没有在日志中区分“进程终止触发 detach”和“运行中动态卸载”，所以仅凭 `DLL 已卸载` 不能推出 DLL 文件被删除，也不能推出 IDE 被系统卸载。

同日 `18:31:45-18:33:10` 的新日志和证据包进一步确认：

- PID `23044` 以协议模式启动，说明 Windows 已把 OAuth 回跳交给 IDE；
- PID `23044/19012/19408` 均因进程终止而分离 DLL，没有动态卸载记录；
- 原主实例 PID `12312` 继续存活，代理网络隧道成功且没有错误或警告；
- `version.dll` 采集时仍存在，IDE 版本为 `2.5.5`，HKCU 协议命令正确指向 IDE 并传入 `--open-url -- %1`；
- 第一份证据包误用不存在的 `%APPDATA%\Antigravity\logs`，因此没有采到 IDE main/auth 日志，仍不能证明第二实例交接和登录态写入结果。

使用修正后的采集器补采同一时间窗后，IDE 日志给出了更窄的失败边界：

- `auth.log` 在 `18:32:08` 启动本地 OAuth 服务并生成 Google 登录 URL，但状态停留在 `signedOut`；
- 协议进程 PID `23044` 于 `18:32:32` 启动后，主实例的 `auth.log` 没有回调、`signedIn`、token exchange 或服务停止记录；
- `ls-main.log` 随后持续出现 `state syncing error: key not found`，说明 language server 没有可读的登录状态；
- 更新器的 `ERR_CONNECTION_CLOSED` 和 Playwright 下载 `404` 与 OAuth 回调交接不在同一决定性分支；
- Google AI Developers Forum 在 2026-08-19 收录了同样的 Windows 回调症状、`state syncing error: key not found` 和 Playwright `404`，因此 IDE `2.5.5` 上游缺陷是当前主判断，而不是 DLL 文件被卸载：<https://discuss.ai.google.dev/t/oauth-callback-not-received-by-app-after-successful-browser-authentication-windows-11/178921>。

代理侧曾有一个待 A/B 的相关风险：`DetourCreateProcessA/W` 在判断具体目标前先增加 `CREATE_SUSPENDED`；当前配置又把 `Antigravity IDE.exe` 列为目标，所以协议 PID `23044` 创建的两个 Electron 子进程均从 `0x80000` 变为 `0x80004`，随后被注入和恢复。后续控制实验已排除该路径，结果见下文。

当前工作区的 `src/main.cpp::DllMain` 已按 `lpvReserved` 区分两类 detach：进程终止时跳过复杂清理，动态卸载或加载失败回滚时保留清理。终止原因日志采用零等待的尽力写入；日志锁争用或写入失败时只进入调试输出，因此“缺少终止日志”不能反证进程没有终止。`src/main.cpp::IsOpenUrlProtocolLaunch` 只判断命令行中是否存在 `--open-url`，不会复制或记录可能含令牌的完整 URL。该修改仍需要用受影响电脑上的实际构建和运行日志验证，不能用源码状态替代运行时证据。

代理日志位置由 `src/core/Logger.hpp::GetLogDirectory` 决定：优先使用 DLL 同级的 `logs` 目录，创建失败时回退到 `%TEMP%\antigravity-proxy-logs`。受影响的 IDE `2.5.5` 运行参数证明用户数据根为 `%APPDATA%\Antigravity IDE`；采集器现在优先读取其 `logs` 子目录，并兼容回退旧的 `%APPDATA%\Antigravity\logs`。`src/hooks/Hooks.cpp::TryGetLatestAntLogDir` 仍使用旧目录，但本次配置中 `diagnostics.agent_ip_probe=false`，不影响 OAuth 证据采集。

## 已闭合与剩余边界

同一时间窗的两轮证据已经确认：

1. `version.dll` 一直存在且 SHA-256 为 `194F16BE74F87E12984E3B0DCE2E0BAFBF6E92DF5D89BC34D1B621362A123B3F`；
2. HKCU 协议命令正确指向 `Antigravity IDE.exe --open-url -- %1`，没有 HKLM 32/64 位冲突；
3. 两次 OAuth 回跳分别启动协议 PID `23044` 与 `20416`；
4. 协议进程及其子进程均因进程终止分离 DLL，没有运行中动态卸载；
5. 两次主实例 `auth.log` 都只记录本地服务启动和 Login URL，之后没有 callback、token exchange 或 `signedIn`。

剩余未知点位于 IDE `2.5.5` 内部：协议第二实例如何把 URL 交给主实例，以及认证服务如何把 OAuth 结果写入统一状态。它们不属于本仓库源码；若要继续定位，需要分析 IDE 自身的 Electron 主进程实现或由上游修复。

## 只读采集脚本

脚本：`scripts/collect-oauth-diagnostics.ps1`

默认行为：

- 自动尝试定位正在运行的 Antigravity IDE 安装目录；
- 默认优先读取 `%APPDATA%\Antigravity IDE\logs`，兼容回退 `%APPDATA%\Antigravity\logs`；
- 默认采集最近 15 分钟；
- 在 `%TEMP%` 下新建一个带时间戳的证据目录；
- 不停止进程、不写注册表、不修改安装目录和源日志；
- 对 URL query/fragment、OAuth/CSRF 参数、Bearer/JWT 等令牌做尽力遮蔽。

在受影响电脑上，以普通 PowerShell 执行：

```powershell
.\scripts\collect-oauth-diagnostics.ps1
```

指定安装目录、IDE 日志根目录、输出目录与事件时间窗：

```powershell
.\scripts\collect-oauth-diagnostics.ps1 `
  -InstallDir "$env:LOCALAPPDATA\Programs\Antigravity IDE" `
  -LogRoot "$env:APPDATA\Antigravity IDE\logs" `
  -OutputDir "$env:TEMP\antigravity-oauth-case-20260901" `
  -WindowStart '2026-09-01 17:04:30' `
  -WindowEnd '2026-09-01 17:07:00'
```

`OutputDir` 必须是一个尚不存在的新目录。输出包含：

- `summary.md`：采集边界、参数与结果计数；
- `summary.json`：DLL/IDE 文件哈希与版本、协议注册、进程、日志清单和采集告警；
- `logs/proxy`、`logs/ide`：按时间窗筛选且已遮蔽的日志副本。

脚本对没有可解析行时间戳的日志采用文件修改时间回退：只有文件修改时间落在窗口内才复制其内容，并在 `summary.json` 的 `Logs[].FilterMode` 标明过滤方式。分享证据包前仍应人工检查敏感信息；自动遮蔽属于尽力处理，不构成绝对保证。

仓库内的合成回归测试不会读取本机 IDE 进程或协议注册表，也不会触碰安装目录：

```powershell
.\scripts\test-oauth-diagnostics.ps1
```

## `child_injection` 最小 A/B

先完全退出 Antigravity IDE，再把 `scripts/set-oauth-child-injection-ab.ps1` 复制到受影响电脑。禁用子进程注入：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\set-oauth-child-injection-ab.ps1 -Action Disable
```

脚本会拒绝覆盖已有备份，并在修改前创建：

```text
%LOCALAPPDATA%\Programs\Antigravity IDE\config.json.oauth-ab.bak
```

启动 IDE，重复一次 Google 登录并记录操作时间。完成证据采集后再次完全退出 IDE，再原样恢复：

```powershell
.\set-oauth-child-injection-ab.ps1 -Action Restore
```

判定标准：

- 禁用后主实例出现 OAuth callback / `signedIn`：代理的子进程创建 Hook 参与故障，再进入窄范围 C++ 修复；
- 禁用后仍无 callback：代理因果基本排除，按 IDE `2.5.5` 上游回调缺陷处理；
- callback 已到达但 token exchange 失败：转查 `auth.log` 中的实际网络或证书错误，不再追踪二实例交接。

### 2026-09-01 实际结果

- 主实例及相关子进程均明确记录 `child_injection=false`；
- 协议 PID `20416` 于 `19:13:36` 启动；
- 代理日志没有“拦截到进程创建”或“已注入新建进程”；
- `auth.log` 仍停留在 `signedOut`，没有 callback 或 token exchange；
- PID `20416/3596/11928` 随后正常终止，仍没有动态卸载记录；
- 测试后已从 `config.json.oauth-ab.bak` 原样恢复，恢复值为 `child_injection=True`。

结论：禁用子进程注入没有改变故障，故本次代理子进程 Hook 不是 OAuth 无响应的根因。论坛中“Try Another Email”路径在部分 `2.5.5` 环境可绕过自动认证，但同一帖子也有仍然失败的反馈，只能作为人工尝试，不能视为已验证修复：<https://discuss.ai.google.dev/t/antigravity-2-5-5-authentication-fails-automatically-but-manual-try-another-email-login-succeeds/178626>。

## 本工作区验证

2026-09-01 已完成以下仓库隔离验证；构建产物只写入独立的 `build-oauth-diagnostics-*` 目录，没有复制到 IDE 安装目录：

- Windows PowerShell 5.1 合成采集回归：通过；
- Windows PowerShell 5.1 `child_injection` A/B 备份/禁用/恢复回归：通过；
- x64 Release 编译：通过，CTest `5/5`；
- x86 Release 编译：通过，CTest `5/5`；
- `git diff --check HEAD`：通过。

这些结果证明代码可编译、既有单元测试未回归、采集器的时间窗与脱敏行为符合夹具预期；它们不替代受影响电脑上的 OAuth 实际回放。

## 建议的双快照回放

下面步骤是待执行占位，不代表已经完成回放：

1. 记录复现电脑、IDE 版本、代理 DLL 构建来源与系统时区：`<待填写>`。
2. 登录前运行一次采集，输出到新的 `before` 目录：`<待填写命令与时间>`。
3. 记录点击 `Continue with Google` 的本地时间：`<待填写>`。
4. 完成浏览器授权并记录跳转发生时间，不手动关闭 IDE：`<待填写>`。
5. 跳转后立即运行第二次采集，输出到新的 `after` 目录：`<待填写命令与时间>`。
6. 对比两次 `summary.json` 中 `InstalledDlls` 的存在性、大小、修改时间和 SHA-256：`<待填写结果>`。
7. 用 `summary.json` 中的 `Processes`、`ProtocolRegistrations` 和同窗日志串联 PID/PPID、`--open-url`、第二实例与 detach：`<待填写结果>`。
8. 若日志仍缺少决定性事件，只增加一个最小观测点后重放，避免同时改变代理配置、协议注册或 IDE 版本：`<待填写观测点>`。

## 证据判定边界

- 浏览器成功页只能证明浏览器侧认证完成。
- 协议注册表存在只能证明静态注册状态；还要由进程与日志证明本次回跳实际使用了它。
- DLL 文件仍存在且哈希未变，可以排除“文件被删除或替换”，不能证明该 PID 一直存活。
- detach 日志与 PID 消失同时出现，支持进程生命周期解释；运行中同一 PID 明确记录动态卸载文本，才支持动态卸载解释。
- IDE 保持在欢迎页只能证明 UI 未进入已登录状态，不能单独定位失败环节。
- 源码中的新日志分支在对应构建部署并复现之前，只是待验证的观测能力。
- `lpvReserved == nullptr` 的显式释放/加载失败回滚分支仍沿用旧清理流程；它位于 loader lock 内，是未在本次进程终止路径中扩展处理的残余风险。

## 参考依据

- Microsoft `DllMain` 文档：`DLL_PROCESS_DETACH` 时 `lpvReserved` 非空表示进程终止，空值表示 `FreeLibrary` 或 DLL 加载失败。
- Microsoft 动态链接库最佳实践：`DllMain` 在 loader lock 下执行，应把工作限制到最小范围并避免同步等待。

参考链接：

- <https://learn.microsoft.com/windows/win32/dlls/dllmain>
- <https://learn.microsoft.com/windows/win32/dlls/dynamic-link-library-best-practices>
- <https://github.com/electron/electron/blob/main/docs/tutorial/launch-app-from-url-in-another-app.md>
- <https://discuss.ai.google.dev/t/oauth-callback-not-received-by-app-after-successful-browser-authentication-windows-11/178921>
- <https://discuss.ai.google.dev/t/antigravity-2-5-5-authentication-fails-automatically-but-manual-try-another-email-login-succeeds/178626>
