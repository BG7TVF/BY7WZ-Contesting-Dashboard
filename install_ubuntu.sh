#!/usr/bin/env bash
###############################################################################
# Node-RED Contesting Dashboard - Ubuntu 24.04 LTS 全自动部署脚本
#
# 功能：从零部署 N1MM/TR4W 业余无线电比赛实时仪表盘
# 用法：上传本脚本到 Ubuntu 24.04 服务器后执行：
#         chmod +x install_ubuntu.sh
#         sudo ./install_ubuntu.sh            # 全新安装
#
# 重复运行（脚本幂等，可反复执行）：
#   sudo ./install_ubuntu.sh            # 检测到已有安装时交互选择 修复/更新
#   sudo ./install_ubuntu.sh -f         # 修复模式：完整重装，修复损坏的安装
#   sudo ./install_ubuntu.sh -u         # 更新模式：仅拉取最新项目文件并更新依赖
#                                       #   （保留数据库与现有配置）
#
# 项目文件自动从 GitHub 拉取，无需本地上传项目目录。
# 详细说明见 INSTALL_UBUNTU_CN.md
###############################################################################

set -euo pipefail
IFS=$'\n\t'

############################### 可配置项（也可用同名环境变量覆盖） #############

# 项目 Git 仓库地址（BY7WZ 定制版，含 SO1R 支持等修复）。
# GitHub 访问困难时可改用镜像，例如：
#   GIT_REPO="https://ghproxy.com/https://github.com/BG7TVF/BY7WZ-Contesting-Dashboard.git"
GIT_REPO="${GIT_REPO:-https://github.com/BG7TVF/BY7WZ-Contesting-Dashboard.git}"

# npm 源。国内默认 npmmirror（官方源 registry.npmjs.org 实测超时）；
# 海外服务器可改为：https://registry.npmjs.org
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

# 强制指定 Node-RED 运行用户（默认自动检测：已有服务配置 > sudo 调用者）
NR_USER="${NR_USER:-}"

# 运行模式：full（完整安装/修复）或 update（仅更新项目文件）。
# 可用命令行参数 -f/--full、-u/--update 或环境变量 MODE 指定；
# 未指定且检测到已有安装时会交互询问。
MODE="${MODE:-}"
# 是否顺带升级系统软件包（默认关闭：全量升级要下载约 1GB，
# 网络不佳时会中断整个安装）。需要时加 --upgrade 或设 UPGRADE_SYSTEM=1。
UPGRADE_SYSTEM="${UPGRADE_SYSTEM:-0}"
for arg in "$@"; do
    case "$arg" in
        -f|--full|--repair) MODE="full" ;;
        -u|--update)        MODE="update" ;;
        --upgrade)          UPGRADE_SYSTEM="1" ;;
        -h|--help)
            echo "用法: sudo $0 [-f|--full 修复模式 | -u|--update 更新模式] [--upgrade 顺带升级系统]"
            exit 0
            ;;
        *) ;;  # 忽略未知参数
    esac
done

################################################################################
# 日志与工具函数
################################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
STEP=0
TOTAL_STEPS=10

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step() {
    STEP=$((STEP+1))
    echo ""
    echo -e "${CYAN}======================================================================${NC}"
    echo -e "${CYAN}  步骤 ${STEP}/${TOTAL_STEPS}: $1${NC}"
    echo -e "${CYAN}======================================================================${NC}"
}

trap 'log_error "脚本在第 $LINENO 行执行失败，安装中断。请查看上方输出排查。"' ERR

# 带重试的 apt update；首次失败后改用 IPv4（部分 VPS/云主机 IPv6 不可达，
# 表现为 "Cannot initiate the connection ... Network is unreachable"）
apt_update() {
    local i
    for i in 1 2 3; do
        apt-get update && return 0
        log_warn "apt-get update 失败，5 秒后重试 ($i/3)..."
        sleep 5
    done
    log_warn "改用 IPv4 重试 apt-get update（忽略 IPv6 不可达问题）..."
    apt-get -o Acquire::ForceIPv4=true update
}

