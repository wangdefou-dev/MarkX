# MarkX macOS 客户端开发规范

文档用途：作为 MarkX macOS 客户端的长期开发、交互、测试、打包和发布规范。本文档记录已经确定的默认行为；产品功能细节以当前 `PRD-MarkX-macOS.md` 为准。

## 1. 产品边界

- MarkX 是 Apple Silicon 原生 macOS 应用，使用 Swift、SwiftUI，必要位置使用 AppKit。
- 只归档 X Article，不下载普通 Post、Note Post、转帖、回复或自回复线程。
- 正常发现、同步、重新拉取和预览链路保持 0 次 X API 请求；使用本机 Chrome 的 X 登录态完成后台采集。
- X 页面、登录页和浏览器工具栏在采集时保持隐藏；用户只看到原生进度、状态和结果。
- 用户文章、Cookie、归档目录和图床密钥默认只在本机处理。用户主动选择外部存储时，媒体必须先完成本地缓存和校验。
- 任何正文结构、媒体数量/顺序、存储 URL 或 Markdown 校验失败，都不得把文章标记为完成；失败任务必须可恢复。

## 2. 数据与交互原则

- 资料库、博主分组支持折叠和展开；分组标题需要明显高于条目，但不得放大条目内容。
- 博主行只展示博主名称、ID 和“已下载 / 线上总数”分数；查看主页、重新拉取、刷新线上总数和删除放入右键菜单。
- 文章列表按当前筛选结果连续编号；“今日推文”按 X 原始发布时间动态更新；“商单内容”只包含带有 X 官方 Paid partnership 标记的文章，列表和详情页需显示同一商单内容标签。
- 文章详情显示发布时间，精确到分钟；文章标题、作者、类型和时间保持清晰的层级关系。
- 任务结果使用可视化统计项展示博主数、检查数、保存数、跳过、订阅、失败、图片、视频和待处理数量，不使用难以扫描的一整段结果文字。
- 所有会改变数据的操作都要说明影响范围，并在删除、迁移或覆盖前要求确认；已完成归档和远程媒体不得被误删。

## 3. 主页面视觉层级

### 3.1 字号

- 侧边栏分组标题：12px 半粗，使用 secondary；条目 13px，博主名称 12px，用户名与分数 10–11px。
- 侧边栏资料库条目和博主名称：使用系统默认正文级别，避免通过放大条目强化层级。
- 博主 ID、文章数量、分数和状态辅助信息：使用 `caption`；数量使用 `monospacedDigit()`，保持紧凑稳定。
- 文章列表标题：`headline`；作者、类型、发布时间和状态说明：`caption`。
- 文章详情标题：`title2` 加粗；作者、类型、发布时间：`subheadline` 和 secondary。
- 任务进度、状态卡和按钮辅助说明：`caption` / `caption2`，避免抢过主内容。
- 正文预览使用独立的文字缩放控制，不因侧边栏或列表字号调整而改变文章排版。

### 3.2 颜色

- 主内容使用 `.primary`，辅助信息使用 `.secondary`，不要用高饱和颜色承载普通文本。
- `.tint` 只用于主要操作和可交互入口。
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
- 构建和测试失败时保留产物与日志，修复失败原因后再继续发布，不得把部分成功报告为完整交付。

## 5. 版本与安装包

- 应用版本同时维护 `Config/Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
- README、官网 `website/src/App.tsx` 的版本号、Build 号、下载地址和更新说明必须与应用包一致。
- 默认只生成 arm64 DMG，不生成或上传 ZIP。DMG 必须包含可拖入 `/Applications` 的快捷入口，并且只保留 App 和 Applications 两项可见内容。
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
4. 将 DMG 和校验文件上传到 R2 的不可变版本目录：

```text
downloads/markx/<version>/MarkX-<version>.dmg
downloads/markx/<version>/SHA256SUMS.txt
```

5. 执行官网线上下载校验，确认下载包校验和、DMG 挂载和包内版本一致。
6. 应用源码仓库和 `website/` 官网仓库分别提交、分别推送；官网仓库不得作为应用仓库的嵌套 Git 内容提交。
7. 官网改动完成后执行 `vercel --prod --yes`，并检查生产域名已经包含当前版本和更新文案。
8. 发布失败时保留已完成产物，明确指出失败环节；不能只提交代码或只触发部署就报告完成。

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
- [ ] 旧版 App 已移入废纸篓，失败环节和残留产物已如实记录。


## 9. 界面布局与视觉验收（0.3.40）

- 侧边栏下载入口保持单行约 44px 高，铺满整个侧栏宽度，取消独立卡片的外边距、描边与圆角；下载主操作和置顶图钉使用橙色。顶部、列表与底部共用背景，底部不放分隔横线。目录与连接状态共用紧凑底部区域，Chrome 与存储状态都可点击；列表数字右对齐，不为每项增加胶囊底色。
- 搜索放在右上角下载、同步和设置按钮组左侧。设置菜单同步展示 Chrome、存储状态，并能直达对应配置。
- 配置与结果弹窗统一使用 `MarkXPaneHeader`、`MarkXSection`、`MarkXFooter`；内容区可滚动，底栏固定，不在标题区放置完成按钮。
- 输入使用可见标签，说明只保留与决策相关的内容；危险操作使用系统确认，不自制替代系统警告的对话框。
- 设置使用原生分类标签；成功、待处理和失败维持语义色，表面使用适配浅色/深色的中性颜色。
- 进度阶段切换只改变可见性，必须保持隐藏 WebKit 及任务挂载；Escape 与关闭窗口一样只隐藏，停止要点击明确的停止按钮。
- 发布前用独立 Debug 预览包检查布局，并在最终安装版确认侧边栏、实际弹窗、设置分类、长路径及字体缩放。

参考：[Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[Settings](https://developer.apple.com/design/human-interface-guidelines/settings)、[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)。
