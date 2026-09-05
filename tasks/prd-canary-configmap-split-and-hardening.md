# PRD: Canary ConfigMap 拆分與上線前修正

> 相關文件：`../canary-manual/CANARY-COMPLETE.md`（完整手冊，本 PRD 的每一項都在那裡有對應章節）、
> `prd-bff-canary-static-assets.md`（靜態資源那一層，**本 PRD 不重複，只交叉引用**）、
> `../bffautocanarydesign.md`（BFF 自動分流的原始設計提案）。

## 1. Introduction

`canary-manual/track-a/` 的 cookie 指定式 canary 已經寫好，BFF 端的自動分流程式
（`canary/` 套件）也已在 `spring_oauth2_backend` 實作並有測試守住。但 K8s 這側的 manifest
**還沒有在真實叢集驗證過**，而且與 image 內建的設定載入方式不相容。

一次程式碼審查找出 5 個會讓 pod 起不來或讓保護機制形同虛設的問題，
以及 8 個影響 canary 正確性的問題。同時，目前只有一份共用 ConfigMap，
使得兩軌無法各自帶不同設定，而版本化的 ConfigMap 命名又與 cleanup 腳本互咬，
造成「回滾時 ConfigMap 已被刪除 → pod 卡在 `ContainerCreating`」。

本 PRD 分四個階段修正這些問題。**階段之間可以獨立上線**，階段 1 是其餘階段的前提。

## 2. Goals

- **G1**：pod 能可靠啟動，且啟動失敗時錯誤訊息指向真正的原因。
- **G2**：健康檢查真的能反映應用狀態（目前無條件通過）。
- **G3**：stable 與 canary 各自持有一份 ConfigMap，可以帶不同的 CSP、後端 URL、log level。
- **G4**：回滾是單一動作（`git revert` 一個 commit），且 image 與設定一起還原。
- **G5**：關閉 canary（不論簽核通過或不通過）都不會讓任何 cookie 持有者收到 503。
- **G6**：需要人工同步的版本號從 3 處降到 1 處（只剩 image tag）。
- **G7**：CORS / CSP 的實際行為與文件一致，且死設定從 repo 移除。

## 3. User Stories

### US-001: 修正設定載入路徑
**Description:** 身為維運人員，我要 pod 能真的讀到掛載的 ConfigMap，而不是在啟動時因為找不到設定檔而 CrashLoop。

**Acceptance Criteria:**
- [ ] `20-deployment-stable.yaml` 與 `21-deployment-canary.yaml` 的 env 從 `SPRING_CONFIG_ADDITIONAL_LOCATION` 改為 `SPRING_CONFIG_LOCATION`，值為 `file:/app/config/application.yml`
- [ ] `kubectl -n ea-pmc logs deploy/pmc-epmmformquerygui-stable -c app` 沒有 `ConfigDataLocationNotFoundException`
- [ ] `kubectl -n ea-pmc exec <pod> -c app -- head -3 /app/config/application.yml` 印得出 ConfigMap 的內容
- [ ] 兩個 Deployment 都**沒有**殘留 `SPRING_CONFIG_ADDITIONAL_LOCATION`（`grep -c ADDITIONAL track-a/release/*.yaml` 回 0）
- [ ] `spring_oauth2_backend/Dockerfile` **不改**（決策：只從 k8s 側修）

### US-002: 補齊 ConfigMap 缺少的 key
**Description:** 身為維運人員，我要 ConfigMap 在 replace 語意下是完整的，這樣就不會有設定悄悄退回 Java 預設值。

**Acceptance Criteria:**
- [ ] ConfigMap 含 `spring.security.oauth2.client.provider.keycloak.issuer-uri: ${KEYCLOAK_ISSUER_URI}`
- [ ] ConfigMap 含 `app.post-logout-redirect-uri`（`@Value` 無預設值，缺了會 `Could not resolve placeholder`）
- [ ] ConfigMap 含 `spring.security.oauth2.client.registration.keycloak.redirect-uri: "{baseUrl}/gui_epmmFormQuery/login/oauth2/code/{registrationId}"`
- [ ] ConfigMap 含 `server.servlet.session.timeout: 8h` 與 `server.servlet.session.cookie.{name,same-site,secure,http-only}`
- [ ] ConfigMap 含 `app.security.csp-policy` 與 `app.security.csp-report-only`
- [ ] ConfigMap 含 `spring.task.scheduling.pool.size: 2`
- [ ] ConfigMap 含 `app.canary.leave-path`
- [ ] `curl -sS -o /dev/null -D - <url> | grep -i content-security-policy` 有回 `Content-Security-Policy-Report-Only`（在此之前完全沒有這個 header）
- [ ] 登入後 F12 → Application → Cookies 看到 session cookie 名為 `__Host-JSESSIONID`

