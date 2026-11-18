# MarkX macOS 客户端开发规范

文档用途：作为 MarkX macOS 客户端的长期开发、交互、测试、打包和发布规范。本文档记录已经确定的默认行为；产品功能细节以当前 `PRD-MarkX-macOS.md` 为准。

## 1. 产品边界

- MarkX 是 Apple Silicon 原生 macOS 应用，使用 Swift、SwiftUI，必要位置使用 AppKit。
- 只归档 X Article，不下载普通 Post、Note Post、转帖、回复或自回复线程。
- 正常发现、同步、重新拉取和预览链路保持 0 次 X API 请求；使用受支持本机浏览器的 X 登录态完成后台采集。
- X 页面、登录页和浏览器工具栏在采集时保持隐藏；用户只看到原生进度、状态和结果。
- 用户文章、Cookie、归档目录和图床密钥默认只在本机处理。用户主动选择外部存储时，媒体必须先完成本地缓存和校验。
- 任何正文结构、媒体数量/顺序、存储 URL 或 Markdown 校验失败，都不得把文章标记为完成；失败任务必须可恢复。

## 2. 数据与交互原则

- 资料库、博主分组支持折叠和展开；分组标题需要明显高于条目，但不得放大条目内容。
- 收藏夹保存在当前资料库的 SQLite 数据库中。同一篇文章可以加入多个收藏夹，收藏夹内沿用资料库搜索。移出收藏只删除对应关系，删除收藏夹需确认并保留原归档。
- 博主行只展示博主名称、ID 和“已下载 / 线上总数”分数；查看主页、重新拉取、刷新线上总数和删除放入右键菜单。
- 文章列表按当前筛选结果连续编号；“今日推文”按 X 原始发布时间动态更新；“商单内容”只包含带有 X 官方 Paid partnership 标记的文章，列表和详情页需显示同一商单内容标签。
- 文章详情显示发布时间，精确到分钟；文章标题、作者、类型和时间保持清晰的层级关系。
- 任务结果使用可视化统计项展示博主数、检查数、保存数、跳过、订阅、失败、图片、视频和待处理数量，不使用难以扫描的一整段结果文字。
- 所有会改变数据的操作都要说明影响范围，并在删除、迁移或覆盖前要求确认；已完成归档和远程媒体不得被误删。

## 3. 主页面视觉层级

### 3.1 字号

- `MarkXTypography` 将界面与正文分开：外层界面在 0.3.44 基础上增加 1pt，正文增加 2pt 后再应用用户缩放。语义字体保留系统字重和设计，原生输入框与产品名跟随界面字号。
- 侧边栏遵循 macOS 原生样式（HIG Sidebars）：分组使用 `Section(isExpanded:)` 的原生小号灰色标题，折叠控件悬停时出现；资料库分类与收藏夹使用 `Label` + `.badge()`，数量为 0 时不显示徽标。“博主”标题后附人数。博主名称 13pt，用户名与分数 11pt，普通博主图标 14pt、置顶图钉 12pt。
- 资料库分类与博主条目共用 18pt 图标列和 8pt 图文间距，文字起点保持一致；缩小视觉内容时保留原有整行点击区域。
- 博主 ID、文章数量、分数和状态辅助信息：使用 `caption`；数量使用 `monospacedDigit()`，保持紧凑稳定。
- 文章列表标题：`headline`；作者、类型、发布时间和状态说明：`caption`。序号列至少预留 44pt，保持等宽数字、单行和右对齐，完整展示至 99999，更多位数允许继续扩宽。列表分隔线按整行的左右边界对齐，两端留白保持一致，不按序号文字的实际起点缩进。
- 文章详情标题：26pt 粗体（`MarkXTypography.system(size: 25, weight: .bold)`），行距 4pt，最多 3 行；作者、类型、发布时间：`subheadline` 和 secondary。
- 任务进度、状态卡和按钮辅助说明：`caption` / `caption2`，避免抢过主内容。
- 正文 100% 时基础字号为 15pt，独立的文字缩放控制作用于新基础字号，不改写用户已有比例。

### 3.2 颜色

