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

# --- Git Bash 的 argv 路徑轉換陷阱（實測過，不要拿掉這一行）------------------
# 這台機器上的 node 是 Windows 原生執行檔，而這支腳本跑在 MSYS2（Git Bash）底下。
# MSYS2 在把參數交給原生執行檔之前，會「好心地」把長得像 POSIX 絕對路徑的參數
# 翻譯成 Windows 路徑。於是：
#
#     node -e '...' "/gui_epmmFormQuery"
#         → node 收到的 argv 其實是 "C:/Program Files/Git/gui_epmmFormQuery"
#
# 這件事對這支腳本是致命的：底下每一個「期望值」都是靠 argv 傳進 node 的，而這個
# repo 的設定值有一大半是 /gui_epmmFormQuery 開頭的路徑。沒有這一行的話，那些
# 斷言會拿一個被竄改過的期望值去比對，結果是【永遠 FAIL】—— 而且錯誤訊息裡印出來
# 的「期望」長得像是有人在 ConfigMap 裡寫了 C:\Program Files，足以讓人查很久。
#
# 改用環境變數傳值也救不了（實測：MSYS2 連環境變數的值也會轉換）。
# MSYS2_ARG_CONV_EXCL='*' 是官方的關閉開關，意思是「所有參數都不要轉換」。
# 在 Linux / macOS 上這個變數不存在意義，設了也完全無害。
export MSYS2_ARG_CONV_EXCL='*'

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

# track-a 的 ConfigMap（US-008 之後是 -stable / -canary 兩份）。
# 底下每一項 key 檢查都對這個陣列裡的【每一份】各跑一次 —— 拆檔案時只要把新檔名
# 加進來，附錄 C 的所有 key 檢查就自動涵蓋兩份，不需要把檢查複製貼上一遍。
# 反過來說：忘記加，就是無聲地少檢查一整份 ConfigMap。
TRACK_A_CONFIGMAPS=(
  "canary-manual/track-a/release/10-configmap-stable.yaml"
  "canary-manual/track-a/release/11-configmap-canary.yaml"
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

# client-id / client-secret：附錄 C.1 一併列了這兩個。它們的「值」是從 Secret 經
#   envFrom 注入的，所以 ConfigMap 裡【只能是 ${...} 佔位符】（附錄 C.4）。把期望值
#   釘成佔位符本身有兩個作用：key 被刪掉會 FAIL，而且有人把真的 client secret 貼進
#   這份檔案時也會 FAIL —— ConfigMap 是明文的，任何拿得到 `kubectl get cm -o yaml`
#   的人都看得到它。
assert_cm_key "spring.security.oauth2.client.registration.keycloak.client-id" \
  '${KEYCLOAK_CLIENT_ID}'
assert_cm_key "spring.security.oauth2.client.registration.keycloak.client-secret" \
  '${KEYCLOAK_CLIENT_SECRET}'

# =============================================================================
# 檢查 3：ConfigMap 必備 key（附錄 C.2 / C.3：漏掉會靜默退回錯誤的預設值）
# =============================================================================
# 為什麼要有這一項：
#   檢查 [2] 釘住的是「漏掉 pod 起不來」那一類 —— 那一類其實是最安全的，因為它
#   會當場炸給你看。這一段釘住的是更危險的一類：漏掉之後 Spring 拿【自己的預設值】
#   頂上，pod 照樣起來、探針照樣綠燈，只有行為悄悄變了。session 從 8 小時縮成
#   30 分鐘、cookie 從 __Host-JSESSIONID 變回 JSESSIONID 去跟 Envoy 的親和 cookie
#   撞名、CSP header 整個不送 —— 這三件事都不會產生任何一行錯誤訊息，也不會有人
#   在 review 時看出來，因為「設定看起來還在」。
#
# 這一段的分工（對應 CANARY-COMPLETE.md 附錄 C）：
#   C.2 —— 預設值跟我們要的【不一樣】，所以一律比對「值」；光檢查 key 存在沒有用。
#   C.3 —— 預設值跟我們要的【剛好一樣】，漏掉不會改變行為，只會讓這份檔案不再是
#          設定的唯一真相（replace 語意下，讀的人沒有別的地方可以查）。所以這一組
#          只檢查存在，不把值釘死 —— 釘死的話等於把另一個 repo 的預設值也抄了一份
#          進來，那是自找的維護負擔。
echo "== [3] ConfigMap 必備 key（附錄 C.2 / C.3：漏掉會靜默退回錯誤的預設值）=="

# --- 附錄 C.2：預設值跟我們要的不一樣，所以一律比對「值」 ---------------------

# session cookie 名稱：漏掉會退回 JSESSIONID，一次失去兩件事 —— __Host- 前綴的
#   瀏覽器層保護，以及「不跟 DestinationRule consistentHash 用的 Envoy 親和 cookie
#   撞名」（見 3.3）。撞名之後的症狀是偶發性掉登入，最難查的那一種。
assert_cm_key "server.servlet.session.cookie.name" "__Host-JSESSIONID"

# session timeout：漏掉會退回 Spring 預設的 30 分鐘（預期 8 小時），而且會破壞
#   「Keycloak SSO Session Idle >= servlet session timeout」這條規則。
assert_cm_key "server.servlet.session.timeout" "8h"

# 排程執行緒數：漏掉會退回 1，於是 30 秒一次的 pilot 名單 reload 排在 60 秒一次的
#   Keycloak token refresh 後面 —— 「改名單多久生效」變成不可預測，而改名單是維運
#   最常做的事。
assert_cm_key "spring.task.scheduling.pool.size" "2"

# canary cookie path：漏掉會退回 Java 預設的 "/"，cookie 變成 host-wide，而且之後
#   CanaryCookies.clear() 清不掉它（Set-Cookie 要 name/Path/Domain 全對才會覆蓋）
#   —— 使用者會被黏在 canary 上直到 8 小時過期，連逃生門都救不了。
assert_cm_key "app.canary.cookie-path" "/gui_epmmFormQuery"

# actuator base-path：漏掉會退回 /actuator，而探針打的是帶前綴的路徑（見 3.6）
#   → 404。US-007 會把探針改成 health/liveness、health/readiness，更依賴這一行。
assert_cm_key "management.endpoints.web.base-path" "/gui_epmmFormQuery/actuator"

# user-name-attribute 不在這一段裡，它有自己的檢查 [4]。原因有兩個：它的斷言要
#   同時涵蓋 track-a 與 track-b（TRACK_A_CONFIGMAPS 只有 track-a），而且它的失效
#   模式特殊到值得一段專屬的錯誤訊息 —— 見底下檢查 [4]。

# csp-policy 不能用 assert_cm_key 直接比對整串：附錄 A.2 與 3.5.1 都明說這條政策
# 是會被改的（canary 那份可以先加一個新 origin 再回頭改 stable），把整串釘死等於
# 每次調政策都得改這支腳本。但「只檢查 key 存在」又擋不住真正的失效模式 ——
# `csp-policy: ""` 是合法 YAML，而空字串正好就是「header 完全不送」的那個值，
# assert_cm_key 會放它過（空字串是刻意允許的，見 CM_KEY_SCRIPT 的說明）。
# 所以這裡改用子字串比對：釘住政策的骨架，同時允許 origin 清單演進。
CM_KEY_CONTAINS_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file, keyPath, needle] = process.argv.slice(1);
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
if (typeof cur !== "string" || !cur.includes(needle)) {
  console.error(file + ": key " + keyPath + " 少了必要的片段");
  console.error("  應包含: " + needle);
  console.error("  實際值: " + JSON.stringify(cur));
  process.exit(1);
}
'

# 用法：assert_cm_key_contains <dotted.key.path> <必須出現的子字串>
assert_cm_key_contains() {
  local key="$1" needle="$2"
  local cm
  for cm in "${TRACK_A_CONFIGMAPS[@]}"; do
    check "cm-key $key contains [$needle] ($(basename "$cm"))" \
      node -e "$CM_KEY_CONTAINS_SCRIPT" "$cm" "$key" "$needle"
  done
}

