#!/usr/bin/env bash
# setup_ssh.sh — Google Colab / Ubuntu 臨時 SSH 連線工具
#
# Colab Cell：!bash /content/setup_ssh.sh
# 公鑰模式：!bash /content/setup_ssh.sh --pubkey-file /content/my_key.pub
# 僅用 bore：!bash /content/setup_ssh.sh --no-cloudflared
# 查詢 / 停止：!bash /content/setup_ssh.sh --status 或 --stop
#
# 預設：colab 帳號 + 隨機 32 字元密碼；兩種隧道各自嘗試。
# 公鑰模式：停用密碼登入；允許 root 公鑰登入，--no-root 可關閉。
# 私鑰留在自己的電腦，只把 .pub 公鑰交給 Colab。
# 重跑會重建本腳本的連線，現有隧道連線會中斷、網址/port 可能改變。
# 不會猜測關閉舊版腳本或其他服務的程序；如有 port 衝突請先停止舊服務。
#
# 適用 Colab 的 Debian/Ubuntu Linux，須 root；使用系統 Python 3 管理背景程序。
# 這是單一 .sh 檔，不需要另存 Python 檔。狀態、日誌均在 /run/colab-ssh。
# Colab runtime 重建後需重新執行；SSH keepalive 不會延長 runtime 壽命。
# 無正數運算單元餘額的免費 Colab runtime 禁止 SSH 等遠端控制；
# 付費且保持正數餘額仍受其他使用規則與 runtime 時限約束。
# https://research.google.com/colaboratory/faq.html
# https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/

set -Eeuo pipefail
set +x  # 不讓命令追蹤將密碼印出。
umask 077

STATE_DIR=/run/colab-ssh
SSHD_CONF="$STATE_DIR/sshd_config"
BORE_VERSION=v0.6.0
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-colab}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
export -n SSH_PASSWORD 2>/dev/null || true
PUBKEYS=(); PUBKEY_FILES=()
ENABLE_BORE=1; ENABLE_CLOUDFLARED=1; PERMIT_ROOT=1
USE_PASSWORD=1; SHOW_PASSWORD=0; GENERATED=0
ACTION=start; WAIT_SECONDS=45; SUCCESS=0; STARTED=0
WORK_DIR=""; BORE_PORT=""; CF_HOST=""; LOGIN_USER=""
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin:/usr/sbin:/sbin"

