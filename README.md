# 微信存储管理 (WeChat Clean)

<p align="center">
  <img src="Resources/Info.plist" alt="WeChat Clean Logo" width="80" height="80" style="display:none;" />
  <h3 align="center">微信存储管理 · WeChat Clean for macOS</h3>
  <p align="center">专为 macOS 微信 4.x 深度打造的原生细粒度存储分析、APFS 硬链接去重与安全清理工具</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014.0%2B-blue.svg?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange.svg?style=flat-square" alt="Swift 6.0" />
  <img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20Native%20macOS-green.svg?style=flat-square" alt="SwiftUI" />
  <img src="https://img.shields.io/badge/License-MIT-purple.svg?style=flat-square" alt="License" />
</p>

---

## 📖 项目简介

macOS 微信自 4.x 版本进行了全栈重构，底层存储机制发生了重大转变：
1. **沙盒路径变更**：从传统的 `2.0b4.0.9` 迁移至 `Documents/xwechat_files/<account_id>/`。
2. **附件复合加密**：图片与附件全面升级为 **V2 AES-128-ECB + XOR** 复合加密格式（不再是简单的单字节异或），导致绝大多数第三方工具只能看到一堆 `.dat` 乱码文件而无法预览。
3. **数据库加密与加固**：联系人 `contact.db`、会话 `session.db` 及聊天消息全部升级为 **SQLCipher 4** 加密，且微信主程序启用了 macOS **Hardened Runtime** 加固运行时。

**微信存储管理 (WeChat Clean)** 采用纯原生 Swift 6 与 SwiftUI 编写，零第三方庞大依赖，深入微信 4.x 底层存储链路，提供从会话识别、联系人解密、.dat 附件极速还原到 APFS 物理无损去重的一站式存储管理方案。

---

## ✨ 核心特性

### 1. 🔍 细粒度分类存储分析
- **多维度视图**：支持按「会话存储分析」、「大文件猎手」、「重复文件瘦身」、「视频」、「聊天文件」、「图片与附件」及「系统缓存」进行智能归类。
- **O(1) 毫秒级筛选**：基于后台并发流水线与存储属性缓存，支持按文件大小、时间、文件类型即时过滤与排序。

### 2. 🖼️ V2 .dat 附件极速解码与缩略图预览
- **原生复合解密**：基于 `CommonCrypto` 原生实现 V2 `AES-128-ECB(PKCS7) + Raw + XOR` 解码，并完美向下兼容传统单字节 XOR 格式。
- **伴生图优先加速**：优先探测解密 9KB 级的同级 `_t.dat` 伴生缩略图，0.1ms 极速解码，内存占用降低 95% 以上。
- **ImageIO 硬件降采样**：支持 Retina 屏高清缩略图渲染，配合双层 LRU 缓存与 QuickLook 原生空格全屏预览。

### 3. 👥 会话与联系人智能识别
- **双版本架构兼容**：原生兼容微信 4.x 的 `contact` 表与微信 3.x 的 `Contact` 表，自动提取好友昵称、群聊名称及头像。
- **MD5 目录反向映射**：自动将 `msg/attach/<md5>` 散列目录与联系人双向绑定，彻底终结「会话 (62cc3bb1)」哈希乱码。
- **本账号智能识别**：自动识别登录账号的真实微信昵称与微信号，侧边栏不再显示生硬的 `wxid_xxxx`。

### 4. 🔑 macOS 标准提权一键提取密钥
- **内置原生提权**：在设置弹窗中点击「一键自动提取微信密钥」，将自动调用 macOS 原生系统权限请求弹窗（输入密码或 Touch ID 验证）。
- **Mach VM 内存扫描**：基于 Mach 虚拟内存接口（`task_for_pid` + `mach_vm_read`）在 1~2 秒内自动捕获微信进程中的 SQLCipher 密钥并完成 HMAC 校验，无需用户手动在终端执行复杂指令。
- **多途径导入**：同时支持导入 `all_keys.json` 文件或手动粘贴 64 位 Hex 密钥。

### 5. ⚡ APFS 原生硬链接无损去重
- **释放物理空间，保留逻辑文件**：借助 macOS APFS 现代文件系统特性的 `link(2)` 硬链接机制，将多个聊天中重复转发的文件合并为一个物理 inode。
- **零破坏性**：微信在各个聊天会话中依然能够正常打开和查看该文件，释放数十 GB 真实磁盘空间的同时，完全保持微信聊天记录的逻辑完整性。

