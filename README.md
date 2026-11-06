# 澄观 · Chengguan

原生 macOS 系统监测与设备工具箱。把 Mac 状态、AI 工具用量、外接存储、线缆、NAS 和搬瓦工服务器放进同一个窗口，也能在菜单栏快速查看。

当前版本：**0.19.1** · SwiftUI / AppKit · MIT

## 功能

| 板块 | 内容 |
| --- | --- |
| Mac 监测 | CPU、内存压力、进程、磁盘 I/O、网络、GPU、温度、风扇、电池与功率 |
| AI 用量 | Codex、Claude、Cursor 等可读取的额度、重置倒计时、本机 Token 和运行会话；另有 Gemini CLI、Qwen Code、Kimi、OpenCode、Kilo 日志适配器 |
| AI 建议 | 自带 Key 接入 MiMo、DeepSeek、通义千问、GLM、Kimi、MiniMax 或硅基流动，结合近期数值与本地异常给出简短建议 |
| 外接设备 | 存储卷即时识别、容量和格式、Finder 入口、安全推出、顺序读写测速；USB-C 芯片及链路能力识别 |
| NAS | 绿联 UGOS 本地监测、旧版 DH2100+ 兼容、双设备切换；可用时显示容量、硬盘、温度及风扇 |
| 服务器 | KiwiVM 只读状态、内存和负载趋势、月流量、每日流量增量及重置倒计时 |
| 显示器 | 亮度、音量、缩放、分辨率记忆、色彩、排列；有总开关，可独立停用 |
| 默认打开 | 浏览器、邮件与常见文件格式的默认应用，写入后读回核对 |
| 整理 | 先扫描、再选择的缓存清理、软件关联文件审阅、空间分析和可恢复的处理记录 |

主窗口与菜单面板共用采集数据，支持深浅色、整块按钮、键盘导航和历史 CSV 导出。macOS 26+ 使用原生 Liquid Glass，旧系统采用原生材质回退。

## 构建

需要 macOS 15+、支持 Icon Composer `.icon` 编译的完整 Xcode（26 或更新版本）、Python 3。构建使用当前 Mac 的架构。本项目目前主要在 Apple Silicon 上实机验证，Intel 与旧系统仍需验证。

```sh
git clone https://github.com/LELE666999/Chengguan-OpenSource.git
cd Chengguan-OpenSource
swift test
./scripts/build.sh
```

成品位于 `dist/澄观.app`，可拖到「应用程序」。脚本默认做本机 ad-hoc 签名；它不等于 Developer ID 签名或 Apple 公证。跨机器分发时使用自己的证书：

```sh
CHENGGUAN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build.sh
```

可选磁盘映像：

```sh
python3 -m venv .venv
.venv/bin/pip install -r scripts/dmg-requirements.txt
.venv/bin/python scripts/make_dmg.py
```

磁盘映像脚本目前面向已通过 Developer ID 签名的 arm64 App。公证通过 `scripts/notarize.sh` 单独提交，配置名由 `CHENGGUAN_NOTARY_PROFILE` 提供，脚本不包含凭据。

## 使用

- `⌘,` 打开设置，`⌘⇧M` 打开菜单面板，`⌘⇧K` 打开整理。
- 关闭主窗口后继续在菜单栏运行，`⌘Q` 完全退出。
- 「设置 → 集成」管理 AI 用量、显示器总开关和服务器连接；模型配置位于「AI 分析」。
- NAS 和 KiwiVM 请在 App 内填写自己的连接信息。AI 模型、NAS 密码与 KiwiVM Key 由本机钥匙串管理，不写入源码。
- 独立 App 混音需要 macOS 系统音频权限；只在内存中处理，不保存音频。

## 服务器的均衡总览

资源圆环、近 30 分钟趋势与每日流量并排展示，菜单版采用紧凑布局。点击资源卡可切换趋势，连接详情原地展开。

趋势来自本机成功采样；每日流量从接入后的计数器差值开始积累。没有历史的日期显示「—」，不补造接入之前的记录。月度重置、计数器回退和跨午夜的未知分摊会重新建立基线。磁盘映像分配量与文件实际占用、系统负载与 CPU 百分比分别标识。

## 数据与边界

- 历史和数值用量记录保存在本机应用支持目录；公开源码不包含账号、真实服务器资料、Key、运行数据库、设备截图或私有开发历史。
- 启用模型分析后，会向你配置的模型服务发送必要的数值与问题。自动诊断采用匿名 App 标签，本机界面还原名称；IP、文件路径及日志正文不在自动分析载荷内。
- AI 用量读取依赖各工具提供的本机日志或对应账号接口。已安装或正在运行不代表额度一定可获取；缺失、过期和限流会明确标识。Token 统计不等于账单金额。
- NAS 不同固件开放的指标不同；旧版网络服务不能提供完整设备指标。风扇、温度或硬盘容量未报告时保留未知，不推算为零。
- 硬件能力依赖机型、接口和系统权限。部分传感器、DDC 与能量接口属于动态检测的私有系统接口，后续 macOS 版本可能改变。
- 显示器的部分高级功能需要另装 BetterDisplay 及相应授权，本项目没有独立实现 BetterDisplay 的全部功能。
- 清理、退出应用、推出和格式化由用户确认执行；AI 不能提交任意命令。测速使用独立临时文件，仍会产生真实写入；格式化会清除所选卷的数据。
- 系统监测和 AI 建议是线索，不能仅凭占用率确认卡顿根因或内存泄漏。

## 源码结构

```text
Sources/MonitorBridge/       Mach / libproc 的 C 桥接
Sources/DisplayBridge/       显示器与 DDC 桥接
Sources/VitalsReplica/      原生界面、采集、历史和各设备适配器
Tests/VitalsReplicaTests/   解析、状态机、数据隔离及回归测试
Design/AppIcon.icon/        项目图标的 Icon Composer 工程
Vendor/                     第三方许可证
scripts/                    构建、图标编译、公证和 DMG 打包
```

`VitalsReplica` 为沿用的内部 Swift target 名，不代表与参考产品存在关联。公开版本使用系统符号作为缺失品牌图片的替代，未包含从参考 App 提取的专有图片。

项目代码采用 [MIT](LICENSE)，第三方来源与各自授权见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。欢迎提交可复现的问题、硬件兼容性反馈和改进。
