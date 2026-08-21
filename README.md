# DualPadMapper / 双手柄映射器

一个小型 macOS 菜单栏工具，用来解决《胡闹厨房 2》（Overcooked! 2）中两只手柄通过 Steam Input 映射为键盘后，方向输入互相覆盖、同一时刻只有一只手柄生效的问题。

它绕过 Steam Input 的键盘合成层，通过 IOKit 直接读取两只实体 Xbox 手柄，再分别输出两套“切分键盘”按键。程序不联网，不采集数据，所有处理均在本机完成。

## 问题原理

本案例中，两只实体 Xbox One S 手柄拥有不同蓝牙序列号，但 Steam Input 为它们创建的虚拟 Xbox 360 设备使用了相同的虚拟身份。映射为键盘后，并发方向输入可能被合并或覆盖；直接按实体键盘的两套按键则不会出现问题。

DualPadMapper 将链路改为：

```text
实体手柄 P1 ──IOHID──> W/A/S/D + Z/X/C
实体手柄 P2 ──IOHID──> U/I/O/P + B/N/M
                         │
                         └──> macOS 键盘事件 ──> 游戏“切分键盘”
```

共享按键（如 Space、Esc）使用“按键拥有者计数”：两只手柄同时按住时，其中一只松开不会错误释放另一只仍按住的按键。

## 适用环境

- macOS 13 或更高版本，支持 Apple 芯片与 Intel Mac。
- Steam 版《胡闹厨房 2》，App ID `728880`。
- 两只通过蓝牙连接的 Xbox One S Wireless Controller。
- 当前版本仅匹配 Microsoft VID `0x045e`、PID `0x02e0`；其他 Xbox、PlayStation、Switch 或第三方手柄尚未验证，也不会被程序识别。

## 下载与安装

1. 从 GitHub Releases 下载 `DualPadMapper-macOS.zip` 并解压。
2. 在 Steam 中右键《胡闹厨房 2》→“属性”→“控制器”，将该游戏的 Steam Input 设为“禁用”。
3. 打开 `双手柄映射器.app`。如果 macOS 阻止首次启动，请在 Finder 中按住 Control 点击应用并选择“打开”。
4. 按系统提示进入“系统设置”→“隐私与安全性”→“辅助功能”，加入该应用并打开开关。
5. 退出并重新打开映射器。菜单栏应显示 `🎮 2/2`，菜单中应显示两个不同的手柄尾号及“辅助功能权限：已启用”。
6. 启动游戏并使用“切分键盘”控制方案。

> 更新或自行重新构建后，临时签名会变化。若菜单显示权限未启用，请删除“辅助功能”中的旧条目，重新加入刚构建的应用，再重启应用。

## 默认映射

| 手柄输入 | P1 键盘输出 | P2 键盘输出 |
|---|---|---|
| 左摇杆 / 十字键 | W / A / S / D | U / O / I / P |
| B | Z（切碎/投掷） | B（切碎/投掷） |
| X | X（捡起/放下） | N（捡起/放下） |
| Y | C（加速） | M（加速） |
| A | Space（确认） | Space（确认） |
| LB | E（表情） | -（表情） |
| RB | T（切换厨师） | =（切换厨师） |
| Menu | Esc | Esc |

方向表中的顺序分别为“上 / 左 / 下 / 右”。如需修改映射，请编辑 `Sources/DualPadMapper/main.swift` 中的 `KeyCodes` 与 `layouts`。

## 从源码构建

需要 Xcode Command Line Tools。无需第三方依赖：

```bash
git clone <your-repository-url>
cd <repository-directory>
bash scripts/build.sh
```

构建结果为 `dist/DualPadMapper-macOS.zip`。脚本会合并 `arm64` 与 `x86_64` 为通用二进制，并先在系统临时目录中完成签名和验证，再打包到 `dist`，以避免 iCloud Drive 等文件提供程序附加扩展属性、破坏代码签名。

仅运行内置并发按键回归测试：

```bash
bash scripts/test.sh
```

测试会验证两只手柄共享按键的引用计数，以及 `W` 与 `U` 能够同时按下并分别释放。

## 状态与故障排查

应用运行后可查看菜单栏图标：

- `🎮 0/2`：未识别到手柄。
- `🎮 1/2`：只识别到一只。
- `🎮 2/2`：两只手柄均已独立连接。

诊断文件位于：

- `/tmp/DualPadMapper-status.txt`：设备数量、权限和手柄尾号。
- `/tmp/DualPadMapper-events.log`：本次运行产生的映射按下/松开事件，不包含游戏数据。

常见问题：

1. **显示 `2/2`，游戏内没有反应**：确认辅助功能权限已启用，并在改动权限后重启映射器。
2. **仍然只有一个方向输入生效**：确认已对《胡闹厨房 2》禁用 Steam Input，且游戏使用“切分键盘”。
3. **显示 `0/2`**：确认手柄是 PID `0x02e0` 的 Xbox One S 蓝牙型号；当前版本不会自动兼容其他 PID。
4. **P1/P2 与预期相反**：菜单会显示每个玩家对应的蓝牙序列号尾号；断开两只手柄后按期望顺序重新连接。

## 项目结构

```text
.
├── Sources/DualPadMapper/main.swift  # IOHID 读取、映射与菜单栏应用
├── Resources/Info.plist              # macOS 应用元数据与权限说明
├── scripts/build.sh                  # 在临时目录构建、签名、自测、打包
├── scripts/test.sh                   # 内置回归测试
└── .github/workflows/build.yml       # GitHub Actions 构建
```

## 已知限制

- 只支持两只手柄，第三只及之后的设备会被忽略。
- 当前设备匹配规则只包含已实测的 Xbox One S 蓝牙型号。
- 发布包使用 ad-hoc 临时签名，未经过 Apple Developer ID 签名和公证，因此首次启动会出现 macOS 安全提示。
- 游戏更新或自定义键位可能需要同步修改映射。

## 参与贡献

欢迎提交 Issue 或 Pull Request，并附上 macOS 版本、手柄名称、VID/PID、连接方式和 `/tmp/DualPadMapper-status.txt` 内容。请不要公开完整蓝牙地址或序列号。

## 许可证

[MIT License](LICENSE)
