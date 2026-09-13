# 森空间 · Mori Space

自用的 Apple 多端群晖客户端，集中管理本机照片、NAS 照片、文件、视频和设备状态。使用 SwiftUI、PhotoKit、AVFoundation 与 Synology 原生接口，没有第三方运行时 SDK，也不通过中转服务器传输照片。

当前版本：**0.10.0（18）**。支持 iPhone / iPad（iOS 17+）和 Mac（macOS 14+，Mac Catalyst）。

## 功能

- **本机照片**：贴边网格、收藏与截图筛选、文件大小、缩放和前后翻页。
- **群晖照片**：接入 Synology Photos，浏览个人／共享空间、文件夹和照片，读取原图。
- **群晖文件**：接入 File Station，目录分页、排序、下载任务及本地导出。
- **Mac 文件浏览**：图标／列表切换、单击选择、双击打开、路径栏、前进后退、右侧信息面板和右键菜单；切换栏目保留当前目录。搜索范围为当前已载入的文件。
- **快速预览**：Mac 使用系统 Quick Look 预览常见图片、文本、PDF 和办公文档；上限 30 MB，关闭后清理临时文件，具体格式以系统支持为准。
- **视频播放**：播放本机能够解码的视频，在线播放要求 NAS 支持分段读取；保存本机播放进度，下次打开可续播。
- **NAS 状态**：CPU、内存、网络、存储和硬盘健康；页面打开且 App 位于前台时每 15 秒刷新。
- **新照片备份**：选择 NAS 目录后备份本机新照片。默认关闭；iOS 后台执行由系统调度，不能保证拍摄后立即上传。

Mac 使用侧边栏与桌面布局；iPhone 使用底部导航，iPad 根据可用宽度调整布局。各端独立保存账号、会话、下载、备份与视频进度，不会自动同步手机和 Mac 的登录信息。

## 编译运行

1. 安装 Xcode 和对应 SDK。当前代码在 Xcode 27 beta 中编译验证，工程使用 Swift 5 语言模式。
2. 打开 `MoriPhotos.xcodeproj`，选择 `MoriPhotos` scheme。
3. 模拟器选择相应 iPhone / iPad；Mac 选择 **My Mac (Mac Catalyst)**。
4. 真机与 Mac 在 **Signing & Capabilities** 中选择自己的开发团队，再运行。

`project.yml` 是工程配置源文件，修改后可通过 XcodeGen 重新生成：

```sh
xcodegen generate
```

Mac 启用了沙盒、网络客户端、照片图库和用户选择文件访问权限；钥匙串访问需要有效的开发签名。个人开发签名并非可通用分发的公证安装包。本仓库不包含证书、描述文件和开发团队配置。

## 连接群晖

在 App 连接设置中填写当前设备可访问的 DSM / Photos HTTPS 地址，例如 `https://nas.example.com:5001`，并使用具有相应权限的 DSM 账号登录。

- Synology Photos 和 File Station 分别维护服务会话，支持从钥匙串恢复已保存的连接。
- 使用受信任的 HTTPS 证书；不会跳过证书校验。暂不支持直接输入 QuickConnect ID。
- NAS 监控可能需要更高的 DSM 权限；应用会显示实际接口或权限错误。
- 自动封锁、双重验证及交互式 Secure SignIn 受 NAS 设置影响，不通过反复登录绕过这些限制。

## 测试

在 Xcode 的 Test Navigator 中选择对应测试。测试中的示例账号、令牌、文件内容与 `.invalid` 域名均为合成数据。模拟 NAS 入口仅在指定 DEBUG 测试构建中启用，不包含于正式 Release 包。

0.10.0 已通过 12 项目录导航、预览与文件下载测试，以及新版桌面交互和原有 iPad 导航两项界面测试。Mac 真实 NAS 目录操作已人工验证；原生文本预览使用隔离测试数据验证。尚未逐一验证所有办公格式、Mac 窄窗口和真实 NAS 大文件预览。

个人截图和详细本地验收记录不随源码上传。运行界面测试前应使用隔离模拟器；视频测试可通过 `Scripts/PrepareVideoTests.command <SIMULATOR_UDID>` 安装合成视频。

## 目录

| 路径 | 内容 |
| --- | --- |
| `MoriPhotos/` | SwiftUI 应用、NAS 客户端与本机服务 |
| `MoriPhotosTests/` | 单元及集成测试 |
| `MoriPhotosUITests/` | iPhone / iPad 界面测试 |
| `MoriPhotosMacUITests/` | Mac 界面测试入口 |
| `Branding/` | 应用图标原稿与设计说明 |
| `Scripts/` | 图标处理、合成视频测试工具 |
| `project.yml` | XcodeGen 工程配置 |

工程及 bundle identifier 继续使用 `MoriPhotos`，以保持已有安装、钥匙串和本机数据的升级兼容。
