# MarkX

**把 X 长文，完整保存到自己的 Mac。**

MarkX 是面向 Apple Silicon Mac 的原生 X Article 归档工具。输入博主主页或文章链接，即可在后台保存正文、原图和支持的视频，导出可迁移的 Markdown，并在三栏资料库中搜索、阅读和持续同步。

[产品官网](https://markx.defou.ai/) · [下载安装](https://markx.defou.ai/#download) · [问题反馈](https://github.com/wangdefou-dev/MarkX/issues) · [MIT 许可证](LICENSE)

## 主要功能

- **按博主或文章归档**：支持单个博主、批量博主和最多 500 条文章链接；可选择最近 1–100 篇或全部可见历史。
- **保留正文结构与媒体顺序**：保存标题、段落、列表、引用、代码、表格、链接和富文本样式，以及原文位置上的图片和支持的 MP4 视频。
- **本地 Markdown 资料库**：正文与媒体保存在你选择的文件夹中，默认使用相对媒体路径，方便迁移、备份或交给 Obsidian 等编辑器继续整理。
- **搜索与阅读**：在当前分类中搜索标题、博主和中文正文；内置阅读视图、文字缩放、原图预览和视频播放。
- **批量与定时同步**：统一检查已跟踪博主的新文章，跳过已经完整保存的归档，也可设置每天定时同步。
- **校验与恢复**：保存前检查正文结构、媒体数量与顺序、文件和 Markdown；失败、停止或需要订阅的任务保留明确状态，方便继续处理。

## 快速开始

1. 从[官网](https://markx.defou.ai/#download)下载 DMG，将 MarkX 拖入“应用程序”。
2. 打开 MarkX，选择一个本地归档文件夹。
3. 在受支持的本机浏览器中登录 X，再到 MarkX 的“设置 → X 登录”选择浏览器并验证会话读取。
4. 保持默认的本地存储，点击“开始下载文章”，粘贴博主主页、用户名或 X Article 链接。
5. 选择最近文章范围或全部文章。任务会在后台进行，完成后可在资料库中阅读，也可直接打开保存的 Markdown。

当前版本：**0.3.53（Build 140）**。安装包采用 ad-hoc 签名，尚未完成 Developer ID 公证。

## 内容保留范围

| 内容 | 保存方式 |
| --- | --- |
| 正文与排版 | 保留标题层级、段落、列表、引用、代码、表格、链接和支持的富文本样式 |
| 图片 | 保存原图，校验文件并按 SHA-256 去重，保持原文顺序 |
| 视频 | 保存支持的渐进式 MP4，在应用内播放，Markdown 中保留视频块与备用下载链接 |
| 来源与状态 | 保存来源快照、原文链接、处理状态和失败原因，便于核对与重试 |

遇到未支持的排版块、未加载完整的媒体或校验失败时，MarkX 会保留任务和原因，等待后续处理。

## 存储与隐私

默认只需本地文件夹，无需配置云服务。图片保存在 `media/images/`，视频保存在 `media/videos/`，文章与索引位于 `Blogger/`。

需要远程媒体地址时，可主动选择 uPic 或原生 S3 / R2。媒体会先完成本地缓存与校验，再上传并验证远程地址；S3 / R2 凭证保存在 macOS 钥匙串中。

正常归档流程不调用 X API，无需 X Developer API Key。MarkX 复用本机浏览器已有的 X 登录会话，只读取 X 所需的 Cookie，在当前采集过程的内存中使用，不打印、不落盘，也不上传给开发者。

## 使用要求与边界

- **系统**：Apple Silicon Mac，macOS 14 或更新版本。
- **文章类型**：仅处理官方 X Article；普通 Post、Note Post、回复和线程不在归档范围内。
- **浏览器**：支持 Chrome、Edge、Brave、Arc、Vivaldi、Opera、Chromium、Chrome Canary、夸克、豆包与 Firefox，并支持多个浏览器配置；Safari 暂不支持自动导入登录态。
- **访问权限**：使用当前 X 账号实际可见的内容；需要订阅的文章会提示相应状态，不绕过订阅权限。
- **视频范围**：目前支持可下载的渐进式 MP4；音频、直播、仅 HLS 的媒体及外站 iframe 暂不支持。
- **定时同步**：关闭主窗口后可在后台执行，睡眠错过的任务会在唤醒后补执行；完全关机时无法运行。

## 从源码运行

需要 Swift 6.2 或更新版本，以及相应的 macOS 开发工具。

```bash
git clone https://github.com/wangdefou-dev/MarkX.git
cd MarkX
swift run XArticleArchiverApp
```

运行测试：

```bash
swift test
```

默认测试不读取实时浏览器会话或上传用户归档；真实浏览器、X、uPic 和视频联调需显式启用。

构建并验证 arm64 DMG：

```bash
./scripts/build-app.sh
./scripts/verify-app.sh
./scripts/verify-packages.sh
```

开发与发布流程见[开发规范](MARKX-macOS-CLIENT-DEVELOPMENT-SPEC.md)，历史版本说明见[更新记录](CHANGELOG.md)。

## 开源许可证

MarkX 使用 [MIT License](LICENSE)，完整版权与许可声明随源码和应用安装包提供。