### 6. 🛡️ 安全废纸篓机制
- **可逆清理**：所有清理操作默认调用系统 `FileManager.default.trashItem` 移入 macOS 废纸篓，支持随时一键放回原处。
- **缩略图智能保护**：清理大体积视频或附件时，可勾选保留轻量缩略图，在微信聊天记录中依然保留预览占位。

---

## 🖥️ 界面预览

- **MotrixMac 极简风格导航**：左侧预留 54pt 避开红黄绿交通灯，胶囊状平滑切换，提供充足的呼吸空间。
- **Pearcleaner 浮动操作胶囊**：底部悬浮操作栏清晰显示选中项数与体积，支持一键「全选全部 (61.62 GB)」与批量清理。
- **原生表头排序**：点击「文件名」、「大小」、「分类」或「修改时间」表头即时排序，修改时间默认按最新时间倒序排列。

---

## 🚀 快速上手

### 环境要求
- macOS 14.0 或更高版本
- 已安装并登录微信 4.x (或 3.x)

### 方式一：直接运行预编译 App
1. 从 [Releases](../../releases) 页面下载最新版 `微信存储管理.zip`。
2. 解压后将 `微信存储管理.app` 拖入 `应用程序` 文件夹即可使用。

### 方式二：源码编译
```bash
# 1. 克隆本项目
git clone https://github.com/ShawnRn/WeChat-Clean.git
cd WeChat-Clean

# 2. 运行打包脚本生成 .app
./scripts/build_app.sh

# 3. 打开应用
open 微信存储管理.app
```

---

## 🛠️ 项目架构

```
WeChat-Clean/
├── Package.swift                  # Swift Package 配置
├── Sources/WeChatClean/
│   ├── App.swift                  # 应用生命周期入口
│   ├── Models/
│   │   └── Models.swift           # 核心领域模型 (文件项、账号、分类等)
│   ├── Engine/
│   │   ├── WeChatDetector.swift   # 微信 4.x 数据目录探测与账号识别
│   │   ├── ScannerEngine.swift    # 极速并发文件扫描与 MS-DOS 时间修正
│   │   ├── WeChatDatDecoder.swift # V2 AES+XOR / 传统 XOR 附件解密引擎
│   │   ├── SQLCipherDecryptor.swift # 纯 Swift SQLCipher 4 数据库解密器
│   │   ├── WeChatContactManager.swift # 联系人加载与 MD5 散列双向映射
│   │   ├── HardlinkDeduplicator.swift # APFS inode 硬链接去重引擎
│   │   └── CleanerEngine.swift    # 安全废纸篓回收引擎
│   └── UI/
│       ├── AppState.swift         # @Observable 核心状态调度器
│       ├── MainView.swift         # 主窗口分栏布局
│       ├── SidebarView.swift      # 侧边栏分类与账号导航
│       ├── FileListView.swift     # 原生文件表格、分页与浮动操作栏
│       ├── SessionListView.swift  # 会话存储钻取与联系人管理
│       ├── DuplicateListView.swift# 重复文件去重视图
│       └── Components/            # 缩略图中心、密钥弹窗、编辑弹窗等
├── Tests/WeChatCleanTests/        # 完整的引擎与流水线单元测试
├── scripts/
│   ├── extract_keys.py            # 纯原生 Python + Mach VM 内存密钥扫描器
│   └── build_app.sh               # 一键自动化编译与打包脚本
└── Resources/
    └── Info.plist                 # 应用元数据
```

---

## 💖 致谢与开源灵感 (Credits & Acknowledgements)

本项目在开发过程中，深受开源社区杰出项目的启发，特向以下项目及作者致以崇高的敬意：

1. **[wx-cli-again](https://github.com/jackwener/wx-cli-again)** (@jackwener)：
   - 极其卓越的微信 4.x macOS 逆向与命令行工具。
   - 本项目深度参考了其对微信 4.x **V2 图片密钥派生算法**、**SQLCipher 4 数据库结构**及 **macOS Mach VM / LLDB 内存密钥提取机制** 的先驱性研究成果。
2. **[Motrix](https://github.com/agalwood/Motrix)**：
   - 提供了现代、纯粹的 macOS 桌面客户端视觉设计哲学与侧边栏布局灵感。
3. **[Pearcleaner](https://github.com/alienator88/Pearcleaner)** (@alienator88)：
   - 提供了优秀的 macOS 原生清理工具交互范式，特别是底部浮动操作胶囊栏与人性化的清理流程。

---

## 📄 开源许可证

本项目采用 [MIT License](LICENSE) 开源许可证。
欢迎提交 Issue 与 Pull Request！