# frame-ancestors 'none' 是這條政策裡唯一真的有安全意義的指令（點擊劫持）；
# default-src 'self' 是整條政策的地基。這兩段還在，就代表沒有人「為了讓某個東西
# 動起來」把政策整條掏空成 default-src *。
assert_cm_key_contains "app.security.csp-policy" "frame-ancestors 'none'"
assert_cm_key_contains "app.security.csp-policy" "default-src 'self'"

# --- 附錄 C.3：值跟 Java 預設相同，只檢查存在 --------------------------------
# 「跟預設相同」不是省略的理由：US-006 之後是 replace 語意，jar 裡的
# application.yml 完全不會被載入，這份 ConfigMap 就是這個環境設定的唯一真相。
# 讀的人要能只看這個檔案就知道 app 怎麼跑，不必去翻另一個 repo 的 @Value 預設值。
# 這一組因此只檢查「有沒有寫」，不比對值 —— 值本來就等於預設，釘死它只是把別的
# repo 的預設值抄一份過來，之後對方改了這裡就會變成假警報。
for cm_key in \
  "app.context-prefix" \
  "app.frontend.url-prefix" \
  "app.frontend.resource-location" \
  "app.frontend.index-path" \
  "app.frontend.classpath-base" \
  "app.canary.entry-path" \
  "app.canary.roster-file" \
  "app.canary.roster-reload-ms" \
  "app.silent-auth.enabled" \
  "app.silent-auth.hint-cookie-name" \
  "app.silent-auth.hint-cookie-max-age-seconds" \
  "app.silent-auth.cookie-secure" \
  "app.token-refresh.enabled" \
  "app.token-refresh.skew-seconds" \
  "app.token-refresh.schedule-rate-ms" \
  "app.security.csp-report-only" \
  "app.security.required-role" \
  "app.privilege.enabled" \
  "app.downstream.base-url" \
  "app.third-party.base-url"
do
  assert_cm_key "$cm_key"
done

# leave-path 是 C.3 裡唯一一個把值釘死的例外，附錄 C.3 也特別點名了它：這個值同時
# 被 CanaryLeaveController 的 @GetMapping、SecurityConfig 的 permitAll 清單、
# CanaryEvictionFilter 的 pass-through 三處讀取。值寫錯不是「退回預設」，而是三處
# 對不上、逃生門安靜地失效 —— 而它存在的意義正好是「其他東西都壞了的時候」。
assert_cm_key "app.canary.leave-path" "/gui_epmmFormQuery/canary/leave"

# =============================================================================
# 檢查 4：user-name-attribute 必須是 sub（track-a 與 track-b 兩份都要）
# =============================================================================
# 為什麼這一項要獨立成一段，而不是併進檢查 [3]：
#
#   1. 它的涵蓋範圍不一樣。上面 TRACK_A_CONFIGMAPS 裡的 key（附錄 C.1/C.2/C.3）
#      是「track-a 的 ConfigMap 必須完整」這件事，track-b 不在這次的範圍內。
#      但 preferred_username 這個回歸【兩份檔案裡都有】，所以這一項的斷言必須
#      同時打到兩個 track —— 只修 track-a 的話，哪天有人從 track-b 複製設定過來，
#      就把它原樣搬回來了。
#
#   2. 它的失效模式值得一段專屬的錯誤訊息。這個 key 的危險不是「漏掉」——
#      Spring 自己的預設剛好就是 sub，漏掉反而是對的。危險的是有人【寫回】
#      preferred_username（這兩份檔案上一版就是那樣）。所以底下的腳本會特別
#      認出那個值，並且把「為什麼不行」整段印出來，而不是只說「值不對」。
#
# 這個回歸會造成什麼：
#   user-name-attribute 決定 Authentication.getName() 回傳哪個 claim，而
#   InMemoryOAuth2AuthorizedClientService 拿那個字串當 key 存 access / refresh
#   token。OIDC 只保證 sub 穩定且唯一；Keycloak 的 preferred_username 可以被改、
#   也可以在帳號刪除後回收給新人 —— 回收之後新的人算出同一個 key，會拿到前一個人
#   的 token，然後以那個身分呼叫下游。這是 review F15 的結論，
#   CANARY-COMPLETE.md 附錄 C.2 也把它列為「絕對不能寫成 preferred_username」。
#
# 為什麼不能只檢查 key 存在：存在檢查對這一項完全沒有防護力 ——
#   preferred_username 是一個「存在而且有值」的合法設定，只是值是錯的。
echo "== [4] user-name-attribute 必須是 sub（兩個 track）=="

# 涵蓋兩個 track 的清單 —— US-008 之後是三份：track-a 的 -stable / -canary
# 加上 track-b 那一份。刻意不跟 TRACK_A_CONFIGMAPS 合併：那個陣列的語意是
# 「track-a 必須完整的那幾份 ConfigMap」，把 track-b 塞進去會讓附錄 C 的每一項
# key 檢查都跑到 track-b 上，而 track-b 這次沒有被補齊，會噴出一整排假失敗。
# 新增 track-a 的 ConfigMap 時【兩個陣列都要加】：漏掉 TRACK_A_CONFIGMAPS 會少掉
# 附錄 C 的 key 檢查，漏掉這個陣列則會少掉「不得寫回 preferred_username」和
# 「死設定不得復活」—— 兩種都是無聲地少檢查一整份檔案。
BOTH_TRACK_CONFIGMAPS=(
  "canary-manual/track-a/release/10-configmap-stable.yaml"
  "canary-manual/track-a/release/11-configmap-canary.yaml"
  "canary-manual/track-b/release/10-configmap-1.2.3.yaml"
)

# 檢查名稱要帶上 track，不能只用 basename。US-008 把 track-a 那份改名成
# 10-configmap-stable.yaml 之後檔名不再撞（track-b 那份還叫 10-configmap-1.2.3.yaml），
# 但「哪一軌」仍然是讀 FAIL 訊息時第一個要知道的事，而且 track-b 哪天照附錄 C
# 補齊、跟著改名成 -stable 的話就又撞回去了。這個 helper 把 track 名字帶出來：
#   canary-manual/track-a/release/10-configmap-stable.yaml → track-a/10-configmap-stable.yaml
cm_label() {
  printf '%s/%s' "$(basename "$(dirname "$(dirname "$1")")")" "$(basename "$1")"
}

USER_NAME_ATTRIBUTE_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file] = process.argv.slice(1);
const KEY = "spring.security.oauth2.client.provider.keycloak.user-name-attribute";
const cm = y.load(fs.readFileSync(file, "utf8"));
const raw = cm && cm.data && cm.data["application.yml"];
if (typeof raw !== "string") {
  console.error(file + ": 沒有 data[\"application.yml\"]，這不是一份預期中的 ConfigMap");
  process.exit(1);
}
const app = y.load(raw);
let cur = app;
for (const seg of KEY.split(".")) {
  if (cur === null || typeof cur !== "object" || !(seg in cur)) {
    console.error(file + ": 缺少 key  " + KEY);
    console.error("  Spring 的預設剛好就是 sub，所以漏掉不會馬上壞 —— 但 US-006 之後是");
    console.error("  replace 語意，這份 ConfigMap 是這個環境設定的唯一真相，而這一行的");
    console.error("  存在本身就是給下一個人的說明（review F15）。請把它寫回來。");
    process.exit(1);
  }
  cur = cur[seg];
}
if (cur === "preferred_username") {
  console.error(file + ": user-name-attribute 又被寫回 preferred_username 了。");
  console.error("  這是 review F15 明確禁止的值，不是風格問題：");
  console.error("    Authentication.getName() 是 InMemoryOAuth2AuthorizedClientService");
  console.error("    存 access / refresh token 用的 key。OIDC 只保證 sub 穩定且唯一；");
  console.error("    Keycloak 的 preferred_username 可以被改、也可以在帳號刪除後回收給");
  console.error("    新人 —— 回收之後新的人會算出同一個 key，拿到【前一個人的 token】。");
  console.error("  正確的值是 sub。詳見 CANARY-COMPLETE.md 附錄 C.2 與該檔案裡的註解。");
  process.exit(1);
}
if (cur !== "sub") {
  console.error(file + ": user-name-attribute 的值不對");
  console.error("  期望: sub");
  console.error("  實際: " + JSON.stringify(cur));
  process.exit(1);
}
'