### US-003: 修正 `user-name-attribute` 回歸
**Description:** 身為開發者，我要 token store 用穩定的 key，這樣帳號被回收重用時不會解析到前一個人的 token。

**Acceptance Criteria:**
- [ ] ConfigMap 的 `spring...provider.keycloak.user-name-attribute` 值為 `sub`（不是 `preferred_username`）
- [ ] `track-b/release/10-configmap-1.2.3.yaml` 同步修正
- [ ] ConfigMap 裡留一行註解說明為什麼（review F15），避免下一個人又改回去
- [ ] 登入後 `kubectl logs` 的 `canary EVICT_TO_STABLE` 那行的 `user=` 仍然顯示帳號名（不是 UUID）—— 證明 `CanaryUsernames` 讀的是 claim 而不是 `Authentication.getName()`

### US-004: 移除死設定
**Description:** 身為維運人員，我不要 repo 裡有「改了不會有任何效果」的設定，因為出事時它們會把人帶往錯的方向。

**Acceptance Criteria:**
- [ ] ConfigMap 移除整塊 `app.cors.*`（5 個 key）
- [ ] ConfigMap 移除 `app.sso.*`（3 個 key，錯的 key 路徑，正確的是 `app.post-logout-redirect-uri`）
- [ ] ConfigMap 移除 `app.test-endpoints.enabled`（後端沒有程式讀）
- [ ] `grep -rn "app.cors\|app.sso\|test-endpoints" track-a/ track-b/` 沒有輸出
- [ ] `CANARY-COMPLETE.md` 附錄 A 說明「BFF 刻意不設 CORS」以及要去哪裡看真正的 CORS 問題

### US-005: 讓健康檢查真的有效
**Description:** 身為維運人員，我要探針在應用壞掉時變紅，而不是無論如何都綠。

**Acceptance Criteria:**
- [ ] **後端**：`SecurityConfig` 的 permitAll 清單加入 `contextPrefix + "/actuator/health"` 與 `contextPrefix + "/actuator/health/**"`
- [ ] **後端**：新增測試，斷言未認證的 `GET /gui_epmmFormQuery/actuator/health` 回 **200**（不是 302）
- [ ] ConfigMap 加入 `management.endpoint.health.probes.enabled: true`
- [ ] `livenessProbe` 改指向 `/gui_epmmFormQuery/actuator/health/liveness`
- [ ] `readinessProbe` 與 `startupProbe` 改指向 `/gui_epmmFormQuery/actuator/health/readiness`
- [ ] `curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/gui_epmmFormQuery/actuator/health/readiness` 在 pod 內回 `200`
- [ ] 刻意把 `KEYCLOAK_ISSUER_URI` 指到不存在的位址，確認 readiness 變紅（而不是照樣通過）
- [ ] Typecheck / `mvn -B test` 通過

### US-006: ConfigMap 拆成 stable / canary 兩份
**Description:** 身為維運人員，我要兩軌各自持有設定，這樣改 canary 的 CSP 或後端 URL 不會連帶滾動 stable。

**Acceptance Criteria:**
- [ ] `release/10-configmap-1.2.3.yaml` 改名為 `release/10-configmap-stable.yaml`，ConfigMap 名稱 `pmc-epmmformquery-config-stable`
- [ ] 新增 `release/11-configmap-canary.yaml`，ConfigMap 名稱 `pmc-epmmformquery-config-canary`
- [ ] 兩份都**沒有** `immutable: true`
- [ ] 兩份都有 `labels.track`（`stable` / `canary`）
- [ ] `20-deployment-stable.yaml` 的 `volumes[config].configMap.name` 指向 `-config-stable`
- [ ] `21-deployment-canary.yaml` 的 `volumes[config].configMap.name` 指向 `-config-canary`
- [ ] 兩份 ConfigMap 初始內容逐字相同（`diff` 只有 `metadata.name` 與 `labels.track` 兩處差異）
- [ ] `kubectl -n ea-pmc get cm -l app=pmc-epmmformquerygui` 列出兩份，且名稱都不帶版本號

