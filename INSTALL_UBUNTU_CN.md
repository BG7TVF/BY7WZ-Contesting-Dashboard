# BY7WZ 定制版 Contesting Dashboard — Ubuntu 部署说明

本文档对应 `install_ubuntu.sh` 全自动部署脚本（Ubuntu 24.04 LTS）。
脚本幂等、可重复运行，既可用于全新安装，也可用于修复损坏的安装。

---

## 一键安装 / 更新 / 修复

在 Ubuntu 服务器上执行两条命令即可（脚本自动从 GitHub 拉取项目文件，无需上传目录）：

**全新安装 / 修复损坏的安装**（完整重装）：

```bash
curl -fsSL https://raw.githubusercontent.com/BG7TVF/BY7WZ-Contesting-Dashboard/master/install_ubuntu.sh -o /tmp/install_ubuntu.sh
sudo bash /tmp/install_ubuntu.sh -f
```

**仅更新代码**（保留数据库与现有配置）：把上面的 `-f` 换成 `-u`。

**自动检测**（已有安装时交互询问选择 修复/更新）：去掉 `-f` / `-u` 参数。

> 提示：
> - 采用"先下载再执行"，兼容 bash / dash 等任意 shell 与精简系统，不依赖 `/dev/fd` 进程替换。
> - URL **不要加反引号**：反引号是 bash 的命令替换，会把 URL 当命令执行，报 `/dev/fd/63: No such file or directory` 和 `curl: (23) Failure writing output to destination`。
> - 不要用 `curl ... | bash`，它会占用标准输入，脚本的交互问答将失效。
> - GitHub 访问困难时，可把 URL 换成镜像前缀（例如 `https://ghproxy.com/https://raw.githubusercontent.com/...`），或在脚本内通过 `GIT_REPO` 环境变量指定镜像仓库。
> - npm 源默认使用国内 npmmirror，海外服务器可用 `NPM_REGISTRY=https://registry.npmjs.org` 覆盖。
> - 系统全量升级默认**不做**（约 1GB 下载且与本项目无关）。确需升级时加 `--upgrade`。

---

## 三种运行模式

| 模式 | 命令 | 用途 |
| --- | --- | --- |
| 完整安装/修复 | `-f` / `--full` | 从零部署，或完整重装修复损坏的安装 |
| 仅更新 | `-u` / `--update` | 拉取最新项目文件并更新依赖，**保留数据库与现有配置** |
| 交互模式 | 无参数 | 已有安装时询问选择修复或更新 |

---

## 安装后必做的配置

安装完成后浏览器打开 `http://<服务器IP>:1880/`（管理界面）和 `http://<服务器IP>:1880/ui/`（仪表盘）。

以下全局配置保存在内存中，**Node-RED 重启后会丢失，需要重新设置**：

1. **比赛类别与 QSO 速率统计**：在仪表盘 `Configuration & Resets` 页面，
   - 用下拉框选择 Contest Category（如 `so1r`，选中后 Radio 1 表格才有数据）；
   - 用下拉框选择 Q's/Hr 的统计维度（`radio`）。
   - 注意：下拉框显示的默认值只是显示假象，必须**实际选择一次**才会写入全局变量。
2. **电台名（Radio 1/2 表格与 Radio Info 页依赖）**：在 `Configuration & Resets` 页面的
   `1 Computer Name Input` 中填入操作计算机名并提交，然后在 Radio1 下拉框中选中它。

### N1MM Logger+ 广播设置

在 N1MM 的 `Config > Configure Ports... > Broadcasts` 中打开 Radio / Score / Contacts 广播，
地址指向 Node-RED 服务器 IP。端口对应关系以 flow.json 中 UDP 节点配置为准（默认 Radio 12060）。

### 重要：Windows 计算机名必须为纯 ASCII

N1MM 的 UDP 广播按**字符数**计算发送长度，当 Windows 计算机名包含非 ASCII 字符（如中文）时，
每字符会少发 2 字节，导致 XML 广播被截断，仪表盘持续出现 `Unclosed root tag` 之类的解析报错。
本版本 flow.json 已内置标签栈补全修复（可容忍截断包），但**根治方法是把计算机名改为纯英文**。

---

## 本定制版相对上游（kylekrieg/Node-Red-Contesting-Dashboard）的改动

- 支持 SO1R 单电台模式（比赛类别 `so1r`）
- N1MM UDP 广播截断的标签栈补全修复（Radio / Score / Contacts 三条链）
- 地图定制：Esri Satellite 唯一底图、Day/Night（加浓）与 Heatmap 默认开启、
  自动缩放至全部标记（新标记时自动 fit，不打扰手动浏览）、单世界显示（无灰边、不越过日更线）、
  Ruler / Auto Pan 默认关闭
- 部署/页面刷新后 2 秒内自动恢复全部地图设置
- Ubuntu 24.04 全自动部署脚本（本文档）

---

## 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| `bash: /dev/fd/63: No such file or directory` + `curl: (23)` | URL 被反引号包裹（bash 命令替换），或当前 shell 不支持进程替换 → 改用"先下载再执行" |
| `Node-RED v4.x no longer supports Nodejs 18` / `无法生成 settings.js` | Ubuntu 24.04 自带 Node 18，Node-RED 4/5 需要 Node 20+ → 新版脚本会自动加 `--node22` 升级；也可手动执行 `--node22` |
| `E: Failed to fetch ... Connection timed out` / `Network is unreachable` | 服务器到 Ubuntu 源网络不稳定或 IPv6 不可达 → 脚本已自动重试并在失败后强制 IPv4；仍失败可换国内 apt 源后重跑 |
| Radio 1/2 表格 Mode/Freq/Status 不显示 | 未设置 global.category / PC1 → 见"安装后必做的配置" |
| 调试面板持续报 `Unclosed root tag` | Windows 计算机名含中文导致广播截断 → 改纯英文计算机名 |
| 重启后表格/地图配置丢失 | 全局变量存内存，属正常现象 → 重新选择一次 |
| 更新后想保留 QSO 记录 | 使用 `-u` 更新模式，脚本不会动数据库 |
