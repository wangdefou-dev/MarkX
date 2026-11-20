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
- 收藏夹保存在当前资料库的 SQLite 数据库中。同一篇文章可以加入多个收藏夹，收藏夹内的文章按收藏夹筛选显示。移出收藏只删除对应关系，删除收藏夹需确认并保留原归档。
- 侧栏最上方是“博主列表”分组（与资料库、收藏夹同样的小号灰色分组标题）：第一行“全部博主”（`SidebarSelection.creators`，徽标为博主人数），下面只列出置顶博主（最多 5 位，橙色 `pin.fill` 图标，徽标为已下载篇数，右键菜单与中间栏博主行相同），未置顶的博主不在侧栏逐个列出。点击“全部博主”后中间栏显示博主列表（置顶博主在前、可拖动排序），默认高亮第一位博主（从某位博主返回时高亮刚才那位），方向键移动高亮、回车打开；阅读区显示高亮博主的名字、@ID、已下载篇数和“查看文章”“打开 X 主页”按钮。点击某位博主后，博主列表向左平移收起、该博主的文章列表从右侧滑入（`.snappy` 0.3s，切换推迟到列表处理完点击之后，保证动画生效），阅读区显示文章，侧栏“全部博主”保持高亮（打开的是置顶博主时高亮侧栏里他那一行）；中间栏最上方（与侧栏工具栏按钮同一行）出现小号“‹ 返回”按钮（`markxCompact`，⌘[），在中间栏双指向右轻扫（触控板或妙控鼠标，`HorizontalSwipeMonitor` 只观察不拦截滚动事件）或点侧栏“全部博主”，都会反向平移回到博主列表；在博主列表状态下点侧栏里的置顶博主，同样向左平移打开。博主行与文章行同样的字号和内边距，只展示博主名称和“已下载 / 线上总数”分数，不显示 @ID（悬停提示里保留）；置顶、查看主页、重新拉取、刷新线上总数和删除放入右键菜单。删除当前博主后回到博主列表。
- 文章列表按当前筛选结果连续编号；“今日推文”按 X 原始发布时间动态更新；“商单内容”只包含带有 X 官方 Paid partnership 标记的文章，列表和详情页需显示同一商单内容标签。
- 文章详情显示发布时间，精确到分钟；文章标题、作者、类型和时间保持清晰的层级关系。
- 任务结果使用可视化统计项展示博主数、检查数、保存数、跳过、订阅、失败、图片、视频和待处理数量，不使用难以扫描的一整段结果文字。
- 所有会改变数据的操作都要说明影响范围，并在删除、迁移或覆盖前要求确认；已完成归档和远程媒体不得被误删。

## 3. 主页面视觉层级

### 3.1 字号

- `MarkXTypography` 将界面与正文分开：外层界面在 0.3.44 基础上增加 1pt，正文增加 2pt 后再应用用户缩放。语义字体保留系统字重和设计，原生输入框与产品名跟随界面字号。
- 侧边栏遵循 macOS 原生样式（HIG Sidebars）：自上而下为“博主列表”（全部博主 + 置顶博主）、资料库、收藏夹，分组标题统一用 `SidebarSectionHeader`（11pt medium、`text3`，避免系统把第一个分组标题画得更亮更粗）；三组不再用 `Section` 包裹（Section 会额外加组间距、并给标题加系统折叠箭头），改由 `SidebarSectionHeader` 整行作为按钮折叠 / 展开（它是分组里的第一行普通行，`.selectionDisabled()`，不用 Section 的 header——系统会在悬停时给侧栏分组标题再加一个折叠箭头，造成两个箭头）（右侧 9pt 箭头的右边缘与下方数字徽标最后一位数字的右边缘对齐：右侧留 8pt，折叠时朝右的箭头较窄，再右移 2pt，展开时旋转 90°，`.snappy` 0.22s，悬停时标题与箭头变深），折叠状态用 `@AppStorage` 记住；分组标题上方留白随上一组状态变化：上一组展开时 24pt，折叠或为第一组时 12pt，全部折叠后三个标题紧凑排列，列表左右再留 8pt（`sidebarInset`，底栏“设置”同步右移对齐）；条目使用图标 + 文字 + `.badge()`，数量为 0 时不显示徽标。博主列表中分数 11pt；普通博主用线性图标，置顶博主（右键“置顶博主 / 取消置顶”）在侧栏和中间栏都用橙色实心图钉 `pin.fill`。
- 资料库分类与博主条目共用 18pt 图标列和 8pt 图文间距，文字起点保持一致；缩小视觉内容时保留原有整行点击区域。
- 博主 ID、文章数量、分数和状态辅助信息：使用 `caption`；数量使用 `monospacedDigit()`，保持紧凑稳定。
- 文章列表每行只显示序号和文章标题（最多两行，短标题按一行高度排，不预留第二行），不显示作者、日期、商单与状态。序号列至少预留 44pt，保持等宽数字、单行和右对齐，完整展示至 99999，更多位数允许继续扩宽。列表分隔线按整行的左右边界对齐，两端留白保持一致，不按序号文字的实际起点缩进。
- 文章详情标题：26pt 粗体（`MarkXTypography.system(size: 25, weight: .bold)`），行距 4pt，最多 3 行；作者、类型、发布时间：`subheadline` 和 secondary。
- 任务进度、状态卡和按钮辅助说明：`caption` / `caption2`，避免抢过主内容。
- 正文 100% 时基础字号为 15pt，独立的文字缩放控制作用于新基础字号，不改写用户已有比例。

### 3.2 颜色

- 视觉语言参考 Fog（`/Applications/Fog.app/Contents/Resources/Web/thread/*.css`）：低饱和中性灰阶、1pt 细描边、wash 浅色底，不用大面积重色。所有界面数值都来自 `MarkXInterface.swift` 中的设计令牌，**界面代码不得再写裸字号、裸间距和裸圆角**。
- 颜色：`canvas` #F9F9FB / #18191B（列表与面板底色），`surface` #FFFFFF / #212225（卡片），`reading` #FCFCFD / #111113（阅读区），`hairline`（细描边），`wash` / `washStrong`（按钮、输入框底色），`hover`（列表行与导航项悬停）、`selection`（选中行），`text2` #646464 / #B4B4B4（次要文字），`text3` #8D8D8D / #6E6E6E（第三级文字、序号、时间）。
- 字号 `MarkXFont`（Fog 字号 +1pt，延续 0.3.4x 界面放大）：`display` 25 medium（欢迎页大标题）、`title` 19 medium（弹窗与面板标题）、`columnTitle` 15 medium（栏标题）、`headline` 14 medium（区块标题、行标题、名字）、`body` 14、`lead` 15（大标题下的导语）、`detail` 13 / `detailStrong` 13 medium（说明、按钮、标签）、`meta` 12 / `metaStrong`（元信息、脚注）、`badge` 11 medium（计数）、`metric` 23 medium 等宽数字。全局只用 regular 与 medium，不用 bold/semibold。
- 间距 `MarkXSpace`：2 / 4 / 6 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48，阅读页边距 `pageSide` 52、`pageTop` 56。圆角 `MarkXRadius`：`control` 6（按钮、标签、输入框、图标块）、`card` 8（卡片、分组、图片、列表容器）、`panel` 12、`hero` 20（欢迎页浮层）。
- 按钮三级：`.markxPillProminent` / `.markxPill`（32pt 胶囊，仅用于弹窗底栏和页面主操作）；`.markxCompact` / `.markxCompactProminent`（26pt、6pt 圆角 wash 底，用于内容区内的操作，可带灰色图标）；`.markxText`（灰色文字按钮，用于次要或危险的低频操作）。内容区内不使用系统 bordered 按钮。
- 输入框为 Fog 填充式：`.markxField()`，wash 底色、6pt 圆角、无描边、30–32pt 高。
- 图标：界面内只用单色线性 SF Symbols（不用 `.fill` 与彩色渲染；置顶博主的橙色 `pin.fill` 是唯一例外），默认 `text2`，次要 `text3`；侧栏统一用 `SidebarIcon`，设置行用 `MarkXIconTile`（28pt wash 方块）。弹窗标题不放装饰图标，只有结果类弹窗保留表示成败的小状态图标。状态一律用 `StatusDot`（7pt、2pt 圆角彩色方点）加文字表示，不用实心彩色圆形图标或彩色胶囊。
- 选中与悬停：侧栏和文章列表都关闭系统高亮，统一用 `markxSelectableRow` 绘制 8pt 圆角矩形：选中为 `selection`，鼠标悬停为更浅的 `hover`，文字保持原色，不使用强调色蓝底。悬停由 `ListRowTracker` 在整行（`NSTableRowView`）上挂追踪区域判断，覆盖行的内边距、行与行之间无空隙、无动画，紧跟鼠标；仅在应用处于前台时显示。列表外的导航项和行用 `.markxHover()`。
- 侧栏行距约 38pt：sidebar 列表样式会忽略最小行高，所以由行内上下各 7pt（`SidebarMetricBadge.rowPadding`）撑开；资料库、收藏夹、博主、“新建收藏夹…”统一使用 `SidebarIcon` + 8pt 间距，文字左缘对齐。分组标题上方多留 8pt。
- 列表行：序号 `meta` + `text3` 右对齐 24pt 列，标题 `body`（常规字重、不加粗）最多两行（短标题只占一行高度），上下 8pt；不显示分隔线。
- 文章列表顶部不显示分组标题、篇数和任何按钮。“同步博主”和“下载文章”（两个系统工具栏图标按钮，不带文字，避免侧栏变窄时被挤进溢出菜单；下载图标用系统强调色，同步保持灰色）放在侧栏顶栏最右侧（侧栏列的 `.primaryAction` 工具栏项，前面用 `ToolbarSpacer(.flexible)` 推到右缘）；任务进行中的“下载进度”“停止”放在侧栏底栏“设置”右侧（`.markxIcon`），菜单快捷键 ⌘N / ⌘R / ⌘. 不变；查看博主主页在博主右键菜单。
- “开始下载文章”弹窗打开时不预选下载来源（单个博主 / 批量博主 / 文章链接）和下载范围（最近文章 / 全部文章）：选了来源才显示输入区和范围，选了范围才能开始下载；重新拉取某位博主或带文章链接打开时自动选好对应来源。
- 设置与表单：使用 `MarkXGroup`（灰色小标题 + 白底卡片 + 灰色脚注）装 `MarkXRow`（左侧图标块、标题与灰色说明，右侧控件），行与行之间不画分隔线（弹窗底栏 `MarkXFooter` 上方、同步弹窗内也都不画横线）；区域一律靠底色区分而不是线：卡片 `markxSurface` 只有 `surface` 底色、无描边，弹窗与设置内容区底色 `canvas` 为 #F1F2F5 / #18191B，未选中的选项卡片无描边（选中保留强调色描边），状态标签用 `wash` 底色，正文图片与视频无外框，只有正文表格保留格线；开关用小号 switch。设置窗口分为通用（软件更新）、X 登录、存储（本地资料库、媒体存储、缓存）、隐私与关于；左侧导航（196pt，`sidebarGradient` 底色，比内容区深一档，两栏之间不画竖线，选中/悬停圆角矩形）+ 右侧分组卡片（右侧不再重复显示分类名称和说明，窗口标题已是分类名），窗口 780 × 580pt。弹窗里的互斥选项（下载来源、下载范围）用 `MarkXChoiceCard` 选项卡片，选中为强调色描边与浅底。
- 阅读排版（`ArticleTypography`，全部按 em 随缩放）：正文 15pt、行距 0.5em；段落间距 1.15em；文章标题 24pt medium；h1 / h2 / h3 为正文的 1.4 / 1.22 / 1.1 倍，medium，上方 1.6em、下方 0.8em；列表项间距 0.5em、缩进 1.25em、圆点 `text3`、编号常规字重；引用为 2pt 灰线 + `text2` 正文、不用斜体；代码与表格 0.857em、wash 底、6pt 圆角；分隔线 1pt `washStrong`。
- 窗口工具栏背景隐藏，内容直通顶部。欢迎页使用冷暖渐变底色与毛玻璃卡片。

- 主内容使用 `.primary`，辅助信息使用 `.secondary`，不要用高饱和颜色承载普通文本。
- 强调色跟随用户在系统设置中选择的强调色（HIG：尊重用户的强调色偏好），不在窗口根部覆盖 `.tint`；品牌橙色只用于置顶博主的图钉。
- 绿色表示完成或已连接，橙色表示等待、部分完成或需要注意，红色表示失败，紫色表示订阅权限，蓝色表示媒体或普通强调。
- 状态色只用于状态点和低面积背景；数量徽标使用低对比度中性色背景。
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


## 8.1 日志、诊断报告与数据库容错（0.3.90）

- 日志统一用 `MarkXLog`（`XArticleArchiverCore/MarkXLog.swift`）：同时写入系统日志（subsystem `ai.defou.markx`，可在“控制台”按此过滤）和 `~/Library/Logs/MarkX/MarkX.log`，单文件 2MB 轮转、保留 4 份旧文件。启动时记录版本、系统、机型；`errorMessage`、`statusMessage` 和进度阶段变化自动记录；数据库打开、日志模式与磁盘错误恢复都有记录。禁止记录 Cookie、Token、图床密钥和文章正文。
- 诊断报告（`DiagnosticReport`）入口：帮助菜单“反馈问题… / 导出诊断报告… / 在 Finder 中显示日志”、设置“通用 → 诊断与反馈”、错误弹窗“导出诊断报告…”。zip 内含 `概要.txt`（版本、系统、归档目录及其磁盘类型、数据库文件大小与日志模式、文章状态统计、连接状态）、`未完成文章.txt`（最近 50 篇未完成或出错文章的状态、错误和处理记录）、`logs/` 和最近 30 天的 `crashes/`。报告只保存到用户选择的位置，不自动上传；“反馈问题…”导出后打开 GitHub 新建 Issue 页面并预填版本和系统。
- 用户反馈 bug 时，先要诊断报告：看 `概要.txt` 的“目录所在磁盘”和“日志模式”，再按时间在 `logs/MarkX.log` 中找 `[ERROR]` 行。
- `ArchiveDatabase` 打开时用 `StorageLocationInfo` 检查归档目录：iCloud（含开启同步的“文稿/桌面”）、`~/Library/CloudStorage` 下的网盘、非本地卷和非 APFS/HFS+ 文件系统（exFAT、FAT、SMB 等）使用 `journal_mode=DELETE`，其余保持 WAL；WAL 打开失败时也回退到 DELETE。所有公开数据库操作经 `recovering` 包装：遇到 `SQLITE_IOERR*`、`SQLITE_CANTOPEN` 或 `SQLITE_READONLY_DBMOVED` 时关闭连接、以 DELETE 模式重新打开并重试一次（事务内的嵌套调用不单独重试），仍失败时抛出 `ArchiveDatabaseError.io`，错误文案带扩展错误码并建议把归档目录换到本机磁盘。

- 设置“X 登录 → 登录 X → 打开 X”（`openBrowserXLogin`）固定用 `NSWorkspace.urlForApplication(toOpen:)` 得到的系统默认浏览器打开 `https://x.com`，不使用 `preferredSessionBrowser` 推断；默认浏览器不在 `BrowserSessionDefinition.supported` 中（如 Safari），或与非“自动查找”的读取来源不一致时，用 `browserSessionCheckMessage` 提示。订阅页等需要复用会话的链接仍按 `openInSessionBrowser` 在会话对应的浏览器打开。

## 8.2 多浏览器 X 登录（0.3.91）

- 来源选择存于 `browserSession.preferredBrowser`，格式由 `BrowserSessionSelection` 解析：`automatic`、浏览器 ID（如 `edge`）或精确配置 `浏览器ID|配置目录`（如 `chrome|Profile 2`）。
- `BrowserSessionAccess.probe()` 始终探测全部受支持浏览器，并把选择写入 `BrowserSessionProbe.selection`；`loggedInProfiles` 按 Cookie 数据库最后修改时间从新到旧排序，`selectedProfiles` 是当前选择允许、按尝试顺序排列的登录。设置的“使用浏览器”菜单列出“自动查找（最近使用的登录）”、全部检测到的登录和按浏览器三组；精确配置失去登录时保留一项“（未检测到登录）”并在读取时报错，不改用其他账号。
- 读取 Cookie 数据库（Chromium 与 Firefox）一律先复制主文件及 `-wal`/`-journal` 到临时目录再打开副本，避免浏览器运行时的独占锁导致 “database is locked”；只有权限被拒时才直接报错。
- 导入会话到 WebView 用 `BrowserSessionAccess.install`：先删除已有的 x.com / twitter.com Cookie 再写入，防止切换账号时新旧 Cookie 混用。

## 9. 界面布局与视觉验收（0.3.46）

- 侧边栏只负责导航（HIG Sidebars）：不放下载等操作按钮，底部不放目录选择入口，运行时仅展示任务摘要。
- 主窗口不提供搜索框（0.3.71 起移除）。“X 登录”与“通用”“存储”“隐私与关于”为同级设置分类。
- 窗口与工具栏使用系统标准（HIG Toolbars）：侧栏开关为系统自带按钮，不自绘标题栏。窗口标题固定为 “MarkX”（三栏都设置，`MarkXWindowPolicy` 依赖它识别主窗口），标题本身隐藏，文章列表栏顶部不放标题（博主文章列表只有一个“‹ 返回”），不提供搜索框，列表用 `.plain` 样式贴近顶栏。主窗口使用 `.windowToolbarStyle(.unified)`，系统工具栏带约 52pt 且无法加高（更高的工具栏项不会撑高它，`.expanded` 样式会让按钮压到内容上），所以三栏在工具栏下统一再空出 `topBandExtra` 20pt：侧栏列表用 `.padding(.top)` 下移并在其上方裁切，内容从 72pt 开始、滚动时不进入这块区域；中间栏则顶到窗口顶部（`.ignoresSafeArea(.container, edges: .top)`），第一行与侧栏工具栏按钮同高，上方留 12pt（`middleColumnTop`）；侧边栏收起后红绿灯和侧栏工具栏按钮会移到中间栏上方，此时留白改为工具栏带加 `topBandExtra`（与阅读栏顶栏等高），避免第一行被压住，这段留白和博主文章列表的“‹ 返回”行用 `safeAreaInset(edge: .top)` 叠在列表之上——直接放在列表上方的视图会被列表的滚动视图盖住、点不到。阅读栏顶部是固定高度的顶栏（`DetailTopBar`，高度为工具栏带加 20pt，`reading` 底色，`zIndex(1)` 压在正文之上），正文滚动视图从顶栏下缘开始并被裁切，滚动时内容不会穿过或盖住顶栏；正文标题上方只留 12pt，紧挨顶栏。文章头部只保留标题和一行“作者昵称 ↗ · 发布时间”（不显示 @ID，悬停提示里保留），“收藏”“打开原文”“更多”放在这一行右侧（已收藏时“收藏”显示橙色实心 `star.fill`，颜色直接设在图标上，因为 `markxIcon` 样式会把整个标签染灰）；不显示“已完成”、图片数、视频数等状态标签，商单文章在“收藏”左侧显示橙色“商单”标签，原来的“按原文顺序重新采集”按钮移入“更多”菜单。头部（及处理面板）与正文之间不画分隔线，只留 24pt 间距。这一整块在页面内时顶栏留空；整块（含分隔线）完全滚出视野后，单行 16pt semibold 标题（左缘与正文对齐）和右侧的“收藏”“打开原文”“更多”以 `.smooth` 0.35s 从下方 22pt 处上移入位（标题同时从 1.35 倍缩小到原大），顶栏与正文之间不画横线，改由 `DetailScrollFade` 让正文在顶栏下缘 24pt 内渐隐；滚回时按原路退出。标题可见状态放在独立的 `DetailTitleState` 里，只在越过边界时变化，整窗不随滚动重绘。
- 拖动中间栏与阅读栏之间的分隔线时（按下点距分隔线 6pt 内），`SplitColumnGuard` 临时把侧栏 `NSSplitViewItem` 的最小、最大宽度都设为当前宽度，松开鼠标后恢复；否则中间栏到达 360 / 520 时 AppKit 会推动侧栏分隔线。
- 三栏之间不画竖线（参考 Fog 用色块区分）：`QuietSplitDivider` 把系统分隔线子视图设为透明（仍可拖动），三栏底色是一条从左到右由深到浅的横向渐变，每栏边界处有小幅台阶：侧栏 `sidebarGradient`（#E4E5E9→#EAEBEE / 深色 #0B0C0E→#0F1012）、文章列表 `listGradient`（#EEEFF2→#F4F4F6 / #131416→#17181A）、阅读区与其顶栏 `readingGradient`（#F8F8FA→#FFFFFF / #1A1B1D→#1E1F21），阅读区左缘加 6pt `columnShadow` 柔和阴影。侧栏底栏左侧为“设置”入口（`SettingsLink`，同 ⌘,），任务运行时右侧出现“下载进度”“停止”；“同步博主”“下载文章”在侧栏顶栏最右侧，欢迎页同样如此。
- 菜单栏覆盖所有常用操作：文件菜单“下载文章…”⌘N、“同步所有博主…”⌘R、“显示下载进度”、“停止当前任务”⌘.；显示菜单含系统侧栏/工具栏命令及正文缩放 ⌘+ ⌘− ⌘0；“文章”菜单含“在浏览器中打开原文”⌘L、“打开 Markdown”⌘O、“在 Finder 中显示”⇧⌘R、“重新处理”、“删除文章…”⌘⌫。整理重复媒体缓存只在设置“存储”中提供。
- 文章头部：标题；其下一行为作者与时间；再下一行为状态标签，右侧为“收藏”“打开原文”“更多”（`.markxIcon`，悬停显示浅底），滚动后移到窗口顶栏最右侧。不放字号按钮。
- 详情标题、作者、标签和正文共用居中的最大 860pt 阅读栏，左右至少留 40pt；标题与作者行间距 12pt、作者行与状态标签 16pt，上下边距为 56pt / 32pt。图片数为 0 时不显示图片标签。扩大阅读区时整栏一起居中，左边缘必须一致。删除顶部排版校验提示与重复统计，保留底层校验和限制说明；窄窗口允许换行，不得裁切或堆叠。
- 浏览器检测在后台运行，仅检查 X 登录元数据；设置中展示实际浏览器与配置，区分未登录和读取/解密受限。显式选择来源后不得跨浏览器回退账号，Firefox 容器不可混用。钥匙串只在主动验证或下载导入时读取，Cookie 和密钥仅存在内存中。
- macOS 会阻止读取其他应用的数据目录（`Operation not permitted`）。探测结果用 `BrowserSessionIssue.isPermissionDenied` 标记，`browserNeedingAccess` 非空时，欢迎页的浏览器登录行与设置“X 登录”页直接显示“授权读取 <浏览器>…”主按钮，打开预置到该浏览器数据目录的选择面板；授权以安全范围书签保存。ad-hoc 签名的新构建可能需要重新授权一次。
- 配置与结果弹窗统一使用 `MarkXPaneHeader`、`MarkXSection`、`MarkXFooter`；内容区可滚动，底栏固定，不在标题区放置完成按钮。下载和同步弹窗在左上角显示圆形关闭按钮（`MarkXPaneHeader(onClose:)` → `MarkXSheetCloseButton`），与窗口关闭按钮位置一致。
- 弹窗文案从简（0.3.91）：标题能说明的不再加副标题或说明；选项卡片只有图标和标题；能从控件看出的限制（如“最多 100 篇”）不写；确认框最多一句短提示（如“已有归档会保留。”）；结果弹窗只显示指标格子，说明文字仅在有失败、待处理等补充信息时出现。
- 输入使用可见标签，说明只保留与决策相关的内容；危险操作使用系统确认，不自制替代系统警告的对话框。
- 设置内容区固定为 640 × 520pt，由 `SettingsView` 统一管理尺寸。设置使用原生工具栏分类标签和 `Form` + `.formStyle(.grouped)`；分类名即标题，面板内不再重复大标题与图标；分组说明放在 Section footer 并左对齐。
- 进度阶段切换只改变可见性，必须保持隐藏 WebKit 及任务挂载；Escape 与关闭窗口一样只隐藏，停止要点击明确的停止按钮。
- 栏宽统一由 `SplitColumnLayout` 定义：侧栏 220–300pt（理想 248pt），文章列表 360–520pt（理想 420pt），阅读区至少 440pt。macOS 27 首次启动时 `navigationSplitViewColumnWidth` 不生效，`SplitColumnGuard` 在布局稳定后把可见的前两栏拉回范围内；侧栏隐藏时文章列表不得超过 520pt。默认窗口 1360 × 860pt。
- 首次启动或资料库为空（未选择收藏夹或博主）时使用两栏布局：侧栏 + 全宽 `WelcomeView`。欢迎页内容居中、最大 640pt，依次为应用图标、标题与说明、三项配置状态卡、主操作（系统强调色胶囊按钮）和三项特性说明；配置完成后主操作变为“开始下载文章”。有文章后自动切回三栏，侧栏显隐状态保持。
- 发布前用独立 Debug 预览包检查布局，并在最终安装版确认侧边栏、实际弹窗、设置分类、长路径及字体缩放。

参考：[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Settings](https://developer.apple.com/design/human-interface-guidelines/settings)、[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)。
