# Antigravity IDE 宿主联网与本地 TLS 回归修复

## 1. 结论

远程电脑先后暴露了两个独立问题：按进程名禁用宿主网络 Hook 会让 IDE 整体断网；恢复全量 Hook 后，本地 Language Server TLS 仍会出现 `ERR_CERT_AUTHORITY_INVALID` / `tls: unknown certificate`。

失败日志中，所有 `Antigravity IDE.exe` 都进入“仅安装进程创建 Hook，跳过网络 Hook”模式；`language_server_windows_x64.exe` 仍安装全量 Hook，并成功为多个 Google 域名建立 SOCKS5 隧道。这说明代理服务可用，但 IDE 主进程、Electron NetworkService 和 NodeService 的外网请求没有进入代理。

本机旧 DLL 能正常联网也不矛盾。本机运行日志显示宿主使用全量 Hook，并已观察到外网隧道、`signedIn` 和 Cloud Code 请求成功。两台电脑实际加载了不同行为的 DLL，产品版本号不能替代 DLL 哈希与启动日志。第一阶段全量 Hook 产物恢复了远程外网，但远程物理验收继续复现 TLS，证明还需要目标级旁路。

## 2. 根因

`src/main.cpp` 曾使用 `Hooks::IsAntigravityHostProcessName` 决定是否安装网络 Hook。Electron 主进程、NetworkService、NodeService、renderer 及部分扩展子进程都使用 `Antigravity IDE.exe`，仅按可执行文件名分类会把职责不同的进程全部排除在代理链路之外。

运行时还证明，同一个 NodeService 既会启动本地 Language Server，也可能直接发起扩展外联。按进程角色继续细分仍会留下局部断网，因此所有目标进程必须保持全量网络 Hook，再按连接目标区分外部代理与本地直连。

原有 loopback 判断发生在统一代理函数的中后段，本地连接在返回原始 API 前已经设置 socket 超时并经过多层 Hook。`DetourWSAConnect` 还会丢弃调用方的连接数据与 QoS 参数，`WSAConnectByNameA/W` 则自行解析并改走另一套 API，均不满足透明直连语义。

## 3. 修复范围

- `src/main.cpp` 固定使用 `enableNetworkHooks = true`，所有已注入目标进程安装网络 Hook 与进程创建 Hook。
- 启动日志统一输出 `使用全量模式：安装网络与进程创建 Hook`。
- `src/network/LocalTargetPolicy.hpp` 严格识别 `127.0.0.0/8`、`::1`、v4-mapped loopback 与 `localhost`，不扩大到 LAN/私网目标。
- `connect`、`WSAConnect`、`ConnectEx`、`WSAConnectByNameA/W` 在读取代理配置或设置超时前调用原始 API；`WSAConnect`、ConnectEx 与 WSAConnectByName 的调用参数保持不变。
- 命中的本地 socket 在 send/recv、WSASend/WSARecv、sendto/recvfrom、WSASendTo/WSARecvFrom、WSAIoctl、WSAGetOverlappedResult、shutdown 与 closesocket 阶段继续旁路代理和流量监控逻辑。
- 本地 ConnectEx 不写入代理 pending context，GQCS/GQCSEx 对其完成事件自然保持 no-op。
- `tests/test_process_name.cpp` 仅验证进程名解析与分类工具，不再把分类结果解释为运行时禁用策略。
- `tests/test_local_target_policy.cpp` 覆盖 IPv4、IPv6、v4-mapped、地址长度校验、localhost 规范化和误判防护。
- `scripts/test-host-network-hook-scope.ps1` 同时校验全量 Hook 与本地旁路源码契约，并执行两项针对性 CTest。

外部目标的 FakeIP、SOCKS5/HTTP、UDP 与 IOCP 状态机保持原样。socket 创建阶段的 IPv6 dual-stack 设置也保持不变，因为创建时尚不知道目标，移除它会破坏外部 IPv6/v4-mapped 代理。

## 4. WinSock 契约依据

