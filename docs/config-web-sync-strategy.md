# Config Web 字段同步与漂移自检方案

## 1. 目标与边界
- 目标：让 `resources/config-web/index.html` 与 `src/core/Config.hpp` 的 `Core::Config::Load()` 长期保持一致，减少字段遗漏。
- 边界：不引入新外部依赖；保持单文件 HTML 方案；只做前端本地校验与提示，不改后端行为。

## 2. 字段真源
- 后端字段真源：`src/core/Config.hpp` 中 `Load()` 解析逻辑（`j.value(...)` / `contains(...)`）。
- 当前覆盖字段（按后端解析）：
  - `log_level`
  - `proxy.host / proxy.port / proxy.type`
  - `fake_ip.enabled / fake_ip.cidr`
  - `timeout.connect / timeout.send / timeout.recv`
  - `traffic_logging`
  - `diagnostics.agent_ip_probe`
  - `child_injection / child_injection_mode / child_injection_exclude[] / target_processes[]`
  - `proxy_rules.allowed_ports[]`
  - `proxy_rules.dns_mode / ipv6_mode / udp_mode / udp_fallback`
  - `proxy_rules.routing.enabled / priority_mode / default_action / use_default_private`
  - `proxy_rules.routing.rules[].name/enabled/action/priority/ip_cidrs_v4[]/ip_cidrs_v6[]/domains[]/ports[]/protocols[]`

## 3. 前端同步点（必须同时维护）
当后端新增/调整字段时，前端至少同步以下位置：

1. `defaultForm()`：补齐默认值
2. `normalizeForm()`：补齐导入归一化（类型、枚举回退、容错）
3. `exportObject()`：补齐导出覆盖路径
4. `validateAll()`：补齐校验与错误提示
5. 表单 UI：补齐输入组件与 `tip-pop` 字段说明
6. （新增）`REQUIRED_CONFIG_PATHS` 与漂移自检映射：保持自检清单一致

## 4. 漂移自检机制（前端内置）
文件：`resources/config-web/index.html`

核心实现：
- `REQUIRED_CONFIG_PATHS`：字段规范路径清单
- `REQUIRED_DATA_BIND_PATHS`：标量 `data-bind` 必需路径
- `REQUIRED_LIST_CONTAINERS`：数组编辑容器映射
- `REQUIRED_RULE_EDITOR_IDS`：规则编辑器关键控件
- `runSchemaDriftCheck()`：启动时执行的交叉检查

检查维度：
- `defaultForm` 覆盖检查
- `exportObject` 覆盖检查
- UI 绑定与容器存在性检查
- `validateAll` 关键字段标记检查

输出方式：
- 侧栏显示 `字段同步自检提示`
- 控制台输出 `[SchemaDriftCheck]`
- Toast 弱提示（不阻断使用）

## 5. 维护建议（KISS / YAGNI / SOLID）
- KISS：字段变更时优先改清单 + 5 个同步点，不做额外抽象。
- YAGNI：不引入复杂 schema 生成器，仅保留必要自检。
- SOLID：
  - 单一职责：默认值、归一化、导出、校验、UI 渲染分开维护。
  - 依赖方向：以后端字段为唯一真源，前端仅做映射与提示。

## 6. 变更后验收清单
- 字段覆盖：后端新增字段在 `defaultForm/normalize/export/validate/UI` 均可检索到。
- 自检结果：页面启动后无 `schemaDrift` 告警。
- 可导出性：无校验错误时可导出 JSON。
- 兼容性：暗黑/亮色正常，移动端触控目标满足可点击尺寸。