for cm in "${BOTH_TRACK_CONFIGMAPS[@]}"; do
  check "user-name-attribute=sub ($(cm_label "$cm"))" \
    node -e "$USER_NAME_ATTRIBUTE_SCRIPT" "$cm"
done

# =============================================================================
# 檢查 5：死設定不得復活 —— app.cors / app.sso / app.test-endpoints（兩個 track）
# =============================================================================
# 為什麼要有這一項：
#   這三塊是從兩份 ConfigMap 裡刪掉的「死設定」—— 後端【沒有任何一行程式讀它們】
#   （CANARY-COMPLETE.md 附錄 C.4）。刪掉它們不會改變任何行為，而這正是它們危險
#   的地方：加回來也一樣不會改變任何行為，所以不會有任何症狀讓人發現加錯了。
#   檢查 [2]/[3] 防的是「key 消失」，這一項防的是反方向 ——「key 長回來」。
#
#   死設定比沒有設定更糟，因為它會主動把查問題的人帶往錯誤的方向：
#     - app.cors.*   出 CORS 問題時一定有人回來改 allowed-origins。但 BFF 是同源
#                    架構，SecurityConfig 只有一行 // No .cors()（review F4），
#                    該回 Access-Control-Allow-Origin 的是【對方的伺服器】——
#                    在這裡改什麼都不會有效果，而查錯方向花掉的時間就是故障時間
#                    （附錄 A.1）。
#     - app.sso.*    錯的 key 路徑。這一塊最陰險：它「看起來」把登出導向設定好了，
#                    於是沒有人會去懷疑那個真正沒有 Java 預設值、缺了就
#                    CrashLoopBackOff 的 app.post-logout-redirect-uri（檢查 [2]）。
#     - app.test-endpoints.*  沒有任何程式讀它。
#
#   最可能讓它們復活的路徑是「從舊版本、或從另一個 track 整段複製設定過來」，
#   所以這一項跟檢查 [4] 一樣涵蓋【兩個 track】—— 只擋 track-a 的話，哪天有人
#   從 track-b 抄設定過來就原樣搬回來了。
#
# 為什麼是解析 YAML 而不是 grep：
#   兩份檔案裡現在都有一段解釋「為什麼刪掉」的註解，而那段註解本身就寫著
#   app.cors.* / app.sso.* 這幾個字。grep 會被它打到，於是這個檢查會永遠 FAIL，
#   然後被人改成「先 grep -v 掉註解」那種一碰就碎的寫法。解析後的物件上不存在
#   註解，問「這個 key 在不在」才是問對問題。
echo "== [5] 死設定不得復活：app.cors / app.sso / app.test-endpoints（兩個 track）=="

# 跟前面幾個斷言腳本相反：路徑走得到就是失敗。
# 注意「走不到」有兩種都算通過（key 完全沒寫、父層根本不存在），
# 而「寫了 key 但沒有值」（例如只留一行 `cors:`）算【失敗】—— 那仍然是一個
# 會被讀到的 key，也仍然會把下一個人引到錯的地方去。
CM_KEY_ABSENT_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file, keyPath, why] = process.argv.slice(1);
const cm = y.load(fs.readFileSync(file, "utf8"));
const raw = cm && cm.data && cm.data["application.yml"];
if (typeof raw !== "string") {
  console.error(file + ": 沒有 data[\"application.yml\"]，這不是一份預期中的 ConfigMap");
  process.exit(1);
}
let cur = y.load(raw);
for (const seg of keyPath.split(".")) {
  if (cur === null || typeof cur !== "object" || !(seg in cur)) {
    process.exit(0);
  }
  cur = cur[seg];
}
console.error(file + ": " + keyPath + " 又出現了 —— 這是一塊沒有任何程式讀的死設定。");
console.error("  " + why);
console.error("  把它加回來不會改變任何行為，所以不會有症狀提醒你加錯了；");
console.error("  但下一個查問題的人會先在它身上花掉時間。請把它刪掉。");
console.error("  見 CANARY-COMPLETE.md 附錄 C.4（不要寫進 ConfigMap 的）。");
process.exit(1);
'

# 用法：assert_cm_key_absent <dotted.key.path> <為什麼不能有>
# 跟檢查 [4] 一樣跑 BOTH_TRACK_CONFIGMAPS，而且一樣用 cm_label 而不是 basename ——
# 兩個 track 的檔名一模一樣，用 basename 的話兩行輸出會長得完全相同，
# FAIL 時看不出是哪一份壞了。
assert_cm_key_absent() {
  local key="$1" why="$2"
  local cm
  for cm in "${BOTH_TRACK_CONFIGMAPS[@]}"; do
    check "cm-key-absent $key ($(cm_label "$cm"))" \
      node -e "$CM_KEY_ABSENT_SCRIPT" "$cm" "$key" "$why"
  done
}

assert_cm_key_absent "app.cors" \
  "BFF 是同源架構，SecurityConfig 刻意沒有 .cors()（review F4），而且有測試守著；CORS 該由對方的伺服器回，見附錄 A.1。"
assert_cm_key_absent "app.sso" \
  "錯的 key 路徑，後端沒有一行程式讀它。正確的是 app.post-logout-redirect-uri（app.* 頂層），由檢查 [2] 釘住。"
assert_cm_key_absent "app.test-endpoints" \
  "沒有任何程式讀它；測試端點的開關不在 ConfigMap 裡。"

# =============================================================================
# 檢查 6：設定載入路徑 —— SPRING_CONFIG_LOCATION 要對上真正的 mount 點
# =============================================================================
# 為什麼要有這一項：
#   這是「pod 現在為什麼起不來」的直接原因（CANARY-COMPLETE.md 3.1），而它的失效
#   方式有兩種，兩種的錯誤訊息都不會指向那一行 env：
#
#     1. 變數【名字】錯。原本兩份 Deployment 寫的是 SPRING_CONFIG_ADDITIONAL_LOCATION
#        —— 那是另一個變數，merge 語意，它蓋不掉 image 內建的同名
#        SPRING_CONFIG_LOCATION=file:/config/application.yaml（Dockerfile:120），
#        而這個 repo 從來不往 /config 掛東西 → Spring Boot 對找不到的非 optional:
#        location 丟 ConfigDataLocationNotFoundException → CrashLoopBackOff。
#     2. 變數【路徑】跟 volumeMount 對不上。改了 mountPath 卻沒回頭改 env（或反過來）
#        是同一個症狀，而改 mountPath 的人通常不會想到 env 也綁著這個值。
#
#   所以底下不是只比對一個寫死的字串，而是把 env 的值跟這份 manifest 自己的
#   config volumeMount mountPath【互相對照】—— 任何一邊被單獨改動都會 FAIL。
#
# 為什麼是解析 YAML 而不是 grep 原始檔：
#   US-006 依這個 repo 的慣例，在 env 上面留了一整段註解解釋「原本是
#   SPRING_CONFIG_ADDITIONAL_LOCATION、為什麼那樣是錯的」。那段註解本身就寫著
#   SPRING_CONFIG_ADDITIONAL_LOCATION 這幾個字，所以 grep 版本的檢查會被自己的
#   說明文字打到、變成永遠 FAIL，然後被人改成「先 grep -v 掉註解」那種一碰就碎的
#   寫法。解析後的物件上不存在註解，問「有沒有這個 env 項目」才是問對問題 ——
#   跟檢查 [5] 是同一個道理。
echo "== [6] 設定載入路徑：SPRING_CONFIG_LOCATION 對上 mount 點 =="

# track-a 的兩份 Deployment。US-007（探針路徑）與 US-009（config-hash 註解）的
# 檢查都會再用到這個陣列，不要另外複製一份清單。
# 這兩個檔名彼此不同，所以這一組可以直接用 basename 當檢查名稱，
# 不需要像 ConfigMap 那樣走 cm_label（那兩份的檔名一模一樣）。
TRACK_A_DEPLOYMENTS=(
  "canary-manual/track-a/release/20-deployment-stable.yaml"
  "canary-manual/track-a/release/21-deployment-canary.yaml"
)

# 期望值寫死在腳本裡、不從 argv 傳，理由跟檢查 [4] 一樣：這一段要比對的東西不只
# 一個值，而且腳本裡本來就要印出「為什麼不行」的整段說明。
SPRING_CONFIG_LOCATION_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file] = process.argv.slice(1);
const EXPECTED = "file:/app/config/application.yml";
const BAD = "SPRING_CONFIG_ADDITIONAL_LOCATION";