# 带重试的 apt install；--fix-missing 可跳过个别下载失败的包
apt_install() {
    local i
    for i in 1 2 3; do
        apt-get install -y --fix-missing "$@" && return 0
        log_warn "apt-get install 失败，5 秒后重试 ($i/3)..."
        sleep 5
        apt-get -o Acquire::ForceIPv4=true update >/dev/null 2>&1 || true
    done
    return 1
}

# 带重试下载到文件（不依赖 bash 进程替换 /dev/fd，任何精简系统都适用）
fetch_file() {
    local url="$1" out="$2" i
    for i in 1 2 3; do
        if curl -fsSL --connect-timeout 20 --retry 2 -o "$out" "$url" && [[ -s "$out" ]]; then
            return 0
        fi
        log_warn "下载失败，5 秒后重试 ($i/3): $url"
        sleep 5
    done
    return 1
}

# 从现有 nodered.service 中读取运行用户（保证重装/续装时一致）
detect_target_user() {
    if [[ -n "$NR_USER" ]]; then TARGET_USER="$NR_USER"; return; fi
    local f
    for f in /etc/systemd/system/nodered.service /lib/systemd/system/nodered.service /usr/lib/systemd/system/nodered.service; do
        if [[ -f "$f" ]] && grep -q '^User=' "$f"; then
            TARGET_USER="$(grep '^User=' "$f" | head -1 | cut -d= -f2)"
            SERVICE_FILE="$f"
            return
        fi
    done
    TARGET_USER="${SUDO_USER:-$USER}"
}

recompute_paths() {
    TARGET_HOME="$(eval echo ~"$TARGET_USER")"
    NR_DIR="$TARGET_HOME/.node-red"
    DB_PATH="$TARGET_HOME/qsos"
    SETTINGS_JS="$NR_DIR/settings.js"
}

################################################################################
# 前置检查
################################################################################

if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 或 sudo 运行本脚本：sudo ./install_ubuntu.sh"
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || log_warn "本脚本针对 Ubuntu 设计，当前系统: ${ID:-unknown}"
fi

# 脚本依赖 systemd 管理 Node-RED 服务；容器/精简系统里没有 systemd 时提前明确报错
if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    log_error "当前环境没有运行 systemd（常见于 Docker/WSL1 容器），无法管理 nodered 服务。"
    log_error "请在普通 Ubuntu 24.04 主机或支持 systemd 的容器中运行。"
    exit 1
fi

SERVICE_FILE=""
detect_target_user
recompute_paths

echo "======================================================================"
echo " Node-RED Contesting Dashboard - Ubuntu 24.04 自动部署"
echo "======================================================================"
log_info "运行用户   : $TARGET_USER"
log_info "Node-RED 目录: $NR_DIR"
log_info "数据库路径 : $DB_PATH"
log_info "npm 源     : $NPM_REGISTRY"
log_info "项目仓库   : $GIT_REPO"

# 运行模式判定：未指定时，检测到已有安装则交互询问
if [[ -z "$MODE" ]]; then
    if command -v node-red >/dev/null 2>&1 || [[ -f "$NR_DIR/flows.json" ]]; then
        echo ""
        echo "  检测到已有安装，请选择运行模式："
        echo "    1) 修复模式 - 完整重装（修复损坏的安装，数据库会先备份）"
        echo "    2) 更新模式 - 仅拉取最新项目文件并更新依赖（保留数据库与配置）"
        read -rp "  请选择 [1/2，默认 2]: " choice || choice=""
        case "${choice:-2}" in
            1) MODE="full" ;;
            *) MODE="update" ;;
        esac
    else
        MODE="full"
    fi
fi

# 更新模式但 Node-RED 核心不存在时，自动回退为完整安装
if [[ "$MODE" == "update" ]] && ! command -v node-red >/dev/null 2>&1; then
    log_warn "未检测到 Node-RED 核心，自动切换为完整安装/修复模式"
    MODE="full"
fi

if [[ "$MODE" == "update" ]]; then
    log_info "运行模式   : 更新模式（保留数据库与现有配置）"
else
    log_info "运行模式   : 完整安装/修复模式"
fi

START_TS=$(date +%s)

################################################################################
step "更新系统并安装基础依赖"
################################################################################
# apt update 失败不直接中止：可能已有本地索引，后面的 install 仍可成功
apt_update || log_warn "apt-get update 多次失败，将尝试使用现有软件包索引继续"

