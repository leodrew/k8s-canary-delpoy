# PRD — BFF canary 靜態資源正確性與前端通用化

> 狀態：待實作。**本文不含程式碼變更**，只定義要做什麼、為什麼、以及每一項怎麼驗。
> 前置文件：`bffautocanarydesign.md`（設計提案）、`canary-manual/SOP-apply-only.md`（發布流程）、
> `canary-manual/canary-ops-runbook.md`（維運與排錯）。
> 相關程式：`spring_oauth2_backend/backend/src/main/java/com/example/epmmformquery/`

---

## 1. Introduction / Overview

自動 canary 分流（cookie → Istio → canary pod）已經實作完成並有 92 個測試通過。
但在檢視「這套 BFF 能不能同時服務 React 與 AngularDart 兩種前端」時，發現**分流本身是對的，
靜態資源這一層是錯的** —— 而且錯的方向剛好是「使用者驗證失敗要退回 stable」那條路。

核心問題一句話：

> 目前 BFF 回應靜態資源時，唯一的快取驗證器是 **`Last-Modified` 時間戳**。
> canary 的 image 一定比 stable 新，所以**從 canary 回到 stable 時，
> 瀏覽器會收到 304，繼續使用 canary 的檔案**。

這份 PRD 要把靜態資源層改成**內容導向**（ETag），讓它對 React 與 dart2js 一視同仁，
並補上使用者的自助逃生口。

---

## 2. Goals

- **G1**：同一份 BFF 程式碼在 React（檔名帶 hash）與 AngularDart（固定檔名）兩種前端上，
  跨軌切換的行為完全相同、且都正確。
- **G2**：消除「回到 stable 卻拿到 canary 檔案」這個靜默錯誤，兩個方向都要正確。
- **G3**：任何人都能用一行 `curl` 回答「我現在拿到的是哪一軌的靜態檔」。
- **G4**：pilot 使用者在 canary 驗證失敗時，**不需要 F12、不需要等管理員**就能回到 stable。
- **G5**：以上每一項都有可執行的自動化測試，紅燈能重現問題、綠燈代表修好。

---

## 3. 問題分析（為什麼要做）

### 3.1 【P0】快取驗證器是時間戳，不是內容

完整證據鏈，全部已驗證：

| # | 事實 | 證據 |
|---|---|---|
| 1 | `/web/**` 全部被設成 `Cache-Control: no-cache` → 瀏覽器**每次都必須回源驗證** | `WebAppConfig.java:46` |
| 2 | 專案中**沒有任何** ETag 設定 | `grep -rn "Etag\|useLastModified" src/` → 無 |
| 3 | `spring.web.resources.cache.use-last-modified` **預設 `true`** | spring-boot-autoconfigure 3.5.16 的 `spring-configuration-metadata.json`：`"defaultValue": true` |
| 4 | 因此 Spring 送出的**唯一驗證器是 `Last-Modified`** | `ResourceHttpRequestHandler` 有 `useLastModified` 欄位與一個沒被用到的 `etagGenerator` |
| 5 | Docker jar surgery 用 `cp -r`（沒有 `-p`）→ SPA 檔案 mtime = **docker build 時間**；canary 較晚建置 ⇒ **canary 的檔案一定比較新** | `pmc-epmmformquerygui-COMPLETE.md:2067` |

於是回源驗證比的是**時間戳**，不是內容：

```
stable → canary   If-Modified-Since(T_stable) < canary 的 T   → 200，拿到 canary 檔案   ✓
canary → stable   If-Modified-Since(T_canary) ≥ stable 的 T   → 304，【繼續用 canary】   ✗
```

**影響範圍比看起來大**，因為 `index.html` 在兩軌是**同一個 URL**：

| 前端 | 資源檔（`main.dart.js` / `index-abc.js`） | `index.html` |
|---|---|---|
| React（Vite，檔名帶 hash） | 安全 —— URL 不同就是不同快取項目 | **會壞**：拿到 canary 的 HTML → 要 canary 的 chunk → stable 的 jar 沒有 → **404 → 白畫面** |
| AngularDart（dart2js，固定檔名） | **會壞**：同一個 URL → 拿到 canary 的 JS 配 stable 的後端 → **靜默混版** | **會壞**：同上 |

