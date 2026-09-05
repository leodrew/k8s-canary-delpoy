#!/usr/bin/env bash
#
# scripts/validate.sh — 這個 repo 的「品質閘門」（quality gate）
#
# 為什麼需要這支腳本：
#   dev/k8s 裡面只有 Kubernetes / Istio 的 YAML、shell 腳本和中文文件，
#   沒有編譯器、沒有測試框架、沒有任何東西可以 build。也就是說在這支腳本
#   出現之前，這個 repo 「完全沒有」自動檢查 —— 一個打錯的縮排、一個被誤刪
#   的 ConfigMap key，要等到 kubectl apply 之後 Pod 起不來才會被發現。
#
#   這支腳本就是這個 repo 的 typecheck。從 repo root 執行：
#
#       bash scripts/validate.sh          （或 npm run validate）
#
#   exit code 0 = 全部通過，1 = 至少一項失敗。
#
# 維護規則（非常重要）：
#   每一次修改 canary-manual/ 底下的 manifest，都必須「在同一個 commit 裡」
#   往這支腳本加上對應的斷言。這是為了讓腳本在每一個 commit 上都是綠的，
#   也是為了防止後面的修改默默地把前面修好的東西弄壞 —— 例如把
#   user-name-attribute 從 sub 改回 preferred_username，或是刪掉某個
#   ConfigMap key 之後沒人發現。改了 manifest 卻沒加檢查，這件事就沒做完。
#
# 工具限制：
#   這台機器上只有 node / npm。沒有 kubectl、沒有 yq、沒有可用的 python
#   （只有 Microsoft Store 的殼）。所以 YAML 一律用 js-yaml 解析，而且用的是
#   釘在 devDependencies 裡的「本地」CLI（node_modules/.bin/js-yaml），
#   不是 `npx --yes js-yaml` —— 後者每次執行都要連網，斷網就整個閘門失效，
#   那就不叫閘門了。

# 刻意不用 set -e：一個檢查失敗時我們要繼續跑完其餘的檢查，
# 一次把所有問題列出來，而不是修一個跑一次。
set -uo pipefail

# --- 一律切到 repo root ------------------------------------------------------
# 讓這支腳本無論從哪個目錄被呼叫（repo root、scripts/、ralph/、CI）
# 結果都一樣。底下所有路徑因此都可以寫成相對於 repo root 的相對路徑。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

JS_YAML="node_modules/.bin/js-yaml"

# --- check helper ------------------------------------------------------------
# 用法：check <名稱> <指令> [參數...]
#
#   指令的 exit code 0 視為通過，印出 "PASS <名稱>"；
#   非 0 視為失敗，印出 "FAIL <名稱>" 並把指令的 stdout+stderr 縮排印出來，
#   同時把失敗計數加一。
#
# 指令是直接以參數陣列執行（"$@"），不經過 eval，所以像
#   check "..." node -e '...'
# 這種帶大量引號的 node 斷言可以原樣傳進來，不用擔心被 shell 二次解析。
# 需要 pipeline 或 shell 語法時再明確地包一層 bash -c。
CHECK_COUNT=0
FAIL_COUNT=0

check() {
  local name="$1"
  shift
  CHECK_COUNT=$((CHECK_COUNT + 1))

  local out
  if out="$("$@" 2>&1)"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/         /'
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# --- 前置檢查：本地 js-yaml 一定要在 -----------------------------------------
# 沒有它的話所有 YAML 檢查都會失敗，與其印出一整排看不懂的 FAIL，
# 不如直接告訴使用者要跑 npm install。
if [ ! -x "$JS_YAML" ]; then
  echo "FAIL preflight: 找不到 $JS_YAML"
  echo "         請先在 repo root 執行 npm install（js-yaml 是 devDependency）"
  exit 1
fi

echo "validate.sh — repo root: $REPO_ROOT"
echo

# =============================================================================
# 檢查 1：YAML 語法
# =============================================================================
# canary-manual/track-a 與 track-b 底下每一個 *.yaml 都必須能被 js-yaml 解析。
#
# 這裡用 find 動態列出檔案、而不是寫死清單，是為了讓之後新增的 manifest
# （例如 US-008 會加出來的 11-configmap-canary.yaml）自動被納入檢查，
# 不需要有人記得回來更新這支腳本。
#
# js-yaml CLI 本身支援多文件（--- 分隔）的 YAML，track-b/base 底下有幾個
# 檔案就是這種格式，所以不需要另外處理。
echo "== [1] YAML 語法檢查 =="

while IFS= read -r manifest; do
  check "yaml-parse $manifest" "$JS_YAML" "$manifest"
done < <(find canary-manual/track-a canary-manual/track-b -type f -name '*.yaml' | sort)

# =============================================================================
# 之後的檢查加在這裡
# =============================================================================
# 加新檢查的慣例：
#   - 新開一個 "== [n] 說明 ==" 區段，說明「這個檢查在防什麼」
#   - 斷言 ConfigMap 內容時，一律解析 YAML，不要 grep 原始檔。
#     真正的設定藏在 data["application.yml"] 裡 —— 那是一份被當成字串塞進
#     另一份 YAML 的 YAML。要先解析外層檔案、再解析那個字串、最後對物件下斷言。
#     直接 grep 原始檔會被「被註解掉的行」騙過去（這些檔案裡有好幾處），
#     給出假的 PASS。

# --- 總結 --------------------------------------------------------------------
echo
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "ALL PASS — $CHECK_COUNT 項檢查全部通過"
  exit 0
else
  echo "FAILED — $CHECK_COUNT 項檢查中有 $FAIL_COUNT 項失敗"
  exit 1
fi
