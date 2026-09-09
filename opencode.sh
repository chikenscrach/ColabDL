#!/usr/bin/env bash
set -euo pipefail

OPENCODE_CONFIG="/root/.config/opencode"

echo "=== 開始安裝 Opencode ==="
if ! command -v opencode &>/dev/null; then
    curl -fsSL https://opencode.ai/install | bash

    # 連結至 /usr/local/bin，讓全局環境與所有 Colab Cell 都能使用
    echo "正在連結至 /usr/local/bin..."
    ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode
else
    echo "Opencode 已安裝，跳過。"
fi

echo "=== 安裝完成！ ==="
opencode models

echo "=== 開始安裝 skills ==="
if [ -d "$OPENCODE_CONFIG/skills/.git" ]; then
    echo "Skills 已存在，執行更新..."
    git -C "$OPENCODE_CONFIG/skills" pull
else
    mkdir -p "$OPENCODE_CONFIG"
    git clone --depth 1 https://git.csg.qzz.io/ayliehamplin/awesome-skill.git "$OPENCODE_CONFIG/skills"
fi

echo "=== 設定 mcp ==="
if [ -f "$OPENCODE_CONFIG/skills/opencode.json" ]; then
    cp "$OPENCODE_CONFIG/skills/opencode.json" "$OPENCODE_CONFIG/opencode.json"
fi
ls "$OPENCODE_CONFIG"

echo "=== 全部完成！ ==="
ls "$OPENCODE_CONFIG/skills"