const docs = y.loadAll(fs.readFileSync(file, "utf8")).filter(Boolean);

// 深走整棵樹收集指定 key 的值。不寫死 spec.template.spec.containers 這條路徑，
// 是為了讓同一段腳本對 Deployment 與 track-b 的 Rollout 都適用。
function collect(node, key, out) {
  if (Array.isArray(node)) { for (const v of node) collect(v, key, out); return out; }
  if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      if (k === key) out.push(node[k]);
      collect(node[k], key, out);
    }
  }
  return out;
}

const containers = [].concat(...collect(docs, "containers", []));
if (containers.length === 0) {
  console.error(file + ": 找不到任何 container，這不是一份預期中的 workload manifest");
  process.exit(1);
}

let failed = false;
for (const c of containers) {
  const where = file + " (container " + c.name + ")";
  const env = Array.isArray(c.env) ? c.env : [];

  if (env.some(e => e && e.name === BAD)) {
    console.error(where + ": 又出現 " + BAD + " 了。");
    console.error("  那是 merge 語意的【另一個變數】，蓋不掉 image 內建的同名");
    console.error("  SPRING_CONFIG_LOCATION=file:/config/application.yaml，於是 image 那個");
    console.error("  沒有東西掛的壞路徑依然生效 → CrashLoopBackOff。要改的是變數名稱，");
    console.error("  不只是路徑。見 CANARY-COMPLETE.md 3.1。");
    failed = true;
  }

  const hits = env.filter(e => e && e.name === "SPRING_CONFIG_LOCATION");
  if (hits.length !== 1) {
    console.error(where + ": SPRING_CONFIG_LOCATION 有 " + hits.length + " 項，應該剛好 1 項");
    failed = true;
    continue;
  }
  const val = hits[0].value;

  if (val !== EXPECTED) {
    console.error(where + ": SPRING_CONFIG_LOCATION 的值不對");
    console.error("  期望: " + EXPECTED);
    console.error("  實際: " + JSON.stringify(val));
    failed = true;
  }

  const mounts = Array.isArray(c.volumeMounts) ? c.volumeMounts : [];
  const cfg = mounts.find(m => m && m.name === "config");
  if (!cfg) {
    console.error(where + ": 找不到名為 config 的 volumeMount");
    console.error("  ConfigMap 沒掛進來的話，SPRING_CONFIG_LOCATION 指到哪都沒有意義。");
    failed = true;
    continue;
  }
  const derived = "file:" + cfg.mountPath + "/application.yml";
  if (val !== derived) {
    console.error(where + ": SPRING_CONFIG_LOCATION 跟 config volumeMount 對不上");
    console.error("  mountPath 是 " + cfg.mountPath + " → env 應該是 " + derived);
    console.error("  env 實際是 " + JSON.stringify(val));
    console.error("  這兩個值是綁在一起的：只改其中一邊，Spring 就會去讀一個沒有東西掛");
    console.error("  的路徑 → ConfigDataLocationNotFoundException → CrashLoopBackOff。");
    failed = true;
  }
}
process.exit(failed ? 1 : 0);
'

for dep in "${TRACK_A_DEPLOYMENTS[@]}"; do
  check "spring-config-location $(basename "$dep")" \
    node -e "$SPRING_CONFIG_LOCATION_SCRIPT" "$dep"
done

# --- 反方向：SPRING_CONFIG_ADDITIONAL_LOCATION 不得出現在任何 manifest 裡 -----
# 上面那段只看 track-a 的兩份 Deployment。這一段掃過 canary-manual/ 底下【每一份】
# *.yaml，防的是「新加的 manifest 從舊檔案複製 env 區塊」這條復活路徑 ——
# 跟檢查 [5] 擋死設定復活是同一個思路。
#
# 掃的是解析後的物件（JSON.stringify 整份文件），所以：
#   - env 的 name、值、甚至 ConfigMap data 裡夾帶的字串都掃得到
#   - YAML 註解掃不到（它們在解析後就不存在了）—— 這正是要的行為，
#     因為 US-006 寫的那段說明註解本身就含有這個變數名。
#
# 兩個刻意不掃的東西，理由寫在這裡免得下一個人以為是漏掉：
#   - *.md 文件（尤其 CANARY-COMPLETE.md 3.1 與 5.x）。那些地方提到這個變數名是
#     在【解釋為什麼它是錯的】，把它們掃進來等於要求刪掉那段說明。
#   - canary-manual/track-b/release/20-rollout.yaml。track-b 這一軌不在這次的範圍
#     內，而它的 ConfigMap 沒有被 US-002/US-003 補齊（附錄 C.2 / C.3 那一批 key
#     都還沒寫）。在那個狀態下把它一起翻成 replace 語意，會讓 session timeout
#     悄悄縮成 30 分鐘、cookie 改回 JSESSIONID、CSP header 整個不送 —— 那是把
#     manifest 改得更糟，不是更好，跟 US-006 排在 US-002..US-005 後面是同一個理由。
#     要修 track-b 的話，順序是：先照附錄 C 補齊 track-b 的 ConfigMap，再把它從
#     這行排除清單拿掉，兩件事在同一個 commit 裡。
SPRING_CONFIG_SWEEP_SKIP="canary-manual/track-b/release/20-rollout.yaml"

SPRING_CONFIG_ADDITIONAL_ABSENT_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file] = process.argv.slice(1);
const BAD = "SPRING_CONFIG_ADDITIONAL_LOCATION";
const docs = y.loadAll(fs.readFileSync(file, "utf8")).filter(Boolean);
if (JSON.stringify(docs).includes(BAD)) {
  console.error(file + ": 出現了 " + BAD + "。");
  console.error("  這個變數是 merge 語意，而 image 內建的是同名的");
  console.error("  SPRING_CONFIG_LOCATION=file:/config/application.yaml（Dockerfile:120）——");
  console.error("  設了前者【蓋不掉】後者，image 那個沒有東西掛的路徑依然生效，");
  console.error("  結果是 ConfigDataLocationNotFoundException → CrashLoopBackOff。");
  console.error("  正確寫法：name 用 SPRING_CONFIG_LOCATION，value 對上 config");
  console.error("  volumeMount 的 mountPath。見 CANARY-COMPLETE.md 3.1。");
  process.exit(1);
}
process.exit(0);
'

while IFS= read -r manifest; do
  if [ "$manifest" = "$SPRING_CONFIG_SWEEP_SKIP" ]; then
    continue
  fi
  check "no-additional-location $manifest" \
    node -e "$SPRING_CONFIG_ADDITIONAL_ABSENT_SCRIPT" "$manifest"
done < <(find canary-manual -type f -name '*.yaml' | sort)

# =============================================================================
# 檢查 7：探針 —— liveness 與 readiness 必須是不同的端點，且路徑對得上 ConfigMap
# =============================================================================
# 為什麼要有這一項：
#   原本三個探針都打 /gui_epmmFormQuery/actuator/health（把所有依賴都算進去的聚合
#   端點）。共用它的失效模式是：Keycloak 或下游 API 抖一下 → readiness 掉的同時
#   liveness 也掉 → kubelet 直接【重啟】pod。一次幾秒鐘的依賴故障被放大成一次全部
#   pod 的滾動重啟，而重啟會清掉 in-memory 的 HttpSession → 所有人被登出。
#   把它改回去不會有任何立即症狀（探針照樣綠燈），要等到某天依賴真的抖一下才會炸，
#   而那時候沒有人會把「大家被登出」聯想到這三行路徑 —— 所以要用檢查釘住。
#
# 為什麼是從 ConfigMap【推導】期望值，而不是各自釘一個常數：
#   這三個路徑同時綁著 ConfigMap 的兩個 key（CANARY-COMPLETE.md 3.6）：
#     - management.endpoint.health.probes.enabled: true  → 這兩個端點才存在
#     - management.endpoints.web.base-path              → 決定路徑前綴
#   兩邊各自跟寫死的字串比對，只擋得住「兩邊都改錯」；真正會發生的是「改了
#   base-path 卻沒回頭改 Deployment」—— 而改 base-path 的人根本不會想到探針也綁著
#   這個值。所以底下是先從 Deployment 讀出它自己掛的是哪一份 ConfigMap（走 config
#   volume 的 configMap.name，再用 metadata.name 去 TRACK_A_CONFIGMAPS 裡找），
#   從那份 ConfigMap 讀出 base-path，推出探針路徑應該長什麼樣，再跟實際的比。
#   任何一邊被單獨改動都會 FAIL。US-008 把 ConfigMap 拆成 -stable / -canary 之後，
#   這段程式會自動各自對到自己那一軌，不需要修改。
#
# 刻意不涵蓋 track-b：
#   canary-manual/track-b/release/20-rollout.yaml 的三個探針仍然打聚合端點，而且
#   刻意不動 —— track-b 的 ConfigMap 沒有 probes.enabled（附錄 C 那一批 key 都還沒
#   補齊，見檢查 [6] 的排除說明），在那個狀態下把路徑換成 health/readiness 會變成
#   404，readiness 永遠不過、pod 永遠不進 Endpoints，那比現況糟得多。
#   解除條件跟檢查 [6] 一樣：先補齊 track-b 的 ConfigMap，再把它的探針一起改。
echo "== [7] 探針：liveness / readiness 分開，且對得上 ConfigMap =="

