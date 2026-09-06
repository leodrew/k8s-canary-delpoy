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

# 涵蓋兩個 track 的清單。刻意不跟 TRACK_A_CONFIGMAPS 合併：那個陣列的語意是
# 「track-a 必須完整的那幾份 ConfigMap」，把 track-b 塞進去會讓附錄 C 的每一項
# key 檢查都跑到 track-b 上，而 track-b 這次沒有被補齊，會噴出一整排假失敗。
BOTH_TRACK_CONFIGMAPS=(
  "canary-manual/track-a/release/10-configmap-1.2.3.yaml"
  "canary-manual/track-b/release/10-configmap-1.2.3.yaml"
)

# 兩個 track 的 ConfigMap 檔名一模一樣（都叫 10-configmap-1.2.3.yaml），
# 所以這裡不能用 basename 當檢查名稱 —— 兩行 PASS 會長得完全一樣，
# 失敗時看不出是哪一份壞了。這個 helper 把 track 名字一起帶出來：
#   canary-manual/track-a/release/10-configmap-1.2.3.yaml → track-a/10-configmap-1.2.3.yaml
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

# --- 總結 --------------------------------------------------------------------
echo
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "ALL PASS — $CHECK_COUNT 項檢查全部通過"
  exit 0
else
  echo "FAILED — $CHECK_COUNT 項檢查中有 $FAIL_COUNT 項失敗"
  exit 1
fi
