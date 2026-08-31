#!/bin/bash
# restore.sh — Bot 主机一键恢复（网页端可直接拉取本脚本执行）
#
# 用法:
#   bash restore.sh <备份包路径或URL> [passphrase文件路径] [--force] [--dry-run [目标目录]]
#
# 典型场景（沙箱被清空后的全新容器里，两条命令完成恢复）:
#   curl -fsSL <你的发布地址>/restore.sh -o restore.sh
#   bash restore.sh <备份包URL或路径> [passphrase文件]
#
# 能力:
#   - 自动补齐基础依赖（curl/gpg/git/python3-venv/tmux，需免密 sudo）
#   - 解密(AES256)并校验备份包 → 还原 hermes 配置/记忆/技能、CLIProxyAPI 全套、
#     隧道保活脚本、SSH 钥匙、shell 配置
#   - 重建 hermes-agent 代码（git clone + 指定 commit + venv）
#   - 解出 CLIProxyAPI 二进制并启动全套服务与隧道守护链
#
set -u

BUNDLE="${1:-}"
PASSFILE="${2:-}"
FORCE=0
DRYRUN=0
DRYTARGET="/tmp/bot-restore-verify"
if [ $# -ge 2 ]; then shift 2; else shift $#; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRYRUN=1; if [ -n "${2:-}" ] && [ "${2#-}" != "$2" ]; then DRYTARGET="$2"; shift; fi ;;
    *) echo "未知参数: $1"; exit 64 ;;
  esac
  shift
done

say() { echo "[restore $(date '+%T')] $*"; }
die() { echo "[restore] ❌ $*"; exit 1; }

[ -n "$BUNDLE" ] || { sed -n '2,20p' "$0"; exit 64; }

# ---------- 0) 依赖 ----------
need_pkgs=""
for c in curl gpg git tar; do command -v $c >/dev/null || need_pkgs="$need_pkgs ${c}"; done
command -v python3 >/dev/null || need_pkgs="$need_pkgs python3"
python3 -c "import venv" 2>/dev/null || need_pkgs="$need_pkgs python3-venv"
command -v tmux >/dev/null || need_pkgs="$need_pkgs tmux"
if [ -n "$need_pkgs" ]; then
  say "安装缺失依赖:$need_pkgs"
  if sudo -n apt-get update -qq 2>/dev/null && sudo -n apt-get install -y -qq $need_pkgs 2>/dev/null; then
    say "依赖安装完成"
  else
    say "⚠️ 自动安装失败（可能无 sudo），请手动安装后重跑: apt-get install -$need_pkgs"
  fi
fi
command -v gpg >/dev/null || die "缺少 gpg 且无法自动安装"

# ---------- 1) 获取备份包 ----------
TMP=/tmp/bot-restore.$$
mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
case "$BUNDLE" in
  http://*|https://*)
    if [[ "$BUNDLE" == *.part-00 ]]; then
      # 多分卷: URL 指向 .part-00, 依次拉取合并
      PREFIX="${BUNDLE%.part-*}.part-"
      say "下载备份包(分卷)..."
      : > "$TMP/bundle.gpg"
      i=0
      while curl -fL --retry 3 -o "$TMP/p.$(printf '%02d' $i)" "$PREFIX$(printf '%02d' $i)" 2>/dev/null; do
        cat "$TMP/p.$(printf '%02d' $i)" >> "$TMP/bundle.gpg"; i=$((i+1))
      done
      [ $i -gt 0 ] || die "分卷下载失败"
    else
      say "下载备份包..."
      curl -fL --retry 3 -o "$TMP/bundle.gpg" "$BUNDLE" || die "下载失败: $BUNDLE"
    fi
    BFILE="$TMP/bundle.gpg"
    ;;
  *) [ -f "$BUNDLE" ] || die "找不到备份包: $BUNDLE"; BFILE="$BUNDLE" ;;
esac

# 本地分卷合并
if [[ "$BFILE" == *.part-00 ]] || ls "$BFILE".part-* >/dev/null 2>&1; then
  cat $(ls "$BFILE".part-* 2>/dev/null | sort) > "$TMP/bundle.gpg"; BFILE="$TMP/bundle.gpg"
fi

# ---------- 2) 解密 ----------
DEC="$TMP/bundle.tar.gz"
say "解密..."
if [ -n "$PASSFILE" ] && [ -f "$PASSFILE" ]; then
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASSFILE" \
      -d -o "$DEC" "$BFILE" 2>/dev/null || die "解密失败（passphrase 文件错误？）"
elif [ -n "${RESTORE_PASS:-}" ]; then
  printf '%s' "$RESTORE_PASS" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 -d -o "$DEC" "$BFILE" 2>/dev/null || die "解密失败（RESTORE_PASS 错误？）"
else
  echo -n "请输入备份口令: "; read -rs P; echo
  printf '%s' "$P" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 -d -o "$DEC" "$BFILE" 2>/dev/null || die "解密失败（口令错误？）"