### US-007: `config-hash` annotation 與同步腳本
**Description:** 身為維運人員，我要改 ConfigMap 內容會自動觸發滾動更新，而且忘記同步時 CI 會擋下來。

**Acceptance Criteria:**
- [ ] 兩個 Deployment 的 `spec.template.metadata.annotations` 用 `config-hash` 取代 `config-version`
- [ ] 新增 `scripts/sync-config-hash.sh`：讀兩份 ConfigMap 的 `data."application.yml"`，算 sha256 前 8 碼，回寫對應 Deployment 的 annotation
- [ ] 腳本是**冪等**的：連跑兩次第二次沒有 diff
- [ ] 新增 CI 檢查：annotation 與 ConfigMap 內容算出來的 hash 不符時 **build 失敗**
- [ ] 改 ConfigMap 內容 → apply → `kubectl rollout status` 顯示真的滾動了
- [ ] 只改 ConfigMap 的註解（不改實質設定）也會觸發滾動 —— 這是可接受的保守行為，寫進手冊

### US-008: 回滾規則
**Description:** 身為維運人員，我要回滾是一個動作，而且不會留下「新設定配舊程式」的半吊子狀態。

**Acceptance Criteria:**
- [ ] `CANARY-COMPLETE.md` 第 8.3 節把 `kubectl rollout undo` 列入禁止動作，並說明原因
- [ ] 發布流程明文要求 ConfigMap 與 Deployment 的改動在**同一個 commit**
- [ ] 新增 CI 檢查：一個 commit 若動到 `release/2*-deployment-*.yaml` 的 image 或 `config-hash`，就必須同時動到對應的 `release/1*-configmap-*.yaml`（或明確標註 `[config-unchanged]`）
- [ ] 實測：`git revert <promote commit>` → apply → ConfigMap 的 sha256 與 Deployment 的 `config-hash` 相同
- [ ] `scripts/canary.sh` 的 `cmd_undo`（`kubectl rollout undo`）移除或改成印出警告後拒絕執行

### US-009: promote 的排空順序
**Description:** 身為維運人員，我要簽核通過之後把 canary 收掉時，不會讓還握著 cookie 的人吃 503。

**Acceptance Criteria:**
- [ ] promote 拆成兩個 commit：第一個把 stable 升版 + canary 換成同版 + `APP_CANARY_ENABLED="false"`（**`replicas` 維持 1**）；第二個（確認排空後）才把 `replicas` 改成 0
- [ ] 第一個 commit 之後，`sum(rate(istio_requests_total{destination_version="canary",response_code="503"}[5m]))` 維持 **0**
- [ ] 提供排空確認指令，且該指令在還有人使用 canary 時回非零值
- [ ] `scripts/canary.sh` 的 `cmd_promote` 與 `cmd_rollback` 移除 `scale --replicas=0`，或整個腳本標為不維護
- [ ] `README.md` 中「簽核不通過 → `replicas: 1 → 0`」的段落改寫或標為已被取代

### US-010: VirtualService 三項修正
**Description:** 身為維運人員，我要路由規則不會誤傷同 host 的其他 app、不會重送 POST、驗證訊號不會說謊。

**Acceptance Criteria:**
- [ ] 規則 1（`pilot-run`）的 match 加上 `uri: { prefix: /gui_epmmFormQuery }`，與 cookie 條件同屬一個 match 項目（AND 語意）
- [ ] 帶 `canary=always` cookie 打 `https://myapp.example.com/gui_epmmFormEdit/...` **不會**被送進本 app 的 canary subset
- [ ] 規則 2（`primary`）移除 `weight: 0` 的 canary destination，只留 stable 單一 destination（不寫 `weight`）
- [ ] 兩條規則的 `retryOn` 移除 `5xx`，只留 `reset,connect-failure,refused-stream`
- [ ] 規則 3（`default`）加上 `timeout: 15s`
- [ ] 不帶 cookie → `x-app-track: stable`；帶 cookie → `x-app-track: canary`（迴歸測試）

### US-011: 親和 cookie 改名
**Description:** 身為開發者，我不要 Envoy 與 Tomcat 搶著寫同一個 cookie 名稱。

