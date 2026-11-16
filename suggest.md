# Duskmoon Bundler 改进建议

审查日期:2026-11-13,基于提交 `a0997ee`(版本 10.1.9)。

## 本轮验收(2026-11-16)

本轮对当前 `10.1.10` 工作区重新审查并验收,交付范围是提交并推送当前 `main`。
下方 2026-11-14 的结果保留为历史记录,不代替本轮验证。

- 补齐 #26 的消费层遗漏:生产 Builder、开发 Vendor 和 Tailwind 解析不能在 npm
  exports 拒绝后退回磁盘或另一个目录中的同名包; 显式子路径映射保持权威。
  保留无 exports 包的 CSS main 优先级和无 manifest 目录的既有回退行为。
- 新增 13 项回归。先复现生产解析的 2 项失败及样式解析的 5 项失败,修复后全部通过。
- 当前工作区 #27 的包样式入口、冷启动、重复浏览器导航和生产 CSS 产物回归也纳入验收。

| 检查 | 本轮结果 |
|---|---|
| `mix format` / `mix format --check-formatted` / `mix compile --warnings-as-errors` | source 模式通过 |
| Bundler | 681 tests + 2 doctests,0 失败,含 Chromium 回归 |
| runtime / npm / OXC / Oxide / Vize / HexSolver | 35 / 571 / 70 / 8 / 34 / 17 tests,全部 0 失败 |
| 发布、staging、workflow、native 下载与策略脚本 | 9 组共 90 tests,0 失败 |
| 独立 runtime consumer / 工作区 JS | 1 / 2 tests,0 失败 |
| Rust | 五个 crate 的 Clippy 1.99.0 `--offline --locked -- -D warnings` 和 rustfmt 通过 |
| CI 配置与归档 | actionlint 1.7.12、native helper / Rust pin 校验、11,371 条 inventory 路径校验通过 |
| 安全审计 | Hex audit 通过; 五份 Cargo.lock 在 RustSec `02e2517f457a359fc6d3440ea4560c8ea188fee8` (2026-11-15) 上均无漏洞或警告,未忽略公告 |

集成测试使用 seed `910037`。本机旧 `/tmp` Zig staging 缺少 `aro/build/generate_def.zig`,
改用本轮独立的 `ZIGLER_STAGING_ROOT` 后源码编译通过,未修改依赖或跳过编译。
QuickBEAM 的既有生成 `.zig` 文件及 `test_addon.node` 构建产物保留在工作区,不纳入提交。

本轮没有重新执行 Hologram / QuickBEAM 全套、Credo / Dialyzer、跨平台 native 发布和
GitHub OIDC 签名流程; 下方已记录的限制仍然适用。本轮不发布新版本。

## 修复状态(2026-11-14)

下文是修复前的审查记录,代码片段和行号对应提交 `a0997ee`。之后在当前工作区分轮修复(未提交)。下面先列本次 GitHub #26 与剩余建议的处理结果,再保留前一轮的修复与验证记录; 历史审查正文不代表当前仍有这些缺陷。

**已修复**:Q1、Q2、Q3、Q4、Q5(粗粒度:任何 CSS 变化驱逐全部 CSS 缓存)、Q6、Q7、Q8(TS/TSX)、Q9(OXC 一份)、Q10、Q11、Q12、Q13 中除下列外的各行、Q14 的选项校验 / `__struct__` 键 / `Bundle.run` 错误形状、Q15 的 preamble 死代码、P1、P4 的低风险部分、P5 的缓存驱逐、A1 的崩溃路径、A2、A3、S1、S2、S3、S4、S5 的认证 / 重定向 / integrity / 大小上限、S7、S8 的 `secrets: inherit` / `env:` 间接引用 / 临时文件 / Dependabot / `SECURITY.md`、D2、D3、D4 的 runner 标签、D6、D7,以及 T1 里的 semver、tarball、Constraint、oxide、vize、oxc 测试。

**审查结论不成立(未改生产代码)**:

- S8 的 Dotenvy 副作用:默认写的是进程字典,不是系统环境变量。
- Q13 的 `public_dir.ex` `URI.decode` 崩溃:Elixir 1.18.5 上不抛错。
- Q13 的 `.cjs` / `.cts` 未监听:dev server 本来就不 serve 这两种文件。

**本次已处理: GitHub #26 与剩余建议**:

| 项目 | 当前行为与验证方式 |
|---|---|
| [#26](https://github.com/duskmoon-dev/duskmoon-bundler/issues/26) exports 通配符 | 按 Node 的前缀长度、完整模式长度选最具体规则; 精确匹配、`null` 和不匹配条件不能回退到宽泛规则或磁盘路径。button/alert 注册路径和顺序无关测试已补,并与 Node 实际解析对照 |
| Q13 导入 CSS 的相对 URL | 在 Vize NIF 内,按每条规则的来源文件重定位 URL,再 minify。覆盖嵌套/循环 import、相对入口、符号链接、重复文件名、图片/字体、query/fragment、dev 与生产产物; 保留 CSS Modules 原有导出约定 |
| Q8 Vue/Svelte HMR | 复用组件插件提取的 script/script setup/module 脚本解析自接受与依赖接受,避免模板文本产生假边界 |
| Q9 / Q15 | CSS 补丁拒绝重叠; AssetURLRewriter 使用普通累加器; 四份 native helper 增加一致性检查(显式保留 Zigler URL 回调返回 tuple 的适配差异) |
| P2 / P5 | Collector 保留并复用 pipeline 结果,每个模块只 load/compile/transform 一次,含 JSON、带 query 的 JSON 和插件模块; chunk 导入需求每个模块只解析一次。已有 graph 直接传给输出阶段 |
| P3 | 缓存解析后的开发配置,以 tsconfig、dotenv 的实际内容、应用/系统环境与 cwd/options 失效; 保留包目录发现和源码图核验,保证未启动 Watcher 的消费者仍看到改动 |
| P4 / S5 | lockfile 保留 os/cpu 约束并离线判断平台; 启用包龄策略时直接请求带 time 的完整 packument。开启策略后会升级先前的精简/旧格式缓存; 完整响应不含 time 的私服仍按 TTL 复用,不会重复请求 |
| npm.pack / npm.publish | 三个打包入口统一文件选择。发布包含 versions、tarball attachment、SHA1/SHA512; 假 registry 验证认证隔离、成功、409、拒绝重定向与无网络 dry-run。拒绝 private 包及尚未支持的 bundledDependencies; 不自动执行生命周期脚本 |
| A1 / A4 | dev task 的 Watcher 进入应用监督树,有 kill 后重启测试; AGENTS.md 明确 HexSolver.Constraint 是同版本 cohort 内部契约 |
| S6 / Cargo release | 根 rust-toolchain.toml 固定 1.99.0; 五个 crate 声明 MSRV,有效 workspace/standalone release profile 显式保持原默认值与 unwind。cross v0.2.5,发布 cargo --locked; CI 校验各处 pin,本地 Clippy/rustfmt 与 rustc 配套 |
| Cargo 审计发现的依赖问题 | 旧 LightningCSS 经 parcel_sourcemap 引入的 rkyv 0.7.46 命中 [RUSTSEC-2026-0235](https://rustsec.org/advisories/RUSTSEC-2026-0235)。CSS 封装统一使用依赖图中已有的 vize_lightningcss 0.702.0 / rkyv 0.8.18,移除 19 个旧依赖条目; 没有新增包或改变保留依赖的版本/校验和 |
| Q15 / S8 native 发布 | 八个 target wrapper 合并为 release matrix,保留 47 产物、目标/NIF ABI/CPU 标志及历史恢复前缀。新发布对 native、精确 Hex tarball、provenance JSON 生成 GitHub OIDC 签名证明 |
| T3 / T4 / T5 | 明确 Hologram 五个嵌套套件不属于根测试/发布门禁; CI 增加 actionlint、Clippy、helper/pin 校验及 Elixir 1.19/1.20 + OTP28 编译矩阵。定时/手动质量工作流分别跑 Credo、Dialyzer、Hex/Cargo audit,失败保留诊断,没有屏蔽已有告警 |
| D1 / D5 / D9 | staging 为九个包加入根 cohort CHANGELOG,保留包内/上游历史并加入 Hex 文件清单,源码版本/历史不改。迁移记录与闲置 Biome 配置归档,inventory 路径验证仍通过; 增加 CONTRIBUTING.md、CODEOWNERS |

**本次验证结果(2026-11-14)**:

| 检查 | 结果 |
|---|---|
| `mix format --check-formatted`、`mix compile --warnings-as-errors` | 最终集成后通过 |
| Bundler | 664 项 + 2 doctests,0 失败; Chromium 浏览器回归包含在内 |
| npm | 571 项,0 失败; 包含 #26、真实发布请求体、pack 文件规则、平台锁信息与包龄缓存模式切换 |
| Vize | 34 项,0 失败; 包含导入 CSS 的 URL、共享/循环导入、相对入口与符号链接、CSS Modules 与既有错误约定 |
| Rust | 五个 crate 的 Clippy 1.99.0 `--offline --locked -- -D warnings` 与 rustfmt 通过 |
| 发布、staging 与 native 脚本 | 本次相关五组套件 33 / 3 / 8 / 4 / 29 项,共 77 项,0 失败 |
| GitHub Actions 与工具链 | actionlint 1.7.12、native helper 副本与 Rust pin 校验通过 |
| Hex 依赖审计 | `mix hex.audit` 通过,未发现已撤回或有安全公告的依赖 |
| Cargo 依赖审计 | 五份锁文件通过。使用 RustSec 数据库 `4ef2df8`(2026-11-13)与本机缓存的 crates.io 索引; Vize 的上述公告在依赖统一后消除,未添加忽略项 |
| 归档与改动边界 | inventory 11,371 条路径验证通过; `git diff --check` 通过。仅 Vize 的 Cargo.lock 因审计修复缩减依赖; 包版本、其余锁文件、native 校验和及原有 QuickBEAM 生成/构建文件保持本轮开始时内容 |

集成回归额外发现并修复了三处问题:缓存编译结果时,带 query 的 JSON 必须按最终 JS 标签编译; 浏览器 fixture 原先使用跨 BEAM 实例会重复的整数目录名,现改为随机名称并独占创建,避免碰到已有 Chromium profile; CSS 循环导入时通过 `../` 表示的同一文件未被识别,导致路径不断增长,现统一文件路径身份并保留符号链接语义。最终 Bundler 全套使用首次失败的同一 seed 复跑通过,未放宽断言或超时。

**保留的兼容性与性能决策**:

- Vize 的默认公共错误形状暂不作破坏性统一。已用测试刻画并修正文档/类型,将默认返回改为统一 `%Vize.Error{}` 需主版本迁移方案。
- 未为 `js/vendor.ex` 的位置参数引入大范围 context struct,也未改写 OXC 的 AST term 编码链路。这两项是需基准支持的内部重构,不是仍可复现的功能缺陷。
- 编译结果已复用,但不强行并行插件钩子; 现有插件可能依赖调用进程与顺序。也不把依赖全局环境/命名 ETS 的测试直接改成 `async: true`。
- 不把配置/源码核验改成仅比较秒级 mtime:同大小同秒编辑和没有 Watcher 的运行方式已有正确性约束。
- 上轮 Credo/Dialyzer 全仓诊断仍未清零; 自动质量工作流会真实报告失败。Hologram 六项环境相关失败和五个嵌套项目未在本次扩大重跑。
- 新的跨平台 native matrix、GitHub OIDC 签名、定时审计和 Elixir 版本矩阵仍需真实 CI 验证。没有发布新版本,下游 #26 需待新 cohort 发布并升级后才能解除其发布阻塞。

**复核后补修(2026-11-14)**:

- 严格缺包错误保留,但 Collector 区分 OXC 降级生成的 `@oxc-project/runtime/helpers/*` 与源码显式导入。自动生成的 helper 交给 Rolldown,恢复私有字段构建及 Hologram 编译; 显式缺包仍失败。
- 生产 manifest 缓存比较实际文件内容,修复相同大小、相同秒级时间戳的原地写入与原子替换。损坏的新内容也不会被旧缓存遮蔽。
- symlink 安装中含有 bin 的缓存包先复制到项目再 chmod,确保 0644 的命令可执行且不修改共享缓存。
- tarball 在 `erl_tar` 展开前校验 GNU sparse 的累计逻辑尺寸、扩展映射与 base-256 字段,限制 raw tar 并拒绝截断 gzip; 非法 PAX 数字字段返回错误而非抛出异常。
- DevServer 对普通 HTML 响应追加独立 HMR 客户端,编译错误按配置、缓存变体和源码版本保存并通过 websocket 重放。具名/默认导入链接失败、连接前错误、修复后恢复、旧编译晚到及 HTML 脚本中的 `</head>` 字符串均有回归覆盖。直接执行错误模块与 websocket 报错共用一个覆盖层,避免副作用导入时重复显示。
- 项目 `.npmrc` 默认不展开环境变量。可信项目可显式设置 `NPM_EX_EXPAND_PROJECT_NPMRC_ENV=true`,或应用配置 `:expand_project_npmrc_env`; 项目 `.npmrc` 自身不能开启此权限。
- Source CI、native 发布和可选 UI 兼容性固定 Rust `1.99.0`,cross 固定为所用 action 支持的 `v0.2.5`。保留目标集合、NIF ABI、CPU 选项与历史产物。真实跨平台构建尚需 CI 验证。
- 已启用仓库 GitHub private vulnerability reporting,并通过 API 读回 `enabled: true`; `SECURITY.md` 的私密报告入口可用。
- Bundler、runtime、npm、OXC、Oxide、Vize 已补 Unreleased 记录,没有回填或改写历史版本。
- 原 `runtime_consumer_test.exs` 是由 `runtime_consumer.exs` 复制到隔离 Mix 项目内的测试 fixture,其 `test_helper.exs` 启动 ExUnit。按正式脚手架验证通过,无需将 fixture 改为独立脚本。
- Bundler 测试中的 `(stop) :draining` 来自 Gaoxy 停止服务器时,新接受连接的 admission 返回 `:draining`,再由 Hell continuation 作为 GenServer stop reason 打印。日志最后事件为 `{:continue, :handle_connection}`,与这条关闭竞态路径吻合; 未发现由本轮改动引入的证据。

**前一轮验证结果(保留记录)**:

| 检查 | 结果 |
|---|---|
| `mix format --check-formatted`、`mix compile --warnings-as-errors` | 通过 |
| Bundler、runtime | 最新为 651 + 2 doctests / 35 项。新增回归通过; Bundler 全套一次出现 Chromium 启动 `:econnrefused`,该用例定点复跑 1/0。此前 650 + 2 doctests 全套 0 失败 |
| npm | 540 项,0 失败 |
| OXC / Oxide / Vize / hex_solver | 70 / 8 / 25 / 17 项,0 失败 |
| QuickBEAM | 1,882 + 7 doctests,0 失败、7 skipped。上轮 OOM 后恢复失败未复现; 另做 100 次独立恢复探针均成功,未修改 native 行为或放宽测试 |
| Hologram Elixir | 9,239 项,6 失败、0 invalid。OXC helper 导致的 setup 失败已修复。剩余失败与 Nix `.erl-wrapped` 启动名、`Enum`/`Access` 缺少 BEAM 源码路径元数据有关; Hologram 源码与测试未修改 |
| Hologram JavaScript | 按 `apps/duskmoon_hologram/assets/package.json` 的 Mocha + jsdom 入口运行,7,326 项通过 |
| 工作区 JS、脚本、runtime consumer | `bun run test` 2/0; 9 个发布/脚本套件共 89/0; 正式隔离 runtime consumer 1/0 |
| 新改的 overlay TypeScript | 使用仓库 OXC formatter/linter 校验,0 格式/规则问题; Chromium 覆盖具名、默认、副作用导入和恢复 |
| Rust Clippy 1.99.0 | 五个 crate 均 `--offline --locked -- -D warnings` 通过; 修正了两个冗余 cast 和一个冗余 `into_iter()` |
| GitHub Actions | actionlint 1.7.12 通过; Rust/cross 输入与现有 action 的接口已核对 |
| Credo | 已执行但未通过。根目录报告 1,698 项,包含 vendored 和第一方代码的风格、复杂度等问题; 未进行全仓风格重构 |
| Dialyzer | 已执行。OXC、Oxide、Vize 按 app 配置均 0 errors; 根目录报告 305 项,多为 Mix/回调元数据缺失及 opaque 类型诊断。Bundler 子目录命令因独立依赖解析失败未进入分析; npm 子目录分析在当前 OTP 环境中因 `prettypr.text/1` 未加载退出。不能视为全仓通过 |

前一轮未执行真实跨平台 native 构建、产物验证与 Hologram 嵌套 Phoenix/umbrella/cluster 套件,也没有发布、提交、创建分支或修改版本号/锁文件。根目录裸 `bun test` 会误发现依赖 Mocha/jsdom 引导的 Hologram 文件; 正式验证使用上表各自的测试入口。

## 范围与方法

- **已审**:`duskmoon_bundler`、`duskmoon_bundler_runtime`、`duskmoon_npm`、`duskmoon_oxc`、`duskmoon_oxide`、`duskmoon_vize` 的 Elixir 与 Rust 代码,`scripts/`,`.github/`,文档与各 app 的 `mix.exs`。约 4.5 万行第一方代码。
- **未审**:`duskmoon_hologram` 与 `duskmoon_quickbeam`(vendored 上游代码),`duskmoon_hex_solver` 只看了集成层面。
- **方法**:静态阅读,没有运行测试套件或构建。数据库查询一项不适用,本仓库没有数据库。

每条建议带一个核实状态:

| 标记 | 含义 |
|---|---|
| **已复现** | 用最小脚本实际跑出了错误行为 |
| **已核对** | 我对照源码确认了代码片段和逻辑,但没有运行 |
| **未复核** | 来自单次阅读,尚未二次确认;动手前请先写一个失败测试 |

工作量:XS < 30 分钟,S 约 1–2 小时,M 约半天到一天,L 一天以上。

## 建议优先处理的十项

| # | 问题 | 优先级 | 工作量 |
|---|---|---|---|
| S1 | workspace 包名未校验即用于 `rm_rf!` 和符号链接 | 高 | S |
| Q1 | `mix npm.run` 只执行 `a && b` 的第一条命令 | 高 | S |
| Q2 | `.js` 结尾的 vendor 包在 dev 下 404 | 高 | XS |
| Q3 | external 的 default / namespace 导入生成错误 JS | 高 | S–M |
| Q4 | chunk 文件名哈希在循环引用时不收敛 | 高 | M |
| Q5 | 修改 `@import` 的 CSS 子文件后返回旧内容 | 高 | M |
| S2 | packument 缓存不区分 registry | 中高 | S |
| S3 | `.npmrc` 的 scoped registry 未生效 | 中 | M |
| S6 | 发布用 Rust 工具链与 `cross` 未固定版本 | 高 | S |
| Q6 | lint 严重级别对三个插件恒为 `:warn` | 高 | XS |

---

## 1. 代码质量与正确性

### Q1. `mix npm.run` 只执行复合命令的第一段 — 已复现

`Port.open({:spawn, cmd})` 在 Unix 上等价于 `sh -c "exec <cmd>"`,`exec` 让第一条命令取代了 shell。

```elixir
# apps/duskmoon_npm/lib/mix/tasks/npm.run.ex:74
port =
  Port.open({:spawn, full_command}, [
    :binary, :exit_status, :stderr_to_stdout, ...
```

复现:`Port.open({:spawn, "true && echo SECOND_RAN"}, ...)` 无任何输出,退出码 0。因此 `"build": "tsc && vite build"` 只跑 `tsc` 并报告成功;`"test": "NODE_ENV=test jest"` 直接失败。额外参数也是未加引号直接拼接的。

**方案**:

```elixir
Port.open({:spawn_executable, System.find_executable("sh")},
  args: ["-c", full_command], ...)
```

并对 `extra_args` 做 shell 转义。该任务目前没有测试。**优先级:高。工作量:S。**

### Q2. `.js` 结尾的 vendor 包在 dev server 下 404 — 已复现

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:152
specifier =
  specifier_js |> String.trim_trailing(".js") |> DuskmoonBundler.JS.Vendor.decode_specifier()
```

`String.trim_trailing/2` 会剥掉所有重复的后缀:`String.trim_trailing("highlight.js.js", ".js")` 返回 `"highlight"`。`highlight.js`、`chart.js`、`video.js`、`lodash/debounce.js` 都受影响。

**方案**:改用 `String.replace_suffix(specifier_js, ".js", "")`,并加一条 `highlight.js` 的测试。同类问题见 Q13。**优先级:高。工作量:XS。**

### Q3. external 的 default / namespace 导入生成错误 JS — 已核对

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/builder/externals.ex:165
{:default, name} -> ~s(const #{name} = #{global}.default;)
{:namespace, name} -> ~s(const #{name} = #{global};)

# apps/duskmoon_bundler/lib/duskmoon_bundler/builder.ex:578
|> String.replace(~r"^@\w+/", "")
```

- `external: ["react"]` 加 `import React from "react"` 生成 `const React = React.default;`,暂时性死区错误。
- `external: %{"jquery" => "jQuery"}` 加 default 导入得到 `jQuery.default`,在 UMD 全局上是 `undefined`。
- `\w+` 不匹配连字符,`@duskmoon-dev/elements` 推导出的全局名带 `@`,输出语法错误。
- 子路径导入(`react-dom/client`)被 `Resolver` 当作 external 跳过,但 `Externals` 只改写精确匹配,最终留下未解析的 import。这一点未复核。

**方案**:用临时绑定加 interop(`const __ext0 = globalThis["React"]; const React = __ext0 && __ext0.__esModule ? __ext0.default : __ext0;`);把推导出的名字规范成合法标识符,scope 正则改为 `~r"^@[^/]+/"`;`Externals` 与 `Resolver` 共用同一个前缀判定。现有测试只覆盖 `vue` 的具名导入。**优先级:高。工作量:S–M。**

### Q4. chunk 文件名哈希在循环引用时不收敛 — 已核对(未构建复现)

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/builder/output.ex:353
next_url_map = chunk_url_map(processed, graph.chunks, name, hash)

if next_url_map == url_map or iteration >= 5 do
  {next_url_map, processed}
```

chunk 名取自代入兄弟 URL 之后的内容哈希。两个 chunk 互相引用时,哈希每轮都变;5 轮后返回的是最新的文件名映射和上一轮的内容,两者不一致,且没有警告。典型场景:`router.js` 动态导入 `page.js`,`page.js` 又静态导入 `router.js`。超过 5 层的无环链同理。

**方案**:文件名改由稳定输入一次性推导(占位符代码加上可达 chunk 的原始哈希),只做一遍改写;如果保留迭代,不收敛时必须 raise。这同时省掉最多 6 轮 `process_chunks`。**优先级:高。工作量:M。**

### Q5. 修改 `@import` 的 CSS 子文件后 dev server 返回旧内容 — 已核对(缓存键部分)

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:270
source = File.read!(file_path)
version = :crypto.hash(:sha256, source)

# apps/duskmoon_bundler/lib/duskmoon_bundler/watcher.ex:296
defp handle_css_change(path, state) do
  DuskmoonBundler.Cache.evict_file(path)
```

缓存版本只是入口文件的哈希,watcher 只驱逐被改动的文件。`app.css` 里 `@import "./buttons.css"`,改 `buttons.css` 后仍命中旧缓存。前提是 `Vize.CSS.bundle` 会内联 `@import`,这一点我没有运行确认。

**方案**:编译时记录 CSS 依赖,把所有被内联文件的哈希并入 `version`;临时方案是任何 CSS 变化都驱逐全部 `.css` 缓存。**优先级:高。工作量:M。**

### Q6. lint 严重级别对 `jsx_a11y` / `react_perf` / `nextjs` 恒为 `:warn` — 已核对(键的构造一侧)

```rust
// apps/duskmoon_oxc/native/oxc_lint_nif/src/lib.rs:115
format!("{plugin}({name})")          // 键:jsx_a11y(alt-text)
// :223
let severity = lint_config.rule_severity_map.get(&full_rule).copied()
    .unwrap_or(AllowWarnDeny::Warn);  // 诊断码:jsx-a11y(alt-text)
```

oxc 对这三个插件的显示名用连字符,查表落空后回退到 `Warn`,配置成 `:deny` 的规则不会让 CI 失败。

**方案**:去掉映射,直接读 `msg.error.severity`。**优先级:高。工作量:XS。**

### Q7. `DynamicImports` 用字节偏移做字素切片 — 已核对

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/js/transforms/dynamic_imports.ex:57
String.slice(source, ref.template_start, ref.template_end - ref.template_start),
```

偏移来自 OXC 的字节 span,同目录其他调用点都用 `binary_part`。文件里在动态 import 之前出现中文注释等多字节字符时切片错位。

**方案**:改为 `binary_part/3`,加一条含非 ASCII 字符的测试。**优先级:中。工作量:XS。**

### Q8. HMR 边界检测把所有源码当作 `.js` 解析 — 已核对

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/hmr/boundary.ex:17
case OXC.parse(source, "hmr-boundary.js") do
  {:ok, ast} -> ast_self_accepting?(ast)
  {:error, _} -> false
```

带类型标注的 TS、`.vue`、`.svelte` 解析失败后返回 `false`,每次编辑都退化成整页刷新。现有测试即使路径是 `.ts` 也只用纯 JS 源码。

**方案**:传入真实文件名,或对编译后的代码做检测。**优先级:中。工作量:S。**

### Q9. `OXC.patch_string` 在补丁重叠时静默输出错误内容 — 已复现(核心行为)

```elixir
# apps/duskmoon_oxc/lib/oxc.ex:1084
|> Enum.sort_by(fn %{start: s} -> s end)
|> Enum.reduce({[], 0}, fn %{start: s, end: e, change: replacement}, {chunks, offset} ->
  chunk = binary_part(source, offset, s - offset)
```

长度为负时 `binary_part` 向后读:`binary_part("abcdefgh", 6, -4)` 返回 `"cdef"`,被替换掉的文本又被输出一次。`apps/duskmoon_vize/lib/vize/css.ex:409` 有一份相同实现。

**方案**:按 `{start, end}` 排序,`s < offset` 时 raise `ArgumentError`。**优先级:中。工作量:XS。**

### Q10. 找不到的裸导入被静默跳过 — 已核对

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/builder/resolver.ex:150
Enum.find_value(dirs, :skip, fn dir -> ... end)
```

包未安装或拼写错误时返回 `:skip`,而相邻分支返回 `{:error, {:not_found, specifier}}`。最终是晦涩的打包错误还是运行时未定义,取决于 Rolldown,未验证。

**方案**:默认值改为 `{:error, {:not_found, specifier}}`。**优先级:中。工作量:S。**

### Q11. 被吞掉的失败 — 已核对

| 位置 | 现状 | 后果 |
|---|---|---|
| `apps/duskmoon_bundler/lib/duskmoon_bundler/css/modules.ex:35` | `{:ok, result} = Vize.CSS.compile(...)`,不检查 `result.errors` | CSS Modules 语法错误时构建通过,运行时类名缺失 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/env.ex:92` | `{:error, _} -> %{}` | `.env` 格式错误时所有 `import.meta.env.*` 变成 undefined |
| `apps/duskmoon_bundler_runtime/lib/duskmoon_bundler.ex:96` | `{:error, _error} -> ensure_leading_slash(path)` | 生产 manifest 损坏时静默返回无哈希 URL |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:141` | `{:ok, body, conn} = Conn.read_body(conn)` | 超大或出错的请求体抛 `MatchError` |

**方案**:只对"预期内的缺失"回退(`:missing_manifest`、`:missing_asset`),其余记录日志或返回错误;`read_body` 加 `length:` 上限。`env.ex` 另见 S8。**优先级:中。工作量:S。**

### Q12. manual chunks 匹配不了 scoped 包和 `deps/` 下的包 — 已核对

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/chunk_graph.ex:349
defp path_pattern?(pattern) do
  String.starts_with?(pattern, "/") or String.starts_with?(pattern, "./") or
    String.starts_with?(pattern, "../") or String.contains?(pattern, "/")
```

任何含 `/` 的模式都被当成文件路径,`"@duskmoon-dev/core"`、`"lodash/fp"` 什么也匹配不到,且不报错。经 `resolve_dirs: ["deps"]` 解析的包路径里没有 `/node_modules/`,同样匹配不到。

**方案**:只有以 `/`、`./`、`../` 开头才算路径;模式零匹配时给出警告。相关问题:manual chunk 命名为 `common` 或 `entry` 会覆盖自动 chunk(未复核),应返回 `{:error, {:reserved_chunk_name, name}}`。**优先级:中。工作量:S。**

### Q13. 其他小的正确性问题

| 位置 | 问题 | 状态 | 优先级 |
|---|---|---|---|
| `apps/duskmoon_bundler/lib/duskmoon_bundler/js/resolver.ex:41` | `String.trim_leading(specifier, prefix)` 剥掉所有重复前缀,`components/components/Button` 解析错;应改 `String.replace_prefix/3` | 已核对 | 低 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/js/transforms/glob_imports.ex:181` | eager glob 标识符按 `i * 100` 分配,单个 glob 超过 100 个文件时与下一个冲突;改用 `Enum.map_reduce` 累计偏移 | 已核对 | 低 |
| `apps/duskmoon_npm/lib/npm_semver/range.ex:287` | `~1.x.3` 走到 `min + 1` 时 `min` 为 `nil`,抛 `ArithmeticError` 而不是返回 `:error` | 已核对(未运行) | 低 |
| `apps/duskmoon_oxc/lib/oxc/lint/type_aware.ex:64` | 读 `Application.get_env(:oxc, ...)`,但 app 名是 `:duskmoon_oxc`,配置永远读不到 | 已核对 | 中 |
| `apps/duskmoon_bundler/lib/mix/tasks/duskmoon_bundler.dev.ex:68` | 启动 Watcher 时没传 `plugins`、`import_source` 等,插件扩展名的文件不触发 HMR | 未复核 | 中 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/js/extensions.ex:21` | `watchable_js` 不含 JSON、`.cjs`、`.cts`,这些文件能被 serve 但不被监听 | 未复核 | 低 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:177` | 请求路径未做百分号解码,带空格或中文的文件名 404 | 未复核 | 中 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:337` | 编译错误覆盖层以 HTTP 500 返回,模块脚本不会执行非 2xx 响应,用户只看到白屏 | 未复核 | 中 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/builder/rewriter.ex:161` | worker URL 映射以 specifier 文本为键,同一 bundle 里两个 `./worker.js` 互相覆盖 | 未复核 | 中 |
| `apps/duskmoon_bundler/lib/duskmoon_bundler/css/asset_url_rewriter.ex:72` | 被 `@import` 的 CSS 里的 `url()` 相对入口文件目录解析 | 未复核 | 中 |
| `apps/duskmoon_npm/lib/npm/lockfile.ex:530` | 嵌套位置用比顶层更严格的名称校验,`JSONStream`、`@0no-co/*` 之类的嵌套包会让 lockfile 读取失败 | 未复核 | 中 |
| `apps/duskmoon_npm/lib/npm/config.ex:264` | `.npmrc` 不展开 `${VAR}`,CI 里常见的 `_authToken=${GITHUB_TOKEN}` 原样发出 | 未复核 | 中 |
| `apps/duskmoon_npm/lib/mix/tasks/npm.publish.ex:111` | 请求体不含 `versions` 和 `_attachments`,没有上传 tarball 却打印 "Published" | 未复核 | 中 |

### Q14. 原生封装的选项与返回值不一致

- **无效选项被静默忽略**(已核对 `format` 一项):`apps/duskmoon_oxc/native/oxc_ex_nif/src/bundle.rs:288` 对未知 `format` 回退到 IIFE;`define` 里只要有一个非字符串值,整个 map 被丢弃;无效 `target` 被忽略(后两项未复核)。**方案**:在 Elixir 侧校验并 raise `ArgumentError`。**优先级:高。工作量:M。**
- **`sourcemap: true` 的结果带多余的 `__struct__` 键**(未复核):`parse.rs:318` 通过 serde 的 struct 序列化输出,与 `@type code_with_sourcemap` 不符。**方案**:改用 `#[derive(NifMap)]`。**优先级:高。工作量:XS。**
- **错误形状不统一**(未复核):`OXC.Bundle.run/1` 返回字符串键的错误,其他函数返回原子键;`Vize` 的公共 API 有五种错误约定。**方案**:统一为 `{:error, %Vize.Error{}}` 和原子键,属于破坏性变更,放到下一个大版本。**优先级:中。工作量:M–L。**
- **文档里的选项没有实现**(未复核):`OXC.Lint.run` 的 `:fix` 计算了修复但不返回;`OXC.Format` 的 `embedded_language_formatting`、`sort_tailwindcss` 未被解码。**方案**:实现或从文档和类型里删掉。**优先级:中。工作量:S。**

### Q15. 重复与过度复杂的代码

- **`js/vendor.ex` 有 2013 行**,约 30 个私有函数反复传递 5 到 8 个位置参数。**方案**:引入一个上下文 struct,顺带解决 P4 的重复计算。**优先级:低。工作量:M。**
- **`inject_external_preamble` 在单 bundle 模式下是死代码**,在 code splitting 模式下会让 external 的声明出现两次(未复核)。**方案**:删除两个调用点和相关辅助函数。**优先级:中高。工作量:S。**
- **`AssetUrlRewriter` 为每个样式表起一个 `Agent`**(`apps/duskmoon_bundler/lib/duskmoon_bundler/css/asset_url_rewriter.ex:133`,未复核),只为在同步回调里传状态。没有运行时理由,应改成普通的累加器。**优先级:低。工作量:S。**
- **`native_url.ex` 和 `native_policy.ex` 各有四份副本**:目前逐字一致,且因为编译期代码必须随各 Hex 包发布,重复是合理的。**方案**:加一个 CI 检查,断言四份文件除模块名外字节相同。**优先级:低。工作量:XS。**
- **八个几乎相同的 `native-<target>.yml`**:加一个目标要改四处。**方案**:在 `release.yml` 里用 matrix 调用 `native-prebuild.yml`;需要一次真实发布来验证恢复流程里的作业名匹配。**优先级:低。工作量:S。**

---

## 2. 性能优化

### P1. 生产环境 `static_path/2` 每次调用都重读并重解析 manifest — 未复核

`apps/duskmoon_bundler_runtime/lib/duskmoon_bundler/static_path.ex:44`:每次调用做 3 次 `File.exists?`,外加最多 6 次 `File.read` 与 `JSON.decode`。每次页面渲染和 LiveView mount 都会触发。

**方案**:按 `{manifest_path, mtime, size}` 缓存到 `:persistent_term`,每次只需一次 `File.stat`。**优先级:中。工作量:S。**

### P2. 每个模块被编译两次,且全程串行 — 未复核

`apps/duskmoon_bundler/lib/duskmoon_bundler/builder/collector.ex:197` 为了提取 import 跑一遍完整管线后丢弃结果,`Builder.compile_modules/2` 再串行跑一遍。JSON 是三遍。

**方案**:把 collector 的编译结果保留下来复用;剩余部分用 `Task.async_stream(..., ordered: true)`。**优先级:中。工作量:M。**

### P3. `DevServer.init/1` 在 dev 下每个请求都执行 — 未复核

Phoenix 开发环境用 `plug_init_mode: :runtime`。`apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:44` 的 `init/1` 会读 `tsconfig.json`、最多四个 `.env`、查找 `node_modules`,并对应用图里的文件重新哈希。

**方案**:把解析后的配置按 `{profile, opts}` 缓存到 `:persistent_term`,用 mtime 做失效。**优先级:中。工作量:M。**

### P4. npm 的重复 I/O — 未复核

- `apps/duskmoon_npm/lib/npm/registry.ex:197`:`get_packument/1` 每次调用都重读缓存文件,并对每个版本重新解析 `.npmrc`。版本很多的包(如 `@types/node`)单次调用是数千次文件读取。
- `apps/duskmoon_npm/lib/npm/install/linker.ex:516`:平台兼容性判断要在线取 packument,串行,每次安装至少两遍。离线时 "Already up to date" 要等几分钟。

**方案**:`allowed_origins` 每次运行只算一次;在 lockfile 条目里持久化 `os`/`cpu`,从 lockfile 判断;`skipped` 每次安装只算一遍。**优先级:中。工作量:M。**

### P5. 重复解析与全表扫描 — 未复核

- `apps/duskmoon_bundler/lib/duskmoon_bundler/builder/output.ex:821`:每条跨 chunk 边都完整 `OXC.parse` 一次导入方;`ChunkGraph.build` 每个入口跑两遍。
- `apps/duskmoon_bundler/lib/duskmoon_bundler/cache.ex:56`:`evict_file` 用 `:ets.tab2list` 复制整表;缓存键含 vendor 哈希,旧代的行会累积。**方案**:键改成 `{file_path, variant}`,用 `:ets.match_delete`。
- `apps/duskmoon_oxc/lib/oxc.ex:560`:`OXC.parse/2` 把 AST 构建三遍(JSON 字符串、term、再用 `String.to_atom` 重建)。**方案**:在 Rust 侧直接输出原子键。

**优先级:低到中。工作量:各 S–M。**

---

## 3. 架构建议

### A1. Watcher 没有进监督树 — 未复核

`mix duskmoon_bundler.dev` 用裸 `start_link` 启动 Watcher(`apps/duskmoon_bundler/lib/mix/tasks/duskmoon_bundler.dev.ex:80`,已核对)。`watcher.ex:364` 的 `File.read!` 在编辑器原子保存的瞬间可能抛错,进程死后没人重启,HMR 静默失效。Watcher 也没有兜底的 `handle_info`。

**方案**:把 Watcher 放到 `DuskmoonBundler.Supervisor` 下;预期内的文件错误用 `File.read/1` 显式处理并广播 `:error`。**优先级:中。工作量:S。**

### A2. CSS 与资源事件没有防抖 — 未复核

`watcher.ex:189`:一次保存产生多个文件事件,每个都做全表扫描和广播。`Extensions.css()` 还包含 `.scss`、`.less` 等没有编译器支持的扩展名。

**方案**:CSS 和资源事件也走 `schedule_rebuild/2`。**优先级:低。工作量:XS。**

### A3. 缓存全局共享目录缺少跨进程保护 — 未复核

`apps/duskmoon_npm/lib/npm/cache.ex:105` 的锁是 `:global.trans`,只在单个 VM 内有效。两个 `mix` 进程(并行 CI 作业共享 `~/.npm_ex`)可能把解压到一半的目录标记为完成。符号链接策略(`NPM_EX_LINK_STRATEGY=symlink`)还会经由符号链接把嵌套包写进全局缓存。

**方案**:解压到临时目录,写完标记后 `File.rename/2` 就位,目标已存在视为成功;有嵌套子包的父包强制用 copy。**优先级:中。工作量:M。**

### A4. `duskmoon_npm` 依赖 `HexSolver.Constraint` 的私有协议

`npm_semver.ex` 和 `npm/resolver.ex` 直接调用一个 `@moduledoc false`、类型为 `@opaque` 的模块。因为两个包同版本发布,目前是安全的,但这个约束没有写在任何地方。

**方案**:在 `duskmoon_hex_solver` 里给这几个函数补测试,并在 AGENTS.md 或模块文档里写明这是 cohort 内部契约。**优先级:低。工作量:S。**

---

## 4. 安全问题

### S1. workspace / `file:` 包名未校验即用于 `rm_rf!` 和符号链接 — 已核对

```elixir
# apps/duskmoon_npm/lib/npm/install/linker.ex:50
|> run_concurrently(fn {name, source} ->
  source = Path.expand(source)
  target = Path.join(node_modules_dir, name)
  link_local_package(source, target)

# apps/duskmoon_npm/lib/npm/workspace.ex:396
name when is_binary(name) and name != "" -> name
```

克隆一个仓库,其中 `pkgs/a/package.json` 写着 `{"name": "../../victim"}`,`mix npm.install` 就会删除 `node_modules/../../victim` 并在那里放一个符号链接。lockfile 名称、缓存路径和 bin 目标都做了加固,只漏了本地链接这条路径。`mix npm.link` 有同样的模式(未复核)。

**方案**:在收集本地链接时用 `NPM.Scope.installable_name?/1` 校验,不合法返回 `{:error, {:invalid_package_name, name, path}}`;`link_local_package` 里再加一层包含性检查。**优先级:高。工作量:S。**

### S2. packument 磁盘缓存不区分 registry — 已核对

```elixir
# apps/duskmoon_npm/lib/npm/packument_cache.ex:27
{:ok, :erlang.binary_to_term(data)}
...
encoded = String.replace(package, "/", "__")
Path.join(dir(), "#{encoded}.etf")
```

项目 X 的 `.npmrc` 指向另一个 registry,它取到的 `react` packument 在 TTL(1 小时)内会被指向 npmjs 的项目 Y 复用,X 的 registry 可以借此影响 Y 的 lockfile。良性情况是在私有镜像和 npmjs 之间切换时版本列表陈旧。另外 `binary_to_term` 没带 `[:safe]`,写入不是原子的。

**方案**:路径里加入 registry origin 的哈希;用 `binary_to_term(data, [:safe])`;写临时文件后 rename。**优先级:中高。工作量:S。**

### S3. `.npmrc` 的 scoped registry 未生效 — 已核对

`Config.scoped_registry/2`(`apps/duskmoon_npm/lib/npm/config.ex:222`)在 `lib` 里没有调用方。`@corp:registry=https://npm.corp.example` 被忽略,`@corp/ui` 会去默认 registry 取,存在依赖混淆风险。

**方案**:按包解析 registry 并选对应的 token;完成之前,检测到 `@scope:registry` 配置时直接报错,不要静默忽略。**优先级:中。工作量:M。**

### S4. HMR WebSocket 与 console 端点不校验 Origin — 已核对

```elixir
# apps/duskmoon_bundler/lib/duskmoon_bundler/dev_server.ex:121
def call(%Conn{request_path: "/@duskmoon_bundler/ws"} = conn, config) do
  conn
  |> WebSockAdapter.upgrade(DuskmoonBundler.HMR.Socket, [], timeout: config.hmr_timeout)
```

Phoenix 的 `check_origin` 不覆盖这个 plug。开发者访问的任意网站都能连上 `ws://localhost:4000/@duskmoon_bundler/ws`,收到变更文件路径和含源码片段的编译错误,还能向 console 端点 POST 任意日志行。

**方案**:升级或接受 POST 前,拒绝 `Origin` 的 host 与 `conn.host` 不一致的请求,并提供可配置的允许列表。**优先级:中。工作量:S。**

### S5. tarball 与完整性相关的缺口 — 未复核

- `apps/duskmoon_npm/lib/npm/tarball.ex:41`:tarball 请求不带认证且总是跟随重定向,绕过了 `allow_registry_redirects`;私有 registry 的 tarball 会 401。
- `tarball.ex:70`:缺少 integrity 只打印警告,`--frozen` 下也接受;缓存命中时连警告都没有。**方案**:`--frozen` 下默认要求 integrity。
- `tarball.ex:160`:解压和 HTTP 响应体全在内存里,没有大小上限,`dist.unpackedSize` 解析了但没用上。
- `apps/duskmoon_npm/lib/npm/registry.ex:61`:请求的是精简版 packument,其中没有 `time` 字段,包龄警告实际上永远不会触发。

**优先级:中。工作量:各 S–M。**

### S6. 发布用的 Rust 工具链与 `cross` 未固定版本 — 已核对

```yaml
# .github/workflows/native-prebuild.yml:67, 85
toolchain: stable
cross-version: from-source
```

Actions 全部按 SHA 固定,Zig 固定在 0.17.1,只有 Rust 编译器是浮动的。同一份源码之后可能编出不同字节,而 runbook 规定重建出不同产物通常需要新版本号。README 说 "需要 Rust 1.99 或更高",但五个 crate 都没有 `rust-version`,也没有 `rust-toolchain.toml`。

**方案**:加一个 `rust-toolchain.toml` 供 CI、devenv 和发布共用;`cross-version` 固定到 tag 或 commit;给 crate 加 `rust-version`;构建加 `--locked`。**优先级:高。工作量:S。**

### S7. "匿名可下载" 校验会退回到带 token 的下载 — 已核对

```elixir
# .github/scripts/release_support.exs:185
cond do
  exit_status == 0 and status == "200" -> output
  (exit_status != 0 or String.starts_with?(status, "5")) and attempt + 1 < attempts -> ...
  true -> release_api_download!(url, output, ...)
```

首次匿名请求拿到 404 或 403 时直接落到 `true ->` 分支,走 `gh` 认证下载。CHANGELOG 10.1.6 描述的是只对持续 5xx 回退。资产尚不能匿名下载时,Hex 发布仍可能继续。

**方案**:只在最后状态是 5xx 或 curl 失败时调用 `release_api_download!`,4xx 直接 raise,并在 `release_test.exs` 加一条测试。**优先级:中。工作量:XS。**

### S8. 其他安全相关项

| 项 | 状态 | 方案 | 优先级 |
|---|---|---|---|
| 没有签名的构建证明:`release-provenance.json` 是自声明的未签名 JSON | 未复核 | 给 `publish` 加 `id-token: write`、`attestations: write`,用 `actions/attest-build-provenance` | 中高 |
| 没有 Dependabot / Renovate,SHA 固定的 action 和四类 lockfile 无自动更新 | 已核对 | 加 `.github/dependabot.yml` | 中 |
| 三个工作流对不使用 secret 的 `test.yml` 传了 `secrets: inherit` | 已核对 | 删掉这三行 | 低 |
| `native-prebuild.yml:157` 把 `inputs.*` 直接插进 `run:` | 未复核 | 改用 `env:` 间接引用 | 低 |
| `Dotenvy.source(files)` 默认会把 `.env` 里的所有变量写进 VM 的系统环境 | 已核对调用,副作用未复核 | 传 `side_effect: false` | 低 |
| `type_aware.ex:110` 的临时文件名用 `System.unique_integer`,只在单个 VM 内唯一 | 已核对 | 用随机后缀加独占创建 | 中 |
| 没有根目录的 `SECURITY.md`;Hologram 的 `SECURITY.md` 把报告指向上游维护者 | 未复核 | 加根 `SECURITY.md`,改写 Hologram 那份 | 中 |

---

## 5. 测试改进

### T1. 风险最高的逻辑缺少测试

| 区域 | 缺口 | 状态 |
|---|---|---|
| npm tarball | 没有 `../`、绝对路径、符号链接、硬链接条目的测试夹具 | 未复核 |
| `NPMSemver` | 约 800 行只有 5 条断言,而模块文档写着 "fixtures ported from node-semver" | 未复核 |
| `mix npm.run`、`PackumentCache`、本地链接名处理 | 完全没有测试 | 未复核 |
| 构建 | 没有循环 chunk、深层 chunk 链、external 配合 code splitting、scoped manual chunk 的用例 | 未复核 |
| dev server | 没有 `@import`、Origin 校验、`.js` 结尾包名的用例 | 未复核 |
| `duskmoon_oxide`(47 行测试) | `Oxide.scan/1` 对真实文件、`files/1`、`globs/1` 未覆盖 | 未复核 |
| `duskmoon_vize`(167 行测试) | `CSS.collect_urls`、`rewrite_urls`、`bundle`、`parse_sfc`、`compile_ssr` 未覆盖 | 未复核 |
| `duskmoon_oxc` | `sourcemap: true` 的返回形状、`patch_string`、非 eslint 插件未覆盖 | 未复核 |
| `duskmoon_hex_solver`(139 行测试) | 上游测试没有带过来;`duskmoon_npm` 直接调用的 `Constraint` 操作未测 | 未复核 |

**方案**:本文档里每条 "已复现" 和 "已核对" 的 bug,先写失败测试再修。移植 node-semver 的 range fixtures。**优先级:中。工作量:L(可分批)。**

### T2. 锁定了错误行为的测试 — 未复核

`dev_server_test.exs:1068` 断言编译错误返回 `status == 500`。修 Q13 里的覆盖层问题时要同步改这条测试。

### T3. Hologram 的五个嵌套测试套件不在 CI 里 — 已核对

`apps/duskmoon_hologram/mix.exs:177` 的 `test_paths` 只有 `test/elixir`。`test/features`、`test/cluster`、`test/cowboy`、`test/ecosystem`、`test/umbrella` 共约 90 个文件被跟踪但没有任何工作流运行。CI 步骤名却叫 "All sub-app Elixir tests including Hologram"。

**方案**:加一个可手动触发或每晚运行的作业;或者在 `UPSTREAM.md` 里写明这些套件不设门禁。**优先级:中。工作量:M。**

### T4. 声明了但 CI 从不运行的检查 — 未复核

`apps/duskmoon_bundler/mix.exs:70` 的 `lint` 别名包含 credo、dialyzer、ex_dna 和 JS 检查,但 `ci.yml` 只跑 `mix format --check-formatted` 和 `mix compile --warnings-as-errors`。也没有 `cargo clippy`、`cargo audit`、`mix hex.audit`、actionlint(尽管有 `.github/actionlint.yaml`)。

**方案**:加一个 `lint` 作业,先上便宜的(`mix hex.audit`、`cargo audit`、actionlint),再加 credo 和 clippy,最后带 PLT 缓存上 dialyzer。**优先级:中。工作量:M,另需处理首批告警。**

### T5. CI 矩阵与并发

- 所有 `mix.exs` 声明 `elixir: ">= 1.18.0"`,CI 只测一组 Elixir/OTP。**方案**:给 `build` 作业加一个只编译的小矩阵。未复核。
- `async: false` 的测试文件占比高:`duskmoon_bundler` 27/53,`duskmoon_npm` 13/18。多半是耦合了全局状态(应用配置、命名 ETS 表)。**方案**:逐步改成参数注入和 `@tag :tmp_dir`。未复核。
- `.formatter.exs` 的 `inputs` 不含 `.github/scripts/*.exs`(已核对),约 2900 行发布脚本不在格式检查内。

**优先级:低到中。工作量:S–M。**

---

## 6. 文档缺口

| # | 问题 | 状态 | 方案 | 优先级 | 工作量 |
|---|---|---|---|---|---|
| D1 | 随 Hex 包发布的各 app `CHANGELOG.md` 过期:bundler 停在 10.0.8,npm 停在 10.1.5,runtime 和 quickbeam 是 `Unreleased`,hex_solver 停在上游 v0.3.0 | 已核对 | 打包时把根 CHANGELOG 复制进各包,或在发布测试里断言顶部版本号 | 中 | S |
| D2 | `skills/duskmoon_bundler/SKILL.md:20` 写着版本 `10.0.0` | 已核对 | 删掉这句,或纳入版本一致性断言 | 低 | XS |
| D3 | `duskmoon_oxide` 和 `duskmoon_vize` 的 README 说 "需要 Rust 工具链,自动编译",实际用的是预编译产物 | 已核对 | 改成与 `duskmoon_oxc` README 一致的说明 | 低 | XS |
| D4 | `docs/releasing.md` 写的 runner 标签(`xcode-27`、`macos-26-intel`)与工作流实际使用的 `macos-26` 不符;还保留着 9.16.17 时期的验证记录 | 未复核 | 更正标签,归档旧段落 | 中 | XS |
| D5 | 已完成的迁移文档仍从 README 链接:`docs/extraction-*.md`、`verification-report.md`、`migration-inventory.json`(约 9 万行) | 未复核 | 移到 `docs/archive/` 并加一行 "历史文档";`THIRD_PARTY_NOTICES.md` 引用了 inventory,移动前先确认 | 低 | XS |
| D6 | `OXC.Bundle` 的大多数公共函数没有 `@doc`,不少没有 `@spec`;`OXC.Native`、`Vize.Native` 缺 `@moduledoc false` | 未复核 | 补文档 | 低 | S |
| D7 | 文档与行为不符:`Oxide.scan/1` 称只返回变更文件的候选;`Vize.vapor_split` 文档写字符串键,实际返回原子键;`NPM.Verify` 的 moduledoc 声称做了完整性检查 | 未复核 | 逐条对照修正 | 低 | S |
| D8 | `config.ex:13` 的示例 `external: ~w(phoenix phoenix_html phoenix_live_view)` 推导出的全局名很可能不是实际的全局变量名 | 未复核 | 修 Q3 时一并核对并更正示例 | 低 | XS |
| D9 | 没有 `CONTRIBUTING.md`、`CODEOWNERS`;`biome.json` 存在但没有任何地方安装或运行 biome | 未复核 | 补文件;biome 要么接入要么删除 | 低 | XS |

---

## 审查中确认做得好的地方

这些是阅读后认为扎实的部分,改动时注意保持:

- **CI 与发布**:所有 action 按 40 位 SHA 固定;顶层权限是 `contents: read`;`HEX_API_KEY` 只暴露给单个发布步骤,且在 `release` 环境之后;校验和文件由最终收集的产物生成,并在发布前逐字节复验;发布、恢复、验证共用按版本的并发锁。
- **npm**:生命周期脚本从不执行;tarball 解压拒绝 `..` 和绝对路径,并在 `Path.expand` 后复查包含性;lockfile 与缓存路径都校验包名和严格 semver;integrity 取最强算法做精确比较;token 不会发往项目 `.npmrc` 指定的 registry。
- **dev server**:`serve/3` 与 `PublicDir.lookup/2` 都在展开路径后检查根目录包含性,并有测试;错误覆盖层用 `textContent`;`Preload.tags` 对 `href` 做了转义。
- **构建**:JS 改写全部基于 AST 和字节 span,不是正则;输出顺序是确定的;vendor 缓存写入是原子的(临时文件加 rename)。
- **NIF**:所有 NIF 都是 `DirtyCpu`;递归工作在 64 MiB 的独立线程上运行并捕获 panic;第一方 Rust 里没有 `unsafe`;没有发现从用户输入创建原子。
