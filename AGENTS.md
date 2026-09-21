# AGENTS.md - WeChat Clean 开发者与 AI 协作规范

本文件为所有参与维护、扩展或重构 **WeChat Clean (微信存储管理)** 代码库的 AI 智能体 (Agents) 和人类工程师提供核心架构蓝图、工程规范与逆向技术备忘。

---

## 🎯 核心工程原则 (Guiding Principles)

1. **技术文稿语言规范 (Artifact Language)**：
   - 所有的计划文件 (`implementation_plan.md`)、任务清单 (`task.md`)、回顾演示 (`walkthrough.md`) 以及给用户的反馈必须始终使用 **简体中文**。
2. **原生实现与极致性能 (Native & Performance-First)**：
   - 绝不引入臃肿的第三方依赖，优先使用 macOS 原生体系（Swift 6、SwiftUI、Observation、CommonCrypto、ImageIO、SQLite3、QuickLook）。
   - 禁止使用软废弃 (Deprecated) 的旧 API（如 `onChange(of:perform:)`, `NavigationView`, `ObservableObject` 等），必须保持最新的现代 Swift 规范。
3. **编译零报错、零警告 (Zero Warnings / Zero Errors)**：
   - 任何代码修改必须在本地执行 `swift build`，确保没有引发任何编译器警告或错误。
   - 必须运行 `swift test` 保证全部单元测试 100% 通过。
4. **并发安全性 (Concurrency Discipline)**：
   - 严格遵循 Swift 6 严格并发检查模式。
   - UI 状态与事件绑定必须在 `@MainActor` 上运行；耗时的大文件哈希、磁盘遍历、图片解密与降采样必须在 `Task.detached(priority: .userInitiated)` 中执行，严禁阻塞主线程 RunLoop。

---

## 🏗️ 架构与核心模块拓扑

```
Sources/WeChatClean/
├── App.swift                  # NSApplication 生命周期适配器，启动即展示主界面
├── Models/
│   └── Models.swift           # 领域数据结构：WeChatFileItem, WeChatAccount, WeChatCategory, DuplicateGroup
├── Engine/                    # 纯逻辑层（不包含任何 SwiftUI 视图依赖，便于单元测试）
│   ├── WeChatDetector.swift   # 微信目录检测（xwechat_files）、账号配置本地持久化
│   ├── ScannerEngine.swift    # 高性能并发文件树扫描，内置 250ms 限流进度广播与 MS-DOS 1980 时间修正
│   ├── WeChatDatDecoder.swift # V2 AES-128-ECB(PKCS7) + Raw + XOR 复合解密器，伴生 _t.dat 探测
│   ├── SQLCipherDecryptor.swift # 纯 Swift 实现的轻量 SQLCipher 4 分页解密器 (PBKDF2 HMAC-SHA512 + AES-256-CBC)
│   ├── WeChatContactManager.swift # 微信 4.x (contact 表) 与 3.x (Contact 表) 联系人加载，MD5 散列双向映射
│   ├── HardlinkDeduplicator.swift # APFS link(2) 物理硬链接无损去重引擎
│   └── CleanerEngine.swift    # 系统废纸篓安全移入 (FileManager.default.trashItem)
└── UI/                        # 视图层 (SwiftUI)
    ├── AppState.swift         # @Observable @MainActor 全局状态调度器（排序、过滤、多选、分页）
    ├── MainView.swift         # NavigationSplitView 双栏分栏容器
    ├── SidebarView.swift      # MotrixMac 风格胶囊分类导航
    ├── FileListView.swift     # 原生 Table 表格视图，支持点击表头排序、分页控制与浮动操作胶囊
    ├── SessionListView.swift  # 会话存储钻取列表与联系人管理
    ├── DuplicateListView.swift# APFS 重复文件组分析与去重执行视图
    └── Components/
        ├── ThumbnailStore.swift     # 缩略图响应式中心，NSCache 双层缓存与回调队列
        ├── MediaThumbnailView.swift # 单元格响应式缩略图，订阅 ThumbnailStore.thumbnails
        ├── DatabaseKeySheet.swift   # 数据库密钥弹窗，支持 AppleScript 管理员提权一键提取
        └── AccountEditSheet.swift   # 微信账号自定义昵称与微信号编辑弹窗
```

---

## 🔬 微信 4.x 核心逆向技术规范

在对本项目进行维护时，请牢记以下已验证的技术事实：

### 1. 存储路径
- 根目录：`~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/<account_id>/`
- 附件目录：`.../<account_id>/msg/attach/<chat_md5>/<year-month>/Img/`
- 数据库目录：`.../<account_id>/db_storage/`
  - `contact/contact.db` (联系人数据库)
  - `session/session.db` (会话列表数据库)
  - `message/message_0.db` ~ `message_5.db` (分片消息数据库)

### 2. V2 .dat 附件解密规范
- **文件魔数**：头部 6 字节为 `07 08 56 32 08 07`（或 V1 `07 08 56 31`）。
- **头部结构 (共 15 字节)**：
  - `[0..6]`：魔数
  - `[6..10]`：`aes_size` (小端 uint32)
  - `[10..14]`：`xor_size` (小端 uint32)
  - `[14..15]`：1 字节填充
- **AES Key 派生**：
  - 从 `kvcomm` 目录中找到 `uin`（如 `key_1129432576_...` 中的 `1129432576`）。
  - `normalized_wxid`：将 `wxid_utsd9tdkmhag22_11bf` 去除后缀得到 `wxid_utsd9tdkmhag22`。
  - `aes_key = md5(str(uin) + normalized_wxid).hex()[:16]` (16 字节 ASCII 字符串)。
  - `xor_key = uin & 0xFF`。
- **解密三段式**：
  1. 对 `[15 ..< 15 + aligned_aes_size]` 进行 `AES-128-ECB` 解密，并剔除 PKCS7 padding。
  2. `[15 + aligned_aes_size ..< len - xor_size]` 为未加密的原始数据段。
  3. `[len - xor_size ..< len]` 为单字节异或数据段，每个字节 `^ xor_key`。
  4. 三段拼接即为原始图片（JPEG `FF D8`, PNG `89 50` 等）。

### 3. SQLCipher 4 数据库结构
- **Page Size**：4096 字节。
- **Reserve Size**：80 字节（IV 16 字节 + HMAC-SHA512 64 字节）。
- **HMAC 验证 (Page 1)**：
  - `mac_salt = bytes([b ^ 0x3a for b in salt])` (Salt 为前 16 字节)。
  - `mac_key = PBKDF2_HMAC_SHA512(raw_key, mac_salt, iterations=2, keylen=32)`。
  - 计算 `content + iv + 1` 的 HMAC-SHA512，与存储在末尾的 64 字节比较。
- **表结构变更**：
  - 微信 4.x 的联系人表名为 `contact`（小写），字段包含 `username, nick_name, remark, verify_flag`。
  - 微信 3.x 旧表名为 `Contact`，字段包含 `m_nsUsrName, m_nsNickName, m_nsRemark, m_nsHeadImgUrl`。
  - 我们的 `WeChatContactManager` 同时适配了这两种结构。

---

## 🛠️ 常用开发与测试指令

```bash
# 1. 编译项目 (Debug)
swift build

# 2. 运行完整单元测试套件
swift test

# 3. 执行独立一键打包脚本生成 .app
./scripts/build_app.sh

# 4. 手动测试运行密钥提取器
sudo python3 scripts/extract_keys.py
```
