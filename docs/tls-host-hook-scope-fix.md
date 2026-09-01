# Antigravity IDE 本地 TLS/gRPC 宿主 Hook 分域修复

## 1. 问题结论

本次失败不是输入控件问题。Antigravity IDE 已向本机 Language Server 发起 HTTPS/gRPC 请求，但宿主进程加载 `version.dll` 后持续返回 `net::ERR_CERT_AUTHORITY_INVALID`，Language Server 同时持续记录 `tls: unknown certificate`。

修复前基线在 `src/main.cpp` 中无条件启用完整网络 Hook。该策略会让 `Antigravity.exe`、`Antigravity IDE.exe` 及其同名 Electron 子进程安装 Winsock/IOCP Hook，重新覆盖了历史提交 `216dd2ae` 针对同一 TLS 症状建立的宿主隔离边界。

现有日志只能证明“宿主完整网络 Hook”是稳定触发条件，不能把某一个具体 API 或 `setsockopt` 单独认定为证书失败根因。因此本次不修改连接状态机，而是恢复已经验证过的进程职责边界。

## 2. 实施内容

### 2.1 宿主仅保留进程创建 Hook

`src/main.cpp` 使用 `Hooks::IsAntigravityHostProcessName` 决定是否安装网络 Hook：

- `Antigravity.exe`、`Antigravity IDE.exe`：仅安装 `CreateProcessA/W` Hook，继续负责子进程注入。
- `language_server.exe`、`language_server_windows_*`、`node.exe`：安装完整网络 Hook，外网请求继续通过 SOCKS5/HTTP 代理。

启动日志会明确区分：

- 宿主：`使用注入器模式：仅安装进程创建 Hook，跳过网络 Hook`
- Language Server/Node：`使用全量模式：安装网络与进程创建 Hook`

### 2.2 保留最小改动面

本次没有新增配置项，没有修改 `connect`、`WSAConnect`、`ConnectEx`、FakeIP、UDP 或 IOCP 状态机。此前工作树中的目标级 bypass 草案已按方案审批移除，避免把两套互斥策略混入同一交付。

`tests/test_process_name.cpp` 保留宿主、Language Server 与 Node 的分类边界断言，并同步说明其 TLS 隔离意图。

## 3. 仓库验证

针对性脚本：

```powershell
.\scripts\test-tls-host-hook-scope.ps1 -Config Release -Arch x64
```

脚本执行以下闭环：

1. 使用 `BUILD_TESTS=ON` 配置独立 x64/x86 构建目录。
2. 编译 `version` DLL 和 `process_name_tests`。
3. 通过精确 CTest 名称运行进程分类回归测试，零测试或失败均返回非零退出码。

2026-09-02 实际验证结果：

- 测试脚本 PowerShell AST 解析通过。
- 针对性 x64 Release 验证通过：`version` 与 `process_name_tests` 编译成功，CTest `1/1` 通过。
- `build.ps1 -Clean -Config Release -Arch x64 -RunTests` 通过：完整 CTest `5/5` 通过。
- 生成的 `output/ide/version.dll` 为 619008 字节，SHA-256 为 `16B8B61128629700C23E0410D687E35C9592BFE919153176DE8785D36E6EDB3A`。
- CMake 仍输出既有最低版本兼容性弃用警告，不影响本次配置、编译或测试结果。
- 构建产物未复制到 IDE 安装目录，未启动 IDE；物理验收仍按下一节执行。

## 4. IDE 物理验收边界

仓库编译和单元测试不能代替 Antigravity IDE 物理验收。最终验收应在关闭 Clash TUN 的条件下检查：

1. 安装目录 `version.dll` 与本次构建产物 SHA-256 一致。
2. 所有 `Antigravity IDE.exe` 日志均显示注入器模式。
3. `language_server_windows_x64.exe` 与必要的 `node.exe` 显示全量模式，并能建立外网代理隧道。
4. `ls-main.log` 启动阶段允许出现少量瞬时 TLS 探测失败，但不能持续重试。
5. 插件商店可加载，会话创建与 `GetInputCompletion`、`GetMcpServerStates` 不再返回 `ERR_CERT_AUTHORITY_INVALID`。

宿主外网请求不再由 DLL 强制代理。如果后续能证明某个 OAuth 或插件请求必须由宿主代理，应基于该具体请求另行设计窄范围方案，不重新默认启用宿主全部 Winsock/IOCP Hook。