- 视觉语言参考 Fog：低饱和中性灰阶、细描边、浅色悬停底，不用大面积重色。色值统一在 `MarkXInterface`：`canvas` #F9F9FB / #18191B（列表与面板底色），`surface` #FFFFFF / #212225（卡片），`reading` #FCFCFD / #111113（阅读区平铺底色），`hairline`（1pt 细描边）、`wash`（悬停与次要按钮底色）。
- 字重克制：标题用 semibold/medium，不用 bold；文章列表标题 14pt medium、元信息 caption 次级色、序号 tertiary；阅读区标题 26pt semibold，上边距 56pt，左右 52pt；列表不显示分隔线。
- 状态标签为 Fog 式小标签：22pt 高、6pt 圆角、细描边、卡片底色、左侧 7pt 彩色圆角方点，文字用 primary。
- 按钮：欢迎页与弹窗底栏使用 `MarkXPillButtonStyle` 胶囊按钮（主操作为强调色实心，次要操作为 wash 底色加细描边）。窗口工具栏背景隐藏，内容直通顶部。欢迎页使用冷暖渐变底色与毛玻璃卡片（22pt 圆角）。

- 主内容使用 `.primary`，辅助信息使用 `.secondary`，不要用高饱和颜色承载普通文本。
- 强调色跟随用户在系统设置中选择的强调色（HIG：尊重用户的强调色偏好），不在窗口根部覆盖 `.tint`；品牌橙色只用于置顶图钉。
- 绿色表示完成或已连接，橙色表示等待、部分完成或需要注意，红色表示失败，紫色表示订阅权限，蓝色表示媒体或普通强调。
- 状态色只用于图标、状态标签和低面积背景；数量徽标使用低对比度中性色背景。
- 保持浅色和深色模式下的可读性，不引入只适用于单一主题的大面积颜色或渐变。

## 4. 代码与测试

- 优先沿用现有 SwiftUI 组件、状态模型和错误处理边界；不为局部样式引入重复抽象。
- 所有新增状态和统计字段都要有数据库往返、迁移或策略测试；涉及采集完整性的改动必须补充失败路径测试。
- 应用改动完成后运行：

```bash
swift test
bash -n scripts/build-app.sh scripts/verify-app.sh scripts/verify-packages.sh
```

- 官网改动完成后运行：

```bash
npm run check
npm run build
npm run test:worker
```

- 外部 X、Chrome、uPic 或真实视频联调默认不作为本地测试的必要条件；显式跳过项必须在结果中说明。
- 如果命令行会话拒绝 WebKit 访问 macOS Launch Services，在 Xcode 中打开 `Package.swift`，选择 `MarkX-Package` 和 `My Mac`，按 ⌘U 运行完整测试，并在测试报告中核对两组 WebKit 用例的结果。
- 构建和测试失败时保留产物与日志，修复失败原因后再继续发布，不得把部分成功报告为完整交付。

## 5. 版本与安装包