**Acceptance Criteria:**
- [ ] `base/02-destinationrule.yaml` 的 `consistentHash.httpCookie.name` 從 `JSESSIONID` 改為 `epmm-affinity`
- [ ] `track-b/base/02-destinationrule.yaml` 兩份 DR 同步修正
- [ ] 登入後 F12 → Cookies 同時看到 `__Host-JSESSIONID`（Tomcat）與 `epmm-affinity`（Envoy），名稱不重疊
- [ ] 連續 20 次請求都落在同一個 pod（`x-pod-name` 或 log 比對）—— 證明黏著仍然有效

### US-012: 安全基線
**Description:** 身為維運人員，我要 namespace 有網路隔離與 pod 安全標準，而不是全通。

**Acceptance Criteria:**
- [ ] 新增 `base/05-networkpolicy.yaml`：default-deny + allow-dns + allow-istio-control-plane + allow-gateway-to-app + egress 到 Keycloak 與外部 API
- [ ] 新增 `base/04-poddisruptionbudget.yaml`：`minAvailable: 1`，selector 只選 `version: stable`
- [ ] 先在測試環境套用 NetworkPolicy 並確認 pod 仍能登入、能打 Keycloak
- [ ] 確認叢集是否有 istio-cni（`kubectl -n istio-system get daemonset | grep -i cni`）；**有**才把 namespace 標成 `pod-security.kubernetes.io/enforce: restricted`，**沒有**則用 `baseline` + `audit/warn: restricted`
- [ ] `PeerAuthentication` 先用 `PERMISSIVE` 上線並觀察 ≥ 1 週，再評估切 `STRICT`

### US-013: CSP 與外部 API 的短期補救
**Description:** 身為前端開發者，我要 React 直接用 axios 打外部 service 時，CSP 與 CORS 的行為是已知且被記錄的。

**Acceptance Criteria:**
- [ ] 確認外部服務的 origin，加進**canary 那份** ConfigMap 的 `csp-policy` 的 `connect-src`
- [ ] `csp-policy` 加上 `report-uri`（或明確記錄「靠 pilot 使用者回報 Console 紅字」這個決定）
- [ ] 用 `curl -i -X OPTIONS <外部端點> -H "Origin: https://myapp.example.com" -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: content-type,x-api-key"` 確認對方回 204 並涵蓋所需 header
- [ ] axios 確認**沒有**設 `withCredentials: true`
- [ ] `pilot-run-guide.md` 的檢查清單加一項：「開啟會打外部 API 的頁面，確認 Console 沒有 CORS 或 CSP 紅字」
- [ ] `pilot-run-guide.md` 加註：「外部 API 在整個 canary 期間必須向後相容；這次改版若動到外部 API 契約，這套 canary 不足以驗它」
- [ ] `csp-report-only` **維持 `true`**，直到跑完一整個 pilot 週期且 Console 乾淨

### US-014: 外部呼叫收回 BFF（獨立階段）
**Description:** 身為架構負責人，我要外部 API 的呼叫走 BFF，這樣 API key 不進瀏覽器，而且 canary 可以指向不同的後端。

**Acceptance Criteria:**
- [ ] 新增 `/gui_epmmFormQuery/rs/**` 的 proxy controller，重用既有的 `DownstreamApiClient` / `ThirdPartyApiClient`（**不要**手動設 `Authorization` header —— 那會繞過 token refresh）
- [ ] SPA 的 axios `baseURL` 改成同源的 `/gui_epmmFormQuery/rs`
- [ ] SPA 在 mutating request 帶上從 `XSRF-TOKEN` cookie 讀來的 `X-XSRF-TOKEN` header（axios 預設會做）
- [ ] SPA 收到 `/rs/**` 的 **401** 時做 top-level navigation（`window.location.assign(window.location.href)`），不是顯示錯誤
- [ ] API key 從前端 bundle 移除，改由 pod 的 Secret 注入
- [ ] `csp-policy` 的 `connect-src` 收回 `'self'`
- [ ] canary 那份 ConfigMap 的 `app.downstream.base-url` 可以指向不同後端，且該設定只影響 canary pod
- [ ] 處理 review F18：`thirdPartyWebClient` 不再重用同一個 `keycloak` registration 的 access token
- [ ] Typecheck / `mvn -B test` 通過；新增 controller 的整合測試

## 4. Functional Requirements