> **這推翻了先前的判斷。** 之前認為 `noCache()` 已經意外滿足設計文件 Part 3.3 的條件①，
> 那個判斷漏掉了「`no-cache` 只保證會回源驗證，不保證驗證的結果是對的」。

### 3.2 【P1】前端通用性的另外兩個缺口

| 缺口 | 現況 | 影響 |
|---|---|---|
| **副檔名白名單** | `WebAppConfig.EXT` 是硬編白名單。不在名單內的副檔名 → `hasExt()` 回 false → **SPA fallback 回 index.html（200）** 而不是 404 | dart2js 的 `main.dart.js.map`、Flutter 的 `.bin`、`.webmanifest`、`.br`、`.gz` 都會拿到 HTML。devtools 讀不到 source map，而且是 200 不是 404，**看起來像檔案存在** |
| **Dockerfile 注入路徑** | Dockerfile 注入到 `${PROJECT_NAME}/${STATIC_DIR}`，`STATIC_DIR` 預設 `dist`；但 app 讀的是 `classpath-base: gui_epmmFormQuery/web` | 路徑不一致 → **整個 SPA 404**。Dockerfile 自帶的驗證步驟 grep 的是自己的路徑，所以**驗不出來** |

### 3.3 【P1】使用者沒有自助逃生口

目前退回 stable 只有兩條路：管理員從名單移除（≤90 秒 + 一次導航），或使用者自己按 F12 貼 bookmarklet。
**canary 前端如果壞到 SPA 渲染不出來，使用者在畫面上沒有任何出口** —— 而那正是最需要出口的時候。

### 3.4 【P2，本次順帶發現】`/page/**` 三個 URL 目前 404

`ExternalPageController` 用 `@RequestMapping("/page")`，但專案**刻意不設 `server.servlet.context-path`**，
也沒有任何 `addPathPrefix` / `PathMatchConfigurer` 設定：

```
SecurityConfig.java:152   accessDeniedPage      → /gui_epmmFormQuery/page/access-denied
SecurityConfig.java:166   permitAll             → /gui_epmmFormQuery/page/**
application.yml:41        post-logout-redirect  → /gui_epmmFormQuery/page/logged-out
ExternalPageController    實際 mapping          → /page              ← 少了前綴
```

三個 URL 都會 404。唯一碰到 `/page` 的測試（`KeycloakLogoutSuccessHandlerTest.java:38`）
只斷言**導轉網址字串**，從來沒有斷言那個端點解析得到。

> 這也決定了逃生口**不要**放在 `/page/` 底下 —— 那個 namespace 現在是壞的，
> 而且 `ExternalPageController` 是 Fortify 加固過的允許清單，不該混入路由邏輯。

---

## 4. User Stories

### US-001：跨軌切換時，兩個方向都拿到正確的靜態檔

**Description:** 作為 pilot 使用者，我在 stable 與 canary 之間來回切換時，
希望每一次都拿到我目前所在那一軌的畫面與程式，而不是上一軌殘留的快取。

**Acceptance Criteria:**
- [ ] `WebAppConfig` 的 resource handler 掛上 `setEtagGenerator(...)`，ETag 值是資源內容的雜湊
- [ ] 同一個 handler 設 `setUseLastModified(false)`，回應中**不再出現 `Last-Modified` 標頭**
- [ ] `StaticAssetCachingTest`：帶一個**未來時間**的 `If-Modified-Since` 請求靜態資源 → **必須回 200**
      （這一條在修好之前會回 304，是本次問題的最小重現）
- [ ] `StaticAssetCachingTest`：帶相符的 `If-None-Match` → 304；帶不符的 → 200
- [ ] `StaticAssetCachingTest`：`index.html` 同樣帶 ETag、同樣沒有 `Last-Modified`
- [ ] `ContentHashEtagGeneratorTest`：內容不同 → ETag 不同；內容相同 → ETag 相同
- [ ] `ContentHashEtagGeneratorTest`：資源讀不到時回 `null`（不發 ETag、不丟例外、不 500）
- [ ] `ContentHashEtagGeneratorTest`：同一個資源第二次呼叫**不重讀檔案**（memoize 生效）
- [ ] `mvn -B test` 全綠，既有 92 個測試無回歸

