# Canary 維運與排錯手冊

> ⚠ **已被 [`CANARY-COMPLETE.md`](CANARY-COMPLETE.md) 取代**（併入其第 7–9 章）。
> 總集手冊的心智模型多了第 ③ 層「應用設定載入」—— 那是目前最容易一次弄死整個環境的一層。

> **這份的用途**：canary 自動分流上線之後，「怎麼確認它在運作」「壞了怎麼定位」。
>
> 文件分工：
> | 文件 | 回答什麼 |
> |---|---|
> | `SOP-apply-only.md` | **發布**要改哪些檔、按什麼順序 |
> | `pilot-run-guide.md` | 給**驗證人員**看的，不需要 K8s 知識 |
> | **本文** | **值班 / 維運**看的：怎麼驗、壞了怎麼查 |
> | `bffautocanarydesign.md` | 設計理由（為什麼這樣做） |
> | `tasks/prd-bff-canary-static-assets.md` | 靜態資源正確性的待辦 |
>
> 標記 🚧 的項目**依賴 PRD 落地**，目前尚未實作。

---

## Part 1：先建立心智模型 —— 三層，排錯時先定位在哪一層

分流不是一件事，是**三層各自獨立**的機制。八成的排錯時間浪費在查錯層。

```
┌─ 第 1 層：Istio 路由 ────────────────────────────────────┐
│  只看 Cookie header 有沒有 canary=always                 │
│  完全不管誰種的、也不管使用者是誰                        │
│  證據：回應的 x-app-track 標頭                           │
└──────────────────────────────────────────────────────────┘
┌─ 第 2 層：BFF 決策 ──────────────────────────────────────┐
│  登入成功時：在名單內 → 發 cookie + 302                  │
│  每次導航時：不在名單 / 開關關了 → 清 cookie + 302       │
│  證據：pod log 的 roster reloaded / canary SWITCH|EVICT   │
└──────────────────────────────────────────────────────────┘
┌─ 第 3 層：瀏覽器快取 ────────────────────────────────────┐
│  決定「畫面上跑的是哪一份 bytes」                        │
│  【重要】跟第 1、2 層完全脫鉤 —— 快取命中時根本不發請求  │
│  證據：資源回應的 ETag 🚧 / devtools 的 200 vs 304        │
└──────────────────────────────────────────────────────────┘
```

**最容易誤判的一件事**：`x-app-track: canary` 只證明**那一個請求**打到了 canary pod。
它**不能**證明畫面上跑的 JavaScript 來自 canary —— 如果 JS 是從瀏覽器快取拿的，
那個請求根本不存在，你在 Network 分頁上什麼都看不到。

---

## Part 2：例行操作速查

### 2.1 名單維護（最常做）

```bash
# 1. 改名單
vi track-a/runtime/05-configmap-canary-pilot.yaml
# 2. commit + apply
kubectl apply -f track-a/runtime/
# 3. 等 ≤90 秒（kubelet 同步 60s + app reload 30s）
# 4. 確認真的讀到了
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui-stable | grep 'roster reloaded'
# canary pilot roster reloaded: 3 user(s)
```

| 動作 | 何時生效 | 使用者要做什麼 |
|---|---|---|
| **加入**一個人 | 他**下次登入**時 | 已登入的要先登出再登入 |
| **移除**一個人 | 他**下一次頁面導航**時 | 什麼都不用做 |

名單一行一個 **Keycloak `preferred_username`**（登入打的帳號名），不是 OIDC 的 `sub`。
大小寫不敏感，`#` 開頭是註解。

> **讀不到檔案 = 空名單**（沒人進 canary），不是「全部都是」。這是刻意的 fail-safe。

### 2.2 開啟 canary

見 `SOP-apply-only.md` 步驟 1–3。三處版本號必須一致：

```
21-deployment-canary.yaml:
  ① image: your-registry/pmc-epmmformquerygui:<版本>
  ② volumes[].configMap.name: pmc-epmmformquery-config-<版本>
  ③ annotations.config-version: "<版本>"
  ④ replicas: 0 → 1
  ⑤ APP_CANARY_ENABLED: "true"
```

