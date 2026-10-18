# Node-RED 业余无线电竞赛实时仪表盘（BY7WZ 定制版）

一个用 Node-RED 编写的多屏业余无线电竞赛实时仪表盘。N1MM Logger+ 等日志软件把电台、分数、QSO、查询等 UDP 广播包发到 Node-RED 服务器，仪表盘实时解析并展示，方便其他队员和线上观众实时跟进比赛进度。适用于 SO1V / SO2V / SO2R / multi-1 / multi-2 / multi-multi 等多种配置，Field Day 等活动同样适用。

> 本仓库是 [kylekrieg/Node-Red-Contesting-Dashboard](https://github.com/kylekrieg/Node-Red-Contesting-Dashboard) 的定制版，在原版基础上加入了 SO1R 支持、N1MM 广播截断修复与多项地图/界面优化，并提供 Ubuntu 一键部署脚本。

## 定制版主要改动

- **SO1R 单电台模式**支持（比赛类别 `so1r`）
- **N1MM UDP 广播截断修复**：Radio / Score / Contacts 三条链内置标签栈补全（可容忍被截断的 XML 包）
- **地图定制**：
  - Esri Satellite 卫星影像为唯一底图
  - Day/Night 昼夜遮罩（加浓对比度）与 Heatmap 默认开启
  - 自动缩放到全部标记完整可见（新标记进入时自动 fit，不打扰手动浏览）
  - 单世界显示（无灰边、不越过日更线，轨迹线在 ±180° 处自动拆分续画）
  - Ruler / Auto Pan 默认关闭，初始位置为本台位置
- **部署/刷新后 2 秒内自动恢复**全部地图设置
- **Ubuntu 24.04 全自动部署脚本**（幂等，支持修复/更新模式）

## 支持的日志软件

| 日志软件 | 兼容性 |
| :--- | :---: |
| [N1MM Logger+](https://n1mmwp.hamdocs.com) | 支持 |
| [TR4W](https://tr4w.net/) | 支持 |
| [DXLog](http://dxlog.net/) | 部分支持 |
| [RumLog](https://dl2rum.de/rumsoft/RUMLog.html) | 部分支持 |
| [N3FJP](https://www.n3fjp.com/) | 暂不支持（需协助开发） |

## 截图

[仪表盘各页面截图（2022 年 3 月）](https://photos.app.goo.gl/J67xuLADBU3CMHYh7)

## 一键安装（Ubuntu 24.04）

在服务器上执行一条命令即可，脚本自动从 GitHub 拉取项目文件，无需上传目录：

**全新安装 / 修复损坏的安装**（完整重装）：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/BG7TVF/BY7WZ-Contesting-Dashboard/master/install_ubuntu.sh) -f
```

**仅更新代码**（保留数据库与现有配置）：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/BG7TVF/BY7WZ-Contesting-Dashboard/master/install_ubuntu.sh) -u
```

**自动检测**（已有安装时交互询问选择修复/更新）：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/BG7TVF/BY7WZ-Contesting-Dashboard/master/install_ubuntu.sh)
```

> 提示：请使用 `bash <(...)`（进程替换）而不是 `curl ... | bash`，后者会占用标准输入导致脚本交互问答失效。GitHub 访问困难时可在脚本内用 `GIT_REPO` 环境变量指定镜像仓库。

## 三种运行模式

| 模式 | 参数 | 用途 |
| --- | --- | --- |
| 完整安装/修复 | `-f` / `--full` | 从零部署，或完整重装修复损坏的安装 |
| 仅更新 | `-u` / `--update` | 拉取最新项目文件并更新依赖，**保留数据库与现有配置** |
| 交互模式 | 无参数 | 已有安装时询问选择修复或更新 |

## 安装后必做的配置

安装完成后浏览器打开 `http://<服务器IP>:1880/`（管理界面）与 `http://<服务器IP>:1880/ui/`（仪表盘）。

以下全局配置保存在内存中，**Node-RED 重启后会丢失，需要重新设置**：

1. **比赛类别与 QSO 速率统计**：在仪表盘 `Configuration & Resets` 页面：
   - 下拉框选择 Contest Category（如 `so1r`，选中后 Radio 1 表格才有数据）；
   - 下拉框选择 Q's/Hr 统计维度（`radio`）。
   - 注意：下拉框显示的默认值只是显示假象，必须**实际选择一次**才会写入全局变量。
2. **电台名**：在 `Configuration & Resets` 页面的 `1 Computer Name Input` 中填入操作计算机名并提交，然后在 Radio1 下拉框中选中它。

### N1MM Logger+ 广播设置

在 N1MM 的 `Config > Configure Ports... > Broadcasts` 中打开 Radio / Score / Contacts 广播，地址指向 Node-RED 服务器 IP。端口对应关系以 flow.json 中 UDP 节点配置为准（默认 Radio 为 12060）。

### 重要：Windows 计算机名必须为纯 ASCII

N1MM 的 UDP 广播按**字符数**计算发送长度，当 Windows 计算机名包含非 ASCII 字符（如中文）时，每字符会少发 2 字节，导致 XML 广播被截断、仪表盘持续出现 `Unclosed root tag` 解析报错。本版本 flow.json 已内置标签栈补全修复（可容忍截断包），但**根治方法是把计算机名改为纯英文**。

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| Radio 1/2 表格 Mode/Freq/Status 不显示 | 未设置 global.category / PC1 → 见"安装后必做的配置" |
| 调试面板持续报 `Unclosed root tag` | Windows 计算机名含中文导致广播截断 → 改纯英文计算机名 |
| Node-RED 重启后表格/地图配置丢失 | 全局变量存内存，属正常现象 → 重新选择一次 |
| 更新后想保留 QSO 记录 | 使用 `-u` 更新模式，脚本不会动数据库 |

## 相关文档

- [INSTALL_UBUNTU_CN.md](/INSTALL_UBUNTU_CN.md) — Ubuntu 部署详细说明（与本文档安装部分一致）

## 提问与交流

欢迎加入 [Node Red for Ham Radio Groups IO 讨论组](https://groups.io/g/nodered-hamradio) 提问（英文）。