# 先釘住 ConfigMap 這一半：沒有這個開關，health/liveness 與 health/readiness
# 這兩個端點根本不會被註冊，探針會拿到 404 —— readiness 404 = pod 永遠不進
# Endpoints，滾動更新會卡死在第一個新 pod 上。
# （Spring Boot 在 K8s 裡會自動打開這個開關，所以漏掉「可能」還是會動 ——
#  正因為如此更要釘住：那是隱式的環境偵測，換個跑法就沒了。）
assert_cm_key "management.endpoint.health.probes.enabled" "true"

PROBE_PATHS_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file, ...cmFiles] = process.argv.slice(1);

function collect(node, key, out) {
  if (Array.isArray(node)) { for (const v of node) collect(v, key, out); return out; }
  if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      if (k === key) out.push(node[k]);
      collect(node[k], key, out);
    }
  }
  return out;
}

// ConfigMap 索引：metadata.name -> 解析後的 application.yml。
// Deployment 引用的是【名字】不是檔名，所以要先建這個索引才對得起來。
const byName = new Map();
for (const f of cmFiles) {
  const cm = y.load(fs.readFileSync(f, "utf8"));
  if (!cm || !cm.metadata || !cm.data || typeof cm.data["application.yml"] !== "string") continue;
  byName.set(cm.metadata.name, { file: f, app: y.load(cm.data["application.yml"]) });
}

const docs = y.loadAll(fs.readFileSync(file, "utf8")).filter(Boolean);
const containers = [].concat(...collect(docs, "containers", []));
const volumes = [].concat(...collect(docs, "volumes", []));
if (containers.length === 0) {
  console.error(file + ": 找不到任何 container，這不是一份預期中的 workload manifest");
  process.exit(1);
}

const cfgVol = volumes.find(v => v && v.name === "config");
if (!cfgVol || !cfgVol.configMap || !cfgVol.configMap.name) {
  console.error(file + ": 找不到名為 config 的 volume（或它不是 configMap）");
  process.exit(1);
}
const cmName = cfgVol.configMap.name;
const entry = byName.get(cmName);
if (!entry) {
  console.error(file + ": 它掛的 ConfigMap 叫 " + cmName + "，但那個名字不在已知的");
  console.error("  track-a ConfigMap 清單裡（validate.sh 的 TRACK_A_CONFIGMAPS）。");
  console.error("  探針路徑的期望值是從那份 ConfigMap 的 base-path 推導出來的，");
  console.error("  對不到檔案就無從檢查。改 ConfigMap 名字時要一起更新那個陣列。");
  process.exit(1);
}

const app = entry.app;
const mgmt = (app && app.management) || {};
const basePath = mgmt.endpoints && mgmt.endpoints.web && mgmt.endpoints.web["base-path"];
if (typeof basePath !== "string") {
  console.error(entry.file + ": 讀不到 management.endpoints.web.base-path");
  console.error("  （檢查 [3] 也會抓到這一項，先修那邊。）");
  process.exit(1);
}
const probesEnabled = mgmt.endpoint && mgmt.endpoint.health &&
  mgmt.endpoint.health.probes && mgmt.endpoint.health.probes.enabled;
if (probesEnabled !== true) {
  console.error(entry.file + ": management.endpoint.health.probes.enabled 不是 true，");
  console.error("  但 " + file + " 的探針打的是 health/liveness、health/readiness。");
  console.error("  這兩個端點只有在那個開關打開時才存在 → 探針會拿到 404 →");
  console.error("  readiness 永遠不過 → pod 永遠不進 Endpoints。兩邊要一起改。");
  process.exit(1);
}

const WANT = {
  startupProbe:   basePath + "/health/readiness",
  readinessProbe: basePath + "/health/readiness",
  livenessProbe:  basePath + "/health/liveness",
};

let failed = false;
for (const c of containers) {
  const where = file + " (container " + c.name + ")";
  for (const p of ["startupProbe", "readinessProbe", "livenessProbe"]) {
    const probe = c[p];
    if (!probe || !probe.httpGet || typeof probe.httpGet.path !== "string") {
      console.error(where + ": 缺少 " + p + " 的 httpGet.path");
      console.error("  三個探針都要有。少了 liveness，卡死（但沒 crash）的 JVM 不會被重啟；");
      console.error("  少了 readiness，滾動更新會把還沒暖機完的 pod 直接放進 Endpoints。");
      failed = true;
      continue;
    }
    if (probe.httpGet.path !== WANT[p]) {
      console.error(where + ": " + p + " 的路徑不對");
      console.error("  期望: " + WANT[p]);
      console.error("  實際: " + probe.httpGet.path);
      console.error("  期望值是從 " + entry.file + " 的");
      console.error("  management.endpoints.web.base-path (" + basePath + ") 推導出來的 ——");
      console.error("  改了 base-path 就要回頭改這裡，反之亦然。見 CANARY-COMPLETE.md 3.6。");
      failed = true;
    }
  }

  // 即使上面每一項都對，這一段還是獨立寫出來：它要防的不是「路徑打錯字」，
  // 而是有人（例如為了「讓探針一致」）把 liveness 改成跟 readiness 同一個端點。
  // 那個改動看起來很無害、而且不會有任何立即症狀。
  const lp = c.livenessProbe && c.livenessProbe.httpGet && c.livenessProbe.httpGet.path;
  const rp = c.readinessProbe && c.readinessProbe.httpGet && c.readinessProbe.httpGet.path;
  if (typeof lp === "string" && lp === rp) {
    console.error(where + ": liveness 與 readiness 打【同一個】路徑 (" + lp + ")");
    console.error("  這兩個問的是不同的問題，不能共用端點：");
    console.error("    readiness 掉 = 暫時退出 Endpoints，依賴好了就自己回來；");
    console.error("    liveness  掉 = kubelet 【重啟】pod。");
    console.error("  共用之後，Keycloak 或下游抖一下就會讓全部 pod 滾動重啟，");
    console.error("  而重啟會清掉 in-memory 的 HttpSession —— 所有人被登出。");
    console.error("  見 CANARY-COMPLETE.md 3.6。");
    failed = true;
  }
}
process.exit(failed ? 1 : 0);
'

for dep in "${TRACK_A_DEPLOYMENTS[@]}"; do
  check "probe-paths $(basename "$dep")" \
    node -e "$PROBE_PATHS_SCRIPT" "$dep" "${TRACK_A_CONFIGMAPS[@]}"
done