### US-002：同一份 BFF 對 React 與 dart2js 行為一致

**Description:** 作為平台維護者，我希望這支 BFF 可以直接套到任何前端 build 出來的檔案上，
不需要針對 React 或 Dart 分別設定或分別出版本。

**Acceptance Criteria:**
- [ ] 移除 `WebAppConfig.EXT` 白名單，SPA fallback 改判斷「最後一段路徑**是否含點**」
- [ ] `SpaFallbackTest`：`/web/some/deep/route`（無點）→ 200 且內容是 `index.html`
- [ ] `SpaFallbackTest`：`/web/missing.js`、`/web/missing.dart.js.map`、`/web/missing.bin`、
      `/web/missing.webmanifest` → **全部 404**（不是 index.html）
- [ ] `SpaFallbackTest`：既有的 asset path-stripping fallback 行為不變
- [ ] 啟動時檢查 `app.frontend.resource-location` 底下有 `index.html`，缺少時記 ERROR log
      並標示元件為 down；`FrontendBundlePresenceTest` 涵蓋「有」與「沒有」兩種情形
- [ ] Dockerfile 的 `STATIC_DIR` 與 `app.frontend.classpath-base` 對齊，
      並且注入後的驗證步驟改成 grep **app 實際會讀的那個路徑**

### US-003：一行指令回答「我現在是哪一軌的靜態檔」

**Description:** 作為值班同仁或 pilot 使用者，我要能在不開 devtools 的情況下確認
自己拿到的是哪一版的靜態檔案。

**Acceptance Criteria:**
- [ ] 靜態資源回應帶 `ETag`，且該值等於檔案內容雜湊
- [ ] `canary-ops-runbook.md` 收錄可直接複製的兩軌 ETag 比對指令
- [ ] 文件明確寫出判讀規則：ETag 不同 = 真的是不同版本；ETag 相同 = 這個檔在兩軌本來就一樣（此時不換才是對的）
- [ ] 文件說明 `x-app-track`（哪個 **pod**）與 ETag（哪份 **bytes**）的分工，
      以及為什麼修好之前 `x-app-track` 單獨看會騙人

### US-004：使用者自助退回 stable

**Description:** 作為 pilot 使用者，當 canary 版本壞到我沒辦法操作時，
我要能自己回到舊版，不必等管理員、也不必開 F12。

**Acceptance Criteria:**
- [ ] 新增 `GET /gui_epmmFormQuery/canary/leave`（**完整路徑寫死，不放 `/page/` 底下**）
- [ ] 加入 `SecurityConfig` 的 permitAll 清單 —— 未登入也要能用
- [ ] `CanaryLeaveControllerTest`：回 302 導向 `app.canary.entry-path`
- [ ] `CanaryLeaveControllerTest`：`Set-Cookie` 清除 `canary`，且 `Path` / `SameSite` / `Secure`
      與 `CanaryCookies.issue()` 完全一致（屬性不一致 = 清不掉）
- [ ] `CanaryLeaveControllerTest`：回應帶 `Cache-Control: no-store`
- [ ] `CanaryLeaveControllerTest`：**未帶 cookie 時呼叫也不出錯**（冪等）
- [ ] `CanaryLeaveControllerTest`：未驗證身分時回 302 而**不是** 401
- [ ] `CanaryEvictionFilter` 對這個路徑放行，讓端點自己的導轉生效
- [ ] `pilot-run-guide.md` 與 `canary-ops-runbook.md` 收錄這個網址

---

### US-005：驅離事件在 log 裡看得到

**Description:** 作為值班同仁，當使用者回報「我突然被踢回舊版」時，
我要能從 log 確認那是系統的決策而不是故障，以及原因是名單移除還是主開關關閉。

**Acceptance Criteria:**
- [ ] `CanaryEvictionFilter` 在**實際執行驅離時**記一筆 INFO log，
      內容包含使用者、觸發原因（不在名單 / 主開關關閉）、導向的路徑
- [ ] log 格式與 `CanarySwitch` 現有的 `canary {action}: redirecting to {path}` 一致，
      讓 `canary-ops-runbook.md` §3.2 的 `grep 'canary EVICT_TO_STABLE'` 在**兩條路徑**上都有效