> **canary 必須維持 `replicas: 1`。** 進行中的 OAuth2 `state` 存在該 pod 的 session 裡，
> 兩個 pod 會讓登入隨機失敗（`authorization_request_not_found`）。

### 2.3 關閉 canary（驗證失敗）

**不要用 `replicas: 0`。** 詳細理由見 `SOP-apply-only.md`；一句話：

```
replicas: 0 之後 VirtualService 規則 1 還在
  → 還帶著 cookie 的人被送進沒有 endpoint 的 subset
  → 503（access log response_flags = UH）
  → 打不到 stable，「清 cookie」的程式碼沒機會執行
  → 卡到 cookie 過期（8 小時）
```

正確做法：**換 image，不是縮到 0**

```
21-deployment-canary.yaml:
  ① image → 改回目前 stable 的版本
  ② configMap.name + config-version → 一併改回 stable 的版本
  ③ APP_CANARY_ENABLED → "false"
→ commit → apply
```

canary pod 還在跑，但跑的是好的程式碼 → 使用者不會 503 → 下一次導航就被清 cookie 送回 stable。
**一次導航排空，零 503。** 確認沒人帶 cookie（或過了 8 小時）之後再從容把 `replicas` 改回 0。

---

## Part 3：驗證指令

### 3.1 第 1 層：路由還活著嗎

```bash
URL="https://myapp.example.com/gui_epmmFormQuery/"

echo "--- 不帶 cookie → 應該是 stable ---"
curl -sS -o /dev/null -D - "$URL" | grep -i 'x-app-track'

echo "--- 手動帶 cookie → 應該是 canary ---"
curl -sS -o /dev/null -D - -H "Cookie: canary=always" "$URL" | grep -i 'x-app-track'
```

兩行輸出不同 = 規則 1 正常。相同 = 路由層就壞了，不用往下查。

### 3.2 第 2 層：BFF 決策正常嗎

```bash
# 名單讀到了嗎（兩軌都要看，stable 發 cookie、canary 趕人）
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui-stable | grep 'roster reloaded'
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui-canary | grep 'roster reloaded'

# 決策有沒有發生（登入時的切換 / 驅離，兩軌都可能出現）
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui-stable | grep 'canary SWITCH_TO_CANARY'
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui-canary | grep 'canary EVICT_TO_STABLE'

# 主開關的實際值
kubectl get deploy -n ea-pmc pmc-epmmformquerygui-canary \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="APP_CANARY_ENABLED")].value}{"\n"}'
```

> 🚧 **目前有一個觀測盲點**：上面兩個 `grep` 只涵蓋**登入時**的決策（`CanarySwitch`）。
> `CanaryEvictionFilter` 在**導航時**把人趕回 stable 這條路徑**目前完全不記 log**
> —— 也就是說「使用者被踢出 canary」這個最需要看到的事件，在 log 裡是看不到的。
> 補上之前，這條路徑只能從使用者回報與 cookie 消失來反推。見 PRD US-005。

### 3.3 第 3 層：靜態檔真的是那一軌的嗎 🚧

**這是最容易被忽略、也最難查的一層。**

```bash
ASSET="https://myapp.example.com/gui_epmmFormQuery/web/main.dart.js"   # 換成你實際的 bundle

echo "--- stable ---"
curl -sS -o /dev/null -D - "$ASSET" | grep -i '^etag'

echo "--- canary ---"
curl -sS -o /dev/null -D - -H "Cookie: canary=always" "$ASSET" | grep -i '^etag'
```

判讀：

| 結果 | 意思 |
|---|---|
| 兩個 ETag **不同** | 兩軌的這個檔案確實不同版本 ✓ |
| 兩個 ETag **相同** | 這個檔在兩軌本來就一模一樣。**這不是故障** —— 例如這次只改後端 Java，前端一個 byte 都沒動。此時瀏覽器不重抓才是正確行為 |