# =============================================================================
# 檢查 8：ConfigMap 拆成 -stable / -canary 之後的四件事
# =============================================================================
# 為什麼要有這一項：
#   US-008 把「一份共用、名稱帶版本號、immutable」的 ConfigMap 換成「每軌一份、
#   名稱固定、可覆寫」。這個換法解掉了三個問題（CANARY-COMPLETE.md 2.1 / 2.2），
#   但也開了四個新的失效方式，而且四個都不會產生指向真正原因的錯誤訊息：
#
#     1. immutable: true 長回來。名稱固定代表這個物件會被反覆 apply 覆寫，
#        而 immutable 的 ConfigMap 連 data 都不能改 —— kubectl apply 直接以
#        "field is immutable" 失敗。它失敗的時間點是【發布當下】，而唯一的出路
#        是先 delete 再 create：那個空窗期裡任何一個掛著它的 pod 只要重啟，
#        就會卡在 ContainerCreating。
#     2. 名稱又帶上版本號。那會把「三處版本號人工同步」整套問題帶回來，
#        而且跟 cleanup 互咬：cleanup 只留 3 份舊 ConfigMap，回滾深度超過 3 版時
#        那一份已經被刪掉 → pod 卡在 ContainerCreating，回不去。
#     3. 兩份的 data 開始漂移。拆檔案這個動作本身不該引進任何設定差異；
#        允許分歧的 key 只有 3.5.1 那幾個，而且必須是刻意的動作。
#     4. Deployment 掛到【別軌】的那一份。這是四個裡最安靜的一個：pod 正常起來、
#        探針正常綠燈，只是讀著另一軌的設定 —— 症狀是「改了 canary 的設定卻沒有
#        生效」，而拆成兩份的意義整個消失。
#
# 為什麼第 4 項用推導而不是各自釘一個常數：
#   Deployment 引用的是 ConfigMap 的 metadata.name（不是檔名），而「該掛哪一份」
#   由這份 Deployment 自己的 version label 決定。所以底下的做法是：從 Deployment
#   讀出 version（stable / canary）→ 推出它該掛哪一軌 → 用 configMap.name 去
#   TRACK_A_CONFIGMAPS 建的索引裡查 → 比對那份 ConfigMap 的 labels.track。
#   任何一邊被單獨改動都會 FAIL，跟檢查 [6]（env ↔ mountPath）和檢查 [7]
#   （探針 ↔ base-path）是同一個手法。查不到名字時【必須 FAIL】而不是 skip ——
#   查不到就跳過，等於改個名字就能讓這個檢查靜靜消失。
echo "== [8] ConfigMap 拆軌：固定名稱、可覆寫、兩份相同、各掛各的 =="

# --- 8a. 兩份檔案都要在 ------------------------------------------------------
# 底下所有斷言（以及檢查 [2]/[3] 的每一個 key）都靠這兩個檔案存在。檔案不見時
# js-yaml 會噴 ENOENT，那也算 FAIL —— 但那是一整串堆疊，不如在這裡先明講
# 「這一份不見了」。改檔名時漏改 TRACK_A_CONFIGMAPS 也是撞這一項。
for cm in "${TRACK_A_CONFIGMAPS[@]}"; do
  check "cm-exists $(cm_label "$cm")" test -f "$cm"
done

# --- 8b. 結構：沒有 immutable、名稱不帶版本號、track label 對得上名稱 --------
CONFIGMAP_SPLIT_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file] = process.argv.slice(1);
const cm = y.load(fs.readFileSync(file, "utf8"));
if (!cm || cm.kind !== "ConfigMap" || !cm.metadata) {
  console.error(file + ": 這不是一份 ConfigMap");
  process.exit(1);
}
let failed = false;

if ("immutable" in cm) {
  console.error(file + ": 又出現 immutable 了（值：" + JSON.stringify(cm.immutable) + "）。");
  console.error("  這份 ConfigMap 的名稱是【固定】的，代表它會被同一個名字反覆 apply 覆寫，");
  console.error("  而 immutable 的 ConfigMap 建立之後連 data 都不能改 —— kubectl apply 會");
  console.error("  直接以 field is immutable 失敗。那不是設定錯誤，是【發布當下】才會炸出");
  console.error("  來的失敗，而唯一的出路是先 delete 再 create：那個空窗期裡任何一個掛著");
  console.error("  它的 pod 只要重啟，就會卡在 ContainerCreating。");
  console.error("  固定名稱與 immutable 不能並存。見 CANARY-COMPLETE.md 2.2。");
  failed = true;
}

const name = cm.metadata.name;
if (typeof name !== "string" || !name) {
  console.error(file + ": 沒有 metadata.name");
  process.exit(1);
}
if (/[0-9]+\.[0-9]+\.[0-9]+/.test(name)) {
  console.error(file + ": metadata.name 又帶上版本號了（" + name + "）。");
  console.error("  版本號只能出現在一個地方：container 的 image tag。ConfigMap 名稱帶版本號");
  console.error("  代表每次發布都要人工同步三處（image、volumes[config].configMap.name、");
  console.error("  pod template 的 annotation），漏改一處就是【新版程式配到舊版設定】，");
  console.error("  而那件事不會報錯。而且版本化命名跟 cleanup 互咬：只留 3 份舊 ConfigMap，");
  console.error("  回滾深度超過 3 版時那一份已經被刪掉 → pod 卡在 ContainerCreating。");
  console.error("  正確的名稱是 pmc-epmmformquery-config-stable / -canary。見第 2 章與 3.5。");
  failed = true;
}

const labels = cm.metadata.labels || {};
if ("config-version" in labels) {
  console.error(file + ": labels 裡又出現 config-version（" + JSON.stringify(labels["config-version"]) + "）。");
  console.error("  名稱都不帶版本號了，label 還帶著只會讓人以為版本化那一套還在。");
  console.error("  這裡要的維度是 track（kubectl get cm -l track=canary）。見 3.5.1。");
  failed = true;
}
const track = labels.track;
if (track !== "stable" && track !== "canary") {
  console.error(file + ": labels.track 必須是 stable 或 canary，實際是 " + JSON.stringify(track));
  console.error("  這是「這份設定屬於哪一軌」的唯一標記，而 Deployment 有沒有掛對，");
  console.error("  底下 8d 就是拿它來比對的。");
  failed = true;
} else if (!name.endsWith("-config-" + track)) {
  console.error(file + ": metadata.name 與 labels.track 對不上");
  console.error("  name  = " + name);
  console.error("  track = " + track + " → name 應該以 -config-" + track + " 結尾");
  console.error("  兩者不一致時，kubectl get cm -l track=... 撈到的東西會跟 Deployment");
  console.error("  實際掛的那一份不同 —— 而那正是查「改了設定卻沒生效」時會用的指令。");
  failed = true;
}
process.exit(failed ? 1 : 0);
'

for cm in "${TRACK_A_CONFIGMAPS[@]}"; do
  check "cm-split-shape $(cm_label "$cm")" node -e "$CONFIGMAP_SPLIT_SCRIPT" "$cm"
done

# --- 8c. 兩份的 data["application.yml"] 必須逐字相同 -------------------------
# 拆檔案本身不該引進任何設定差異：引進了的話，之後 canary 行為跟 stable 不一樣時
# 會同時有兩個嫌疑犯（拆檔案、改設定），而 canary 的問題本來就比較難重現 ——
# 只有 pilot 使用者打得到，重現一次的成本高得多。
#
# 這條斷言【預期會有壽命】：canary 遲早要分歧（3.5.1 允許 csp-policy、
# downstream/third-party base-url、logging.level 不同）。那一天要做的是把它改成
# 「只有那幾個 key 可以不同」，不是整段刪掉 —— 刪掉之後兩份會開始無聲漂移，
# 而 promote（把 canary 的 data 整段複製進 stable）會把不該帶過去的東西一起帶過去。
CONFIGMAP_IDENTICAL_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const files = process.argv.slice(1);
const read = f => {
  const cm = y.load(fs.readFileSync(f, "utf8"));
  const raw = cm && cm.data && cm.data["application.yml"];
  if (typeof raw !== "string") {
    console.error(f + ": 沒有 data[application.yml]，這不是一份預期中的 ConfigMap");
    process.exit(1);
  }
  return raw;
};
const [a, b] = files.map(read);
if (a === b) process.exit(0);