- [ ] **不得**在被放行的請求上記 log —— 這個 filter 跑在 canary 的每一個請求上
- [ ] `CanaryEvictionFilterTest`：驅離時有 log、放行時沒有

> **為什麼補這個**：目前 `CanaryEvictionFilter` 只在**例外**時記 log，成功驅離完全靜默。
> 「使用者被踢出 canary」是這套機制最需要被觀測的事件，而它現在在 log 裡不存在。

---

## 5. Functional Requirements

**FR-1** — 系統必須以**資源內容的雜湊**作為靜態資源的 HTTP 快取驗證器，
透過 `ResourceHandlerRegistration.setEtagGenerator(Function<Resource,String>)` 掛載。

**FR-2** — 系統必須關閉靜態資源的 `Last-Modified` 驗證器
（`ResourceHandlerRegistration.setUseLastModified(false)`）。
**不可以**改用 `spring.web.resources.cache.use-last-modified: false` —— 該屬性只作用在
Spring Boot **自動註冊**的 handler 上，對 `WebAppConfig.addResourceHandlers()` 手動註冊的無效。

**FR-3** — ETag 計算必須 memoize。jar 內資源在執行期不會變，快取無需失效機制。

**FR-4** — ETag 計算失敗時必須回 `null`（不發驗證器 → 每次回 200 完整內容），
**絕不可**丟出例外或造成 5xx。這段跑在 100% 正式流量路徑上。

**FR-5** — 快取策略維持 `Cache-Control: no-cache`。快取標頭的來源必須維持**只有 `WebAppConfig` 一處**；
不得另外新增設定快取標頭的 filter（`ResourceHttpRequestHandler` 用 `response.setHeader()` 覆寫，
filter 設的值會被靜默蓋掉）。

**FR-6** — SPA fallback 的判斷必須改為「路徑最後一段是否含點」：含點 → 視為檔案請求，找不到就 404；
不含點 → 回 `index.html`。移除硬編副檔名白名單。

**FR-7** — 應用程式啟動時必須驗證前端 bundle 的 `index.html` 存在於
`app.frontend.resource-location`，不存在時記 ERROR 並回報為不健康。

**FR-8** — 系統必須提供 `GET {context-prefix}/canary/leave`，行為為：
清除 canary cookie（屬性與發放時完全一致）、設 `Cache-Control: no-store`、
302 導向 `app.canary.entry-path`。此端點必須 permitAll、必須冪等、必須不依賴 JavaScript。

**FR-9** — Docker 映像建置時，SPA 注入路徑必須等於 `app.frontend.classpath-base`，
且建置後的驗證步驟必須檢查 app 實際讀取的路徑。

---

## 6. Non-Goals（明確不做）

- **不做 `?v=` URL 改寫**（設計文件 Part 3.4 的 `ContentHashIndexTransformer`）。
  ETag 已經涵蓋正確性，而且**額外涵蓋了 `?v=` 碰不到的執行期資源**
  （`config.json`、i18n 語言包、CSS `url()` 字型、dart 的 `.part.js`）。
  `?v=` 只是效能優化，留到有量測數據再談。
- **不做長快取（`max-age=1y`）**。維持 `no-cache` + 304，跟現況相同，本次不改變效能特性。
- **不處理 stable / canary 兩套 YAML 的重複**。已確認可接受手動維護。
- **不動 Istio `base/`**。VirtualService 規則 1 原樣可用。
- **不改 `user-name-attribute`**（見 Open Questions）。
- **不做前端本地儲存（localStorage / IndexedDB）的清除**。已確認暫不需要。
- **不做百分比分流、不做 session 外部化**。

---

## 7. Technical Considerations

### 7.1 為什麼 ETag 比設計文件的 `?v=` 方案更適合

| | `?v=` URL 改寫（Part 3.4） | **ETag（本 PRD）** |
|---|---|---|
| dart2js 固定檔名 | 需要 | 自動涵蓋 |
| React hash 檔名 | 要記得關掉 | 不用管，天然無害 |
| **執行期才抓的資源** | **涵蓋不到**（文件自己列為缺口） | **自動涵蓋** |
| 需要解析 / 改寫 HTML | 要 | 不用 |
| 程式碼量 | 一個 transformer + 設定分支 | 兩行 + 一個小類別 |
| 對「回到 stable」的方向 | 有效 | 有效 |

