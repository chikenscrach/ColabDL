#!/usr/bin/env bash
#
# 安裝 OpenCode v2（Google Colab / root 環境）+ skills + MCP 設定
#
# 變更重點：安裝來源改為 v2 官方安裝腳本，並在安裝後驗證 skills 與 MCP 是否被 v2 正確載入。
#   - v2 安裝腳本：https://opencode.ai/v2/install
#   - v2 仍然讀取 ~/.config/opencode/opencode.json（與 v1 相同位置），v1 格式的 mcp / agent 設定
#     會在記憶體中被自動正規化，不需要先改寫設定檔。
#
set -euo pipefail

# ===== 可調參數 =====
OPENCODE_INSTALL_URL="${OPENCODE_INSTALL_URL:-https://opencode.ai/v2/install}"
WANT_MAJOR=2                                                   # 要安裝的主版本
OPENCODE_CONFIG="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
SKILLS_REPO="${SKILLS_REPO:-https://git.csg.qzz.io/ayliehamplin/awesome-skill.git}"
SKILLS_DIR="$OPENCODE_CONFIG/skills"
BIN_DIR="$HOME/.opencode/bin"

# ===== 輸出工具 =====
info() { printf '\033[0;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m[警告] %s\033[0m\n' "$*" >&2; }

# 取得目前安裝的版本號（例如 2.2.0），沒有安裝則輸出空字串
installed_version() {
    opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# 取主版本號
major_of() { printf '%s' "$1" | cut -d. -f1; }

# ===== 0. 基本需求檢查 =====
for cmd in curl git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "找不到 $cmd，嘗試安裝..."
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "$cmd" >/dev/null 2>&1 || warn "$cmd 安裝失敗，後續步驟可能出錯。"
    fi
done

# ===== 1. 安裝 OpenCode v2 =====
info "=== 開始安裝 OpenCode v$WANT_MAJOR ==="

current_version="$(installed_version)"
current_major=""
if [ -n "$current_version" ]; then
    current_major="$(major_of "$current_version")"
fi

if [ -n "$current_major" ] && [ "$current_major" -ge "$WANT_MAJOR" ]; then
    ok "已安裝 OpenCode v${current_version}（v$WANT_MAJOR 以上），跳過安裝。"
else
    if [ -n "$current_version" ]; then
        info "偵測到舊版 OpenCode v${current_version}，將升級為 v$WANT_MAJOR..."
    else
        info "未偵測到 OpenCode，開始安裝 v$WANT_MAJOR..."
    fi

    # v2 官方說明：若 v1 是用 npm / 套件管理器安裝的，要先移除，避免兩個二進位檔互相衝突。
    oc_path="$(command -v opencode || true)"
    case "$oc_path" in
        *node_modules*)
            warn "目前 opencode 來自 npm 全域安裝（$oc_path），先移除 v1 npm 版本..."
            npm uninstall -g opencode-ai >/dev/null 2>&1 || warn "npm 移除 v1 失敗，請手動執行：npm uninstall -g opencode-ai"
            hash -r
            ;;
    esac

    # --no-modify-path：不改寫 ~/.bashrc，統一由下面的 /usr/local/bin 連結處理，
    # 這樣 Colab 的每個 cell / SSH 進來的 shell 都找得到 opencode。
    if [ -n "${OPENCODE_VERSION:-}" ]; then
        curl -fsSL "$OPENCODE_INSTALL_URL" | bash -s -- --version "$OPENCODE_VERSION" --no-modify-path
    else
        curl -fsSL "$OPENCODE_INSTALL_URL" | bash -s -- --no-modify-path
    fi
fi

# 連結至 /usr/local/bin，讓全局環境與所有 Colab Cell 都能使用
link_bin() {
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then
        return 0
    fi
    if ln -sf "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n ln -sf "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    warn "無法建立連結 $dst -> $src（權限不足），請手動處理或改用 export PATH=\"$BIN_DIR:\$PATH\"。"
}