**階段 1 — P0（其餘階段的前提）**

- FR-1：兩個 Deployment 的設定載入 env 為 `SPRING_CONFIG_LOCATION=file:/app/config/application.yml`。
- FR-2：ConfigMap 必須包含 `CANARY-COMPLETE.md` 附錄 C 的 C.1、C.2、C.3 所列的全部 key。
- FR-3：`user-name-attribute` 必須是 `sub`，並附註解說明。
- FR-4：`app.cors.*`、`app.sso.*`、`app.test-endpoints.*` 從所有 manifest 移除。
- FR-5：`SecurityConfig` 的 permitAll 必須涵蓋帶 `app.context-prefix` 前綴的 actuator health 路徑。
- FR-6：liveness 與 readiness 必須使用不同端點（`health/liveness` 與 `health/readiness`）。

**階段 2 — ConfigMap 拆分**

- FR-7：ConfigMap 名稱固定為 `pmc-epmmformquery-config-stable` / `-canary`，不帶版本號、不 immutable。
- FR-8：pod template 用 `config-hash`（ConfigMap `data."application.yml"` 的 sha256 前 8 碼）取代 `config-version`。
- FR-9：`scripts/sync-config-hash.sh` 必須冪等，且 CI 要驗證 annotation 與內容一致。
- FR-10：CI 必須驗證動到 Deployment image / `config-hash` 的 commit 同時動到對應的 ConfigMap。
- FR-11：整個 repo 只有 container image tag 一處帶版本號。

**階段 3 — canary 正確性**

- FR-12：promote 必須拆成「換版 + 停用主開關」與「排空後縮容」兩個 commit。
- FR-13：VirtualService 規則 1 必須同時比對 cookie 與 `uri: prefix: /gui_epmmFormQuery`。
- FR-14：VirtualService 規則 2 只能有一個 destination（stable）。
- FR-15：所有 `retryOn` 不得包含 `5xx`。
- FR-16：VirtualService 每一條 route 都必須設 `timeout`。
- FR-17：DestinationRule 的親和 cookie 名稱為 `epmm-affinity`。
- FR-18：`scripts/canary.sh` 與 `README.md` 不得再指示單獨使用 `replicas: 0` 或 `kubectl rollout undo`。

**階段 4 — 外部呼叫收回 BFF**

- FR-19：SPA 對外部服務的呼叫必須經由同源的 `/gui_epmmFormQuery/rs/**`。
- FR-20：外部服務的憑證（API key）不得出現在前端 bundle 中。
- FR-21：`csp-policy` 的 `connect-src` 在階段 4 完成後收回 `'self'`。

## 5. Non-Goals

- **不做百分比分流。** VirtualService 的正式流量永遠 100% 走 stable，`weight` 欄位在階段 3 被移除正是為了讓這件事顯而易見。
- **不做 session 外部化**（Spring Session + Redis）。那會讓兩軌共用 session store，canary 寫壞 session 會污染 stable。
- **不改 `spring_oauth2_backend/Dockerfile`。** 決策已定：設定載入只從 k8s 側修。
- **不處理靜態資源的快取與 ETag。** 那一層由 `prd-bff-canary-static-assets.md` 負責，本 PRD 只交叉引用。
- **不做 Argo Rollouts（Track B）的自動分流。** Track B 目前完全沒跟上（缺 `APP_TRACK`、`APP_CANARY_ENABLED`、名單掛載，`10-configmap` 還被截斷）。要嘛另開一個 PRD 補齊，要嘛把 `track-b/` 標為不維護 —— 見 Open Question 4。
- **不修 `ExternalPageController` 的前綴漂移。** 已記錄在手冊第 10 章，但它與 canary 無關，屬於後端獨立議題。
- **不引入 Kustomize 或 Helm。** 現行 CD 只能 `kubectl apply`，維持純 YAML。

## 6. Design Considerations

- **兩份 ConfigMap 的差異必須最小化。** 只有 `metadata.name`、`labels.track`、`csp-policy`、`downstream/third-party.base-url`、`logging.level.*` 允許不同。promote 的動作是整段複製 `data:`，差異越少越不容易出事。
- **`APP_CANARY_ENABLED` 與 `APP_TRACK` 留在 Deployment 的 env**，不進 ConfigMap —— 關閉 canary 只要改一個 env。
- **pilot 名單 ConfigMap 不參與 `config-hash`。** 改名單不該重啟任何 pod。它的 volume 必須維持 `optional: true`，否則名字打錯會讓 **stable** 卡在 `ContainerCreating`。
- 掛載一律**掛目錄，不用 `subPath`** —— `subPath` 掛的檔案永遠不會跟著 ConfigMap 更新。