fi
[ -s "$DEC" ] || die "解密产物为空"

# ---------- 3) 解包 ----------
say "解包..."
mkdir -p "$TMP/x"
tar -C "$TMP/x" -xzf "$DEC" || die "tar 解包失败"
X="$TMP/x"
[ -f "$X/manifest.txt" ] && say "备份时间/指纹:" && grep -E "^(created|hostname|egress_ip|bore_port|hermes_commit)" "$X/manifest.txt" | sed 's/^/    /'

if [ "$DRYRUN" = 1 ]; then
  say "=== 演练模式: 校验完整性并预览还原映射（不改动系统） ==="
  (cd "$X" && sha256sum -c --quiet manifest.sha256 2>/dev/null) && say "✅ 包内文件校验全部通过" || say "⚠️ 部分文件校验失败"
  echo "---- 还原映射 ----"
  echo "  hermes-config/*    -> ~/.hermes/  (config/SOUL/记忆/技能/state.db)"
  echo "  CLIProxyAPI/*      -> ~/CLIProxyAPI/ (+从发布包解出二进制)"
  echo "  cpa-tools/*        -> ~/CLIProxyAPI/tools/ (原 /tmp/cpa-*)"
  echo "  bore/*             -> ~/.bore/ (隧道保活全家桶)"
  echo "  dot-ssh/*          -> ~/.ssh/"
  echo "  home-files/*       -> ~/ (.bashrc 等)"
  echo "  system/*           -> ~/.local/bin/bore, /usr/local/bin/tailscale-watchdog.sh"
  echo "  skills:  $(find $X/hermes-config/skills -maxdepth 1 -mindepth 1 2>/dev/null | wc -l) 个"
  echo "  包大小:  $(du -h "$DEC" | cut -f1)"
  say "演练结束。正式恢复请去掉 --dry-run。"
  exit 0
fi

# ---------- 4) 安全检查 ----------
HOME_DIR=${HOME:-/home/box}
if [ "$FORCE" != 1 ]; then
  if [ -e "$HOME_DIR/.hermes/config.yaml" ] || [ -e "$HOME_DIR/.ssh/id_tunnel_ed25519" ]; then
    die "目标机已存在 hermes 配置或 SSH 钥匙（避免覆盖）。确认要覆盖请加 --force"
  fi
fi

# ---------- 5) 还原文件 ----------
say "还原文件..."
mkdir -p "$HOME_DIR/.hermes"
cp -a "$X/hermes-config/." "$HOME_DIR/.hermes/" 2>/dev/null
mkdir -p "$HOME_DIR/CLIProxyAPI"
cp -a "$X/CLIProxyAPI/." "$HOME_DIR/CLIProxyAPI/" 2>/dev/null
mkdir -p "$HOME_DIR/CLIProxyAPI/tools"
cp -a "$X/cpa-tools/." "$HOME_DIR/CLIProxyAPI/tools/" 2>/dev/null
mkdir -p "$HOME_DIR/.cli-proxy-api"
cp -a "$X/cpa-auth/." "$HOME_DIR/.cli-proxy-api/" 2>/dev/null
chmod 600 "$HOME_DIR/.cli-proxy-api/"*.json 2>/dev/null
mkdir -p "$HOME_DIR/.bore"
cp -a "$X/bore/." "$HOME_DIR/.bore/" 2>/dev/null
rm -rf "$HOME_DIR/.ssh"; cp -a "$X/dot-ssh" "$HOME_DIR/.ssh"
if [ -d "$X/dot-config-gh" ]; then
  mkdir -p "$HOME_DIR/.config/gh"
  cp -a "$X/dot-config-gh/." "$HOME_DIR/.config/gh/" 2>/dev/null
fi
cp -a "$X/home-files/." "$HOME_DIR/" 2>/dev/null
mkdir -p "$HOME_DIR/.local/bin"
[ -f "$X/system/bore" ] && cp -a "$X/system/bore" "$HOME_DIR/.local/bin/bore" && chmod +x "$HOME_DIR/.local/bin/bore"
if [ -f "$X/system/tailscale-watchdog.sh" ] && sudo -n true 2>/dev/null; then
  sudo -n cp -a "$X/system/tailscale-watchdog.sh" /usr/local/bin/ 2>/dev/null