info "正在連結至 /usr/local/bin..."
if [ -x "$BIN_DIR/opencode" ]; then
    link_bin "$BIN_DIR/opencode" /usr/local/bin/opencode
    # v2 安裝腳本會附帶一個 opencode2 相容 shim，一併連結（部分舊腳本會呼叫 opencode2）
    if [ -x "$BIN_DIR/opencode2" ]; then
        link_bin "$BIN_DIR/opencode2" /usr/local/bin/opencode2
    fi
else
    warn "找不到 $BIN_DIR/opencode，改用系統既有的 opencode。"
fi
hash -r 2>/dev/null || true

info "=== 安裝完成 ==="
final_version="$(installed_version)"
if [ -n "$final_version" ]; then
    ok "OpenCode 版本：v$final_version"
    if [ "$(major_of "$final_version")" -lt "$WANT_MAJOR" ]; then
        warn "版本仍是 v$final_version，未達 v$WANT_MAJOR，請檢查安裝輸出。"
    fi
else
    warn "無法取得 OpenCode 版本（opencode --version 失敗）。"
fi

# ===== 2. 安裝 skills =====
info "=== 開始安裝 skills ==="
if [ -d "$SKILLS_DIR/.git" ]; then
    info "Skills 已存在，執行更新..."
    git -C "$SKILLS_DIR" pull --ff-only || warn "skills 更新失敗（可能是網路或本地有變更），沿用現有內容。"
else
    mkdir -p "$OPENCODE_CONFIG"
    if [ -d "$SKILLS_DIR" ] && [ -n "$(ls -A "$SKILLS_DIR" 2>/dev/null)" ]; then
        warn "$SKILLS_DIR 已存在但不是 git repo，改為備份後重新 clone。"
        mv "$SKILLS_DIR" "${SKILLS_DIR}.bak.$(date +%s)"
    fi
    git clone --depth 1 "$SKILLS_REPO" "$SKILLS_DIR" || warn "skills clone 失敗（$SKILLS_REPO），跳過 skills 安裝。"
fi

# v2 的全域 skills 目錄就是 $OPENCODE_CONFIG/skills（與 v1 相同路徑），
# 另外 v2 也相容 ~/.claude/skills、~/.agents/skills 與設定檔中的 "skills" 陣列。
if [ -d "$SKILLS_DIR" ]; then
    skill_dirs="$(find "$SKILLS_DIR" -name SKILL.md -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    skill_files="$(find "$SKILLS_DIR" -maxdepth 1 -name '*.md' -not -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')"
    ok "skills 目錄：$SKILLS_DIR（SKILL.md 形式 $skill_dirs 個、根目錄單檔形式 $skill_files 個）"
fi

# ===== 3. 設定 MCP =====
info "=== 設定 MCP ==="
SRC_CONFIG="$SKILLS_DIR/opencode.json"
DST_CONFIG="$OPENCODE_CONFIG/opencode.json"
if [ -f "$SRC_CONFIG" ]; then
    if [ -f "$DST_CONFIG" ] && ! cmp -s "$SRC_CONFIG" "$DST_CONFIG"; then
        backup="${DST_CONFIG}.bak.$(date +%s)"
        cp "$DST_CONFIG" "$backup"
        warn "原有設定已備份為 $backup（避免覆蓋你手動加過的 provider / API key）。"
    fi
    cp "$SRC_CONFIG" "$DST_CONFIG"
    ok "已複製 MCP 設定：$SRC_CONFIG -> $DST_CONFIG"
else
    warn "找不到 $SRC_CONFIG，略過 MCP 設定。"
fi

# 檢查設定內容（v1 格式在 v2 仍可用，這裡只做健檢與提示）
if [ -f "$DST_CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$DST_CONFIG" <<'PY' || warn "設定檔檢查失敗，v2 啟動時可能會有警告。"
import json, re, sys, pathlib

path = pathlib.Path(sys.argv[1])
raw = path.read_text(encoding="utf-8")

def strip_jsonc(text):
    out, i, n, in_str, esc = [], 0, len(text), False, False
    while i < n:
        ch = text[i]
        if in_str:
            out.append(ch)
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            i += 1
            continue
        if ch == '"':
            in_str = True
            out.append(ch)
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
        else:
            out.append(ch)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))