## 7. Technical Considerations

- **`SPRING_CONFIG_LOCATION` 是 replace 語意**，不是 merge。這是「ConfigMap 必須完整」這條要求的根源。Deployment 的 `env` 會覆蓋 image 的 `ENV`，所以不需要重建 image。
- **拿掉 `immutable: true` 是必要的**，不是偏好：固定名稱的 ConfigMap 要能被 `kubectl apply` 覆寫，留著 immutable 會直接噴 `field is immutable`。
- **`kubectl rollout undo` 在拆分後會製造靜默的 code/config 錯配** —— 它還原 pod template（含舊的 `config-hash`）但 ConfigMap 內容已經是新的。這是拆分換來的唯一代價，用「同一個 commit + `git revert`」補回來。
- **canary 必須維持 `replicas: 1`**：in-flight OAuth2 `state`、`HttpSession`、authorized-client token 全部在 pod 記憶體。
- **`maxSurge: 1` 代表換 canary image 時會短暫有 2 個 pod**，該窗口內的 canary 使用者要重登一次。屬於已知代價。
- **PSS `restricted` 需要 istio-cni**，否則 `istio-init` 的 `NET_ADMIN`/`NET_RAW` 會被擋掉，整個 namespace 的 pod 都建不起來。上線前必須先確認。
- **`app.canary.leave-path` 是一個值被三處讀取**（`CanaryLeaveController` 的 `@GetMapping`、`SecurityConfig` 的 permitAll、`CanaryEvictionFilter` 的 pass-through）。任何不同步都會靜默失效。
- **不要新增設快取 header 的 filter。** `ResourceHttpRequestHandler` 用 `response.setHeader()` 寫 Cache-Control，會覆蓋 filter 先前設的值 —— 那個 filter 會安靜地什麼都不做。

## 8. Success Metrics

| 指標 | 現況 | 目標 |
|---|---|---|
| 需要人工同步的版本號處數 | 3（image / configMap.name / annotation） | **1**（只有 image tag） |
| 「回滾時 ConfigMap 找不到」的可能性 | 存在（cleanup 只留 3 版） | **0**（名稱固定，永遠存在） |
| 關閉 canary 造成的 503 | promote 與 reject 兩條路徑都可能發生 | **0** |
| 探針能偵測到的故障 | 0（無條件通過） | Keycloak 不可達、bundle 缺失都能讓 readiness 變紅 |
| 啟動失敗到定位原因的時間 | 未知（錯誤訊息不指向真因） | 手冊 9.1 的對照表可以直接對到修法 |
| 改 canary 的 CSP 需要滾動 stable | 需要 | **不需要** |
| repo 內的死設定 | 3 組（`app.cors.*`、`app.sso.*`、`app.test-endpoints.*`） | **0** |

## 9. Open Questions

1. **外部 service 的實際 origin 是什麼？** US-013 的 `connect-src` 與 preflight 驗證都需要具體位址。
2. **那把 API key 有配額、計費或寫入權限嗎？** 如果有，US-014（收回 BFF）就不是「長期最佳化」而是必須優先做的。
3. **叢集有沒有裝 istio-cni？** 決定 US-012 的 PSS 能上 `restricted` 還是只能 `baseline`。
4. **Track B（Argo Rollouts）要補齊還是廢除？** 目前它與自動分流完全不相容，而且 `10-configmap-1.2.3.yaml` 檔案本身是截斷的。留著不修比刪掉更危險 —— 有人會以為它可用。
5. **CSP 什麼時候切 enforce？** 建議先在 canary 那份切、stable 維持 report-only，跑完一個 pilot 週期再說。需要有人拍板時程。
6. **`ExternalPageController` 的前綴漂移誰修？** 它讓登出落地頁與拒絕存取頁 404，跟 canary 無關但會影響 pilot 使用者的觀感。
7. **值班同仁接受 promote 拆成兩個 commit 嗎？** 這是流程變更（第二個 commit 可能隔天才送），不只是程式變更，需要有人同意。