fi
chmod 700 "$HOME_DIR/.ssh"; chmod 600 "$HOME_DIR/.ssh"/id_* 2>/dev/null
chmod 644 "$HOME_DIR/.ssh"/*.pub "$HOME_DIR/.ssh"/authorized_keys "$HOME_DIR/.ssh"/known_hosts* 2>/dev/null
chmod +x "$HOME_DIR/.bore"/*.sh "$HOME_DIR/CLIProxyAPI"/*.sh "$HOME_DIR"/tailscale-*.sh 2>/dev/null
mkdir -p "$HOME_DIR/backup"
cp -a "$X/manifest.txt" "$X/manifest.sha256" "$HOME_DIR/backup/" 2>/dev/null
cp -a "$0" "$HOME_DIR/backup/restore.sh" 2>/dev/null; chmod +x "$HOME_DIR/backup/restore.sh"

# ---------- 6) CPA 二进制（从随包发布 tar.gz 解出） ----------
if [ ! -x "$HOME_DIR/CLIProxyAPI/cli-proxy-api" ] && [ -f "$HOME_DIR/CLIProxyAPI/"CLIProxyAPI_7.2.144_linux_amd64.tar.gz ]; then
  say "解出 CLIProxyAPI 二进制..."
  tar -xzf "$HOME_DIR/CLIProxyAPI/CLIProxyAPI_7.2.144_linux_amd64.tar.gz" -C "$HOME_DIR/CLIProxyAPI" cli-proxy-api \
    && chmod +x "$HOME_DIR/CLIProxyAPI/cli-proxy-api"
fi

# ---------- 7) 重建 hermes-agent 代码 ----------
A="$HOME_DIR/.hermes/hermes-agent"
if [ ! -d "$A" ]; then
  ORIGIN=$(cat "$X/hermes-agent-meta/origin.txt" 2>/dev/null || echo https://github.com/NousResearch/hermes-agent.git)
  COMMIT=$(cat "$X/hermes-agent-meta/commit.txt" 2>/dev/null)
  say "克隆 hermes-agent ($ORIGIN)..."
  git clone -q "$ORIGIN" "$A" || die "git clone 失败（网络？）"
  [ -n "$COMMIT" ] && git -C "$A" checkout -qf "$COMMIT"
  PY=$(command -v python3.11 || command -v python3)
  say "构建 venv 并安装（这可能要几分钟）..."
  if [ -f "$A/setup-hermes.sh" ]; then
    (cd "$A" && bash setup-hermes.sh > "$TMP/setup-hermes.log" 2>&1) \
      || say "⚠️ setup-hermes.sh 未成功，看 $TMP/setup-hermes.log；回退手动 venv..."
  fi
  if [ ! -x "$A/venv/bin/python" ]; then
    (cd "$A" && "$PY" -m venv venv && venv/bin/pip install -q -e . > "$TMP/pip.log" 2>&1) \
      || say "⚠️ venv/pip 安装失败，请查看 $TMP/pip.log 后手动重试"
  fi
fi

# ---------- 8) 启动全家桶 ----------
say "启动服务与隧道守护链..."
cd "$HOME_DIR"
bash "$HOME_DIR/.bore/ensure-daemons.sh" 2>/dev/null
bash "$HOME_DIR/tailscale-ensure.sh" 2>/dev/null
sleep 2
bash "$HOME_DIR/CLIProxyAPI/start.sh" 2>/dev/null
# hermes 前台进程用 tmux 托管（恢复后可 tmux attach -t hermes 查看）
if [ -x "$A/venv/bin/python" ] && ! pgrep -f "hermes-agent/hermes" >/dev/null 2>&1; then
  command -v tmux >/dev/null && tmux new-session -d -s hermes \
    "cd /workspace 2>/dev/null || cd $HOME_DIR; DISPLAY=:2 NO_COLOR=1 $A/venv/bin/python $A/hermes; bash" \
    || ( DISPLAY=:2 NO_COLOR=1 nohup "$A/venv/bin/python" "$A/hermes" >/tmp/hermes.log 2>&1 & )
fi

# ---------- 9) 状态报告 ----------
sleep 5
BORE_PORT=$(grep -oaE "listening at bore\.pub:[0-9]+" "$HOME_DIR/.bore/bore-58548.log" 2>/dev/null | tail -1 | grep -oE "[0-9]+$")
echo
echo "================ 恢复完成 ================"
echo "  隧道:   $([ -n "$BORE_PORT" ] && echo "✅ bore.pub:$BORE_PORT" || echo "⏳ 启动中, 稍后运行 bash ~/backup/../.bore/get-bore-port.sh 查看")"
echo "  CPA:    $(pgrep -f 'cli-proxy-api -config' >/dev/null && echo '✅ 运行中 (127.0.0.1:8317)' || echo '❌ 未运行, 手动: ~/CLIProxyAPI/start.sh')"
echo "  hermes: $(pgrep -f 'hermes-agent/hermes' >/dev/null && echo '✅ 运行中' || echo '⏳ 未运行(venv未就绪?), tmux attach -t hermes / 手动启动')"
echo "  守护链: $(pgrep -f '.bore/self-heal.sh' >/dev/null && echo '✅ self-heal 运行中' || echo '❌ 未运行')"
echo
echo "  恢复后检查清单:"
echo "   1. 新容器出口 IP 已变化 → CPA/各 provider 可能需重新授权或验证"
echo "   2. hermes 的 provider 登录态在 state.db 里, 失效则需重新 OAuth"
echo "   3. 立即做一次新备份: bash ~/backup/bot-backup.sh"
echo "   4. 外部访问: ssh -p $BORE_PORT box@<bore地址>"
echo "=========================================="