> 測 transformer 有沒有生效時，請用**前端真的有改動**的 canary 版本，
> 否則你會看到兩個相同的 ETag 然後誤以為沒生效。

> 🚧 **PRD 落地前**，靜態資源沒有 ETag，這一層**無法驗證**，
> 而且存在已知缺陷：從 canary 回到 stable 時瀏覽器會收到 304 並繼續使用 canary 的檔案。
> 見 `tasks/prd-bff-canary-static-assets.md` §3.1。

---

## Part 4：排錯

### 4.1 症狀對照表

| 症狀 | 最可能的層 | 怎麼確認 | 處置 |
|---|:---:|---|---|
| 在名單裡但進不了 canary | 2 | `grep 'roster reloaded'` 看數字對不對 | 名單是否用了 `sub` 而不是帳號名？改名單後有沒有**重新登入**？等滿 90 秒了嗎？ |
| 名單是空的（`0 user(s)`） | 2 | `kubectl describe pod` 看 volume 有沒有掛上 | ConfigMap 名字打錯（`optional: true` 會讓它靜默不掛）。掛載路徑必須是**目錄** `/app/canary`，不能用 `subPath` |
| 名單改了但完全沒動靜 | 2 | 比對 ConfigMap 內容與 pod 內檔案 | 用了 `subPath` → kubelet **永遠不會**更新該檔案 |
| pilot 使用者被踢來踢去 | 2 | 比對兩軌的 `roster reloaded` 數字 | 兩軌 reload 有時間差，等滿 90 秒。仍不一致就查兩份 Deployment 是否都掛了名單 |
| 一登入就被彈回 stable，canary 一個人都進不去 | 2 | canary pod log 有 `EVICT_TO_STABLE` 且緊接在切換之後 | `CanaryEvictionFilter` 的「未驗證放行」guard 失效。session 是 per-pod，切過來的第一個請求**必然未驗證**，此時不能踢 |
| 剛登入完又被要求登入一次 | 2 | — | **正常**。跨軌切換 = 完整重新認證；那一刻 Keycloak SSO 剛好過期就會這樣。重登即可 |
| 使用者一直被登出 | 2 | `kubectl get pods -l version=canary` | canary 開超過 1 個 replica。OAuth2 `state` 在 pod session 裡 |
| 大量 503，`response_flags = UH` | 1 | `kubectl get endpoints` | `subset: canary` 沒有 endpoint。多半是有人用了 `replicas: 0` 關閉。改用 §2.3 的流程 |
| 帶了 cookie 還是進 stable | 1 | §3.1 | cookie 的 `Path` 對不對（是 `/gui_epmmFormQuery`，**不是** `/`）；VirtualService 規則 1 是否在最前面 |
| **白畫面，靜態資源 404** | 3 | devtools Network 看 404 的檔名屬於哪一軌 | 拿到了一軌的 `index.html` 配另一軌的 chunk。見 §4.2 |
| **畫面看起來是舊版，但 `x-app-track: canary`** | 3 | devtools 看 JS 請求是 200 還是 304，或**根本沒發請求** | 瀏覽器快取。見 §4.2 |
| **功能詭異、錯誤散落各處、查不出來** | 3 | 同上 | **靜默混版**，最難查的一種。見 §4.2 |
| 登出後看到 404 | — | — | 已知缺陷：`/gui_epmmFormQuery/page/**` 三個 URL 目前無對應 handler。見 PRD §3.4 |

### 4.2 第 3 層專章：三種混版長什麼樣

兩軌是**同一個 origin、同一個 URL**，瀏覽器快取因此是共用的。

| 前端 | 資源檔 | `index.html` |
|---|---|---|
| React（Vite，檔名帶 hash） | 安全 —— 檔名不同就是不同快取項目 | **會壞**：舊 HTML 要新 chunk → **404 → 白畫面** |
| AngularDart（dart2js，固定檔名） | **會壞** —— 同一個 URL → **靜默混版** | **會壞**：同上 |

