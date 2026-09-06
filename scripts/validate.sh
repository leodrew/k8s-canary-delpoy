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

# =============================================================================
# 檢查 2：ConfigMap 必備 key（CANARY-COMPLETE.md 附錄 C.1）
# =============================================================================
# 為什麼要有這一項：
#   US-006 之後 Deployment 會改用 SPRING_CONFIG_LOCATION，那是 **replace** 語意 ——
#   jar 裡的 application.yml 完全不會被載入。所以 ConfigMap 漏掉的每一個 key，
#   都不是「退回 jar 裡的設定」，而是退回 Java 的 @Value 預設值；沒有預設值的
#   那幾個則是直接讓 pod 起不來，而且錯誤訊息不會指向 ConfigMap。
#
#   這一段釘住的是附錄 C.1 裡「漏掉 pod 就起不來」的那幾個 key。它們曾經真的
#   從這份檔案裡消失過（issuer-uri 就被誤刪過一次，track-b 那份還留著），
#   而在沒有這個檢查之前，那種刪除要等到 kubectl apply、Pod 進 CrashLoopBackOff
#   才會被發現。
#
# 為什麼比對「值」而不只是「存在」：
#   redirect-uri 最典型 —— 把它刪掉，Spring 會用自己的預設值頂上，key 看起來
#   還是「有設定」，但少了 /gui_epmmFormQuery 前綴，登入 callback 就進不來。
#   這一類錯誤只有比對實際值才抓得到。
#   值改了就要連這裡一起改，這是刻意的：這份 ConfigMap 是環境設定的唯一真相。
echo "== [2] ConfigMap 必備 key（附錄 C.1：漏掉 pod 起不來）=="

# 之後 US-008 會把 track-a 的 ConfigMap 拆成 -stable / -canary 兩份。
# 到時候只要把新檔名加進這個陣列，底下每一項 key 檢查就會自動對兩份各跑一次，
# 不需要把檢查複製貼上一遍。
TRACK_A_CONFIGMAPS=(
  "canary-manual/track-a/release/10-configmap-1.2.3.yaml"
)

# 共用的斷言腳本。用法：
#   node -e "$CM_KEY_SCRIPT" <configmap 檔> <dotted.key.path> [期望值]
#
# 它做的事情正是這個 repo 的規則：先解析外層 ConfigMap，再把
# data["application.yml"] 這個「字串形式的 YAML」解析成物件，最後對物件下斷言。
# 不要改成 grep 原始檔 —— 這些檔案裡有好幾段被註解掉的設定，grep 會給出假的 PASS。
#
# 省略「期望值」時只檢查 key 存在。注意兩者的差別：
#   key 完全沒寫       → 路徑走不到，失敗
#   寫了 key 但沒有值  → 解析成 null，也算失敗（`issuer-uri:` 後面空白就是這種）
#   寫成空字串 ""      → 通過（app.security.required-role 就是刻意的空字串）
CM_KEY_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file, keyPath, expected] = process.argv.slice(1);
const cm = y.load(fs.readFileSync(file, "utf8"));
const raw = cm && cm.data && cm.data["application.yml"];
if (typeof raw !== "string") {
  console.error(file + ": 沒有 data[\"application.yml\"]，這不是一份預期中的 ConfigMap");
  process.exit(1);
}
const app = y.load(raw);
let cur = app;
for (const seg of keyPath.split(".")) {
  if (cur === null || typeof cur !== "object" || !(seg in cur)) {
    console.error(file + ": 缺少 key  " + keyPath);
    process.exit(1);
  }
  cur = cur[seg];
}
if (cur === null) {
  console.error(file + ": key " + keyPath + " 有寫但沒有值（解析成 null）");
  process.exit(1);
}
if (expected !== undefined && String(cur) !== expected) {
  console.error(file + ": key " + keyPath + " 的值不對");
  console.error("  期望: " + expected);
  console.error("  實際: " + String(cur));
  process.exit(1);
}
'

# 用法：assert_cm_key <dotted.key.path> [期望值]
# 對 TRACK_A_CONFIGMAPS 裡的每一份 ConfigMap 各跑一次。
assert_cm_key() {
  local key="$1"
  shift
  local cm
  for cm in "${TRACK_A_CONFIGMAPS[@]}"; do
    check "cm-key $key ($(basename "$cm"))" node -e "$CM_KEY_SCRIPT" "$cm" "$key" "$@"
  done
}

# --- 附錄 C.1：這三個漏掉 pod 直接起不來 -------------------------------------
# issuer-uri：無預設值。jar 裡那份在 !test profile 的 document，replace 語意下
#   不會被載入，所以沒有東西可以退回 → OAuth2 client 建不起來，啟動失敗。
assert_cm_key "spring.security.oauth2.client.provider.keycloak.issuer-uri" \
  '${KEYCLOAK_ISSUER_URI}'

# post-logout-redirect-uri：後端是 @Value("${app.post-logout-redirect-uri}")，
#   【沒有預設值】→ Could not resolve placeholder → 啟動失敗。
#   注意這裡釘的是 app.* 頂層的 key；app.sso.post-logout-redirect-uri 是錯的
#   key 路徑，沒有任何程式讀它，所以那個路徑存在與否都救不了這個檢查。
assert_cm_key "app.post-logout-redirect-uri" \
  '${POST_LOGOUT_REDIRECT_URI:{baseUrl}/gui_epmmFormQuery/page/logged-out}'

# redirect-uri：Spring 有預設值，所以缺了不會啟動失敗 —— 它會安靜地變成
#   {baseUrl}/login/oauth2/code/{registrationId}（沒有 /gui_epmmFormQuery 前綴），
#   跟 redirectionEndpoint.baseUri 對不上，登入 callback 進不來。
#   這就是為什麼這一項一定要比對完整的值，光檢查 key 存在沒有意義。
assert_cm_key "spring.security.oauth2.client.registration.keycloak.redirect-uri" \
  '{baseUrl}/gui_epmmFormQuery/login/oauth2/code/{registrationId}'

# --- 總結 --------------------------------------------------------------------
echo
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "ALL PASS — $CHECK_COUNT 項檢查全部通過"
  exit 0
else
  echo "FAILED — $CHECK_COUNT 項檢查中有 $FAIL_COUNT 項失敗"
  exit 1
fi