- 应用版本同时维护 `Config/Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
- README、官网 `website/src/App.tsx` 的版本号、Build 号、下载地址和更新说明必须与应用包一致。
- 默认只生成 arm64 DMG，不生成或上传 ZIP。DMG 必须包含可拖入 `/Applications` 的快捷入口，并且只保留 App 和 Applications 两项可见内容。应用包的 `Contents/Resources/LICENSE` 必须附带完整 MIT 版权与许可声明，并与仓库根目录的 `LICENSE` 一致。
- 使用以下脚本构建和验证：

```bash
./scripts/build-app.sh
./scripts/verify-app.sh
./scripts/verify-packages.sh
```

- 发布前必须核对包内架构、签名、图标、Bundle 版本、DMG 布局和 SHA-256。当前没有 Developer ID 身份时，明确标记为本机测试用 ad-hoc 签名。

## 6. 默认发布闭环

除非用户明确要求“仅本地修改”，修复缺陷或交付功能默认完成以下闭环：

1. 运行相关测试并修复失败项。
2. 更新应用版本、Build 号、README 和必要的产品文档。
3. 构建并验证新的 DMG；生成 `SHA256SUMS.txt`。
4. 将应用版本提交推送到 `main`，在 Mac 上运行 `bash scripts/publish-release.sh [DMG 路径]`。脚本校验 DMG 后创建对应 GitHub 预发行版，触发 [Publish MarkX website](https://github.com/wangdefou-dev/MarkX/actions/workflows/publish-website.yml)。
5. CI 上传 DMG 和校验文件到 R2 的不可变版本目录，并通过生产下载地址逐字节核对两个文件。

```text
downloads/markx/<version>/MarkX-<version>.dmg
downloads/markx/<version>/SHA256SUMS.txt
```

6. CI 从 `Config/Info.plist` 和 `CHANGELOG.md` 取版本、Build 和更新说明，构建并推送独立官网仓库，等待 Vercel 发布，并核对生产站点 `release.json` 中的版本和校验值。
7. 发布失败时，保留版本产物，从 GitHub Actions 重跑该发布任务。同一版本只允许重用完全相同的 R2 文件。

首次启用在应用仓库的 **Settings → Secrets and variables → Actions** 配置以下凭据：

| 名称 | 类型 | 值 |
| --- | --- | --- |
| `R2_ENDPOINT` | Variable | Cloudflare R2 显示的 S3 API 端点 |
| `R2_ACCESS_KEY_ID` | Secret | `defou-ai` 桶的 Object Read & Write Access Key ID |
| `R2_SECRET_ACCESS_KEY` | Secret | 同一 R2 凭据的 Secret Access Key |
| `MARKX_WEBSITE_DEPLOY_KEY` | Secret | `markx-product-website` 仓库写入 Deploy Key 的 SSH 私钥 |

在 Actions 手动运行此工作流时，填写当前线上 DMG 的 SHA-256 可检查现有下载和官网构建。勾选 `publish` 时会同时执行上传和生产部署，可用于首次接入或恢复官网发布。

### 6.1 应用内自动更新（0.3.66）

- 更新源为生产站点 `https://markx.defou.ai/release.json`，由 `scripts/update-release-website.py` 生成，字段：`version`、`build`、`sha256`、`url`（`download.markx.defou.ai` 下的不可变 DMG 地址）、`notes`（取自 `CHANGELOG.md` 对应版本）。缺少 `url` 时按固定路径推导；只接受 `download.markx.defou.ai` 与 `1want.link` 的 HTTPS 地址。
- `AppUpdater` 在启动 5 秒后及之后每小时检查一次（距上次检查不足 6 小时则跳过），可在设置“通用 → 软件更新”关闭；“跳过此版本”只抑制自动提醒，菜单“检查更新…”始终显示结果。
- 安装流程（`AppUpdateInstaller`）：下载 DMG → 核对 SHA-256 → 只读挂载并复制 App → 核对 Bundle ID、版本与 `codesign --verify --deep --strict` → 旧版移入废纸篓、新版放回原路径 → 进程退出后由 `/bin/sh` 辅助进程重新打开。任一步失败都不改动已安装的应用；有下载任务时禁止重启安装。
- 调试：设置环境变量 `MARKX_UPDATE_MANIFEST_URL` 可指向本地更新源（此时允许任意下载地址，Debug 构建也会自动检查）。端到端验证用独立 Bundle ID 的旧版本 + 本地 HTTP 服务；macOS 27 上 `hdiutil create -srcfolder` 可能生成损坏镜像，测试包用 `diskutil image create from` 制作。

## 7. 本机强制覆盖

每次有新的应用安装包时，都必须覆盖用户当前使用的 `/Applications/MarkX.app`：