const la = a.split("\n"), lb = b.split("\n");
let i = 0;
while (i < la.length && i < lb.length && la[i] === lb[i]) i++;
console.error("兩份 ConfigMap 的 data[application.yml] 不一樣了：");
console.error("  " + files[0]);
console.error("  " + files[1]);
console.error("  第一個不同的地方在第 " + (i + 1) + " 行：");
console.error("    A: " + JSON.stringify(la[i] === undefined ? null : la[i]));
console.error("    B: " + JSON.stringify(lb[i] === undefined ? null : lb[i]));
console.error("  拆檔案本身不該引進設定差異。如果這是【刻意】要讓 canary 分歧：");
console.error("    可以分歧的 key 只有 app.security.csp-policy、app.downstream.base-url、");
console.error("    app.third-party.base-url、logging.level.*（CANARY-COMPLETE.md 3.5.1），");
console.error("    而且要把這條斷言改成「只有那幾個 key 可以不同」，不要整段刪掉。");
process.exit(1);
'

check "cm-data-identical stable==canary" \
  node -e "$CONFIGMAP_IDENTICAL_SCRIPT" "${TRACK_A_CONFIGMAPS[@]}"

# --- 8d. 每一份 Deployment 要掛【自己那一軌】的 ConfigMap --------------------
DEPLOYMENT_TRACK_CONFIGMAP_SCRIPT='
const fs = require("fs"), y = require("js-yaml");
const [file, ...cmFiles] = process.argv.slice(1);

function collect(node, key, out) {
  if (Array.isArray(node)) { for (const v of node) collect(v, key, out); return out; }
  if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      if (k === key) out.push(node[k]);
      collect(node[k], key, out);
    }
  }
  return out;
}

// ConfigMap 索引：metadata.name -> { file, track }。
// Deployment 認的是名字不是檔名，所以一定要先建這個索引才對得起來（同檢查 [7]）。
const byName = new Map();
for (const f of cmFiles) {
  const cm = y.load(fs.readFileSync(f, "utf8"));
  if (!cm || !cm.metadata || !cm.metadata.name) continue;
  byName.set(cm.metadata.name, { file: f, track: (cm.metadata.labels || {}).track });
}

const docs = y.loadAll(fs.readFileSync(file, "utf8")).filter(Boolean);
const dep = docs.find(d => d && d.kind === "Deployment");
if (!dep) {
  console.error(file + ": 找不到 Deployment");
  process.exit(1);
}

// 這份 Deployment 屬於哪一軌，是 pod template 的 version label 說了算 ——
// 那也是 DestinationRule 分 subset 的依據，所以它是全 repo 對「軌」最權威的來源。
const tmplLabels = (dep.spec && dep.spec.template && dep.spec.template.metadata &&
  dep.spec.template.metadata.labels) || {};
const track = tmplLabels.version;
if (track !== "stable" && track !== "canary") {
  console.error(file + ": pod template 的 version label 不是 stable/canary（" + JSON.stringify(track) + "）");
  console.error("  那個 label 是 DestinationRule 分 subset 的依據，也是這裡推導「該掛哪一份");
  console.error("  ConfigMap」的來源。推導不出來就不能放行 —— 跳過等於這個檢查消失。");
  process.exit(1);
}

const volumes = [].concat(...collect(dep, "volumes", []));
const cfgVol = volumes.find(v => v && v.name === "config");
if (!cfgVol || !cfgVol.configMap || !cfgVol.configMap.name) {
  console.error(file + ": 找不到名為 config 的 volume（或它不是 configMap）");
  process.exit(1);
}
const cmName = cfgVol.configMap.name;
const entry = byName.get(cmName);
if (!entry) {
  console.error(file + ": 它掛的 ConfigMap 叫 " + cmName + "，但那個名字不在已知的");
  console.error("  track-a ConfigMap 清單裡（validate.sh 的 TRACK_A_CONFIGMAPS）。");
  console.error("  沒有對應檔案的名字，代表 apply 之後叢集裡不會有這個物件 →");
  console.error("  pod 卡在 ContainerCreating（FailedMount）。改名字時兩邊要一起改。");
  process.exit(1);
}
if (entry.track !== track) {
  console.error(file + ": 這是 " + track + " 那一軌的 Deployment，卻掛了 " + entry.track + " 的 ConfigMap");
  console.error("  掛的是 " + cmName + "（" + entry.file + "）");
  console.error("  應該掛 labels.track = " + track + " 的那一份。");
  console.error("  這個錯【不會有任何錯誤訊息】：pod 正常起來、探針正常綠燈，只是讀著另一軌");
  console.error("  的設定 —— 症狀是「改了 canary 的 CSP / downstream base-url 卻沒有生效」，");
  console.error("  而拆成兩份 ConfigMap 的意義整個消失。見 CANARY-COMPLETE.md 2.1 / 3.5.1。");
  process.exit(1);
}
process.exit(0);
'

for dep in "${TRACK_A_DEPLOYMENTS[@]}"; do
  check "deployment-own-track-configmap $(basename "$dep")" \
    node -e "$DEPLOYMENT_TRACK_CONFIGMAP_SCRIPT" "$dep" "${TRACK_A_CONFIGMAPS[@]}"
done

# =============================================================================
# 檢查 9：config-hash 必須等於自己那一軌 ConfigMap 內容的雜湊
# =============================================================================
# 為什麼要有這一項：
#   US-008 之前，ConfigMap 的名字帶版本號，改設定 = 改名字 = 改到 pod template，
#   kubectl apply 自然會滾動更新。名字固定之後那條因果鏈斷了：
#
#       改 ConfigMap 內容 → apply → pod template 一個欄位都沒變
#         → 沒有任何 pod 重啟 → Spring 只在啟動時讀一次設定檔
#         → 新設定 apply 了卻【沒有生效】
#
#   而且這件事沒有錯誤訊息：kubectl get / describe 都正常，ConfigMap 裡確實是
#   新內容，只有行為跟你以為的不一樣。config-hash（data["application.yml"] 的
#   sha256 前 8 碼）就是把那條鏈接回來的東西 —— 內容變 → hash 變 → template 變
#   → 滾動更新（CANARY-COMPLETE.md 2.2 表格第 3 條、3.6）。
#
#   但 config-hash 自己的失效方式一樣是安靜的：改了 ConfigMap 卻忘了跑
#   scripts/sync-config-hash.sh，hash 就停在舊值 —— 不會報錯，只是不重啟，
#   症狀跟上面那一段一模一樣。這一段檢查是那個安靜失效【唯一】的攔截點：
#   它自己重算一次雜湊，跟 manifest 裡寫的值比對，忘了跑同步腳本就 FAIL。
#
# 為什麼是推導而不是釘一個常數：
#   期望值不是寫死的字串，而是從「這份 Deployment 掛的那一份 ConfigMap」的內容
#   即時算出來的（走 volumes[config].configMap.name → metadata.name 索引，
#   同檢查 [7] / [8d]）。所以改 ConfigMap 內容、改掛載的名字、改 hash 值，
#   三者任何一個被單獨改動都會 FAIL。查不到名字時【必須 FAIL】不能 skip。
echo "== [9] config-hash 對得上 ConfigMap 內容 =="

CONFIG_HASH_SCRIPT='
const fs = require("fs"), y = require("js-yaml"), crypto = require("crypto");
const [file, ...cmFiles] = process.argv.slice(1);

function collect(node, key, out) {
  if (Array.isArray(node)) { for (const v of node) collect(v, key, out); return out; }
  if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      if (k === key) out.push(node[k]);
      collect(node[k], key, out);
    }
  }
  return out;
}

// ConfigMap 索引：metadata.name -> { file, hash }。
// 雜湊的對象是【解析後】的 data[application.yml] 字串，不是原始檔的位元組 ——
// 叢集那一端（6.3 節的 kubectl ... | sha256sum | cut -c1-8）算的也是這個，
// 所以兩邊的值可以直接對照。對原始檔算的話，改一個註解就會讓 hash 變，
// 而那不是設定變更、不該觸發全部 pod 滾動重啟。
const byName = new Map();
for (const f of cmFiles) {
  const cm = y.load(fs.readFileSync(f, "utf8"));
  if (!cm || !cm.metadata || !cm.metadata.name || !cm.data) continue;
  const app = cm.data["application.yml"];
  if (typeof app !== "string") continue;
  byName.set(cm.metadata.name, {
    file: f,
    hash: crypto.createHash("sha256").update(app, "utf8").digest("hex").slice(0, 8),
  });
}

const docs = y.loadAll(fs.readFileSync(file, "utf8")).filter(Boolean);
const dep = docs.find(d => d && d.kind === "Deployment");
if (!dep) {
  console.error(file + ": 找不到 Deployment");
  process.exit(1);
}