> **404 反而是好消息** —— 使用者會立刻回報「整個壞掉」。
> **靜默混版才可怕** —— 使用者回報的是一堆**看起來像新版 bug、實際上根本不存在**的問題，
> 你會浪費好幾輪去追不存在的東西。

**現場急救**（PRD 落地前）：請使用者用無痕視窗，或 `Ctrl+Shift+R` 硬重新整理。
這只是繞過症狀，不是修好。

**判斷是不是第 3 層問題的最快方法**：請使用者開無痕視窗重試。
無痕正常 = 快取問題，就是這一層。

---

## Part 5：出事時的三張牌

| # | 手段 | 生效速度 | 對 cookie 持有者 | 什麼時候用 |
|---|---|---|---|---|
| 1 | `APP_CANARY_ENABLED=false` + image 改回 stable 版 | 下一次導航 | 乾淨排空 | **預設做法** |
| 2 | 規則 1 的 destination 改成 `subset: stable` | 瞬間 | 立刻全部回 stable | 緊急，連一次導航都不能等 |
| 3 | `replicas: 1 → 0` | 瞬間 | **503 UH，卡到 cookie 過期** | **不可單獨使用** |

第 2 張牌在 `base/03-virtualservice.yaml`，依規範要用單獨 stage + 額外核准，
所以列為第二道 —— 但值班的人要**知道有這張牌**。

**使用者端的自助逃生口** 🚧：`https://myapp.example.com/gui_epmmFormQuery/canary/leave`
—— 直接輸入網址即可清 cookie 回到 stable，不需要登入、不需要 JavaScript、canary 前端壞掉也能用。
（依賴 PRD US-004）

**目前的替代手段**：請使用者按 F12 → Console 貼上

```javascript
document.cookie = "canary=always;path=/gui_epmmFormQuery;max-age=0"; location.reload();
```

> 注意 `path` 是 `/gui_epmmFormQuery`。用 `/` 會清不掉（那是兩個不同的 cookie）。

---

## Part 6：已知限制與陷阱

| # | 事實 | 為什麼要知道 |
|---|---|---|
| 1 | **跨軌切換必定多一次 Keycloak 往返** | session 是 per-pod in-memory，切過去等於重新認證。有 `ea_login_hint` 時是無畫面的（`prompt=none`） |
| 2 | **canary 必須 `replicas: 1`** | OAuth2 `state` 在 pod session 裡 |
| 3 | **cookie 不是 HttpOnly** —— 任何人都能自己種 | 刻意保留人工覆寫。真正的門禁是 `CanaryEvictionFilter`（使用者驗證後把不在名單的踢掉）。**把那個 filter 拿掉就同時失去門禁** |
| 4 | **名單只在「登入」與「導航」兩個時機生效** | 不是即時的。加人要重新登入，移除則下次導航生效 |
| 5 | **`x-app-track` 不能證明畫面上跑的是哪一版** | 它只說這個請求打到哪個 pod。見 Part 1 |
| 6 | **cookie `Path` 是 `/gui_epmmFormQuery`** | 跟 `XSRF-TOKEN` 一致。舊文件寫 `/`，手動種錯 path 會變成兩個 cookie |
| 7 | 若日後前端加了 **Service Worker（PWA）**，整套 cookie 路由會被架空 | SW 攔截所有請求優先回快取。症狀：畫面一直是舊版但 `x-app-track: canary`。目前已確認沒有註冊 SW，**加了必須重驗** |
| 8 | 若 AngularDart 日後加了 **deferred loading**（`.part.js`） | 那些分片由 `main.dart.js` 在執行期抓取，不經過 `index.html`。請寫進該專案的 code review 檢查項 |
| 9 | 兩軌共用 **localStorage / IndexedDB** | canary 寫了新格式 → 使用者回 stable → 舊版可能壞掉，而且那時 canary 已下線，**事後極難聯想** |
