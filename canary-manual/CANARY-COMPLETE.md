# Canary 完整手冊 — 寫 YAML → 上線 → 測試 → 維運 → 排錯

> **這份取代了什麼**
>
> | 舊文件 | 狀態 |
> |---|---|
> | `README.md` | 已被取代（設計理由仍可讀，操作步驟以本文為準） |
> | `SOP.md` | 已被取代（需要完整 kubectl 權限的版本） |
> | `SOP-apply-only.md` | 已被取代（apply-only 的版本） |
> | `canary-ops-runbook.md` | 已被取代（併入第 7–9 章） |
> | `pilot-run-guide.md` | **保留** —— 讀者是驗證人員，不是維運，維持獨立入口 |
>
> 相關但不重複的文件：
> `../k8s-ecosystem-guide.md` Part 14/15（設計原理）、
> `../bffautocanarydesign.md`（BFF 自動分流的設計提案）、
> `../tasks/prd-bff-canary-static-assets.md`（靜態資源那一層的 PRD）、
> `../tasks/prd-canary-configmap-split-and-hardening.md`（本文所列修正的實作 PRD）。

---

## 0. 這套機制在做什麼

正式流量的權重**永遠**是 stable 100 / canary 0。只有帶 `canary=always` cookie 的 pilot 使用者
會被 Istio 送進 canary。cookie 由 stable pod 在**登入成功那一刻**依名單自動發放。

```
   正式使用者 ───────────────────────▶ stable（舊版，weight 100）
                                          ▲
   pilot 使用者                           │  簽核通過後
   （BFF 依名單自動發 cookie）             │  才把 canary 的 image 升為 stable
        └────────────────────────────▶ canary（新版，weight 0）
```

**這代表 pilot 期間對正式使用者的路由風險是零** —— 但**程式風險不是零**，
發 cookie 的那段程式跑在 stable 的每一次登入上。這個取捨要講清楚，見第 10 章。

### 適用範圍

- namespace `ea-pmc`、app `pmc-epmmformquerygui`
- CD 只能 `kubectl apply`（不能 patch / scale / delete）
- Track A（純 Deployment + Istio）。Track B（Argo Rollouts）目前**沒有跟上自動分流**，見第 10 章。

---

## 1. 心智模型：四層

排錯的第一件事是**定位在哪一層**。四層各自獨立壞掉，症狀卻很像。

| 層 | 誰負責 | 壞掉的樣子 | 用什麼看 |
|---|---|---|---|
| **① Istio 路由** | `base/` 的 Service / DestinationRule / VirtualService | 503（`UH` / `NC`）、帶 cookie 還是進 stable | 回應的 `x-app-track`、`istioctl proxy-config` |
| **② BFF 決策** | `canary/` 套件（發 cookie / 趕人 / 逃生門） | 在名單裡卻沒被切過去、被踢來踢去 | pod log 的 `roster reloaded` 與 `canary EVICT_TO_STABLE` |
| **③ 應用設定載入** | Deployment 的 `SPRING_CONFIG_LOCATION` + ConfigMap | **CrashLoopBackOff**，或更糟：起得來但一堆設定悄悄變成 Java 預設 | `kubectl logs` 的啟動例外、`/actuator/env` |
| **④ 瀏覽器快取** | `WebAppConfig` 的 `noCache()` + content ETag | 白畫面、靜默混版（看起來像新版 bug，其實不存在） | F12 Network 的 `ETag` / `Cache-Control` |

> **第 ③ 層是這份手冊新增的。** 之前的 runbook 只有三層，
> 但實際上最容易一次弄死整個環境的就是這一層 —— 見第 3.1 節。

---

## 2. 檔案分層與命名規則

```
track-a/
├── base/          變更頻率：極低（網路設定）      → 單獨 stage，額外簽核
│   ├── 00-serviceaccount.yaml
│   ├── 01-service.yaml
│   ├── 02-destinationrule.yaml
│   └── 03-virtualservice.yaml
├── release/       變更頻率：每次發布              → 發布 pipeline
│   ├── 10-configmap-stable.yaml
│   ├── 11-configmap-canary.yaml
│   ├── 20-deployment-stable.yaml
│   └── 21-deployment-canary.yaml
└── runtime/       變更頻率：pilot 期間一天數次    → 獨立，不經過發布流程
    └── 05-configmap-canary-pilot.yaml
```

`kubectl apply -f <dir>/` 依**檔名順序**套用，所以 ConfigMap（`10-`/`11-`）一定先於
workload（`20-`/`21-`）建立。順序反了 pod 會卡在 `ContainerCreating`。

### 命名規則：固定 `-stable` / `-canary`，不帶版本號

| 物件 | 名稱 | 帶版本號？ |
|---|---|---|
| Deployment | `pmc-epmmformquerygui-stable` / `-canary` | ✗ |
| ConfigMap（應用設定） | `pmc-epmmformquery-config-stable` / `-canary` | ✗ |
| ConfigMap（pilot 名單） | `pmc-epmmformquery-canary-pilot` | ✗ |
| Service / DestinationRule / VirtualService / ServiceAccount | 單一物件，兩軌共用 | ✗ |
| **container image** | `your-registry/pmc-epmmformquerygui:1.3.0` | **✓ 唯一一處** |

> **改動重點：整個 repo 只剩 image tag 一處帶版本號。**
> 舊做法有「三處版本號」（image、`configMap.name`、`config-version` annotation）要人工同步，
> 少改一處就是「新版程式配舊版設定」。現在 ConfigMap 名稱固定，annotation 改成
> **內容雜湊**（第 2.2 節），所以只剩一處需要人工維護。

### 2.1 為什麼 ConfigMap 拆成兩份

一份共用 ConfigMap 有三個具體問題：

1. **CSP / 外部 API URL 這類設定改不動。** canary 的新前端要多一個 `connect-src` origin，
   或要指向不同的 `DOWNSTREAM_API_URL`，你必須改到 stable 也在讀的那份 → 連 stable 一起滾動。
2. **canary 期間兩軌必然要不同設定**（至少 `APP_CANARY_ENABLED`），共用一份就得靠 env 覆蓋，
   而 env 覆蓋在 `SPRING_CONFIG_LOCATION` 的 replace 語意下容易看不出全貌。
3. **版本化命名 + cleanup 會互咬。** 舊做法把 ConfigMap 命名成 `...-config-1.2.3` 並保留舊版供回滾，
   但 `scripts/canary.sh cleanup` 預設只留 3 個。回滾超過 3 版 → ConfigMap 不存在 →
   pod 卡在 `ContainerCreating`。這正是「回滾時找不到檔案」。

### 2.2 拆分之後放棄了什麼

固定名稱的 ConfigMap 是**可變**的（必須拿掉 `immutable: true`，否則 `kubectl apply` 會噴
`field is immutable`）。代價是：

> **`kubectl rollout undo` 不再會回滾設定。**
> 它還原 pod template（含舊的 `config-hash` annotation），但 ConfigMap 的內容已經是新的 ——
> pod 用舊 annotation 重啟、掛到**新**設定。這是靜默的 code/config 錯配，沒有任何錯誤訊息。

用三條規則補回來：

| # | 規則 |
|---|---|
| 1 | **ConfigMap 與 Deployment 的改動必須在同一個 commit。** 回滾一律 `git revert <該 commit>` → 重跑 apply |
| 2 | **`kubectl rollout undo` 列入禁止動作**（跟 `replicas: 0` 並列，見第 8 章） |
| 3 | `config-hash` 由 `scripts/sync-config-hash.sh` 計算回寫，**再加 CI 檢查**確認一致 —— hash 過期不會報錯，只會安靜地不重啟 |

---

## 3. 怎麼寫這些 YAML

以下是**修正後**的版本。跟目前 repo 裡的 `track-a/` 有差異的地方都標了 `【修正】`。
本文件不會替你套用 —— 確認過再自己改。

### 3.1 【先讀這一節】設定是怎麼載入的

這是整套機制最容易一次弄死整個環境的地方，而且錯誤訊息不會指向真正的原因。

```
image 的 Dockerfile:120     ENV SPRING_CONFIG_LOCATION=file:/config/application.yaml
Deployment 的 env           SPRING_CONFIG_ADDITIONAL_LOCATION=file:/app/config/application.yml
ConfigMap 掛載點            /app/config
```

三個值互不相容：

| 問題 | 後果 |
|---|---|
| 沒有任何東西掛在 `/config/application.yaml` | Spring Boot 2.4+ 對非 `optional:` 且找不到的 `spring.config.location` 丟 `ConfigDataLocationNotFoundException` → **CrashLoopBackOff** |
| `SPRING_CONFIG_LOCATION` 是 **replace** 語意，不是 merge | jar 裡的 `application.yml` **完全不會載入**。ConfigMap 沒寫的每一個 key 都退回 Java 的 `@Value` 預設 |

`【修正】` **Deployment 改用 `SPRING_CONFIG_LOCATION`，路徑對上 mount 點：**