let failed = false;

const tmplMeta = (dep.spec && dep.spec.template && dep.spec.template.metadata) || {};
const ann = tmplMeta.annotations || {};
const topAnn = (dep.metadata && dep.metadata.annotations) || {};

// 反方向的斷言：舊機制不得復活。
if ("config-version" in ann || "config-version" in topAnn) {
  console.error(file + ": 又出現 config-version annotation 了。");
  console.error("  ConfigMap 的名稱在 US-008 之後是固定的（不帶版本號），所以這個值");
  console.error("  不會再跟著設定變動 —— 它是一個永遠不動的常數，等於沒有這個機制。");
  console.error("  留著它最大的害處是讓人以為「版本化那一套還在、改設定會自動重啟」，");
  console.error("  於是改完設定就直接 apply，然後花很久去查為什麼設定沒有生效。");
  console.error("  要的是 config-hash（見 CANARY-COMPLETE.md 2.2 / 3.6）。");
  failed = true;
}

const got = ann["config-hash"];
if (typeof got !== "string") {
  console.error(file + ": spec.template.metadata.annotations 底下沒有 config-hash");
  console.error("  實際的 annotations: " + JSON.stringify(Object.keys(ann)));
  if ("config-hash" in topAnn) {
    console.error("  它跑到 Deployment 自己的 metadata.annotations 去了 —— 那個位置");
    console.error("  【不是】pod template 的一部分，改了不會觸發任何滾動更新。");
  }
  console.error("  沒有這一行，改 ConfigMap 內容就不會有任何 pod 重啟，而 Spring");
  console.error("  只在啟動時讀一次設定檔 → 設定 apply 了卻沒有生效，且不會報錯。");
  process.exit(1);
}
if (!/^[0-9a-f]{8}$/.test(got)) {
  console.error(file + ": config-hash 的格式不對（" + JSON.stringify(got) + "）");
  console.error("  它必須是 sha256 前 8 碼的小寫十六進位，由 scripts/sync-config-hash.sh");
  console.error("  回寫。手打的值不會跟 ConfigMap 的內容對上 —— 而對不上就代表下一次");
  console.error("  改設定時 hash 可能【剛好不變】，於是不重啟。");
  process.exit(1);
}

// Deployment 認的是 ConfigMap 的名字不是檔名，所以要走索引查（同檢查 [7] / [8d]）。
const volumes = [].concat(...collect(dep, "volumes", []));
const cfgVol = volumes.find(v => v && v.name === "config");
if (!cfgVol || !cfgVol.configMap || !cfgVol.configMap.name) {
  console.error(file + ": 找不到名為 config 的 volume（或它不是 configMap）");
  process.exit(1);
}
const cmName = cfgVol.configMap.name;
const entry = byName.get(cmName);
if (!entry) {
  console.error(file + ": 它掛的 ConfigMap 叫 " + cmName + "，但那個名字不在已知的");
  console.error("  track-a ConfigMap 清單裡（validate.sh 的 TRACK_A_CONFIGMAPS）。");
  console.error("  config-hash 的期望值是從那份 ConfigMap 的內容算出來的，對不到檔案");
  console.error("  就無從檢查 —— 而「查不到就跳過」等於改個名字就能讓這個檢查消失。");
  process.exit(1);
}

if (got !== entry.hash) {
  console.error(file + ": config-hash 跟它掛的 ConfigMap 內容對不上");
  console.error("  manifest 寫的: " + got);
  console.error("  重算出來的  : " + entry.hash + "（來源 " + entry.file + "）");
  console.error("  最常見的原因：改了 ConfigMap 的內容，但忘了跑");
  console.error("      bash scripts/sync-config-hash.sh");
  console.error("  這件事在叢集上【不會報錯】，只是 pod template 沒變 → 沒有任何 pod");
  console.error("  重啟 → Spring 只在啟動時讀一次設定檔 → 新設定沒有生效，而 kubectl");
  console.error("  get / describe 全都正常。跑完同步腳本後，ConfigMap 與 Deployment 的");
  console.error("  改動要放進【同一個 commit】—— 那是 git revert 能一次回滾兩者的前提");
  console.error("  （CANARY-COMPLETE.md 2.2 表格第 1 條、8.4）。");
  failed = true;
}

process.exit(failed ? 1 : 0);
'

for dep in "${TRACK_A_DEPLOYMENTS[@]}"; do
  check "config-hash $(basename "$dep")" \
    node -e "$CONFIG_HASH_SCRIPT" "$dep" "${TRACK_A_CONFIGMAPS[@]}"
done

# --- 9b. 同步腳本必須存在且冪等 ----------------------------------------------
# 冪等的意思是「連跑兩次，第二次不會產生任何改動」。為什麼這件事值得檢查：
# 這支腳本是用【文字取代】改 manifest 的（不能用 y.dump 整份寫回去，那會把整個
# repo 的中文註解洗掉）。文字取代寫壞的典型症狀就是每跑一次就多改一點 ——
# 例如把行尾的 \r 吃掉、或每次都重新排版 —— 於是「跑一次同步腳本」變成一個
# 會製造雜訊 diff 的動作，而雜訊 diff 會讓人在 code review 時看不見真正的改動。
#
# 做法：先把兩份 Deployment 備份起來，跑一次腳本，比對位元組，然後【無論結果】
# 都從備份還原。這樣：
#   - 檔案裡的 hash 是對的（檢查 9a 已經確認）時，腳本什麼都不會改，比對通過；
#   - 檔案裡的 hash 過期時，腳本會把它改對 → 比對失敗 → 這裡也 FAIL，
#     跟 9a 指向同一個原因（忘了跑同步腳本），兩邊的訊息互相印證。
#   - 還原是無條件的：品質閘門不應該順手改你的工作目錄，即使改對了也一樣。
#
# 刻意不用 `git diff --quiet` 判定：那個指令比對的是 HEAD，所以只要工作目錄裡
# 有任何未 commit 的改動（而「改完 manifest 跑一次 validate.sh」正是這個 repo
# 的標準工作流程）它就會失敗 —— 一個在正常開發途中永遠是紅的檢查，下場是被
# 刪掉或被無視。備份比對問的是「跑這支腳本有沒有改到東西」，那才是冪等的定義，
# 而且不管工作目錄乾不乾淨都成立。
sync_config_hash_idempotent() {
  local tmp rc=0 f out
  tmp="$(mktemp -d)" || { echo "無法建立暫存目錄"; return 1; }

  for f in "${TRACK_A_DEPLOYMENTS[@]}"; do
    cp "$f" "$tmp/$(basename "$f").before" || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    echo "備份 Deployment 失敗，這一項無法判定"
    rm -rf "$tmp"
    return 1
  fi

  if ! out="$(bash scripts/sync-config-hash.sh 2>&1)"; then
    echo "scripts/sync-config-hash.sh 執行失敗："
    printf '%s\n' "$out"
    rc=1
  fi

  for f in "${TRACK_A_DEPLOYMENTS[@]}"; do
    if ! cmp -s "$f" "$tmp/$(basename "$f").before"; then
      echo "$f: 跑一次 scripts/sync-config-hash.sh 之後檔案內容變了。"
      echo "  這代表 manifest 裡的 config-hash 是過期的（改了 ConfigMap 卻沒跑同步"
      echo "  腳本），或者腳本自己不冪等。前者請跑 bash scripts/sync-config-hash.sh"
      echo "  並把改動跟 ConfigMap 放進同一個 commit；後者請修腳本。"
      echo "  差異："
      diff "$tmp/$(basename "$f").before" "$f" | sed 's/^/    /'
      rc=1
    fi
    # 還原是無條件的：閘門不改你的工作目錄。
    cp "$tmp/$(basename "$f").before" "$f"
  done

  rm -rf "$tmp"
  return "$rc"
}

check "sync-script-exists" test -f scripts/sync-config-hash.sh
check "sync-config-hash-idempotent" sync_config_hash_idempotent

# --- 總結 --------------------------------------------------------------------
echo
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "ALL PASS — $CHECK_COUNT 項檢查全部通過"
  exit 0
else
  echo "FAILED — $CHECK_COUNT 項檢查中有 $FAIL_COUNT 項失敗"
  exit 1
fi
