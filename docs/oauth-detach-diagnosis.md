# OAuth 回跳与 DLL 卸载日志诊断记录

## 当前状态

这份记录用于区分以下三个不同事件：

1. 浏览器完成 Google 身份验证；
2. `antigravity-ide://oauth-success` 被 Windows 协议处理器接收并交给 IDE；
3. IDE 进程退出、第二实例交接，或 DLL 被动态卸载。

当前证据还没有形成从协议回跳到 IDE 登录态落盘的完整链路，因此这里不把问题标记为已解决。

## 已有证据

用户提供的浏览器截图显示 `You have successfully authenticated.`，并提示将跳回产品；IDE 截图仍停留在 `Continue with Google` 欢迎页。它们能证明浏览器侧授权页成功，不能单独证明自定义协议已由预期 IDE 进程处理，也不能证明 IDE 已接收并持久化登录态。

用户提供的 2026-09-01 日志显示：

- `17:06:08`，PID `21804` 加载代理 DLL，并创建、注入 PID `28772` 与 `2440`；
- `17:06:09`，PID `2440` 记录 `Antigravity-Proxy DLL 已卸载`；
- `17:06:11`，PID `21804` 与 `28772` 记录同一条卸载文本。

旧日志文本只表示执行到了 DLL detach 分支。旧实现没有在日志中区分“进程终止触发 detach”和“运行中动态卸载”，所以仅凭 `DLL 已卸载` 不能推出 DLL 文件被删除，也不能推出 IDE 被系统卸载。

当前工作区的 `src/main.cpp::DllMain` 已按 `lpvReserved` 区分两类 detach：进程终止时跳过复杂清理，动态卸载或加载失败回滚时保留清理。终止原因日志采用零等待的尽力写入；日志锁争用或写入失败时只进入调试输出，因此“缺少终止日志”不能反证进程没有终止。`src/main.cpp::IsOpenUrlProtocolLaunch` 只判断命令行中是否存在 `--open-url`，不会复制或记录可能含令牌的完整 URL。该修改仍需要用受影响电脑上的实际构建和运行日志验证，不能用源码状态替代运行时证据。

代理日志位置由 `src/core/Logger.hpp::GetLogDirectory` 决定：优先使用 DLL 同级的 `logs` 目录，创建失败时回退到 `%TEMP%\antigravity-proxy-logs`。IDE 日志的已知根目录为 `%APPDATA%\Antigravity\logs`，现有代码也从该位置查找最新的 `ls-main.log`（`src/hooks/Hooks.cpp::TryGetLatestAntLogDir` 与相邻日志扫描逻辑）。

## 待证明的链路

后续证据需要按同一时间窗回答：

1. 登录前后安装目录中的 `version.dll` 是否一直存在，大小和 SHA-256 是否变化；
2. `antigravity-ide` 协议在 HKCU/HKLM 实际注册到哪条命令；
3. OAuth 回跳时哪个 PID 以 `--open-url` 或协议 URL 启动，它的 PPID 是谁；
4. detach 日志对应的是进程终止、动态卸载还是加载失败回滚；
5. IDE 的 main/auth 日志是否记录回调接收、第二实例交接、登录态写入或明确错误。

只有上述链路闭合后，才能判断问题属于协议注册、第二实例交接、进程生命周期、DLL 加载回滚，还是 IDE 自身的认证状态处理。

## 只读采集脚本

脚本：`scripts/collect-oauth-diagnostics.ps1`

默认行为：

- 自动尝试定位正在运行的 Antigravity IDE 安装目录；
- 默认读取 `%APPDATA%\Antigravity\logs`；
- 默认采集最近 15 分钟；
- 在 `%TEMP%` 下新建一个带时间戳的证据目录；
- 不停止进程、不写注册表、不修改安装目录和源日志；
- 对 URL query/fragment、OAuth 参数、Bearer/JWT 等令牌做尽力遮蔽。

在受影响电脑上，以普通 PowerShell 执行：

```powershell
.\scripts\collect-oauth-diagnostics.ps1
```

指定安装目录、IDE 日志根目录、输出目录与事件时间窗：

```powershell
.\scripts\collect-oauth-diagnostics.ps1 `
  -InstallDir "$env:LOCALAPPDATA\Programs\Antigravity IDE" `
  -LogRoot "$env:APPDATA\Antigravity\logs" `
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

## 本工作区验证

2026-09-01 已完成以下仓库隔离验证；构建产物只写入独立的 `build-oauth-diagnostics-*` 目录，没有复制到 IDE 安装目录：

- Windows PowerShell 5.1 合成采集回归：通过；
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