1. 先验证最终 DMG，再退出当前 MarkX；若进程未退出，使用精确进程路径强制终止。
2. 读取旧版 `CFBundleShortVersionString` 和 `CFBundleVersion`，将旧 App 移入 `/Users/Wangdefou/.Trash/`，保留可恢复副本，不直接删除。
3. 从已验证的 DMG 挂载路径复制新版到 `/Applications/MarkX.app`，不得使用未验证的临时构建目录。
4. 启动新版应用，并核对 Bundle 版本、实际运行路径和进程：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/MarkX.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/MarkX.app/Contents/Info.plist
ps ax -o pid=,command= | rg '/Applications/MarkX\\.app/Contents/MacOS/XArticleArchiverApp'
```

5. 只有新版本已启动并完成上述核对，才能报告本机更新完成。

## 8. 交付检查清单

- [ ] 应用测试通过，外部跳过项已说明。
- [ ] Shell 脚本语法通过；官网检查、构建和 Worker 测试通过（官网有改动时）。
- [ ] 应用版本、Build、README、官网文案和下载地址一致。
- [ ] 仅生成 DMG，DMG 挂载和签名校验通过。
- [ ] R2 版本目录中的 DMG 与 `SHA256SUMS.txt` 可访问且校验一致。
- [ ] 应用仓库和官网仓库已分别推送，生产官网已部署。
- [ ] `/Applications/MarkX.app` 已由最终 DMG 覆盖并启动，版本和运行路径已核对。
- [ ] 已关闭本次验收打开的测试页面和窗口，并退出为验收启动的临时程序。用户原先使用的页面和程序及正式版 MarkX 保持可用。
- [ ] 旧版 App 已移入废纸篓，失败环节和残留产物已如实记录。


## 9. 界面布局与视觉验收（0.3.46）

- 侧边栏只负责导航（HIG Sidebars）：不放下载等操作按钮，底部不放目录选择入口，运行时仅展示任务摘要。
- 搜索使用原生 `.searchable(placement: .toolbar)`。“X 登录”与“通用”“存储”“隐私与关于”为同级设置分类。
- 窗口与工具栏使用系统标准（HIG Toolbars）：侧栏开关为系统自带按钮，不自绘标题栏。窗口标题固定为 “MarkX”（三栏都设置，`MarkXWindowPolicy` 依赖它识别主窗口），标题本身隐藏，列表栏左侧显示“分类名 + 篇数”。工具栏按栏分组：列表栏放“下载文章”“同步博主”，任务运行时追加“下载进度”“停止”；阅读栏放“收藏”菜单、“打开原文”、“更多”菜单（打开 Markdown、在 Finder 中显示、订阅、重新处理/停止处理、删除）；搜索位于最右侧，仅资料库三栏布局提供。欢迎页只在右侧显示“下载文章”“同步博主”。设置不放工具栏，通过应用菜单“设置…”（⌘,）打开。
- 菜单栏覆盖所有常用操作：文件菜单“下载文章…”⌘N、“同步所有博主…”⌘R、“显示下载进度”、“停止当前任务”⌘.；显示菜单含系统侧栏/工具栏命令及正文缩放 ⌘+ ⌘− ⌘0；“文章”菜单含“在浏览器中打开原文”⌘L、“打开 Markdown”⌘O、“在 Finder 中显示”⇧⌘R、“重新处理”、“删除文章…”⌘⌫。整理重复媒体缓存只在设置“存储”中提供。
- 文章头部只放内容：标题、作者与时间、状态标签；不再放字号、收藏、更多和“查看文章原文”按钮。
- 详情标题、作者、标签和正文共用居中的最大 860pt 阅读栏，左右至少留 40pt；头部纵向间距 14pt，上下边距为 36pt / 22pt。图片数为 0 时不显示图片标签。扩大阅读区时整栏一起居中，左边缘必须一致。删除顶部排版校验提示与重复统计，保留底层校验和限制说明；窄窗口允许换行，不得裁切或堆叠。
- 浏览器检测在后台运行，仅检查 X 登录元数据；设置中展示实际浏览器与配置，区分未登录和读取/解密受限。显式选择来源后不得跨浏览器回退账号，Firefox 容器不可混用。钥匙串只在主动验证或下载导入时读取，Cookie 和密钥仅存在内存中。
- macOS 会阻止读取其他应用的数据目录（`Operation not permitted`）。探测结果用 `BrowserSessionIssue.isPermissionDenied` 标记，`browserNeedingAccess` 非空时，欢迎页的浏览器登录行与设置“X 登录”页直接显示“授权读取 <浏览器>…”主按钮，打开预置到该浏览器数据目录的选择面板；授权以安全范围书签保存。ad-hoc 签名的新构建可能需要重新授权一次。
- 配置与结果弹窗统一使用 `MarkXPaneHeader`、`MarkXSection`、`MarkXFooter`；内容区可滚动，底栏固定，不在标题区放置完成按钮。
- 输入使用可见标签，说明只保留与决策相关的内容；危险操作使用系统确认，不自制替代系统警告的对话框。
- 设置内容区固定为 640 × 520pt，由 `SettingsView` 统一管理尺寸。设置使用原生工具栏分类标签和 `Form` + `.formStyle(.grouped)`；分类名即标题，面板内不再重复大标题与图标；分组说明放在 Section footer 并左对齐。
- 进度阶段切换只改变可见性，必须保持隐藏 WebKit 及任务挂载；Escape 与关闭窗口一样只隐藏，停止要点击明确的停止按钮。
- 栏宽统一由 `SplitColumnLayout` 定义：侧栏 220–300pt（理想 248pt），文章列表 360–520pt（理想 420pt），阅读区至少 440pt。macOS 27 首次启动时 `navigationSplitViewColumnWidth` 不生效，`SplitColumnGuard` 在布局稳定后把可见的前两栏拉回范围内；侧栏隐藏时文章列表不得超过 520pt。默认窗口 1360 × 860pt。
- 首次启动或资料库为空（未选择收藏夹或博主）时使用两栏布局：侧栏 + 全宽 `WelcomeView`。欢迎页内容居中、最大 640pt，依次为应用图标、标题与说明、三项配置状态卡、主操作（系统强调色胶囊按钮）和三项特性说明；配置完成后主操作变为“开始下载文章”。有文章后自动切回三栏，侧栏显隐状态保持。
- 发布前用独立 Debug 预览包检查布局，并在最终安装版确认侧边栏、实际弹窗、设置分类、长路径及字体缩放。

参考：[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Settings](https://developer.apple.com/design/human-interface-guidelines/settings)、[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)。