### 7.2 已驗證的 API

`ResourceHandlerRegistration`（spring-webmvc 6.2.19）確認有：

```
setCacheControl(CacheControl)
setUseLastModified(boolean)
setEtagGenerator(Function<Resource, String>)
resourceChain(boolean)
```

### 7.3 效能

每個資源每個 pod 只雜湊一次（memoize）。3MB 的 `main.dart.js` 約 10–20ms，發生在第一次請求。
之後每次請求只做字串比對。維持 `no-cache` 代表每個資源仍有一次 304 往返 —— **這是現況，不是回歸**。

### 7.4 逃生口的路徑選擇

放 `{context-prefix}/canary/leave` 而非 `/page/leave-canary`，三個理由：
`/page/**` 目前整個是壞的（3.4）；`ExternalPageController` 的
`@GetMapping("/{pageName:[a-z0-9-]{1,40}}")` 會吃掉 `leave-canary` 這個名稱；
canary 邏輯集中在 `canary/` 套件，之後要抽成 starter 才是乾淨的一刀。

### 7.5 與既有 canary 元件的互動

`CanaryEvictionFilter` 目前對「已驗證且不在名單」的導航請求會清 cookie + 302。
逃生口的最終效果相同，但仍應在 filter 中明確放行該路徑，避免行為取決於巧合。

---

## 8. Success Metrics

- 「回到 stable 卻拿到 canary 檔案」這一類事件歸零 —— 由 US-001 那條
  `If-Modified-Since` 未來時間的測試把關，紅→綠可證。
- pilot 使用者遇到 canary 故障時的平均脫困時間：從「≤90 秒 + 需要管理員」
  降到「一個網址、立即」。
- 同一份 BFF 程式碼可直接套用到第二種前端，**不需要任何 per-frontend 設定分支**。
- `mvn -B test` 從 92 個測試成長到約 110 個，全綠。

---

## 9. Open Questions

| # | 問題 | 為什麼還沒決定 |
|---|---|---|
| 1 | `10-configmap-1.2.3.yaml` 把 `user-name-attribute` 從 jar 的 `sub` 蓋回 `preferred_username`（`SPRING_CONFIG_ADDITIONAL_LOCATION` 優先權較高），與 review F15 相反 | 這會改變 token store 的 key，是安全決策，且不影響 canary 分流（`CanaryUsernames` 兩種設定下都正確）。需要獨立決策 |
| 2 | 該 ConfigMap 仍帶 `app.cors` / `app.sso` / `app.test-endpoints`，後端已無這些設定 | 需確認線上跑的是不是這一份，還是另有一份真正的生產 ConfigMap |
| 3 | `/page/**` 三個 URL 404（3.4）—— 要在本次一起修，還是另開 | 修法很小（`@RequestMapping(contextPrefix + "/page")`），但屬於既有缺陷，不是 canary 引入的 |
| 4 | K8s probe 打 `/gui_epmmFormQuery/actuator/health`，jar 內設定是 `/actuator/health`（只有 ConfigMap 裡有 `management.endpoints.web.base-path`） | 與問題 2 綁在一起：取決於線上實際套用哪份設定 |
| 5 | SPA 是否使用 localStorage / IndexedDB | 目前答案是「沒用 / 不確定」，先不做。若日後確認有用，逃生口需要補一次性清除訊號 |

---

## 10. 實作順序建議

1. **US-001（ETag）** —— 先寫那條 `If-Modified-Since` 未來時間的測試看它變紅，再修，再看它變綠。
   這是唯一的 P0，其他都可以等。
2. **US-004（逃生口）** —— 獨立、小、對 pilot 體驗影響最大。
3. **US-005（驅離 log）** —— 三行程式，但沒有它 runbook 的排錯流程是斷的。跟 US-004 一起做。
4. **US-002（前端通用化）** —— SPA fallback 與啟動檢查在程式內；Dockerfile 那項要能實際建一次映像才算驗完。
5. **US-003（驗證方式）** —— 純文件，跟著 US-001 一起收尾。

> 全部完成後 `mvn -B test` 應從 92 個測試成長到約 115 個，且既有測試零回歸。