info() { printf '%s\n' "$*"; }
warn() { printf '提醒：%s\n' "$*" >&2; }
die() { printf '錯誤：%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
用法：bash setup_ssh.sh [選項]
  -u, --user USER        一般登入帳號，預設 colab；不可指定 root
  -p, --password PASS    指定密碼（優先使用環境變數 SSH_PASSWORD，避免命令列留存）
  -k, --pubkey "KEY"     OpenSSH 公鑰，可重複；有公鑰時停用密碼登入
      --pubkey-file FILE 公鑰文字檔，可重複；每行一把公鑰，允許空白行及 # 註解
      --port PORT        本機 SSH port，預設 2222
      --no-root          公鑰模式也禁止 root；不修改 root 帳號或公鑰
      --no-bore          不啟動 bore
      --no-cloudflared   不啟動 Cloudflare Quick Tunnel
      --wait SECONDS     每種隧道啟動等待時間，預設 45 秒，範圍 1–180
      --show-password    顯示密碼；預設只顯示本次自動產生的密碼
      --status           顯示本腳本的程序與上次連線資訊；可搭配 --show-password
      --stop             停止本腳本記錄的 SSH listener 與隧道
  -h, --help             顯示說明

範例（在 Colab Cell 前加 !）：
  bash /content/setup_ssh.sh
  bash /content/setup_ssh.sh --pubkey-file /content/my_key.pub --no-cloudflared
  bash /content/setup_ssh.sh --pubkey 'ssh-ed25519 AAAA... your-pc' --no-root
  bash /content/setup_ssh.sh --status
  bash /content/setup_ssh.sh --stop

設定：SSH_PORT、SSH_USER、SSH_PASSWORD 亦可透過環境變數提供。
未安裝 cloudflared 時下載官方最新版本；可用 CLOUDFLARED_VERSION 指定 release tag。
既有 bore / cloudflared 會直接沿用，不會自動更新。
密碼模式只允許一般帳號登入；公鑰模式預設允許 root 與一般帳號登入。
一般帳號不自動取得 sudo 權限；需使用 root 的 Python/檔案時，請使用公鑰模式。
未指定密碼時，每次重跑會產生新密碼。重跑請從 Colab Cell 操作。
兩個 --no-* 同時指定時，只啟動 localhost SSH，不建立外網隧道。
--stop 不刪除帳號、已安裝工具或公鑰；已存在的獨立本機 SSH session 可能仍保留。
EOF
}

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 缺少值"; }
parse_args() {
  while (( $# )); do
    case "$1" in
      -p|--password) need_value "$@"; SSH_PASSWORD="$2"; shift 2 ;;
      -u|--user) need_value "$@"; SSH_USER="$2"; shift 2 ;;
      -k|--pubkey) need_value "$@"; PUBKEYS+=("$2"); shift 2 ;;
      --pubkey-file) need_value "$@"; PUBKEY_FILES+=("$2"); shift 2 ;;
      --port) need_value "$@"; SSH_PORT="$2"; shift 2 ;;
      --wait) need_value "$@"; WAIT_SECONDS="$2"; shift 2 ;;
      --no-bore) ENABLE_BORE=0; shift ;;
      --no-cloudflared) ENABLE_CLOUDFLARED=0; shift ;;
      --no-root) PERMIT_ROOT=0; shift ;;
      --show-password) SHOW_PASSWORD=1; shift ;;
      --status|--stop)
        [[ "$ACTION" == start ]] || die "--status 與 --stop 只能擇一"
        ACTION="${1#--}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知選項，請查看 --help" ;;
    esac
  done
  [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$SSH_USER" != root ]] || die "--user 請指定合法的一般帳號"
  [[ "$SSH_PORT" =~ ^[0-9]{1,5}$ ]] || die "port 必須是 1–65535 的數字"
  SSH_PORT=$((10#$SSH_PORT))
  (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "port 必須介於 1–65535"
  [[ "$WAIT_SECONDS" =~ ^[0-9]{1,3}$ ]] || die "--wait 必須介於 1–180 秒"
  WAIT_SECONDS=$((10#$WAIT_SECONDS))
  (( WAIT_SECONDS >= 1 && WAIT_SECONDS <= 180 )) || die "--wait 必須介於 1–180 秒"
  [[ "$SSH_PASSWORD" != *$'\n'* && "$SSH_PASSWORD" != *$'\r'* ]] || die "密碼不可含換行字元"
  [[ "$CLOUDFLARED_VERSION" =~ ^[a-zA-Z0-9._-]+$ ]] || die "CLOUDFLARED_VERSION 格式不正確"
}

# Python 只負責程序管理；不使用 pkill。PID、啟動時間、執行檔、參數都會核對。
# close_fds 避免背景服務繼承腳本鎖；start_new_session 避免 Cell 結束時帶走服務。
process() {
  local action="$1" name="$2"; shift 2
  python3 - "$action" "$STATE_DIR/$name.json" "$STATE_DIR/$name.log" "$@" <<'PY'
import json, os, pathlib, signal, subprocess, sys, time
action, record_name, log_name, *command = sys.argv[1:]
record = pathlib.Path(record_name)

def snapshot(pid):
    if pid <= 1:
        return None
    try:
        base = pathlib.Path('/proc') / str(pid)
        stat = (base / 'stat').read_text().rsplit(') ', 1)[1].split()
        if stat[0] == 'Z':
            return None
        return {'pid': pid, 'start': stat[19], 'exe': os.readlink(base / 'exe'),
                'args': (base / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()}
    except (OSError, IndexError):
        return None

def matches(saved):
    live = snapshot(saved['pid'])
    if not live or any(live[k] != saved[k] for k in ('pid', 'start', 'exe')):
        return False
    # sshd 會把 argv 改成「sshd: ... [listener]」；仍須含自己的設定檔。
    if record.stem == 'sshd':
        return saved['config'] in live['args'] and ('[listener]' in live['args'] or '-D' in live['args'])
    return live['args'] == saved['args']

saved = None
if record.exists():
    try:
        saved = json.loads(record.read_text())
        live = matches(saved)
    except (ValueError, KeyError, TypeError):
        print(f'無法辨識程序紀錄：{record}；未發出停止訊號。', file=sys.stderr)
        sys.exit(1)
else:
    live = False

if action == 'start':
    if live:
        sys.exit('此程序仍在執行，請先停止。')
    env = {k: v for k, v in os.environ.items() if k not in ('SSH_PASSWORD', 'SSHPASS')}
    env['NO_COLOR'] = '1'
    with open(log_name, 'wb') as log:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 start_new_session=True, close_fds=True, env=env)
    saved = snapshot(child.pid)
    if saved is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        sys.exit('程序已退出或無法讀取 /proc 的程序資訊，請查看日誌。')
    if record.stem == 'sshd':
        saved['config'] = command[command.index('-f') + 1]
    try:
        temp = record.with_suffix('.new')
        temp.write_text(json.dumps(saved))
        temp.replace(record)
    except BaseException:
        child.terminate()
        raise
elif action in ('alive', 'status'):
    if action == 'status':
        print(f'{record.stem}: ' + (f'執行中 (PID {saved["pid"]})' if live else '未執行或紀錄已過期'))
    sys.exit(0 if live else 1)
elif action == 'stop':
    if live:
        pid = saved['pid']
        fd = None
        try:
            if hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'):
                fd = os.pidfd_open(pid)
            def send(sig):
                if matches(saved):
                    if fd is not None:
                        signal.pidfd_send_signal(fd, sig)
                    else:
                        os.kill(pid, sig)
            send(signal.SIGTERM)
            for _ in range(50):
                if not matches(saved):
                    break
                time.sleep(0.1)
            if matches(saved):
                send(signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            if fd is not None:
                os.close(fd)
    record.unlink(missing_ok=True)
else:
    sys.exit('未知程序操作')
PY
}

stop_managed() {
  local name failed=0
  for name in bore cloudflared sshd; do
    process stop "$name" || failed=1
  done
  return "$failed"
}
cleanup() {
  local rc=$?
  trap - EXIT
  if (( STARTED && ! SUCCESS )); then
    stop_managed || true
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  exit "$rc"
}
port_open() {
  python3 - "$SSH_PORT" <<'PY'
import socket, sys
try:
    with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=1):
        pass
except OSError:
    sys.exit(1)
PY
}

ensure_dependencies() {
  local cmd pkg
  local -a packages=()
  for cmd in sshd ssh ssh-keygen openssl curl useradd chpasswd passwd; do
    if ! command -v "$cmd" >/dev/null; then
      case "$cmd" in
        sshd) pkg=openssh-server ;;
        ssh|ssh-keygen) pkg=openssh-client ;;
        openssl) pkg=openssl ;;
        curl) pkg=curl ;;
        *) pkg=passwd ;;
      esac
      packages+=("$pkg")
    fi
  done
  if (( ${#packages[@]} )); then
    command -v apt-get >/dev/null || die "需要 Debian/Ubuntu 的 apt-get 安裝缺少的依賴"
    info "安裝缺少的依賴；日誌：$STATE_DIR/install.log"
    if ! (export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq && apt-get install -y -qq "${packages[@]}" ca-certificates
         ) > "$STATE_DIR/install.log" 2>&1; then
      tail -n 30 "$STATE_DIR/install.log" >&2
      die "依賴安裝失敗"
    fi
  fi
  SSHD_BIN="$(command -v sshd)"
}

prepare_keys() {
  local file line key
  for file in "${PUBKEY_FILES[@]}"; do
    [[ -r "$file" ]] || die "無法讀取公鑰檔：$file"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      PUBKEYS+=("$line")
    done < "$file"
  done
  (( ${#PUBKEY_FILES[@]} == 0 || ${#PUBKEYS[@]} > 0 )) || die "公鑰檔沒有有效內容"
  : > "$WORK_DIR/authorized_keys"
  for key in "${PUBKEYS[@]}"; do
    key="${key%$'\r'}"
    [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] || die "每個 --pubkey 只能包含一行公鑰"
    printf '%s\n' "$key" > "$WORK_DIR/check.pub"
    ssh-keygen -l -f "$WORK_DIR/check.pub" >/dev/null 2>&1 || die "公鑰格式無效；請提供 .pub，勿提供私鑰"
    printf '%s\n' "$key" >> "$WORK_DIR/authorized_keys"
  done
  if (( ${#PUBKEYS[@]} )); then
    USE_PASSWORD=0
    sort -u -o "$WORK_DIR/authorized_keys" "$WORK_DIR/authorized_keys"
  fi
}

install_keys() {
  local account="$1" home_dir group_name status_line status_code
  home_dir="$(getent passwd "$account" | cut -d: -f6)"
  group_name="$(id -gn "$account")"
  [[ "$home_dir" == /* && -d "$home_dir" ]] || die "$account 的家目錄不存在"
  [[ ! -L "$home_dir/.ssh" ]] || die "$account 的 .ssh 是符號連結，請先確認其目的地"
  install -d -m 700 -o "$account" -g "$group_name" "$home_dir/.ssh"
  # 使用專用檔案，避免改寫使用者原本的 authorized_keys。
  install -m 600 -o "$account" -g "$group_name" "$WORK_DIR/authorized_keys" "$home_dir/.ssh/authorized_keys_colab"
  status_line="$(LC_ALL=C passwd -S "$account")"
  read -r _ status_code _ <<< "$status_line"
  if [[ "$status_code" == L || "$status_code" == NP ]]; then
    # UsePAM no 會拒絕鎖定帳號；設定不公開的隨機密碼解除鎖定。
    # SSH 仍禁用密碼與互動式認證，不使用空密碼或 passwd -l。
    printf '%s:%s\n' "$account" "$(openssl rand -hex 32)" | chpasswd
  elif [[ "$status_code" != P ]]; then
    die "無法辨識 $account 的帳號狀態"
  fi
}

configure_accounts() {
  if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -U -s /bin/bash -- "$SSH_USER"
  fi
  [[ "$(id -u "$SSH_USER")" != 0 ]] || die "--user 不可指向 UID 0 帳號"
  LOGIN_USER="$SSH_USER"
  if (( USE_PASSWORD )); then
    if [[ -z "$SSH_PASSWORD" ]]; then
      SSH_PASSWORD="$(openssl rand -hex 16)"
      GENERATED=1
    fi
    printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd
    printf '%s\n' "$SSH_PASSWORD" > "$STATE_DIR/password"
    chmod 600 "$STATE_DIR/password"
  else
    install_keys "$SSH_USER"
    if (( PERMIT_ROOT )); then
      install_keys root
      LOGIN_USER=root
    fi
    rm -f -- "$STATE_DIR/password"
  fi
}

configure_sshd() {
  local root_mode=no password_mode=no pubkey_mode=yes allow_users="$SSH_USER"
  if (( USE_PASSWORD )); then
    password_mode=yes; pubkey_mode=no
  elif (( PERMIT_ROOT )); then
    root_mode=prohibit-password; allow_users+=" root"
  fi
  # 自己的 host key 在同一 runtime 內沿用，避免重跑就改變指紋。
  if [[ ! -f "$STATE_DIR/host_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$STATE_DIR/host_ed25519"
  fi
  install -d -m 755 /run/sshd
  cat > "$SSHD_CONF" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
PidFile $STATE_DIR/sshd.pid
HostKey $STATE_DIR/host_ed25519
PermitRootLogin $root_mode
AllowUsers $allow_users
PubkeyAuthentication $pubkey_mode
AuthorizedKeysFile .ssh/authorized_keys_colab
PasswordAuthentication $password_mode
PermitEmptyPasswords no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
MaxAuthTries 3
MaxStartups 10:30:30
LoginGraceTime 30
ClientAliveInterval 30
ClientAliveCountMax 4
TCPKeepAlive yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
PermitUserEnvironment no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF
  "$SSHD_BIN" -t -f "$SSHD_CONF"
}

start_sshd() {
  local i found=0
  process start sshd "$SSHD_BIN" -D -e -f "$SSHD_CONF"
  for ((i=0; i<30; i++)); do
    process alive sshd || break
    if port_open; then found=1; break; fi
    sleep 0.2
  done
  if (( ! found )); then
    tail -n 30 "$STATE_DIR/sshd.log" >&2
    die "sshd 無法啟動"
  fi
  # 用實際 host key 建立本機驗證檔；不關閉主機金鑰檢查。
  printf '[127.0.0.1]:%s %s\n' "$SSH_PORT" "$(cat "$STATE_DIR/host_ed25519.pub")" > "$WORK_DIR/known_hosts"
  if (( USE_PASSWORD )); then
    # SSH_ASKPASS 接受密碼，避免 sshpass -p 將密碼放進程序參數。
    cat > "$WORK_DIR/askpass" <<EOF
#!/bin/sh
cat '$STATE_DIR/password'
EOF
    chmod 700 "$WORK_DIR/askpass"
    if ! SSH_ASKPASS="$WORK_DIR/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=colab-ssh:0 \
         ssh -F /dev/null -p "$SSH_PORT" -o StrictHostKeyChecking=yes \
         -o UserKnownHostsFile="$WORK_DIR/known_hosts" -o GlobalKnownHostsFile=/dev/null \
         -o PubkeyAuthentication=no -o PreferredAuthentications=password \
         -o NumberOfPasswordPrompts=1 -o ConnectTimeout=8 -o ConnectionAttempts=1 \
         "$SSH_USER@127.0.0.1" true </dev/null > "$STATE_DIR/login-test.log" 2>&1; then
      tail -n 15 "$STATE_DIR/login-test.log" >&2
      tail -n 15 "$STATE_DIR/sshd.log" >&2
      die "本機密碼登入測試失敗；未開啟隧道"
    fi
    info "本機密碼登入測試通過。"
  else
    info "已檢查公鑰格式與帳號狀態；私鑰留在電腦，請從電腦驗證公鑰登入。"
  fi
}

download() {
  curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 \
    --max-time 180 --retry 2 --retry-delay 2 --output "$2" "$1"
}
install_bore() {
  local arch asset
  if command -v bore >/dev/null; then BORE_BIN="$(command -v bore)"; return 0; fi
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) warn "bore 不支援此架構"; return 1 ;;
  esac
  asset="bore-$BORE_VERSION-$arch-unknown-linux-musl.tar.gz"
  info "下載 bore $BORE_VERSION…"
  download "https://github.com/ekzhang/bore/releases/download/$BORE_VERSION/$asset" "$WORK_DIR/bore.tar.gz" || return 1
  tar -xzf "$WORK_DIR/bore.tar.gz" -C "$WORK_DIR" --no-same-owner -- bore || return 1
  install -m 755 "$WORK_DIR/bore" /usr/local/bin/bore || return 1
  BORE_BIN="$(command -v bore)" || return 1
}
install_cloudflared() {
  local arch base
  if command -v cloudflared >/dev/null; then CF_BIN="$(command -v cloudflared)"; return 0; fi
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "cloudflared 不支援此架構"; return 1 ;;
  esac
  base=https://github.com/cloudflare/cloudflared/releases
  if [[ "$CLOUDFLARED_VERSION" == latest ]]; then
    base+=/latest/download
  else
    base+="/download/$CLOUDFLARED_VERSION"
  fi
  info "下載 cloudflared $CLOUDFLARED_VERSION…"
  download "$base/cloudflared-linux-$arch" "$WORK_DIR/cloudflared" || return 1
  install -m 755 "$WORK_DIR/cloudflared" /usr/local/bin/cloudflared || return 1
  CF_BIN="$(command -v cloudflared)" || return 1
}
parse_cf_host() {
  # 僅採用網址表格的內容，不抓錯誤行中的 api.trycloudflare.com。
  sed -nE 's/.*\|[[:space:]]+https:\/\/([a-z0-9-]+\.trycloudflare\.com)[[:space:]]+\|.*/\1/p' "$1" \
    | awk '$0 != "api.trycloudflare.com" && !seen {print; seen=1}'
}
start_bore() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  process start bore "$BORE_BIN" local "$SSH_PORT" --local-host 127.0.0.1 --to bore.pub || return 1
  while (( SECONDS < deadline )); do
    process alive bore || break
    BORE_PORT="$(sed -nE 's/.*listening at bore\.pub:([0-9]+).*/\1/p' "$STATE_DIR/bore.log" | awk '!seen {print; seen=1}')"
    if [[ "$BORE_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$BORE_PORT >= 1 && 10#$BORE_PORT <= 65535 )); then
      return 0
    fi
    sleep 0.5
  done
  BORE_PORT=""
  tail -n 15 "$STATE_DIR/bore.log" >&2
  process stop bore || true
  return 1
}
start_cloudflared() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  printf '{}\n' > "$STATE_DIR/cloudflared.yml" || return 1
  process start cloudflared "$CF_BIN" tunnel --config "$STATE_DIR/cloudflared.yml" \
    --url "tcp://127.0.0.1:$SSH_PORT" --no-autoupdate || return 1
  while (( SECONDS < deadline )); do
    process alive cloudflared || break
    CF_HOST="$(parse_cf_host "$STATE_DIR/cloudflared.log")"
    if [[ -n "$CF_HOST" ]] && grep -q 'Registered tunnel connection' "$STATE_DIR/cloudflared.log"; then
      return 0
    fi
    sleep 0.5
  done
  CF_HOST=""
  tail -n 20 "$STATE_DIR/cloudflared.log" >&2
  process stop cloudflared || true
  return 1
}

connection_info() {
  info "SSH 帳號：$LOGIN_USER"
  [[ "$LOGIN_USER" != root ]] || info "也可使用一般帳號：$SSH_USER"
  info "本機監聽：127.0.0.1:$SSH_PORT"
  if (( USE_PASSWORD )); then
    info "認證：密碼（root 登入已停用）"
  else
    info "認證：公鑰（密碼登入已停用）"
  fi
  info "主機金鑰指紋（首次連線時請核對）："
  ssh-keygen -lf "$STATE_DIR/host_ed25519.pub"
  if [[ -n "$BORE_PORT" ]]; then
    cat <<EOF

bore 連線（電腦只需有 SSH 用戶端）：
  ssh -p $BORE_PORT $LOGIN_USER@bore.pub

加入電腦的 ~/.ssh/config，可供 VS Code Remote-SSH 使用：
Host colab-bore
    HostName bore.pub
    Port $BORE_PORT
    User $LOGIN_USER
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking ask
EOF
  fi
  if [[ -n "$CF_HOST" ]]; then
    cat <<EOF

Cloudflare 已註冊；電腦需安裝 cloudflared，並可從命令列找到它：
Host colab-cf
    HostName $CF_HOST
    User $LOGIN_USER
    ProxyCommand cloudflared access tcp --hostname %h
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking ask

儲存以上設定後，在電腦執行：ssh colab-cf
EOF
  fi
  info ""
  info "公鑰私鑰若非預設檔名，請在 Host 區塊加上 IdentityFile ~/.ssh/你的私鑰檔名。"
  info "主機金鑰在同一 runtime 內沿用；runtime 重建或 bore port 重用時須重新核對。"
  info "請從電腦實際連線確認外網路徑；Colab 端完成啟動不等於已驗證外網登入。"
  info "日誌：$STATE_DIR/{sshd,bore,cloudflared}.log"
  info "Colab runtime 的閒置與最長執行時間限制仍然適用。"
}

main() {
  parse_args "$@"
  [[ "$(id -u)" == 0 ]] || die "請以 root 執行；Colab 預設為 root"
  command -v python3 >/dev/null || die "找不到 Python 3；此腳本針對 Colab 環境"
  command -v flock >/dev/null || die "需要 util-linux 提供的 flock"
  [[ ! -L "$STATE_DIR" ]] || die "狀態目錄不可為符號連結"
  install -d -m 700 -o root -g root "$STATE_DIR"
  exec 9> "$STATE_DIR/lock"
  flock -n 9 || die "另一個 setup_ssh.sh 正在操作，請稍後重試"
  trap cleanup EXIT
  trap 'printf "錯誤：第 %s 行失敗（exit=%s）；請查看 %s 的日誌。\n" "$LINENO" "$?" "$STATE_DIR" >&2' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ "$ACTION" == stop ]]; then
    stop_managed || die "部分程序紀錄無法核對，請查看提示"
    rm -f -- "$STATE_DIR/connection.txt" "$STATE_DIR/password"
    info "已停止本腳本記錄的 SSH listener 與隧道。"
    return 0
  fi
  if [[ "$ACTION" == status ]]; then
    local name
    for name in sshd bore cloudflared; do process status "$name" || true; done
    if [[ -f "$STATE_DIR/connection.txt" ]]; then
      info "以下為上次成功啟動資訊，網址仍需以目前程序及實際連線確認："
      cat "$STATE_DIR/connection.txt"
    fi
    if (( SHOW_PASSWORD )) && [[ -f "$STATE_DIR/password" ]]; then
      printf 'SSH 密碼：'; cat "$STATE_DIR/password"
    fi
    return 0
  fi

  WORK_DIR="$(mktemp -d "$STATE_DIR/work.XXXXXX")"
  info "[1/4] 檢查依賴與輸入"
  ensure_dependencies
  prepare_keys
  info "[2/4] 重建本腳本服務並設定認證"
  stop_managed || die "舊程序紀錄無法核對，已停止重建"
  rm -f -- "$STATE_DIR/connection.txt"
  if port_open; then
    die "127.0.0.1:$SSH_PORT 已被其他服務使用；請停止舊版服務、換 --port，或重建 Colab runtime"
  fi
  configure_accounts
  configure_sshd
  STARTED=1
  start_sshd

  info "[3/4] 建立隧道"
  if (( ENABLE_BORE )); then
    if install_bore && start_bore; then
      info "bore 已啟動：bore.pub:$BORE_PORT"
    else
      warn "bore 無法使用；繼續處理其他選項"
    fi
  fi
  if (( ENABLE_CLOUDFLARED )); then
    if install_cloudflared && start_cloudflared; then
      info "Cloudflare 已註冊：$CF_HOST"
    else
      warn "Cloudflare 無法使用；保留已成功的其他隧道"
    fi
  fi
  # 第二條隧道建立期間，第一條也可能已退出；輸出前再核對程序。
  if [[ -n "$BORE_PORT" ]] && ! process alive bore; then BORE_PORT=""; fi
  if [[ -n "$CF_HOST" ]] && ! process alive cloudflared; then CF_HOST=""; fi
  process alive sshd || die "sshd 已停止，請查看 sshd.log"
  if (( ENABLE_BORE || ENABLE_CLOUDFLARED )) && [[ -z "$BORE_PORT" && -z "$CF_HOST" ]]; then
    die "所有啟用的隧道皆失敗；已停止本次服務，日誌保留供檢查"
  fi

  info "[4/4] 連線資訊"
  connection_info > "$STATE_DIR/connection.txt"
  cat "$STATE_DIR/connection.txt"
  if (( USE_PASSWORD )); then
    if (( GENERATED || SHOW_PASSWORD )); then
      printf '\nSSH 密碼：%s\n' "$SSH_PASSWORD"
      info "分享 Notebook 前請清除包含密碼的 Cell 輸出。"
    else
      info "使用你指定的密碼（未顯示）。"
    fi
    info "重查密碼：bash /content/setup_ssh.sh --status --show-password"
  fi
  SSH_PASSWORD=""
  SUCCESS=1
  info "完成。"
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
  main "$@"
fi