```yaml
            - name: SPRING_CONFIG_LOCATION
              value: "file:/app/config/application.yml"
```

Deployment 的 `env` 會覆蓋 image 的 `ENV`，所以**不需要重建 image**。
replace 語意維持不變，代價是 **ConfigMap 必須真的完整** —— 完整的定義見附錄 C。

> 目前的 ConfigMap **不完整**，而且缺的三個 key 會直接讓 pod 起不來：
>
> | 缺的 key | Java 端 | 後果 |
> |---|---|---|
> | `spring...provider.keycloak.issuer-uri` | 無預設（在 jar 的 `!test` profile document，replace 語意下不載入） | OAuth2 client 建不起來 → **啟動失敗** |
> | `app.post-logout-redirect-uri` | `@Value("${app.post-logout-redirect-uri}")` **沒有預設值** | `Could not resolve placeholder` → **啟動失敗** |
> | `spring...registration.keycloak.redirect-uri` | Spring 預設 `{baseUrl}/login/oauth2/code/{registrationId}`（**沒有 `/gui_epmmFormQuery` 前綴**） | 跟 `redirectionEndpoint.baseUri` 對不上 → callback 進不來 / Keycloak 回 redirect_uri 不符 |

### 3.2 `base/01-service.yaml`

不變。三個關鍵：

```yaml
spec:
  type: ClusterIP
  selector:
    app: pmc-epmmformquerygui     # (1) 只比對 app —— 兩軌的 pod 都要被選中
  ports:                          #     多寫 version 會讓另一個 subset 沒有 endpoint → 503 UH
    - name: http                  # (2) 必要：Istio 靠它判定 L7 協定
      port: 8080
      targetPort: 8080
      protocol: TCP
      appProtocol: http           # (3) 比 port 命名更明確，兩個都寫
```

**不要加 `sessionAffinity: ClientIP`** —— 那是 kube-proxy 的功能，mesh 內的流量由 sidecar
直送 Pod IP，繞過 kube-proxy，設了也不會生效。黏著交給 DestinationRule。

### 3.3 `base/02-destinationrule.yaml`

```yaml
spec:
  host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: epmm-affinity     # 【修正】原本是 JSESSIONID
          ttl: 10800s
    connectionPool:
      tcp:  { maxConnections: 100, connectTimeout: 3s }
      http: { http1MaxPendingRequests: 100, maxRequestsPerConnection: 0 }
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
  subsets:
    - name: stable
      labels: { version: stable }
    - name: canary
      labels: { version: canary }
```

`【修正】` **親和 cookie 改名 `epmm-affinity`。** Envoy 對這顆 cookie 的行為是
「請求裡沒有就自己發一顆」，所以名字若跟應用的 session cookie 撞在一起，
就會有**兩個系統寫同一個名字**。

風險路徑很具體：ConfigMap 若沒寫 `server.servlet.session.cookie.name`，
Spring 會退回預設的 `JSESSIONID` —— 正好就是舊設定裡叫 Envoy 管的那個名字。
`spring_oauth2_backend/docs/istio-stickiness.md` 本來就寫 `epmm-affinity`，兩邊對齊即可。

> **`maxEjectionPercent: 50` 對 canary 永遠不會生效**（1 個 pod 的 50% = 0 個）。
> 這剛好是好事 —— 踢掉唯一的 canary pod 等於讓所有 cookie 持有者吃 503。
> 但不要把它當成 canary 還有熔斷保護。

### 3.4 `base/03-virtualservice.yaml`

```yaml
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   # 內部呼叫也要納管
  gateways:
    - istio-system/my-gateway
    - mesh                        # 必要：寫了 gateway 就不含 mesh，要顯式加回來
  http:
    # ===== 規則 1：pilot run —— 必須排第一（first-match-wins）=====
    - name: pilot-run
      match:
        - headers:
            cookie:
              regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"
          uri: { prefix: /gui_epmmFormQuery }   # 【修正】原本沒有 uri match
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: canary
            port: { number: 8080 }
      headers:
        response:
          set: { x-app-track: "canary" }
      timeout: 15s
      retries:
        attempts: 3
        perTryTimeout: 4s
        retryOn: "reset,connect-failure,refused-stream"   # 【修正】拿掉 5xx

    # ===== 規則 2：正式流量 =====
    - name: primary
      match:
        - uri: { prefix: /gui_epmmFormQuery/ }
        - uri: { exact: /gui_epmmFormQuery }
      route:
        - destination:                          # 【修正】拿掉 weight: 0 的 canary destination
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: stable
            port: { number: 8080 }
      headers:
        response:
          set: { x-app-track: "stable" }
      timeout: 15s
      retries:
        attempts: 3
        perTryTimeout: 4s
        retryOn: "reset,connect-failure,refused-stream"

    # ===== 規則 3：catch-all，一定放最後 =====
    - name: default
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: stable
            port: { number: 8080 }
      timeout: 15s                              # 【修正】原本沒有 timeout
```

三個修正的理由：

**`【修正】` 規則 1 加 `uri: prefix: /gui_epmmFormQuery`。**
原本規則 1 只比對 cookie，沒有路徑條件。這代表握有 cookie 的人，對
`myapp.example.com` 上**任何路徑**的請求都會被送進**這支 app** 的 canary subset ——
包含同 host 的 FormEdit / FormRender。cookie 的 `Path` 已經縮到 `/gui_epmmFormQuery`
（所以實務上瀏覽器不會把它送到別的路徑），但路由規則本身沒有對應的護欄，
一旦有人把 cookie path 改回 `/`，就會變成跨 app 劫持。加一行成本為零。

**`【修正】` 規則 2 拿掉 `weight: 0` 的 canary destination。**
`headers.response.set` 是 **route 層級**的，不是 destination 層級。原本那條 route
同時含 stable(100) 與 canary(0)，兩個 destination 回來的東西都會被貼上
`x-app-track: stable`。今天 weight 是 0 所以看不出來，但**任何人一放量，
SOP 唯一的驗證訊號就開始說謊**。這套機制的定位是「不做百分比分流」，
那就不要留一個 weight 欄位在那裡引誘人去改它 —— 真要放量時再加回來，
並同時把 header 改成由 app 依 `APP_TRACK` 自己發。

**`【修正】` `retryOn` 拿掉 `5xx`。** Istio 的 retry **不分 HTTP method**。
`5xx` 會讓一個失敗的 `POST` 表單最多重送 3 次。只留連線層級的重試
（`reset` / `connect-failure` / `refused-stream`）才是安全的。

### 3.5 `release/10-configmap-stable.yaml` 與 `11-configmap-canary.yaml`

兩份的差異**只有 `metadata.name`、`labels.track`，以及第 3.5.1 節列的那幾個 key**。
其餘逐字相同。

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-config-stable     # canary 版：...-config-canary
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
    track: stable                           # canary 版：canary