# 系统全量升级可选（--upgrade）：约 1GB 下载，网络差时极易中断，
# 且失败与仪表盘本身无关，因此默认不做、失败也不中止
if [[ "$UPGRADE_SYSTEM" == "1" ]]; then
    log_info "按请求执行系统软件包升级（--upgrade）..."
    apt-get full-upgrade -y || log_warn "系统升级未完成（网络或依赖问题），继续安装本项目"
    apt-get clean || true
fi

if [[ "$MODE" == "full" ]]; then
    apt_install git sqlite3 build-essential curl ca-certificates \
        || { log_error "基础依赖安装失败，请检查网络/apt 源后重试"; exit 1; }
    log_info "基础依赖安装完成 (git / sqlite3 / build-essential / curl)"
else
    apt_install git sqlite3 curl ca-certificates \
        || { log_error "基础依赖安装失败，请检查网络/apt 源后重试"; exit 1; }
    log_info "基础依赖检查完成（更新模式跳过系统升级）"
fi

# 关键命令缺失时给出明确提示，避免后续步骤以难懂的错误中断
for cmd in git sqlite3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "缺少必需命令: $cmd"; exit 1; }
done

################################################################################
step "配置 npm 镜像源（解决 registry.npmjs.org 超时问题）"
################################################################################
# 全新系统上 npm 尚未安装（Node.js 由下一步的官方安装器安装），
# 此时跳过配置，等核心装好后再设置，避免 "npm: command not found" 中断
if command -v npm >/dev/null 2>&1; then
    npm config set registry "$NPM_REGISTRY" || true
    npm config set fetch-retries 5 || true
    npm config set fetch-retry-maxtimeout 120000 || true
    log_info "root 用户 npm 源: $(npm config get registry 2>/dev/null || echo "$NPM_REGISTRY")"
else
    log_info "npm 尚未安装，将在安装 Node-RED 核心后配置镜像源"
fi

################################################################################
step "安装 Node-RED 核心（已安装则自动跳过）"
################################################################################
if command -v node-red >/dev/null 2>&1; then
    log_info "检测到 Node-RED 已安装，跳过核心安装"
    node-red --version 2>/dev/null || true
else
    log_info "调用 Node-RED 官方安装器（约 10-20 分钟，请耐心等待）..."
    NODERED_INSTALLER="/tmp/update-nodejs-and-nodered"
    if fetch_file "https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered" "$NODERED_INSTALLER"; then
        bash "$NODERED_INSTALLER" --nodered-user="$TARGET_USER" --confirm-root \
            || log_warn "官方安装器返回失败，尝试其他安装方式..."
    else
        log_warn "官方安装器下载失败（GitHub 不可达），尝试其他安装方式..."
    fi

    # 官方安装器即使核心安装失败也返回成功，必须显式验证
    if ! command -v node-red >/dev/null 2>&1; then
        log_warn "Node-RED 核心未就绪，改用 npm 手动安装..."
        if ! command -v npm >/dev/null 2>&1; then
            log_warn "系统缺少 npm，尝试通过 apt 安装 nodejs/npm..."
            apt_install nodejs npm || log_warn "apt 安装 nodejs/npm 失败"
        fi
        if command -v npm >/dev/null 2>&1; then
            npm config set registry "$NPM_REGISTRY" || true
            npm install -g --unsafe-perm --no-audit --no-fund node-red \
                || log_warn "npm 全局安装 node-red 失败"
        fi
    fi

    if ! command -v node-red >/dev/null 2>&1; then
        log_error "Node-RED 核心安装失败。请检查 /var/log/nodered-install.log，或手动重试："
        log_error "  curl -fsSL https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered -o /tmp/nr.sh && bash /tmp/nr.sh --nodered-user=$TARGET_USER --confirm-root"
        exit 1
    fi

    # 核心就绪后 npm 一定存在，补设镜像源供后续依赖安装使用
    npm config set registry "$NPM_REGISTRY" 2>/dev/null || true
    npm config set fetch-retries 5 2>/dev/null || true
    npm config set fetch-retry-maxtimeout 120000 2>/dev/null || true
fi