`context7` 查询 `MicrosoftDocs/win32` 与 `MicrosoftDocs/sdk-api` 均因仓库过大返回 422，改用 Microsoft Learn 官方页面核对：

- [WSAConnect](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaconnect)：连接数据与 QoS 参数属于 API 契约，本地旁路必须原样传递。
- [ConnectEx](https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nc-mswsock-lpfn_connectex)：使用 Overlapped I/O，可携带连接建立后的首包，旁路不得改写缓冲区、字节数或 `OVERLAPPED`。
- [WSAConnectByNameA](https://learn.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-wsaconnectbynamea)：成功时由系统回填 LocalAddress 与 RemoteAddress，本地旁路直接调用原实现。

## 5. 验证与远程部署

仓库验证命令：

```powershell
.\scripts\test-host-network-hook-scope.ps1 -Config Release -Arch x64
.\build.ps1 -Clean -Config Release -Arch x64 -RunTests
```

2026-09-02 第一阶段（仅恢复全量 Hook）验证结果：

- `test-host-network-hook-scope.ps1` 通过 PowerShell AST 解析。
- 针对性 x64 Release 构建通过，`process_name_tests` 实际执行并以 CTest `1/1` 通过。
- 完整 x64 Release 构建通过，CTest `5/5` 通过。
- `output/ide/version.dll`：617472 字节，SHA-256 `C0A7DD2F855A04370BE2B4B76D5DCF11F56C715106BC4DE637399A63EC133675`。
- `output/ide/config.json`：SHA-256 `DAECDBDACF489C5C2877C6758AABF397C8B17D073BCE8AD3DC9E756F26D9EC6F`。
- 本机安装目录中的可用旧 DLL 未被覆盖，其 SHA-256 为 `BDA89304EBEE956BFA14D0BCDE9BB3F5BDA5740FEEF649B7634CE763A91C6291`。

2026-09-02 第二阶段（严格 loopback 全生命周期旁路）验证结果：

- `test-host-network-hook-scope.ps1` 的源码契约检查通过，针对性 CTest `2/2` 通过。
- 完整 x64 Release 构建通过，CTest `6/6` 通过。
- `output/ide/version.dll`：627712 字节，SHA-256 `D1031776502098E1C231A36BE61147D17B4C9B8A0A06F70F7310B4AF4802522F`。
- `output/ide/config.json`：1558 字节，SHA-256 `0F147660722C165C4F22C19DE0B8EBA1F16CDC3C04E6B8CE69E206AC51E7DB6E`。
- `output/cli/antigravity_proxy.dll` 与 IDE DLL 内容一致，SHA-256 同为 `D1031776502098E1C231A36BE61147D17B4C9B8A0A06F70F7310B4AF4802522F`。

远程电脑部署时：

1. 完全退出 Antigravity IDE，并确认没有残留的 `Antigravity IDE.exe`、`language_server_windows_x64.exe`。
2. 备份安装目录中的 `version.dll` 与 `config.json`，记录替换前 SHA-256。
3. 将本次 x64 Release 构建生成的 `output/ide/version.dll` 复制到远程安装目录。远程日志已证明现有代理配置可用，优先保留原 `config.json`；只有配置字段缺失时才对照 `output/ide/config.json` 合并，避免覆盖远程自定义值。
4. 记录替换后 SHA-256，启动 IDE。
5. 检查宿主、Language Server 和必要 Node 进程均记录 `使用全量模式`。
6. 检查日志出现 `本地目标全透明旁路`，目标应为 `127.0.0.0/8`、`::1` 或 v4-mapped loopback，且不得出现公网目标。
7. 检查插件市场、登录态、Cloud Code 与会话创建；代理日志应出现外网域名的重定向和隧道成功记录，`ls-main.log` 不再持续出现 TLS 证书错误。

构建和单元测试不能替代远程电脑上的物理验收。远程日志与本地日志必须按机器、启动时间、PID 和 DLL 哈希分别归档，避免把两台电脑的运行态混为同一版本。