# 【修正】沒有 immutable: true —— 固定名稱的 ConfigMap 必須可以 apply 覆寫，
#         留著 immutable 會讓 kubectl apply 直接噴 "field is immutable"
data:
  application.yml: |
    # =========================================================================
    # 【重要】Deployment 用 SPRING_CONFIG_LOCATION（replace 語意）載入這一份，
    # jar 內的 application.yml 完全不會被讀到。這裡漏掉的每一個 key 都會
    # 退回 Java 的 @Value 預設值 —— 完整清單見手冊附錄 C。
    # =========================================================================
    server:
      port: 8080
      # 載重設定：TLS 在 Istio 終止，沒有這行 Tomcat 看到的是 http，
      # OAuth2 redirect-uri 會解析成 http:// 而在 Keycloak 比對失敗，HSTS 也不會送
      forward-headers-strategy: framework
      servlet:
        session:
          timeout: 8h                    # 【修正】缺這行會退回 30 分鐘
          cookie:
            name: __Host-JSESSIONID      # 【修正】缺這行會退回 JSESSIONID，
            same-site: lax               #         跟 Envoy 的親和 cookie 撞名
            secure: true
            http-only: true

    spring:
      application:
        name: pmc-epmmformquerygui
      task:
        scheduling:
          pool:
            size: 2                      # 【修正】預設 1 會讓名單 reload 排在
                                         # Keycloak token refresh 後面，生效時間變不可預測
      security:
        oauth2:
          client:
            registration:
              keycloak:
                client-id: ${KEYCLOAK_CLIENT_ID}
                client-secret: ${KEYCLOAK_CLIENT_SECRET}
                authorization-grant-type: authorization_code
                scope: [openid, profile, email]
                # 【修正】缺這行會退回 Spring 預設（沒有 /gui_epmmFormQuery 前綴），
                # 跟 redirectionEndpoint.baseUri 對不上
                redirect-uri: "{baseUrl}/gui_epmmFormQuery/login/oauth2/code/{registrationId}"
            provider:
              keycloak:
                issuer-uri: ${KEYCLOAK_ISSUER_URI}   # 【修正】被誤刪過，缺了直接啟動失敗
                # 【修正】原本寫 preferred_username —— 那會覆蓋 jar 裡刻意設定的 sub。
                # InMemoryOAuth2AuthorizedClientService 以 Authentication.getName() 當 key，
                # OIDC 不保證 preferred_username 穩定或唯一，帳號被回收重用時
                # 會解析到前一個人的 token（review F15）。必須是 sub。
                user-name-attribute: sub

    app:
      context-prefix: /gui_epmmFormQuery

      # 【修正】原本這裡有一整塊 app.cors.* —— 後端沒有任何一行程式讀它，已刪除。
      # BFF 是同源架構，刻意不設 CORS（SecurityConfig 的 // No .cors()，review F4）。
      # 詳見手冊附錄 A。

      # 【修正】原本寫成 app.sso.post-logout-redirect-uri（錯的 key 路徑）。
      # 正確的 key 沒有 Java 預設值，缺了會 Could not resolve placeholder → 啟動失敗。
      post-logout-redirect-uri: ${POST_LOGOUT_REDIRECT_URI:{baseUrl}/gui_epmmFormQuery/page/logged-out}

      security:
        # 【修正】缺這兩行 → @Value 拿到空字串 → 連 Report-Only 的 header 都不會送出去
        csp-policy: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        csp-report-only: true
        required-role: ""

      token-refresh:
        enabled: true
        skew-seconds: 60
        schedule-rate-ms: 60000

      silent-auth:
        enabled: true                    # 註：目前沒有程式讀這個 toggle
        hint-cookie-name: ea_login_hint
        hint-cookie-max-age-seconds: 2592000
        cookie-secure: true

      downstream:
        base-url: ${DOWNSTREAM_API_URL:http://internal-api:8080}
      third-party:
        base-url: ${THIRD_PARTY_API_URL:https://partner.example.com}

      privilege:
        enabled: ${PRIVILEGE_CHECK_ENABLED:false}   # true 目前會 fail closed（全部 503）

      frontend:
        url-prefix: /gui_epmmFormQuery/web
        resource-location: classpath:/gui_epmmFormQuery/web/
        index-path: /gui_epmmFormQuery/web/index.html
        classpath-base: gui_epmmFormQuery/web

      canary:
        enabled: ${APP_CANARY_ENABLED:false}
        track: ${APP_TRACK:stable}
        cookie-max-age: 8h
        # 【關鍵】Java 預設是 "/" —— 漏掉這行 canary cookie 會變成 host-wide，
        # 而且之後 CanaryCookies.clear() 清不掉（Set-Cookie 要 name/Path/Domain 全對）
        cookie-path: /gui_epmmFormQuery
        roster-file: /app/canary/pilot-users.txt
        roster-reload-ms: 30000
        entry-path: /gui_epmmFormQuery/web/
        # 【修正】原本缺這行。這個值同時被 CanaryLeaveController 的 @GetMapping、
        # SecurityConfig 的 permitAll、CanaryEvictionFilter 的 pass-through 讀取，
        # 三處只要有一處不同步就會靜默失效
        leave-path: /gui_epmmFormQuery/canary/leave

    logging:
      pattern:
        console: "%d{HH:mm:ss.SSS} [%X{traceId:-}] %-5level %logger{36} - %msg%n"
      level:
        com.example.epmmformquery: INFO
        org.springframework.security.oauth2.client: INFO

    management:
      endpoints:
        web:
          base-path: /gui_epmmFormQuery/actuator
          exposure:
            include: health,info
      endpoint:
        health:
          show-details: when-authorized
          probes:
            enabled: true                # liveness / readiness 兩個獨立群組
```

#### 3.5.1 兩份 ConfigMap 唯一該不同的地方

| key | stable | canary | 為什麼 |
|---|---|---|---|
| `metadata.name` | `...-config-stable` | `...-config-canary` | 各自掛載 |
| `metadata.labels.track` | `stable` | `canary` | 方便 `kubectl get cm -l track=canary` |
| `app.security.csp-policy` | 現行政策 | **可以先加新 origin** | canary 前端要多打一個外部服務時，不必動到 stable |
| `app.downstream.base-url` / `app.third-party.base-url` | 正式後端 | **可以指向 canary 後端** | 這是拆兩份之後才做得到的事，見附錄 A |
| `logging.level.*` | INFO | 可以開 DEBUG | canary 只有 pilot 使用者，log 量可控 |

**除了這幾行，其他每一個字都必須相同。** promote 的時候是把 canary 那份的 `data:`
整段複製進 stable 那份 —— 差異越少，複製時越不容易出事。

> `APP_CANARY_ENABLED` / `APP_TRACK` **不要寫死在 ConfigMap 裡**，維持用 Deployment 的 env 注入。
> 關閉 canary 時只要改一個 env，不必動設定檔。

### 3.6 `release/20-deployment-stable.yaml`

只列跟現況不同的部分，其餘（securityContext、topologySpreadConstraints、preStop、
`holdApplicationUntilProxyStarts`）維持原樣 —— 那些寫得很好，不要動。

```yaml
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui
        version: stable
      annotations:
        # 【修正】原本是 config-version: "1.2.3"。
        # 改成 ConfigMap data 區塊的 sha256 前 8 碼，由 scripts/sync-config-hash.sh 回寫。
        # 改設定內容 → hash 變 → pod template 變 → 觸發滾動更新。
        config-hash: "a1b2c3d4"
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.2.3   # 唯一帶版本號的地方
          env:
            # 【修正】原本是 SPRING_CONFIG_ADDITIONAL_LOCATION 且路徑指向 /config/
            - name: SPRING_CONFIG_LOCATION
              value: "file:/app/config/application.yml"
            - name: APP_TRACK
              value: "stable"
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }

          # 【修正】liveness 與 readiness 分開，不要共用同一個端點。
          # 前提：SecurityConfig 的 permitAll 要加上帶前綴的路徑（見下方警告）
          startupProbe:
            httpGet: { path: /gui_epmmFormQuery/actuator/health/readiness, port: 8080 }
            failureThreshold: 30
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /gui_epmmFormQuery/actuator/health/readiness, port: 8080 }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /gui_epmmFormQuery/actuator/health/liveness, port: 8080 }
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3

          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
            - name: tmp
              mountPath: /tmp                 # readOnlyRootFilesystem: true 需要
            - name: canary-pilot
              mountPath: /app/canary          # 【關鍵】掛目錄，不是 subPath
              readOnly: true                  #   subPath 掛的檔案永遠不會跟著 ConfigMap 更新
      volumes:
        - name: config
          configMap:
            name: pmc-epmmformquery-config-stable    # 【修正】固定名稱，不帶版本號
        - name: tmp
          emptyDir: {}
        - name: canary-pilot
          configMap:
            name: pmc-epmmformquery-canary-pilot
            optional: true                  # 【關鍵】ConfigMap 不在也不能卡住 pod 啟動