# 官方安装器可能把服务配置成与预期不同的用户（例如 root），
# 以实际生成的 service 文件为准重新检测，保证后续路径一致
OLD_USER="$TARGET_USER"
detect_target_user
if [[ "$TARGET_USER" != "$OLD_USER" ]]; then
    log_warn "检测到 nodered.service 运行用户为 $TARGET_USER（而非 $OLD_USER），已自动适配"
    recompute_paths
fi

# 用户显式指定了 NR_USER 且与服务文件不一致时，改写服务文件
if [[ -n "$NR_USER" && -n "$SERVICE_FILE" ]]; then
    sed -i "s/^User=.*/User=$NR_USER/; s/^Group=.*/Group=$NR_USER/" "$SERVICE_FILE"
    systemctl daemon-reload
    TARGET_USER="$NR_USER"; recompute_paths
    log_info "已强制 nodered.service 运行用户为 $NR_USER"
fi

systemctl enable nodered.service 2>/dev/null || true
log_info "Node-RED 核心就绪"

################################################################################
step "生成并配置 settings.js（启用 Projects + contextStorage）"
################################################################################

# 更新模式下若已配置 contextStorage 则跳过，避免停服重配
if [[ "$MODE" == "update" && -f "$SETTINGS_JS" ]] && grep -q "contextStorage" "$SETTINGS_JS"; then
    log_info "settings.js 已启用 contextStorage，更新模式跳过配置修改"
else
systemctl stop nodered.service 2>/dev/null || true
sleep 1
mkdir -p "$NR_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME" 2>/dev/null || true
mkdir -p "$NR_DIR" && chown -R "$TARGET_USER:$TARGET_USER" "$NR_DIR"

# settings.js 只在 Node-RED 首次启动时生成；不存在则短暂启动一次生成
if [[ ! -f "$SETTINGS_JS" ]]; then
    log_warn "settings.js 不存在，短暂启动 Node-RED 以生成默认配置..."
    su - "$TARGET_USER" -c "node-red >/dev/null 2>&1" &
    BOOT_PID=$!
    for _ in $(seq 1 30); do [[ -f "$SETTINGS_JS" ]] && break; sleep 1; done
    kill "$BOOT_PID" 2>/dev/null || true
    pkill -u "$TARGET_USER" -f "node-red" 2>/dev/null || true
    wait "$BOOT_PID" 2>/dev/null || true
fi
[[ -f "$SETTINGS_JS" ]] || { log_error "无法生成 settings.js"; exit 1; }

BACKUP="$SETTINGS_JS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS_JS" "$BACKUP"
log_info "已备份原配置: $BACKUP"