try:
    try:
        cfg = json.loads(raw)
        fmt = "原生 JSON"
    except json.JSONDecodeError:
        cfg = json.loads(strip_jsonc(raw))
        fmt = "JSONC（含註解）"
except Exception as err:
    print("  ! 無法解析設定檔：%s" % err)
    print("    請手動檢查 %s，OpenCode v2 啟動時可能無法載入 MCP 設定。" % path)
    sys.exit(1)

print("  · 設定檔格式：%s" % fmt)

mcp = cfg.get("mcp") or {}
if isinstance(mcp.get("servers"), dict):
    servers, native = mcp["servers"], True
else:
    servers = {k: v for k, v in mcp.items() if isinstance(v, dict)}
    native = False

if not servers:
    print("  · MCP：未設定任何伺服器")
else:
    if native:
        print("  · MCP：偵測到 %d 個伺服器（原生 v2 格式 mcp.servers）" % len(servers))
    else:
        print("  · MCP：偵測到 %d 個伺服器（v1 格式，v2 載入時會自動轉成 mcp.servers）" % len(servers))
    for name, entry in servers.items():
        if not isinstance(entry, dict):
            print("    - %s：格式無法辨識" % name)
            continue
        kind = entry.get("type") or ("local" if entry.get("command") else "remote" if entry.get("url") else "?")
        if entry.get("disabled") is True:
            state = "disabled"
        elif entry.get("enabled") is False:
            state = "v1 enabled=false（v2 視為 disabled）"
        else:
            state = "enabled"
        print("    - %s（%s，%s）" % (name, kind, state))

skills = cfg.get("skills")
if isinstance(skills, list):
    print("  · skills 額外來源：%d 筆（v2 陣列格式）" % len(skills))
elif isinstance(skills, dict):
    print("  · skills 額外來源：%d 筆（v1 格式，v2 會自動合併）"
          % (len(skills.get("paths") or []) + len(skills.get("urls") or [])))
else:
    print("  · skills：使用預設目錄自動探索")

ignored = [k for k in ("lsp", "server", "logLevel") if k in cfg]
if ignored:
    print("  ! 以下欄位 v2 仍接受但不會生效：%s" % ", ".join(ignored))
PY
fi

info "=== 驗證 v2 載入結果 ==="
# v2 採用「背景服務」架構：設定檔是在服務啟動時載入的。
# 若服務比 opencode.json 早啟動（例如安裝過程中跑過 opencode models），
# 新加入的 MCP 伺服器不會立刻生效，這裡主動 reload 一次。
if ! opencode reload 2>&1 | sed 's/^/  /'; then
    warn "opencode reload 失敗，稍後開啟 opencode 時會重新載入設定。"
fi

model_list="$(opencode models 2>/dev/null || true)"
model_count="$(printf '%s\n' "$model_list" | grep -c . || true)"
if [ "${model_count:-0}" -gt 0 ]; then
    info "可用模型數量：$model_count"
    printf '%s\n' "$model_list" | head -n 3 | sed 's/^/  - /'
else
    warn "無法取得模型清單（可能是網路問題），可稍後手動執行：opencode models"
fi

# 注意：v2 會實際啟動 MCP 伺服器，遠端服務慢的話這裡可能等一下子，失敗也只提示、不中斷安裝。
timeout 60 opencode mcp list 2>&1 | sed 's/^/  /' || warn "opencode mcp list 未完成（可稍後手動執行確認）。"

info "=== 全部完成！ ==="
echo "  設定目錄：$OPENCODE_CONFIG"
ls -1 "$OPENCODE_CONFIG" 2>/dev/null | sed 's/^/    /' || true
if [ -d "$SKILLS_DIR" ]; then
    echo "  skills："
    ls -1 "$SKILLS_DIR" 2>/dev/null | head -n 20 | sed 's/^/    /' || true
fi
echo
echo "  使用方式："
echo "    opencode                 # 開啟 TUI"
echo "    opencode run \"...\"      # 單次執行"
echo "    opencode models          # 列出模型"
echo "    opencode mcp list        # 檢查 MCP 狀態"