```

> **⚠ 探針目前是假的，YAML 改不掉。**
>
> `SecurityConfig` 的 permitAll 清單裡只有**沒有前綴**的 `/actuator/health`、`/actuator/health/**`，
> 但 ConfigMap 的 `management.endpoints.web.base-path` 把 actuator 搬到
> `/gui_epmmFormQuery/actuator`。前綴路徑落在 `anyRequest().authenticated()` → 回 **302**。
>
> **kubelet 把 2xx 和 3xx 都算成功**，所以 startup / readiness / liveness 三個探針
> **無條件通過** —— app 完全壞掉也偵測不到，`maxUnavailable: 0` 的保護一起失效。
>
> 還有一個附帶損害：kubelet 會跟著同 host 的 302 走到
> `/gui_epmmFormQuery/oauth2/authorization/keycloak`，而那個端點會**建立一個 HttpSession**
> 來存 in-flight 的 OAuth2 `state`。三個探針 × 每 10 秒 × 每個 pod，
> 等於持續製造沒有人用的 session，每個活到 `session.timeout`（8 小時）才消失。
>
> 修法是後端加一行（PRD 階段 1）：
> ```java
> a.requestMatchers(
>         "/actuator/health", "/actuator/health/**",
>         contextPrefix + "/actuator/health",          // 新增
>         contextPrefix + "/actuator/health/**",       // 新增
>         ...
> ).permitAll();
> ```
> **在那行上線之前，不要相信探針的綠燈。**

### 3.7 `release/21-deployment-canary.yaml`

跟 stable 的差異：

| 欄位 | 值 |
|---|---|
| `metadata.name` | `pmc-epmmformquerygui-canary` |
| `labels` / `selector` / template labels 的 `version` | `canary` |
| `replicas` | **1**（發布期間）／ 0（靜止期間，但只能在排空後才設，見第 8 章） |
| `volumes[config].configMap.name` | `pmc-epmmformquery-config-canary` |
| `env` 多一個 | `APP_CANARY_ENABLED: "true"` |
| `env` 的 `APP_TRACK` | `"canary"` |

> **canary 永遠只能 1 個 replica。** in-flight 的 OAuth2 `state`、`HttpSession`、
> authorized-client token 全部在 pod 記憶體裡。2 個 pod 會讓使用者隨機拿到
> `authorization_request_not_found` 並被踢回 Keycloak。
>
> 附帶問題：`maxSurge: 1, maxUnavailable: 0` 代表**換 canary image 的那幾十秒會有 2 個 pod**。
> 這個窗口內的 canary 使用者會被要求重新登入一次。屬於已知代價，寫進第 10 章即可。

### 3.8 `runtime/05-configmap-canary-pilot.yaml`

不變。三個「不要」都是刻意的：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-canary-pilot   # 不帶版本號：帶了改名單就要重啟 stable
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
# 不要加 immutable: true —— 改名單就是要能改
# 不要在 Deployment 加對應的 config-hash annotation —— 改名單不該重啟任何 pod
data:
  pilot-users.txt: |
    # 一行一個 Keycloak 的 preferred_username（使用者登入時打的帳號名，不是 OIDC sub）
    # 開頭是 # 的是註解，空行忽略，大小寫不敏感
    # 空檔案 = 沒有任何人會被自動送進 canary
```

### 3.9 【新增】`base/04-poddisruptionbudget.yaml`

目前沒有 PDB。node drain 可能一次拿掉 stable 的兩個 pod。

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pmc-epmmformquerygui-stable-pdb
  namespace: ea-pmc
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: pmc-epmmformquerygui
      version: stable        # 只保護 stable —— canary 只有 1 個 pod，
                             # 給它 PDB 會擋住 node drain
```

---

## 4. 首次上線

### 4.1 前置檢查（沒過就不要往下走）

```bash
NS=ea-pmc

# (1) sidecar 有沒有注入？沒有的話 Istio 什麼都管不到
kubectl get ns $NS --show-labels | grep istio-injection
kubectl -n $NS get pod -l app=pmc-epmmformquerygui \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
# 每個 pod 都要看到 istio-proxy

# (2) 叢集有沒有裝 istio-cni？（決定 namespace 能不能上 restricted PSS，見附錄 B）
kubectl -n istio-system get daemonset | grep -i cni || echo "  沒有 istio-cni"

# (3) Service 的 port 有 name 與 appProtocol 嗎？沒有的話 cookie 比對（L7）不會生效
kubectl -n $NS get svc pmc-epmmformquerygui-svc -o jsonpath='{.spec.ports[0]}'; echo

# (4) 全部 dry-run（server 端會驗 CRD schema，client 端不會）
kubectl apply --dry-run=server -f track-a/base/
kubectl apply --dry-run=server -f track-a/release/
kubectl apply --dry-run=server -f track-a/runtime/
```

### 4.2 套用順序

```bash
kubectl apply -f track-a/base/       # 身分與網路（單獨 stage，需要額外簽核）
kubectl apply -f track-a/runtime/    # pilot 名單（先建立，Deployment 才掛得到）
kubectl apply -f track-a/release/    # ConfigMap(10/11) 一定先於 Deployment(20/21)
```

`kubectl apply -f <dir>/` 依檔名排序，所以 `10-` `11-` 會先於 `20-` `21-`。
**不要用 `kubectl apply -f a.yaml -f b.yaml` 手動指定順序** —— 少一個檔就是 `ContainerCreating`。

### 4.3 首次上線的驗收

```bash
# pod 真的起來了嗎（不是只有探針綠燈 —— 探針目前是假的，見 3.6）
kubectl -n $NS get pod -l app=pmc-epmmformquerygui -L version
kubectl -n $NS logs deploy/pmc-epmmformquerygui-stable -c app --tail=50

# 啟動失敗最常見的三個訊息，對照 3.1：
#   ConfigDataLocationNotFoundException     → SPRING_CONFIG_LOCATION 路徑錯
#   Could not resolve placeholder 'app.post-logout-redirect-uri'
#                                           → ConfigMap 缺 key
#   Unable to resolve Configuration with the provided Issuer
#                                           → ConfigMap 缺 issuer-uri

# 兩個 subset 都要有 endpoint（沒有就是 503 UH 的來源）
istioctl -n $NS proxy-config endpoint deploy/pmc-epmmformquerygui-stable \
  --cluster "outbound|8080|canary|pmc-epmmformquerygui-svc.$NS.svc.cluster.local"
istioctl -n $NS proxy-config endpoint deploy/pmc-epmmformquerygui-stable \
  --cluster "outbound|8080|stable|pmc-epmmformquerygui-svc.$NS.svc.cluster.local"
```

---

## 5. 每次發布

假設線上是 `1.2.3`，要發 `1.3.0`。**所有動作都只是「改 YAML + apply」。**

### 步驟 0｜開分支

```bash
git checkout -b release/1.3.0
```

### 步驟 1【改動】canary 的設定與 image

改 `track-a/release/11-configmap-canary.yaml`：
把新版需要的設定差異寫進去（多數版本這一步沒有任何改動，直接跳過）。

改 `track-a/release/21-deployment-canary.yaml`：

```yaml
  replicas: 1                                          # 0 → 1
  ...
        image: your-registry/pmc-epmmformquerygui:1.3.0   # 唯一的版本號
        env:
          - name: APP_CANARY_ENABLED
            value: "true"                              # 確認是 true
```

重算 hash 並確認：

```bash
./scripts/sync-config-hash.sh                # 回寫兩個 config-hash annotation
git diff --stat                              # 應該只有 11-configmap 與 21-deployment
grep -n '1\.3\.0\|1\.2\.3' track-a/release/21-deployment-canary.yaml
#   → 只能看到一個 1.3.0（image），不能有殘留的 1.2.3
```

**ConfigMap 與 Deployment 的改動必須在同一個 commit。** 這是回滾能運作的前提。

```bash
git commit -am "release: deploy pmc-epmmformquerygui 1.3.0 to canary"
```

### 步驟 2【驗證】cookie 路由真的有效

**這一步沒過就不要往下走。** 指令見第 6.1 節。

### 步驟 3｜請使用者做 pilot run

1. 把帳號加進 `track-a/runtime/05-configmap-canary-pilot.yaml` → commit → apply → 等 ≤ 90 秒
2. 把 `pilot-run-guide.md` 發給驗證人員
3. 期間盯著 canary 的 log：

```bash
kubectl -n ea-pmc logs -l version=canary -c app --tail=100 -f
kubectl -n ea-pmc logs -l version=canary -c app | grep 'canary EVICT_TO_STABLE'
```

### 步驟 4a【改動】簽核通過 → promote

> **promote 不是「stable 換 image、canary 縮到 0」那麼簡單。**
> 縮到 0 會讓還握著 cookie 的人吃 503 —— 跟「canary 不通過」那條路徑是同一個坑。
> 正確的順序是**先讓 canary 變成無害，排空之後才縮**。

**第 1 個 commit —— promote：**

1. 把 `11-configmap-canary.yaml` 的 `data:` 整段複製進 `10-configmap-stable.yaml`
2. `20-deployment-stable.yaml` 的 `image` 改成 `1.3.0`
3. `21-deployment-canary.yaml` 的 `APP_CANARY_ENABLED` 改成 `"false"`，**`replicas` 維持 1**
4. `./scripts/sync-config-hash.sh`
5. commit → apply

```bash
# 確認兩份 ConfigMap 的 data 已經一致
diff <(yq '.data."application.yml"' track-a/release/10-configmap-stable.yaml) \
     <(yq '.data."application.yml"' track-a/release/11-configmap-canary.yaml) \
  && echo "OK: 兩軌設定一致"
```

此刻的狀態：兩軌跑同一版程式、同一份設定。**還握著 cookie 的人不會有任何感覺**，
而且 `CanaryEvictionFilter` 看到 `enabled=false`，會在他們下一次頁面導航時清 cookie + 302 回 stable。

**第 2 個 commit —— 排空後才縮（隔天，或確認沒人帶 cookie 之後）：**

```bash
# 確認已經排空：canary pod 最近沒有服務任何請求
kubectl -n ea-pmc logs deploy/pmc-epmmformquerygui-canary -c app --since=30m | grep -c 'GET /gui_epmmFormQuery'
# 0 = 沒人在上面了

# 也可以用 Istio metrics 確認
# sum(rate(istio_requests_total{destination_version="canary"}[10m]))
```

確認為 0（或已過 8 小時的 cookie Max-Age）之後，才把 `21-deployment-canary.yaml`
的 `replicas` 改回 0 → commit → apply。

### 步驟 4b【改動】簽核不通過 → 關掉 canary

**同樣不是 `replicas: 0`。** 見第 8 章。

### 步驟 5【改動】promote 之後才發現問題 → 回滾

```bash
git log --oneline -- track-a/release/
git revert <promote 那個 commit 的 sha>     # ConfigMap 與 Deployment 一起還原
git push                                    # 重跑 pipeline 的 apply
```

**不要用 `kubectl rollout undo`** —— 它只還原 pod template，ConfigMap 的內容已經是新的，
pod 會用舊 annotation 重啟卻掛到新設定。見第 8.3 節。

---

## 6. 測試與驗收

### 6.1 第 ① 層：路由還活著嗎（不需要真人）

```bash
URL="https://myapp.example.com/gui_epmmFormQuery/"

echo "--- 1. 不帶 cookie → 應該是 stable ---"
curl -sS -o /dev/null -D - "$URL" | grep -i 'x-app-track'

echo "--- 2. 手動帶 cookie → 應該是 canary ---"
curl -sS -o /dev/null -D - -H "Cookie: canary=always" "$URL" | grep -i 'x-app-track'

echo "--- 3. index.html 必須每次回源 ---"
curl -sS -o /dev/null -D - "$URL" | grep -iE 'cache-control|etag'
#   期望：Cache-Control: no-cache（不是 no-store，也不是 max-age=...）
#         有 ETag，沒有 Last-Modified
```

從 cluster 內部測（排除 gateway 因素）：

```bash
kubectl -n ea-pmc run curl-$$ --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- sh -c "
  curl -sS -o /dev/null -D - http://pmc-epmmformquerygui-svc:8080/gui_epmmFormQuery/ | grep -i x-app-track
  curl -sS -o /dev/null -D - -H 'Cookie: canary=always' http://pmc-epmmformquerygui-svc:8080/gui_epmmFormQuery/ | grep -i x-app-track
"
```

兩次都是 stable、或完全沒有 header，最可能的三個原因：

1. VirtualService 的 `gateways` 沒有包含 `mesh`（內部呼叫繞過所有路由規則）
2. Service 的 port 沒有 `name: http` / `appProtocol: http`（Istio 用 L4 處理，L7 的 cookie 比對失效）
3. cookie 規則沒有排在 `http[]` 的第一條

### 6.2 第 ② 層：BFF 決策正常嗎

```bash
# 名單讀到了嗎（兩軌都要看：stable 發 cookie、canary 趕人）
kubectl -n ea-pmc logs deploy/pmc-epmmformquerygui-stable -c app | grep 'roster reloaded'
kubectl -n ea-pmc logs deploy/pmc-epmmformquerygui-canary -c app | grep 'roster reloaded'
#   canary pilot roster reloaded: 3 user(s)

# 三種離開 canary 的路徑共用同一個 log prefix，一次抓完
kubectl -n ea-pmc logs -l app=pmc-epmmformquerygui -c app | grep 'canary EVICT_TO_STABLE'
#   每一行都帶 user= 與 cause=
#     cause=master-switch-off  → 收工，會一次全部出現（正常）
#     cause=roster-removal     → 個別移除（正常）
#     cause=self-service       → 使用者自己按逃生門。【一批同時出現代表有人在逃】

# 主開關的實際值
kubectl -n ea-pmc get deploy pmc-epmmformquerygui-canary \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="APP_CANARY_ENABLED")].value}'; echo
```

### 6.3 第 ③ 層：設定真的載進去了嗎

**這是新增的一層，而且是上線前最該做的一項。**

```bash
# 用 pilot 帳號登入後（actuator 的 env 需要授權），比對關鍵 key
POD=$(kubectl -n ea-pmc get pod -l version=stable -o name | head -1)
kubectl -n ea-pmc exec $POD -c app -- sh -c '
  wget -qO- http://localhost:8080/gui_epmmFormQuery/actuator/health; echo'

# 更直接：確認 ConfigMap 真的掛到了，而且是你以為的那一份
kubectl -n ea-pmc get deploy pmc-epmmformquerygui-stable \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}'; echo
kubectl -n ea-pmc exec $POD -c app -- head -5 /app/config/application.yml

# config-hash 有沒有跟 ConfigMap 對上（過期的 hash 不會報錯，只會不重啟）
kubectl -n ea-pmc get cm pmc-epmmformquery-config-stable -o jsonpath='{.data.application\.yml}' \
  | sha256sum | cut -c1-8
kubectl -n ea-pmc get deploy pmc-epmmformquerygui-stable \
  -o jsonpath='{.spec.template.metadata.annotations.config-hash}'; echo
#   兩個值必須相同
```

### 6.4 第 ④ 層：靜態檔真的是那一軌的嗎

```bash
URL="https://myapp.example.com/gui_epmmFormQuery/web/"

# 兩軌的 index.html ETag 應該不同（前端有改的話）
curl -sS -o /dev/null -D - "$URL" | grep -i etag
curl -sS -o /dev/null -D - -H "Cookie: canary=always" "$URL" | grep -i etag
```

> **兩邊 ETag 一樣不一定是壞掉。** 如果這一版只改後端 Java，`index.html` 一個 byte 都沒變，
> 兩邊本來就該一樣，而且瀏覽器繼續用快取那份**是正確行為**。
> 測試時請用**前端真的有改動**的 canary 版本。

### 6.5 端對端驗收（要一個 pilot 帳號）

| # | 步驟 | 預期 |
|---|---|---|
| 1 | 把測試帳號加進名單 → apply → 等 90 秒 | log 出現 `roster reloaded: N user(s)` |
| 2 | 用該帳號登入 | 自動多一次跳轉，最後停在首頁 |
| 3 | F12 → Application → Cookies | 有 `canary=always`，**Path 是 `/gui_epmmFormQuery`** |
| 4 | F12 → Network → 第一個請求的 Response Headers | `x-app-track: canary` |
| 5 | 確認畫面是**新版** GUI | 不是舊版 |
| 6 | 開啟一個會打外部 API 的頁面 | 沒有 CORS 錯誤、沒有 CSP 違規（見附錄 A） |
| 7 | 從名單移除 → apply → 等 90 秒 → 點任一連結 | 自動回 stable，cookie 消失 |
| 8 | 確認畫面變回**舊版**，而且沒有 404 / 白畫面 | ← 混版問題的實測 |
| 9 | 直接開 `/gui_epmmFormQuery/canary/leave` | 302 回首頁，cookie 消失（逃生門，登出狀態也要能用） |

> **第 7、8、9 項比第 2–5 項更重要。** 那是出事時要靠的路徑，
> 而正向流程壞掉會有人立刻回報，關閉流程壞掉沒有人會發現。

---

## 7. 例行維運

### 7.1 pilot 名單維護（最常做的事）

```
改 track-a/runtime/05-configmap-canary-pilot.yaml
  → commit
  → kubectl apply -f track-a/runtime/
  → 等 ≤ 90 秒（kubelet 同步 ≤60s + app reload 30s）
```

**不需要重啟任何 pod，不影響正式流量。**

| 動作 | 什麼時候生效 |
|---|---|
| **加入**一個人 | 他**下次登入**時（已登入的要先登出） |
| **移除**一個人 | 他**下一次頁面導航**時自動被送回 stable（不用他配合） |

名單一行一個 Keycloak 的 `preferred_username`（登入時打的帳號名），**不是** OIDC 的 `sub`。
確認真的讀到了：

```bash
kubectl -n ea-pmc logs deploy/pmc-epmmformquerygui-stable -c app | grep 'roster reloaded'
```

> 讀不到檔案 = **空名單**（沒有人進 canary），不是「全部都是」。這是刻意的 fail-safe。

### 7.2 要盯的訊號

| 訊號 | 指令 / 查詢 | 正常值 |
|---|---|---|
| canary 的錯誤率 | `sum(rate(istio_requests_total{destination_version="canary",response_code=~"5.."}[5m])) / sum(rate(istio_requests_total{destination_version="canary"}[5m]))` | 跟 stable 同數量級 |
| canary 的流量 | `sum(rate(istio_requests_total{destination_version="canary"}[5m]))` | > 0 才代表真的有人在驗 |
| **503 UH** | `sum(rate(istio_requests_total{destination_version="canary",response_code="503"}[5m]))` | **必須是 0**。> 0 代表有人被卡在沒有 endpoint 的 subset |
| 名單大小 | `grep 'roster reloaded'` | 跟你以為的人數一致，**兩軌都要看** |
| 自助逃生 | `grep 'cause=self-service'` | 零星是正常，**一批同時出現代表有人在逃** |

---

## 8. 關閉與回滾

### 8.1 三張牌

| # | 手段 | 生效速度 | 對 cookie 持有者 | 什麼時候用 |
|---|---|---|---|---|
| 1 | `APP_CANARY_ENABLED=false` + image 改回 stable 版 | 下一次頁面導航 | **乾淨排空，零 503** | **預設做法** |
| 2 | `base/03-virtualservice.yaml` 規則 1 的 destination 改成 `subset: stable` | 瞬間 | 立刻全部回 stable | 緊急（需要 `base/` 的單獨 stage 與額外簽核） |
| 3 | `replicas: 1 → 0` | 瞬間 | **503 UH，卡到 cookie 過期（8h）** | **不可單獨使用**，只能在確認排空後收尾 |

### 8.2 為什麼 `replicas: 0` 是 outage 不是不方便

自動分流之前，cookie 是 pilot 使用者自己種的，只有 2、3 個人，而且他們**知道**自己種了。
現在 cookie 是系統自動發的，持有者可能是幾十個人，**而且他們不知道自己有**。

```
手上還有 cookie 的人
  → VirtualService 規則 1 仍然把他們送進 subset: canary
  → 沒有 endpoint
  → 503（access log 的 response_flags = UH）
  → 他們永遠打不到 stable，app 端「清 cookie」的邏輯根本沒機會執行
  → 卡死到 cookie 過期為止（8 小時）
```

正確做法是**讓 canary 變成無害**，而不是讓它消失：

```
改 track-a/release/21-deployment-canary.yaml：
  1. image                 → 改回目前 stable 的版本
  2. volumes[config]       → 已經是固定名稱，不用動
  3. 11-configmap-canary.yaml 的 data → 複製 stable 那份回來
  4. APP_CANARY_ENABLED    → "false"
  5. replicas              → 【維持 1】
  6. ./scripts/sync-config-hash.sh
  → 同一個 commit → apply
```

效果：canary pod 還在跑，但跑的是「好的程式碼」。使用者不會 503，
`CanaryEvictionFilter` 看到 `enabled=false`，下一次導航就清 cookie + 302 回 stable。
**一次導航就排空。** 排空確認之後（第 5 章步驟 4a 的指令），才把 `replicas` 改回 0。

### 8.3 【絕對不要做】

| 動作 | 為什麼 |
|---|---|
| **`kubectl rollout undo`** | 固定名稱的 ConfigMap 是可變的。undo 還原 pod template（含舊的 `config-hash`），但 ConfigMap 內容已經是新的 → pod 用**舊 annotation** 重啟卻掛到**新設定**。沒有錯誤訊息 |
| **單獨把 canary `replicas` 設成 0** | 見 8.2 |
| **把 ConfigMap 與 Deployment 拆成兩個 commit** | `git revert` 只還原一半，另一半留在新版 |
| **手動 `kubectl edit` ConfigMap** | 下次 apply 會把你的改動蓋掉，而且 `config-hash` 不會變 → 不會重啟 → 你以為改了但沒生效 |
| **刪掉 `optional: true`（pilot 名單那個 volume）** | ConfigMap 打錯名字會讓 **stable** 卡在 `ContainerCreating` → 從「canary 壞掉」升級成「正式環境掛掉」 |
| **canary 開超過 1 個 replica** | in-flight OAuth2 `state` 在 pod 記憶體，使用者會拿到 `authorization_request_not_found` |

### 8.4 回滾（promote 之後才發現問題）

```bash
git log --oneline -- track-a/release/
git revert <promote commit>
git push          # 重跑 pipeline apply

# 驗證 image 與 ConfigMap 一起回去了
kubectl -n ea-pmc get deploy pmc-epmmformquerygui-stable \
  -o custom-columns='IMAGE:.spec.template.spec.containers[0].image,HASH:.spec.template.metadata.annotations.config-hash'
kubectl -n ea-pmc get cm pmc-epmmformquery-config-stable -o jsonpath='{.data.application\.yml}' \
  | sha256sum | cut -c1-8
```

**兩個 hash 相同才算回滾成功。** 不同就代表 apply 沒跑完，或有人手動改過 ConfigMap。

---

## 9. Troubleshoot

### 9.1 症狀對照表

| 症狀 | 層 | 最可能的原因 | 先跑什麼 |
|---|---|---|---|
| pod `CrashLoopBackOff` | ③ | `SPRING_CONFIG_LOCATION` 路徑錯 / ConfigMap 缺 `issuer-uri` 或 `app.post-logout-redirect-uri` | `kubectl logs --previous` 看啟動例外，對照 3.1 |
| pod 卡 `ContainerCreating` | ③ | ConfigMap 不存在（名字打錯，或 apply 順序反了） | `kubectl describe pod` 看 Events |
| 探針全綠但 app 是壞的 | ③ | 探針打到需要認證的路徑，回 302，kubelet 當成功 | 見 3.6 的警告；`curl -o /dev/null -D - <probe path>` 看實際 status |
| 大量 503，`response_flags=UH` | ① | subset 沒有 endpoint（`replicas: 0`、label 對不上） | `kubectl get endpoints`、`istioctl proxy-config endpoint` |
| 503，`response_flags=NC` | ① | VirtualService 的 `subset` 名稱打錯，或 DR 的 `host` 跟 VS 對不上 | `istioctl proxy-config cluster` |
| 帶了 cookie 還是進 stable | ① | ①VS 沒有 `mesh` ②Service port 缺 `name`/`appProtocol` ③cookie 規則不在第一條 | 6.1 的三項檢查 |
| 內部呼叫隨機打到 canary | ① | VS 的 `gateways` 沒有 `mesh`，或 `hosts` 沒列內部 FQDN | 看 `03-virtualservice.yaml` 的 `gateways` |
| 在名單裡卻進不了 canary | ② | 名單沒讀到 / 用了 `sub` 而不是 `preferred_username` / 使用者沒重新登入 | `grep 'roster reloaded'` |
| pilot 使用者被踢來踢去 | ② | 兩軌讀到的名單不一致（reload 時間差） | 等 90 秒；仍如此就確認兩個 Deployment 都掛了 `canary-pilot` volume |
| 剛登入完又被要求登入 | ② | 跨軌切換會重新認證一次；那一刻 Keycloak SSO session 剛好過期 | 重登即可，非故障 |
| 使用者偶發被登出 | ① | canary 開了 >1 replica，或親和 cookie 沒生效 | `kubectl get deploy -o wide`；檢查 DR 的 `consistentHash` |
| 白畫面 / 404 靜態檔 | ④ | `index.html` 被快取，配到另一軌的 asset | 6.4 的 ETag 比對；確認 `Cache-Control: no-cache` 且**沒有** `Last-Modified` |
| 功能詭異但不 404 | ④ | 靜默混版（拿到另一軌的 JS） | 硬重整（Ctrl+Shift+R）能好 → 就是快取問題 |
| Console 出現 CORS 錯誤 | — | 外部服務沒回 `Access-Control-Allow-Origin`，或 preflight 沒過 | 見附錄 A |
| Console 出現 CSP 違規 | — | `connect-src 'self'` 擋掉外部呼叫 | 見附錄 A |
| 登出後落到 404 頁 | — | `ExternalPageController` 的前綴漂移，見第 10 章 | — |

### 9.2 混版的三種樣子（第 ④ 層專章）

| 樣子 | 症狀 | 好認嗎 |
|---|---|---|
| **404 混版** | 白畫面，Network 一片紅 | 好認，使用者會立刻說「整個壞掉」 |
| **靜默混版** | 功能怪、錯誤散落各處，沒有 404 | **極難**。使用者回報的是「看起來像新版 bug、實際上不存在」的問題 |
| **304 混版** | 切回 stable 之後仍在跑 canary 的 bytes | **最難**。這正是 `setUseLastModified(false)` 要擋的 —— canary image 永遠比 stable 新，`Last-Modified` 的比對會回答錯的問題 |

> 現行 `WebAppConfig` 用 `noCache()` + `ContentHashEtagGenerator` + `setUseLastModified(false)`
> 已經把這三種都處理掉了。**那三個設定是一組，不能只留其中一個。**
> 另外 `ResourceHttpRequestHandler` 用 `response.setHeader()` 寫 Cache-Control，
> 會**覆蓋** filter 先前設的值 —— 所以絕對不要另外加一個設快取 header 的 filter，
> 那個 filter 會安靜地什麼都不做。

---

## 10. 已知限制與陷阱

| # | 限制 | 影響 | 現況 |
|---|---|---|---|
| 1 | **發 cookie 的程式跑在 stable 的每一次登入上** | 「零風險」只成立在路由層，不成立在程式層 | 全段 try/catch，任何例外一律放行。這段程式的品質標準要比業務程式高一級 |
| 2 | **canary 只能 1 replica** | 換 image 那幾十秒有 2 個 pod，canary 使用者要重登一次 | 已知代價，`maxSurge: 1` 造成 |
| 3 | **跨軌切換一定會多一次 Keycloak 往返** | 使用者被切過去時看到一次跳轉 | 設計如此，不是故障 |
| 4 | **cookie 不是 HttpOnly** | 任何人可以手動種 cookie 進 canary | 刻意的 —— 保留 bookmarklet 當備援。**真正把關的是 `CanaryEvictionFilter`**，非名單使用者一認證就被趕走。不要當成簡化把那個 filter 拿掉 |
| 5 | **`x-app-track` 只證明 pod，不證明 bytes** | header 對了畫面仍可能是舊的（快取） | 要同時看 ETag，見 6.4 |
| 6 | **兩軌共用 localStorage / IndexedDB** | canary 寫了新格式 → 使用者切回 stable → 舊版讀到不認識的結構而壞掉。**事後極難聯想**，因為那時 canary 已經下線 | canary 的 storage key 要加版本前綴 |
| 7 | **Service Worker 會讓整套 cookie 路由失效** | 症狀是畫面一直是舊版但 `x-app-track: canary` | 目前確認沒有註冊 SW。**日後若加 PWA 必須重驗** |
| 8 | **外部 API 不在 canary 的涵蓋範圍內** | pilot 使用者拿 canary 的前端打**正式**的外部 API | 見附錄 A |
| 9 | **探針目前無條件通過** | app 壞掉偵測不到 | 見 3.6，等後端補 permitAll |
| 10 | **`ExternalPageController` 前綴漂移** | controller 在 `/page/**`，但 permitAll、`accessDeniedPage`、`post-logout-redirect-uri` 都指向 `/gui_epmmFormQuery/page/**` → **登出落地頁與拒絕存取頁 404** | 後端待修 |
| 11 | **Track B（Argo Rollouts）沒有跟上** | `20-rollout.yaml` 沒有 `APP_TRACK` / `APP_CANARY_ENABLED` / 名單掛載，`10-configmap` 還被截斷 | 自動分流在 Track B 跑不起來。**要嘛補齊，要嘛把 track-b 標成不維護** |
| 12 | **`scripts/canary.sh` 與 `README.md` 仍在教 `replicas: 0`** | 照著做就會製造 8.2 的 outage | 待修；在那之前不要用那個腳本的 `rollback` / `promote` |
| 13 | **死掉的設定** | `app.cors.*`（沒有程式讀）、`app.test-endpoints.enabled`（沒有程式讀）、`app.silent-auth.enabled`（沒有程式讀）、`/gui_epmmFormQuery/rs/gui/ping`（permitAll 但沒有 controller） | 出事時會有人去改它們然後往錯方向查 |

---

## 附錄 A：CORS / CSP / React 直接打外部 service

前提：這支 app 是 **BFF（server-side `oauth2Login`）**。瀏覽器裡只有三顆 cookie
（`__Host-JSESSIONID`、`ea_login_hint`、`XSRF-TOKEN`，pilot 期間多一顆 `canary`），
**沒有任何一顆是 token**。React SPA 被打包進 jar，由 Spring 從
`/gui_epmmFormQuery/web/**` 供應 —— 跟後端**同源**。

### A.1 CORS

**BFF 這側刻意沒有 CORS 設定。** `SecurityConfig.java:165` 只有一行註解：

```java
// No .cors(): the SPA is same-origin by design (BFF) — credentialed
// cross-origin access was review finding F4.
```

而且有測試守著（`SecuritySmokeTest.crossOriginRequestGetsNoCorsGrant`）。

> **`app.cors.*` 是死設定。** 舊 ConfigMap 裡那塊 `allowed-origins` / `allowed-methods` /
> `allow-credentials` / `max-age`，後端**沒有任何一行程式讀它**。
> 這比沒寫更糟：出 CORS 問題時一定有人來改這幾行，改完什麼都不會變，
> 然後往錯的方向查半天。已經在第 3.5 節刪掉了。

**React 用 axios 打不同 origin 的外部 service 時：**

| 問題 | 誰負責 | 你要做什麼 |
|---|---|---|
| `Access-Control-Allow-Origin` | **對方的伺服器** | 請對方回你的 origin。你不帶 credentials，所以對方可以用 `*` |
| **preflight（`OPTIONS`）** | 對方 | 只要 axios 帶 `Content-Type: application/json` 或自訂 header（例如 `X-API-Key`），瀏覽器就會**先送 `OPTIONS`**。對方必須回 `204` + `Access-Control-Allow-Headers` 列出那些 header。**這是最常見的失敗點** |
| `withCredentials` | 你 | **不要開**。開了對方就不能用 `*`，而且你也沒有東西要送 —— 外部服務用的是 API key，不是你的 session |

驗證對方有沒有開好：

```bash
# 模擬 preflight
curl -i -X OPTIONS "https://api.other.example.com/v1/things" \
  -H "Origin: https://myapp.example.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type,x-api-key"
# 期望 204 + Access-Control-Allow-Origin + Access-Control-Allow-Headers 涵蓋上面兩個
```

> **API key 放在前端等於公開。** 任何人 F12 就拿得到。
> 如果那把 key 有配額、計費或寫入權限，這是實質的暴露，不只是理論問題。

### A.2 CSP

政策定義在 `app.security.csp-policy`：

```
default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline';
img-src 'self' data:; font-src 'self' data:; connect-src 'self';
frame-ancestors 'none'; base-uri 'self'; form-action 'self'
```

**今天的實際狀態有三件事要知道：**

1. **`csp-report-only: true`** → 只送 `Content-Security-Policy-Report-Only`，不擋任何東西。
2. **政策裡沒有 `report-uri` / `report-to`** → report-only **兩件事都沒做**：不擋、也不收。
   你不會事先看到違規，直到有人把它切成 enforce 的那一刻。
3. **舊 ConfigMap 根本沒有 `csp-policy` 這個 key**，加上 `SPRING_CONFIG_LOCATION` 是 replace 語意
   → `@Value("${app.security.csp-policy:}")` 拿到空字串 → **連 Report-Only 的 header 都不會送**。
   也就是說，**你現在其實完全沒有 CSP**。第 3.5 節已經把 key 補回去。

**切成 enforce 的那一刻會發生什麼：**

```
Refused to connect to 'https://api.other.example.com/v1/things'
because it violates the following Content Security Policy directive: "connect-src 'self'"
```

`connect-src 'self'` 會擋掉每一個打外部 origin 的 `fetch` / `XHR` / WebSocket。
若外部還供圖片或字型，`img-src` / `font-src` 也要一起開。

**要繼續直接打外部的話，政策改成：**

```yaml
        csp-policy: >-
          default-src 'self';
          script-src 'self';
          style-src 'self' 'unsafe-inline';
          img-src 'self' data:;
          font-src 'self' data:;
          connect-src 'self' https://api.other.example.com;
          frame-ancestors 'none'; base-uri 'self'; form-action 'self'
```

**切 enforce 的順序（不要跳）：**

1. 先加 `report-uri`（或至少要求 pilot 使用者回報 Console 的紅字）
2. 維持 `csp-report-only: true` 跑完一整個 pilot 週期，把所有頁面都點過
3. Console 完全乾淨之後，才 `csp-report-only: false`
4. **先在 canary 那份 ConfigMap 切 enforce，stable 維持 report-only** —— 這是拆兩份之後才做得到的

其他兩個小缺口：

- `frame-ancestors 'none'` 目前是 report-only，實際擋點擊劫持的是 Spring 預設的 `X-Frame-Options: DENY`。
- **沒有 `Referrer-Policy`**（Spring Security 預設不送）。建議補 `strict-origin-when-cross-origin`，
  否則使用者從你的頁面點到外部連結時，完整 URL（含 query）會出現在對方的 Referer。

### A.3 前端直接打外部 service 對 canary 的影響

**這才是這一節跟 canary 真正相關的部分。**

`canary=always` 這顆 cookie 是 `Path=/gui_epmmFormQuery` + `SameSite=Lax`。
**跨 origin 的 XHR 完全不會帶上它**（Lax 只允許 top-level 導航）。所以：

```
pilot 使用者的瀏覽器
  ├── /gui_epmmFormQuery/** ──── 帶 canary cookie ──▶ canary pod（新版前端）
  └── https://api.other...  ──── 不帶任何 cookie ───▶ 【正式】的外部 API
```

三個後果：

| # | 後果 |
|---|---|
| 1 | **pilot run 驗的是一個從未存在過的組合**：新版前端 + 正式外部 API。如果這次改版前後端契約有連動，簽核通過的東西上線後才第一次真的組在一起 |
| 2 | **外部服務無法跟著你的 Deployment 一起回滾。** `git revert` 只還原你的 image 與 ConfigMap |
| 3 | **兩軌的前端打同一個外部端點**，所以你無法在 canary 期間驗外部 API 的新版本 |

**短期補救（不改架構）：**

- 把「外部 API 在整個 canary 期間必須向後相容」寫進 `pilot-run-guide.md` 的檢查清單
- 端對端驗收加一項（第 6.5 節第 6 項）：pilot 使用者要實際開啟會打外部 API 的頁面，
  確認 Console 沒有 CORS 或 CSP 紅字
- 若這一版有動到外部 API 契約，**這套 canary 不足以驗它** —— 要另外安排

**根本解（PRD 階段 4）：把外部呼叫收回 BFF。**

後端已經有 `DownstreamApiClient` 與 `ThirdPartyApiClient` 兩個 `WebClient` bean
（會自動掛 `Authorization: Bearer`、走共用的 token refresh），
缺的只是 `/rs/**` 的 controller —— 目前 `/rs/**` **一個 controller 都沒有**，
`/gui_epmmFormQuery/rs/gui/ping` 只是 permitAll 但沒有實作。

補上 proxy endpoint 之後，四個問題一次消失：

| 問題 | 收回 BFF 之後 |
|---|---|
| API key 在瀏覽器公開 | key 只存在 pod 的 env / Secret 裡 |
| 要對方開 CORS + preflight | 同源，沒有 CORS 這回事 |
| CSP `connect-src` 要開洞 | `'self'` 就夠 |
| **canary 打到正式外部 API** | **canary pod 用自己那份 ConfigMap 的 `DOWNSTREAM_API_URL` 指向不同後端** ← 這正是拆兩份 ConfigMap 才做得到的事 |

> 順帶：目前 `thirdPartyWebClient` 重用同一個 `keycloak` registration，
> 也就是把發給自己 API 的 access token 送給外部夥伴（review F18，尚未解決）。
> 收回 BFF 時要一併處理 audience。

---

## 附錄 B：安全基線

Pod 層已經做得很好，**不要動**：

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      # container 層
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
      automountServiceAccountToken: false
```

以下是**缺的**，按投報比排序。

### B.1 NetworkPolicy（目前完全沒有）

`ea-pmc` 沒有任何 NetworkPolicy，等於 namespace 內外全通。先上 default-deny，再逐條開。

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ea-pmc
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: ea-pmc
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-istio-control-plane
  namespace: ea-pmc
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: istio-system }
      ports:
        - { protocol: TCP, port: 15012 }   # xDS
        - { protocol: TCP, port: 15010 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway-to-app
  namespace: ea-pmc
spec:
  podSelector:
    matchLabels: { app: pmc-epmmformquerygui }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: istio-system }
      ports:
        - { protocol: TCP, port: 8080 }
```

還要一條 egress 允許打 Keycloak 與外部 API（依你們的網段 / egress gateway 寫）。

> **上 default-deny 之前務必先在測試環境跑一輪。** 漏掉 DNS 或 istiod 的規則，
> 症狀是 pod 起得來但什麼都連不上，而且錯誤訊息（DNS timeout）不會指向 NetworkPolicy。

### B.2 Pod Security Standards（namespace 層）

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ea-pmc
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

> **⚠ 前提：叢集要裝 `istio-cni`。**
> 沒有 istio-cni 的話，sidecar 注入會加一個 `istio-init` initContainer，它需要
> `NET_ADMIN` / `NET_RAW` —— `restricted` 會直接擋掉，**整個 namespace 的 pod 都建不起來**。
>
> 先確認：
> ```bash
> kubectl -n istio-system get daemonset | grep -i cni
> ```
> 沒有的話，先上 `enforce: baseline` + `audit/warn: restricted`，看 audit 的結果再決定。
> 你的 pod spec 本身已經符合 restricted，所以 istio-init 是唯一的阻礙。

### B.3 Istio mTLS 與授權

```yaml
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ea-pmc
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: pmc-epmmformquerygui-allow
  namespace: ea-pmc
spec:
  selector:
    matchLabels: { app: pmc-epmmformquerygui }
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]
```

> 這條 AuthorizationPolicy 擋掉「namespace 內其他 pod 直接呼叫 canary pod IP，
> 繞過 cookie 閘門」的路徑。**先用 `mtls.mode: PERMISSIVE` 觀察一段時間**再切 STRICT，
> 否則沒有 sidecar 的呼叫方會全部斷線。
>
> `security.istio.io/v1` 需要 Istio ≥ 1.22。舊版用 `security.istio.io/v1beta1`
> （欄位完全相同）。用 `kubectl api-resources | grep security.istio.io` 確認你的叢集支援哪一個。

> **注意：stable 與 canary 共用同一個 ServiceAccount**（刻意的）。
> 這代表 AuthorizationPolicy **無法用 principal 區分兩軌**。
> 目前不需要，但如果哪天要做「只有 stable 能寫 DB」，就得拆成兩個 SA。

---

## 附錄 C：ConfigMap 必備 key 清單

**`SPRING_CONFIG_LOCATION` 是 replace 語意 —— 這裡列的每一個 key，ConfigMap 漏掉就會出事。**
兩份 ConfigMap（stable / canary）都要有。

### C.1 漏掉會讓 pod 起不來

| key | 為什麼 |
|---|---|
| `spring.security.oauth2.client.provider.keycloak.issuer-uri` | 無預設。OAuth2 client 建不起來 |
| `app.post-logout-redirect-uri` | `@Value` **沒有預設值** → `Could not resolve placeholder` |
| `spring.security.oauth2.client.registration.keycloak.client-id` / `client-secret` | 無預設（值本身從 Secret 的 env 注入） |

### C.2 漏掉會靜默出錯（最危險的一類）

| key | 漏掉的話會變成 | 後果 |
|---|---|---|
| `app.canary.cookie-path` | Java 預設 **`"/"`** | canary cookie 變 host-wide；`CanaryCookies.clear()` 之後**清不掉**（Set-Cookie 要 name/Path/Domain 全對才會覆蓋），使用者卡在 canary 直到 8 小時過期 |
| `spring...registration.keycloak.redirect-uri` | Spring 預設 `{baseUrl}/login/oauth2/code/{registrationId}`（**無前綴**） | 跟 `redirectionEndpoint.baseUri` 對不上 → callback 進不來 |
| `spring...provider.keycloak.user-name-attribute` | Spring 預設 `sub`（**剛好是對的**） | 但**絕對不能寫成 `preferred_username`** —— 那會讓 token store 用不穩定的 key，帳號回收重用時解析到前一個人的 token（review F15） |
| `server.servlet.session.cookie.name` | `JSESSIONID` | 失去 `__Host-` 前綴的保護，而且跟 Envoy 的親和 cookie 撞名（見 3.3） |
| `server.servlet.session.timeout` | **30 分鐘** | 使用者 30 分鐘沒動作就被登出（預期是 8 小時）。也會破壞「Keycloak SSO Session Idle ≥ servlet timeout」這條規則 |
| `app.security.csp-policy` | 空字串 | **連 Report-Only 的 CSP header 都不會送** |
| `spring.task.scheduling.pool.size` | **1** | 名單 reload 會排在 60 秒一次的 Keycloak token refresh 後面 → 「改名單多久生效」變得不可預測 |
| `management.endpoints.web.base-path` | `/actuator` | 探針路徑會 404（探針目前打的是帶前綴的路徑） |

### C.3 漏掉不會出事，但要一起寫（值跟 Java 預設相同）

`app.context-prefix`、`app.frontend.*`（4 個）、`app.canary.entry-path`、`app.canary.leave-path`、
`app.canary.roster-file`、`app.canary.roster-reload-ms`、`app.silent-auth.*`（4 個）、
`app.token-refresh.*`（3 個）、`app.security.csp-report-only`、`app.security.required-role`、
`app.privilege.enabled`、`app.downstream.base-url`、`app.third-party.base-url`。

> 「跟預設相同」不是省略的理由。**這份 ConfigMap 是這個環境設定的唯一真相**，
> 讀的人要能只看它就知道 app 怎麼跑，不需要去翻 Java 原始碼的 `@Value` 預設值。
>
> 特別是 `app.canary.leave-path`：它同時被 `CanaryLeaveController` 的 `@GetMapping`、
> `SecurityConfig` 的 permitAll 清單、`CanaryEvictionFilter` 的 pass-through 讀取。
> 三處只要有一處不同步，逃生門就會安靜地失效 —— 而它存在的意義正是「其他東西都壞了的時候」。

### C.4 不要寫進 ConfigMap 的

| key | 放哪 | 為什麼 |
|---|---|---|
| `APP_CANARY_ENABLED` / `APP_TRACK` | Deployment 的 `env` | 關閉 canary 只要改 env，不必動設定檔 |
| `KEYCLOAK_CLIENT_ID` / `KEYCLOAK_CLIENT_SECRET` | Secret（`envFrom.secretRef`） | ConfigMap 只寫 `${...}` 佔位 |
| pilot 名單 | `runtime/05-configmap-canary-pilot.yaml` | 改名單不該觸發任何 pod 重啟 |
| `app.cors.*`、`app.test-endpoints.*`、`app.sso.*` | **哪裡都不要放** | 沒有任何程式讀它們 |

### C.5 驗證清單完整性

```bash
# 從 jar 的 application.yml 抽出所有葉節點 key，跟 ConfigMap 比對
BACKEND=~/OneDrive/桌面/dev/spring_oauth2_backend/backend/src/main/resources/application.yml
CM=track-a/release/10-configmap-stable.yaml

diff <(yq -o props '.' "$BACKEND" 2>/dev/null | cut -d= -f1 | sort -u) \
     <(yq '.data."application.yml"' "$CM" | yq -o props '.' | cut -d= -f1 | sort -u)
```

**這個比對應該進 CI。** 它是 replace 語意下唯一能防止「jar 加了新設定但 ConfigMap 沒跟上」的東西。