# 用 Node.js 修改配置（比 sed 范围匹配可靠，避免改坏文件）：
#  1) 取消注释 contextStorage 块（按花括号配平，兼容缩进/空格差异）
#  2) 启用 editorTheme.projects.enabled
#  3) 若完全没有 contextStorage，则在 module.exports 末尾插入
node -e "
const fs = require('fs');
const file = '$SETTINGS_JS';
let lines = fs.readFileSync(file, 'utf8').split('\n');
let out = [], inBlock = false, depth = 0, hasCommentedCS = false;
for (const raw of lines) {
    const t = raw.trim();
    if (!inBlock && /^\/\/\s*contextStorage:/.test(t)) { inBlock = true; hasCommentedCS = true; }
    if (inBlock) {
        const u = raw.replace(/^[ \t]*\/\/[ \t]?/, '');
        out.push(u);
        depth += (u.match(/\{/g) || []).length - (u.match(/\}/g) || []).length;
        if (depth <= 0) inBlock = false;
    } else {
        out.push(raw);
    }
}
let text = out.join('\n');
if (!hasCommentedCS && !/^\s*contextStorage:/m.test(text)) {
    const idx = text.lastIndexOf('}');
    text = text.slice(0, idx) + '    contextStorage: { default: { module: \"localfilesystem\" } },\n' + text.slice(idx);
}
text = text.replace(/(projects\s*:\s*\{[\s\S]{0,400}?enabled\s*:\s*)false/, function (m, p) { return p + 'true'; });
fs.writeFileSync(file, text);
"

# 语法校验，失败则自动还原备份
if node --check "$SETTINGS_JS" 2>/dev/null; then
    chown "$TARGET_USER:$TARGET_USER" "$SETTINGS_JS"
    log_info "settings.js 配置完成并通过语法校验"
else
    log_error "settings.js 修改后语法校验失败，已自动还原备份"
    cp "$BACKUP" "$SETTINGS_JS"
    exit 1
fi
fi # 更新模式跳过门控结束

################################################################################
step "创建 qsos SQLite 数据库"
################################################################################
# flow.json 中数据库使用相对路径 qsos，最终解析到服务 WorkingDirectory（家目录）
if [[ -f "$DB_PATH" ]]; then
    cp "$DB_PATH" "$DB_PATH.bak.$(date +%Y%m%d%H%M%S)"
    log_warn "已存在 $DB_PATH，已备份"
fi

sqlite3 "$DB_PATH" <<'SQLEOF'
CREATE TABLE IF NOT EXISTS qsos(
  "app" TEXT, "contestname" TEXT, "contestnr" TEXT, "timestamp" TEXT,
  "mycall" TEXT, "band" TEXT, "rxfreq" TEXT, "txfreq" TEXT, "operator" TEXT,
  "mode" TEXT, "call" TEXT, "countryprefix" TEXT, "wpxprefix" TEXT,
  "stationprefix" TEXT, "continent" TEXT, "snt" TEXT, "sntnr" TEXT,
  "rcv" TEXT, "rcvnr" TEXT, "gridsquare" TEXT, "exchange1" TEXT,
  "section" TEXT, "comment" TEXT, "qth" TEXT, "name" TEXT, "power" TEXT,
  "misctext" TEXT, "zone" TEXT, "prec" TEXT, "ck" TEXT,
  "ismultiplier1" TEXT, "ismultiplier2" TEXT, "ismultiplier3" TEXT,
  "points" TEXT, "radionr" TEXT, "run1run2" TEXT, "RoverLocation" TEXT,
  "RadioInterfaced" TEXT, "NetworkedCompNr" TEXT, "IsOriginal" TEXT,
  "NetBiosName" TEXT, "IsRunQSO" TEXT, "StationName" TEXT, "ID" TEXT,
  "IsClaimedQso" TEXT, "lat" TEXT, "lon" TEXT, "isbusted" TEXT, "distance" TEXT
);
CREATE TABLE IF NOT EXISTS radio(
  "timestamp" TEXT, "app" TEXT, "StationName" TEXT, "RadioNr" TEXT,
  "Freq" TEXT, "TXFreq" TEXT, "Mode" TEXT, "OpCall" TEXT, "IsRunning" TEXT,
  "FocusEntry" TEXT, "EntryWindowHwnd" TEXT, "antenna" TEXT, "Rotors" TEXT,
  "FocusRadioNr" TEXT, "IsStereo" TEXT, "IsSplit" TEXT, "ActiveRadioNr" TEXT,
  "IsTransmitting" TEXT, "FunctionKeyCaption" TEXT, "RadioName" TEXT,
  "AuxAntSelected" TEXT, "AuxAntSelectedName" TEXT
);
CREATE TABLE IF NOT EXISTS spots(
  "timestamp" TEXT, "call" TEXT type UNIQUE, "lat" TEXT, "lon" TEXT, "grid" TEXT
);
CREATE INDEX IF NOT EXISTS call_idx on spots(call);
SQLEOF

chown "$TARGET_USER:$TARGET_USER" "$DB_PATH"
chmod 664 "$DB_PATH"
log_info "数据库初始化完成: $DB_PATH (qsos / radio / spots 三张表)"

################################################################################
step "配置 systemd 服务（WorkingDirectory 指向数据库所在目录）"
################################################################################
OVERRIDE_DIR="/etc/systemd/system/nodered.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE_DIR/workingdir.conf" <<EOF
[Service]
WorkingDirectory=$TARGET_HOME
EOF
systemctl daemon-reload
log_info "systemd override 已创建: WorkingDirectory=$TARGET_HOME"

################################################################################
step "从 GitHub 拉取项目文件"
################################################################################
CLONE_DIR="$(mktemp -d)"
CLONE_OK=0
for i in 1 2 3; do
    if git clone --depth 1 "$GIT_REPO" "$CLONE_DIR/repo"; then CLONE_OK=1; break; fi
    log_warn "git clone 失败，5 秒后重试 ($i/3)..."
    sleep 5
done
[[ "$CLONE_OK" -eq 1 ]] || { log_error "无法从 $GIT_REPO 获取项目文件"; exit 1; }

# 覆盖前备份现有流程文件（更新/修复模式可回滚）
[[ -f "$NR_DIR/flows.json" ]] && cp "$NR_DIR/flows.json" "$NR_DIR/flows.json.bak.$(date +%Y%m%d%H%M%S)" && log_info "已备份现有 flows.json" || true

cp "$CLONE_DIR/repo/flow.json" "$NR_DIR/flows.json"
[[ -f "$CLONE_DIR/repo/flow_cred.json" ]] && cp "$CLONE_DIR/repo/flow_cred.json" "$NR_DIR/flows_cred.json"
cp "$CLONE_DIR/repo/package.json" "$NR_DIR/package.json"
rm -rf "$CLONE_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$NR_DIR"
log_info "flows.json / package.json 已部署到 $NR_DIR"

################################################################################
step "安装 Dashboard 节点依赖（15 个 npm 包，自动重试）"
################################################################################
# 给目标用户也配置镜像源（su - 切换后读取的是目标用户的 npm 配置）
if [[ "$TARGET_USER" != "root" ]]; then
    su - "$TARGET_USER" -c "npm config set registry '$NPM_REGISTRY'; npm config set fetch-retries 5; npm config set fetch-retry-maxtimeout 120000"
fi

ATTEMPT=1
until su - "$TARGET_USER" -c "cd '$NR_DIR' && npm install"; do
    if [[ $ATTEMPT -ge 3 ]]; then
        log_error "npm install 重试 $ATTEMPT 次仍失败。可手动重试："
        log_error "  sudo su - $TARGET_USER -c \"cd $NR_DIR && npm install\""
        exit 1
    fi
    ATTEMPT=$((ATTEMPT+1))
    log_warn "npm install 失败（网络抖动），5 秒后重试 (第 $ATTEMPT/3 次)..."
    sleep 5
done
log_info "节点依赖安装完成"

################################################################################
step "启动 Node-RED 并验证"
################################################################################
systemctl restart nodered.service   # restart 对全新/已运行场景都适用，确保加载最新 flows.json
sleep 5

if ! systemctl is-active --quiet nodered.service; then
    log_error "Node-RED 启动失败，最近日志如下："
    journalctl -u nodered -n 30 --no-pager || true
    exit 1
fi

if ss -tln | grep -q ':1880'; then
    log_info "端口 1880 已监听"
else
    log_warn "端口 1880 暂未监听，服务可能仍在初始化，稍后可执行: ss -tln | grep 1880"
fi

################################################################################
step "部署完成"
################################################################################
SERVER_IP=$(hostname -I | awk '{print $1}')
ELAPSED=$(( $(date +%s) - START_TS ))

cat <<EOF
======================================================================
 部署成功! 总耗时约 $((ELAPSED/60)) 分 $((ELAPSED%60)) 秒
 运行模式: $([ "$MODE" == "update" ] && echo "更新模式" || echo "完整安装/修复模式")
======================================================================

 Node-RED 编辑器 : http://${SERVER_IP}:1880
 仪表盘界面      : http://${SERVER_IP}:1880/ui

 运行用户        : $TARGET_USER
 数据库          : $DB_PATH
 配置目录        : $NR_DIR

 后续配置:
 1) N1MM -> Config -> Broadcast Data 勾选 Radio/Contacts/Score/
    External Callsign Lookup，目标地址填:
       Radio/Contacts/Lookup -> ${SERVER_IP}:12060/12061
       Score                 -> ${SERVER_IP}:12062 (仅主台勾选!)
 2) 每次比赛前在仪表盘 Configuration & Resets 页点击
    "DELETE ALL QSOS AND CLEAR STATS" 清空数据库
 3) 首次打开编辑器若弹出 Projects 引导，选择跳过即可

 常用命令:
   sudo systemctl status nodered     # 查看状态
   sudo systemctl restart nodered    # 重启
   sudo journalctl -u nodered -f     # 实时日志
   ss -ulnp | grep -E '1206[012]'    # 检查 UDP 数据端口
======================================================================
EOF
