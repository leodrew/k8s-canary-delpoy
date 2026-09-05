# BFF 自動分流設計 — 用程式取代手動種 cookie

> 這份是**設計提案**，不是操作手冊。要動手前請先看完 Part 3（不可協商的前提）
> 與 Part 8（風險），並回答 Part 10 的待決問題。
>
> 相關文件：`pilot-run-guide.md`（現行人工流程）、`SOP-apply-only.md`（發布流程）、
> `track-a/base/03-virtualservice.yaml`（路由規則）、`k8s-ecosystem-guide.md` Part 7 / Part 14。

---

## Part 0：這是在解決什麼問題

### 現況

`pilot-run-guide.md` 要求驗證人員自己種 cookie：

```javascript
document.cookie = "canary=always;path=/;max-age=28800"; location.reload();
```

然後 `base/03-virtualservice.yaml` 的規則 1 比對這個 cookie，把他送進 `subset: canary`。

### 現況的四個痛點

| # | 痛點 | 後果 |
|---|---|---|
| 1 | 靠使用者自己操作 | 公司瀏覽器政策擋 `javascript:` 書籤，改用 F12 貼指令，非技術使用者會卡住 |
| 2 | 使用者可能忘記切回 | promote 之前他一直看未驗證的版本，出事了沒人知道他在 canary 上 |
| 3 | 無法擴大 pilot 人數 | 每多一個人就多一份教學成本，實務上 pilot 人數卡在 2～3 人 |
| 4 | 沒有紀錄 | 「現在誰在 canary 上」只能用 Istio metrics 猜，無法回答「這個人驗過了嗎」 |

### 目標

**使用者登入,系統自己決定他該去哪一軌。** 名單由 config 控制,改名單不需要重啟正式環境。
使用者端的操作降為零。

### 明確不在範圍內

- **不做百分比分流**。`03-virtualservice.yaml` 規則 2 的權重維持 stable 100 / canary 0。
  這套機制只做「指定名單」,不做「隨機抽樣」。
- **不做 session 外部化**（Spring Session + Redis）。那是 guide 7.4 解法 C,是另一個題目,
  而且會讓 canary 和 stable 共用 session store —— canary 寫壞 session 會污染 stable。

---

## Part 1：為什麼這件事可行

### 關鍵事實：Envoy 不在乎 cookie 是誰種的

`base/03-virtualservice.yaml` 的規則 1 只做一件事 —— 比對 cookie header：

```yaml
match:
  - headers:
      cookie:
        regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"
```

瀏覽器 console 種的 cookie、跟 BFF 用 `Set-Cookie` 發的 cookie,送到 Envoy 是**同一個 header**。

> **所以 `base/` 底下一個檔案都不用改。** 這是這個方案最大的優點 ——
> 網路設定不動,只動應用層,爆炸半徑可控。

`k8s-ecosystem-guide.md:2952` 其實已經寫下這個想法了：

> 其餘走 v1,**並由 v1 決定要不要發 canary-group cookie**

### 「導轉到 canary 的頁面」這個講法要修正

前端是**打包在 BFF 的 jar 裡**的（`release/10-configmap-1.2.3.yaml:72`）：

```yaml
frontend:
  resource-location: classpath:/gui_epmmFormQuery/web/
  index-path: /gui_epmmFormQuery/web/index.html
```

所以 stable pod 和 canary pod 回應**同一個 URL**,只是回出來的 bytes 不同 —— 各自 jar 裡的那份。
**沒有第二個網址可以導。**

而且規則 1 **沒有 `uri` match**,只比對 cookie。這代表 cookie 一種下去,那個瀏覽器的
`index.html`、JS bundle、CSS、圖片、XHR API 呼叫**全部**進 canary pod,不會有一半打到 stable。

> **結論：兩版 GUI 完全不同也自動成立。**
> 你不需要導轉到別的頁面,只需要「種 cookie + 302 回原本的 URL」。
> 但這會引爆快取問題,見 Part 3.3。

### 流程對照

```
【現況】
  使用者 ──F12 貼指令──▶ 種 cookie ──▶ 重整 ──▶ Envoy 比對 ──▶ canary

【新做法】
  使用者 ──登入──▶ stable 的 BFF ──比對名單──▶ Set-Cookie + 302
                                                      │
                                       ┌──────────────┘
                                       ▼
                             Envoy 比對 cookie ──▶ canary
```

---

## Part 2：整體架構

### 決策點放在哪裡

**放在登入成功那一刻（`AuthenticationSuccessHandler`）,不要放在 per-request filter。**

| 方案 | 每個請求都判斷 | 只在登入成功時判斷 ✅ |
|---|---|---|
| 正式流量的延遲成本 | 每個請求都要算 | 一次登入算一次 |
| 302 打壞 POST / XHR 的風險 | **高**（要小心排除） | 無（登入 callback 本來就是 GET 導向） |
| 使用者體感 | 操作到一半畫面跳掉 | 藏在本來就在跳轉的登入流程裡,無感 |
| 名單改了多久生效 | 下一個請求 | 下次登入（可接受） |

你的 app 已經是 Spring Security OAuth2 + Keycloak
（`10-configmap-1.2.3.yaml` 的 `oauth2.client.registration.keycloak`,
`user-name-attribute: preferred_username`）,登入成功那一刻 `preferred_username`
已經在 `OAuth2User` 裡了。

> **所以預設不需要打任何外部 service。** 見 Part 4.4 討論「名單真的必須來自外部系統」的情況。

### 但仍然需要一個 per-request filter —— 用途不同

`AuthenticationSuccessHandler` 只能處理「登入當下」。有兩種情況需要在請求中途把人趕回 stable：

1. **主開關被關掉**（canary 驗證失敗,要收工）
2. **使用者被從名單移除**,但他的 cookie 還沒過期

這個 filter 叫 `CanaryEvictionFilter`,**只跑在 canary pod 上**,而且只處理導航請求。
它的存在是為了讓「關閉 canary」這件事能自癒,見 Part 7.2。

### 兩個元件的分工

| 元件 | 跑在哪 | 何時作用 | 做什麼 |
|---|---|---|---|
| `CanarySwitchSuccessHandler` | stable + canary | 登入成功 | 在名單內 → 種 cookie + 302 |
| `CanaryEvictionFilter` | 實際只在 canary 生效 | 每個導航請求 | 不在名單 / 開關關了 → 清 cookie + 302 |

---

## Part 3：不可協商的三個前提

這三件事任何一件沒做,方案會直接不會動,或是會在 pilot 中途爆掉。

> 3.4 不是第四個前提 —— 它是 3.3 條件②在 dart2js 前端上的具體作法。
> React 那批不需要看 3.4。

### 3.1 Filter 必須「先」在 stable 上線

沒帶 cookie 的請求 **100% 被路由到 stable**（規則 2 / 規則 3）。
所以「發 cookie 的那段程式」只有 **stable pod** 跑得到。

> **如果你把這段程式只放進 canary image,永遠沒有人拿得到 cookie,canary 一個請求都收不到。**

這代表這段程式是**基礎建設程式碼**,不是某個版本的功能。上線順序必須是：

```
版本 N   ── 含 filter ── 用「現行的手動 bookmarklet」做 pilot ── promote 進 stable
                                                                        │
版本 N+1 ─────────────────── 從這個版本開始才享受自動分流 ◀──────────────┘
```

一次性成本,但**順序反了整套不會動**。

### 3.2 名單不能放進現在那份 ConfigMap

`release/10-configmap-1.2.3.yaml` 是 `immutable: true` 且檔名帶版本號。名單放進去的話,
「加一個 pilot 使用者」會變成：

新增一份 ConfigMap → 改 `20-deployment-stable.yaml` 的 `config-version` annotation
→ **滾動重啟整個正式環境**

顯然不行。必須另外開一份**可變、不帶版本號、不 immutable** 的 ConfigMap,單獨掛在另一個路徑。

#### 【踩雷】ConfigMap 熱更新的兩個陷阱

| 陷阱 | 後果 | 對策 |
|---|---|---|
| 用 `subPath` 掛檔案 | kubelet **永遠不會**同步更新那個檔案 | **掛目錄,不要用 subPath** |
| 以為 kubelet 更新了 app 就會看到 | kubelet 只換檔案內容,JVM 不會自己重讀 | app 端要自己定期重讀 |

kubelet 大約 1 分鐘內把新內容同步到掛載目錄（用 `..data` symlink 原子換掉）。
app 端每 30 秒重讀一次檔案即可,見 Part 5.2。

> 不要為了這個引進 Spring Cloud Kubernetes —— 它會要 ServiceAccount 有 K8s API 權限,
> 而 `base/00-serviceaccount.yaml` 刻意設了 `automountServiceAccountToken: false`。
> 自己寫 30 行的檔案 reload 比較省事,也不用開權限。

### 3.3 快取:兩個獨立條件,不是一件事

**這一條只在「兩版 GUI 不同」時才會爆,但它幾乎一定會爆。**
而且它其實是**兩個彼此獨立的條件**,各自擋不同的東西 —— 只做其中一個不會有效果。

| | 條件 | 擋什麼 | 少了它會怎樣 |
|:---:|---|---|---|
| **①** | `index.html` 必須 `no-store` | 保證你拿到的 HTML 來自你被路由到的那個 pod | 拿到 stable 的 HTML,人卻在 canary |
| **②** | 兩版的 asset URL 必須不同 | 保證瀏覽器不會拿快取的 stable 檔案,去回應 canary HTML 要的那個 URL | canary HTML 要 `main.js`,瀏覽器直接給快取裡 stable 那份 |

> **①做了②沒做,一樣會壞。** 這點值得特別講,因為②通常是 build 工具免費附贈的,
> 很容易誤以為不用管 —— 直到遇上一個不附贈的前端。

#### 各前端的現況

| 前端 | 條件① | 條件② | 要補什麼 |
|---|:---:|:---:|---|
| React — `react-scripts build`（CRA） | 要加 | ✅ 預設就有 content hash | 只要① |
| React — `vite build` | 要加 | ✅ 預設就有 content hash | 只要① |
| React — 手寫 / ejected webpack | 要加 | 看 `output.filename` 有沒有 `[contenthash]` | 要先驗 |
| **AngularDart — dart2js** | 要加 | ❌ **固定檔名,而且沒有選項可以開** | ①+②,見 3.4 |

> webpack 的 `[hash]` / `[chunkhash]` / `[contenthash]` 對 canary 來說**都可以** ——
> 我們只需要「stable 和 canary 的檔名不同」。`[contenthash]` 最好（內容沒變就不換名字,
> 快取命中率最高）,但另外兩個也不會壞。

#### 條件①沒做會怎樣

以已經有 content hash 的前端為例（React）：

```
1. 使用者在 stable,瀏覽器快取了 index.html（裡面引用 main.a1b2c3.js）
2. filter 種 cookie + 302
3. 下一個請求進 canary pod ── 但 index.html 是從瀏覽器快取拿的,還是舊那份
4. 瀏覽器照舊 HTML 去要 main.a1b2c3.js
   → canary 的 jar 裡只有 main.x9y8z7.js
   → 404
5. 白畫面
```

切回 stable 時反向再爆一次。`k8s-ecosystem-guide.md:4648` 那張表裡
「v1.3.1 **FAIL**（靜態資源 404）」就是這一類。

| 檔案 | Cache-Control | 為什麼 |
|---|---|---|
| `index.html` | `no-store` | 唯一必須每次回源的檔案 |
| `main.<hash>.js` 等 | `max-age=31536000, immutable` | 檔名不同就不會撞,可以長快取 |

#### 【踩雷】條件②沒做,不會 404,而是靜默混版

固定檔名的前端（`main.js`、`main.dart.js` 那種）,瀏覽器會拿快取的 stable 檔案
去配 canary 的 `index.html`。**不會 404,而是功能詭異、錯誤散落各處、極難查。**

> 404 至少會讓 pilot 使用者立刻回報「整個壞掉」。靜默混版會讓他回報一堆
> **看起來像新版 bug、實際上根本不存在的問題** —— 你會浪費好幾輪去追一個不存在的東西。

#### 如果前面有共用快取（CDN / nginx / F5）

HTML 回應要加 `Vary: Cookie`,否則 stable 的 HTML 會被快取後餵給 canary 使用者 ——
這比 404 危險,因為它**靜默地混版**。

> `Vary: Cookie` **只加在 HTML 上**。加在 hash 資源上會讓快取命中率歸零。

#### 【踩雷】條件②有個涵蓋不到的缺口：執行期才抓的資源

不論是 React 的 content hash,還是 3.4 的 `?v=` 改寫,**都只涵蓋
`index.html` 裡用 `src=` / `href=` 引用的檔案**。

App 在**執行期**自己去抓的東西,兩種機制都碰不到：

| 例子 | 為什麼漏掉 |
|---|---|
| `assets/config.json` 這類啟動設定 | JS 裡 fetch 的,不在 HTML 裡 |
| i18n 語言包 | 同上,而且常常是動態組路徑 |
| JS 動態組出來的圖片路徑 | build 工具無法靜態分析 |
| CSS 裡 `url()` 引用的字型 | 在 CSS 裡,不在 HTML 裡 |
| dart2js 的 `*.part.js`（若有 deferred loading） | 執行期由 `main.dart.js` 去要 |

這些 URL 在兩軌上**完全相同**。如果又套了 `max-age=1y`,使用者切到 canary 之後
會繼續用 stable 的那份 —— 又是一次靜默混版。

> **這個缺口對 React 和 AngularDart 一樣存在。** React 有 content hash 不代表安全,
> 它保護的只是 build 工具「看得到」的那些檔案。

#### 對策：快取策略改成看「這個 URL 分不分得出版本」

現行寫法是**用路徑前綴**決定要不要長快取 —— 只要在 `web/` 底下就給一年。
改成用「這個 URL 有沒有版本標記」來決定,見 Part 5.7 的實作。

沒有版本標記的一律 `no-cache`（可以存,但每次都要跟伺服器確認)。
多一個 304 往返,換掉一整類靜默混版的 bug。

> **這樣預設是安全的** —— 任何版本化機制沒觸及的檔案會自動掉進安全那一格,
> 而不是靜默地被長快取釘住。新加了一個 runtime 抓取的資源也不用記得改設定。

### 3.4 AngularDart（dart2js）要自己補條件②

dart2js 的輸出是**固定檔名**,`pub build` / `webdev build` / `build_runner --release` 都一樣：

```
build/
  index.html
  main.dart.js              ← 永遠叫這個名字,不管內容變成什麼
```

**這不是設定問題,是 dart2js 的輸出格式就長這樣 —— 沒有開關可以打開 content hash。**

#### 不要去改 build,改在 Spring 這一側

硬要讓 dart2js 產生 hash 檔名只會讓 build pipeline 變複雜。改成在 Spring 供應
`index.html` 的時候,把資源引用改寫成帶版本查詢字串。

【關鍵】接進 Spring 的 **resource chain**,不要自己讀檔算好放在記憶體裡。
自己讀檔的寫法會漏掉一件事：**你算出來的字串沒有任何東西會去用它** ——
`index.html` 仍然是靜態資源處理器從 classpath 直接送出去的原始那份。

#### 先決定:version 這個值從哪來

| 來源 | 問題 |
|---|---|
| Deployment 加一個 `APP_BUILD_VERSION` env | 已經有「**三處版本號**」要同步（image tag、ConfigMap 名稱、`config-version` annotation),再加第四處只是多一個會漏改的地方 |
| Spring 的 `BuildProperties`（`build-info.properties`） | 可行,跟著 maven version 走。但**前端沒改的版本也會換 URL**,白白丟掉快取 |
| **啟動時算 `main.dart.js` 的內容雜湊** | **推薦** —— 見下方 |

內容雜湊最好,理由很直接:**它就是 content hash,只是改在啟動時算,而不是 build 時算。**
dart2js 不給你,那就自己補上。

它**不可能跟實際檔案不同步**,因為它是從那個檔案本身算出來的 —— 沒有第四處要維護,
也沒有「版本號改了但檔案沒換」或反過來的可能。

```java
public class ContentHashIndexTransformer implements ResourceTransformer {

    private static final Logger log = LoggerFactory.getLogger(ContentHashIndexTransformer.class);

    private static final Pattern REF =
            Pattern.compile("(src|href)=\"([^\"?#]+\\.(?:js|css))\"");

    private final ResourceLoader loader;
    private final String base;                            // classpath:/gui_epmmFormQuery/web/
    private final Map<String, String> cache = new ConcurrentHashMap<>();

    @Override
    public Resource transform(HttpServletRequest req, Resource resource,
                              ResourceTransformerChain chain) throws IOException {

        Resource out = chain.transform(req, resource);
        if (!"index.html".equals(out.getFilename())) return out;   // 只改 index.html

        String html = new String(out.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        Matcher m = REF.matcher(html);
        StringBuilder sb = new StringBuilder();
        while (m.find()) {
            String v = cache.computeIfAbsent(m.group(2), this::hashOf);
            m.appendReplacement(sb, Matcher.quoteReplacement(
                    m.group(1) + "=\"" + m.group(2) + "?v=" + v + "\""));
        }
        m.appendTail(sb);

        return new TransformedResource(out, sb.toString().getBytes(StandardCharsets.UTF_8));
    }

    private String hashOf(String ref) {
        try (InputStream in = loader.getResource(base + ref).getInputStream()) {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(in.readAllBytes());
            return HexFormat.of().formatHex(d, 0, 4);              // 8 個 hex 字元
        } catch (Exception e) {
            // 【重要】算不出來就不版本化,絕不讓它擋住首頁。
            // 這段跑在正式流量的路徑上,寧可退化成「沒有版本化」也不能丟 500。
            log.warn("asset hash failed for {}, serving unversioned", ref, e);
            return "0";
        }
    }
}
```

```java
registry.addResourceHandler(fe.getUrlPrefix() + "/**")
        .addResourceLocations(fe.getResourceLocation())
        .resourceChain(true)               // true = 轉換結果快取,每個資源只算一次
        .addTransformer(new ContentHashIndexTransformer(loader, fe.getResourceLocation()));

// 【不要】在這裡呼叫 .setCacheControl(...) —— 見下方陷阱
```

> `resourceChain(true)` 會把轉換結果快取起來,所以整份 HTML 只算一次,
> 3MB 的 `main.dart.js` 也只讀一次。

走 resource chain 還有一個附帶好處：**SPA fallback 自動涵蓋**。深連結
（`/gui_epmmFormQuery/web/some/route`）最後也是解析到 `index.html`,同一個
transformer 就處理掉了。用「controller 回傳記憶體字串」的寫法,你得自己把
fallback 的路由也接上,很容易漏掉一條。

#### 【踩雷】不要在 resource handler 上設 cache control

```java
registry.addResourceHandler(...).setCacheControl(CacheControl.maxAge(365, DAYS));
```

這會套用到這個 handler 供應的**所有**檔案,`index.html` 也會拿到 `max-age=1y`
—— **條件①直接失效,而且失效得很安靜**（沒有錯誤,只是快取行為變錯）。

快取 header 全部交給 Part 5.7 那個 filter 依路徑決定,單一來源,不會打架。

#### 為什麼查詢字串就夠

配上條件①之後就正確了：

```
stable      → 新鮮的 index.html → main.dart.js?v=8f3a1c02 → 瀏覽器快取這個 URL
切到 canary → 新鮮的 index.html → main.dart.js?v=b41d7e90 → 不同 URL,重抓 ✓
切回 stable → 新鮮的 index.html → main.dart.js?v=8f3a1c02 → 快取命中,拿到正確的 stable ✓
```

> **不需要真的改檔名。** 瀏覽器的快取鍵包含查詢字串,
> 所以 `?v=8f3a1c02` 和 `?v=b41d7e90` 是兩個不同的快取項目。

#### 【觀念】`?v=` 不是查找鍵,version 也不經過 Istio

容易誤會的地方：以為「瀏覽器帶著 version 進來 → VirtualService 或後端依據 version
去找對應的 `main.dart.js`」。**不是這樣。**

```
瀏覽器
  │  Cookie: canary=always          ← Istio 只看這個
  ▼
VirtualService 規則 1 ──────────▶ canary pod
                                     │  這個 pod 的 jar 裡
                                     │  只有「一份」main.dart.js
                                     ▼
                         回它自己的 index.html
                         裡面寫 main.dart.js?v=b41d7e90
                                     │
  ┌──────────────────────────────────┘
  ▼
瀏覽器去要 main.dart.js?v=b41d7e90
  → 還是同一個 canary pod（cookie 還在）
  → 它直接回自己那份,【完全忽略 ?v= 這個查詢字串】
```

**pod 不需要「找」版本,因為它只有一個版本 —— 它自己的。**
`?v=` 唯一的作用是讓**瀏覽器**把它當成不同的快取項目。

所以：

- **VirtualService 一行都不用改**,規則 1 只比對 cookie header
- 靜態資源落在規則 2 的 `uri: prefix: /gui_epmmFormQuery/`,前綴比對不受查詢字串影響
- 後端也不需要解析 `?v=`,Spring 的靜態資源處理器本來就會忽略它

#### 驗證

直接透過 VirtualService 打,比對兩軌的 hash：

```bash
URL="https://myapp.example.com/gui_epmmFormQuery/"

echo "--- stable ---"
curl -sS "$URL" | grep -oE 'main\.dart\.js\?v=[a-f0-9]+'

echo "--- canary ---"
curl -sS -H "Cookie: canary=always" "$URL" | grep -oE 'main\.dart\.js\?v=[a-f0-9]+'
```

> **兩邊 hash 一樣不一定是壞掉。** 如果這次 canary 只改了後端 Java,
> 前端 `main.dart.js` 一個 byte 都沒變,那兩邊 hash **本來就該一樣**,
> 而且瀏覽器繼續用快取那份**是正確行為**。
>
> 這正是內容雜湊比「用 app 版本號」好的地方：它只在真的該換的時候才換。
> 但測試時請用**前端真的有改動**的 canary 版本,否則你會看到兩個相同的 hash,
> 然後誤以為 transformer 沒生效。

> **React 那批要明確關掉這個 transformer。** 它們的檔名已經帶 content hash,
> 再加 `?v=<版本>` 會讓每次發版**連沒改過的 chunk 也換 URL** ——
> 快取命中率白白變差,而且沒有任何好處。

#### 【踩雷】如果之後在 AngularDart 加了 deferred loading

`deferred as` + `loadLibrary()` 會讓 dart2js 多吐出 `main.dart.js_1.part.js` 這類分片。
**那些是 `main.dart.js` 在執行期自己去要的,不經過 index.html** —— 上面那個 HTML 改寫
碰不到它們,`?v=` 加不上去。屆時要額外把 `*.part.js` 設成 `no-store`。

> **目前已確認這支 app 沒有用 deferred loading**（build 產出裡沒有任何 `.part.js`）,
> 所以這段暫時不適用。但如果之後有人為了縮小首屏 bundle 而加了 deferred route,
> **這個 canary 機制會開始靜默出錯,而且不會有任何錯誤訊息提醒你** ——
> 請把這件事寫進那個專案的 code review 檢查項。

#### 怎麼確認有沒有 deferred loading

```bash
# 最準：看 jar 裡實際有沒有分片（不需要原始碼,不會被寫法差異騙過）
unzip -l target/*.jar | grep 'part\.js'

# 看原始碼：三個關鍵字都要查,只查 deferred as 會漏掉 router 的寫法
grep -rn "deferred as"           --include="*.dart" lib/ web/
grep -rn "loadLibrary()"         --include="*.dart" lib/ web/
grep -rn "RouteDefinition.defer" --include="*.dart" lib/
```

---

## Part 4：詳細設計

### 4.1 狀態機

用兩個 Deployment 都已經有的 `APP_TRACK` env var 判斷「我是誰」
（`20-deployment-stable.yaml` 與 `21-deployment-canary.yaml` 都設了）。

| 主開關 | 我在哪一軌 | 在名單內 | 有 cookie | 動作 |
|:---:|:---:|:---:|:---:|---|
| off | canary | — | ✅ | **清 cookie + 302**（收工時把人趕回去） |
| off | 任何 | — | — | 放行 |
| on | stable | ✅ | ❌ | **種 cookie + 302** |
| on | stable | ✅ | ✅ | 放行（理論上到不了,防迴圈用） |
| on | stable | ❌ | — | 放行 |
| on | canary | ✅ | — | 放行 |
| on | canary | ❌ | — | **清 cookie + 302**（誤入的人趕回去） |

這個狀態機是**收斂的** —— 每個 302 之後的下一個請求都會落在「放行」,不會迴圈。

### 4.2 Cookie 屬性

```
canary=always; Path=/; Max-Age=28800; Secure; SameSite=Lax
```

| 屬性 | 值 | 為什麼 |
|---|---|---|
| `Path` | `/` | **不是** `/gui_epmmFormQuery`。actuator 和其他路徑也要帶到 |
| `SameSite` | `Lax` | **絕對不能 `Strict`** —— Strict 會讓從 Keycloak 導回來的 cross-site navigation 不帶 cookie,整條流程直接壞掉 |
| `Max-Age` | `28800`（8 小時） | 跟現行 bookmarklet 一致。縮短 cookie 殘留窗口,見 Part 7.3 |
| `Secure` | 有 | 走 HTTPS |
| `HttpOnly` | **不加** | 加了之後 `pilot-run-guide.md` 的 bookmarklet 人工 override 就失效。保留它當備援 |

> `HttpOnly` 不加是**刻意的取捨**。這個 cookie 不含任何機密,只是一個路由開關,
> 被 JS 讀到沒有安全影響;但保留人工覆寫的能力在 pilot 期間很有價值。

### 4.3 302 的目標 URL

Spring Security 預設會導向 **saved request**（使用者原本想去的深連結）。
但那是 **stable 時代的 URL**。

如果新版 GUI 改了路由（`/web/form` → `/web/forms`）,使用者會被導到 canary 上不存在的路徑。

> **跨軌切換時忽略 saved request,直接導到 app 根路徑**（`/gui_epmmFormQuery/web/`）。
> 多走一步,但保證落在有效頁面上。

### 4.4 名單的來源

**預設方案：不打外部 service。** 用 Keycloak 已經給的 `preferred_username` 比對本地名單。

如果名單真的必須來自外部權限系統：

- **只在登入成功那一次打**,結果存進 `HttpSession`
- timeout ≤ 1 秒
- **fail-open** —— 打不到就當作「不在名單」,留在 stable,**絕不擋住請求**

> **絕對不要做成 per-request 呼叫。** 那等於把一個外部相依塞進 100% 正式流量的熱路徑 ——
> 那隻 service 慢,你整個系統跟著慢。

### 4.5 兩個「同 origin」造成的副作用

#### localStorage / IndexedDB 是共用的

stable 和 canary 是**同一個 origin**（同 host、同 port）,所以瀏覽器本地儲存兩版共用。

GUI 改版通常會動到前端本地儲存的結構。canary 寫了新格式 → 使用者驗完切回 stable
→ 舊版讀到不認識的結構 → **舊版壞掉**。

> 這是「pilot 使用者驗完新版之後,舊版壞了」的典型成因,而且因為那時 canary 已經下線,
> **事後極難聯想**。

對策：canary 的 storage key 全部加版本前綴（`v2:`）,或在清 cookie 那條路徑上
順便回一個讓前端清掉自己 storage 的訊號。

#### Service Worker（如果有的話）

> **已確認：這支 app 沒有註冊 Service Worker**
> （`navigator.serviceWorker.getRegistrations()` 回傳 0）。
> 這一節保留下來,是因為**哪天有人加了 PWA,這個機制會靜默失效**。

如果前端有註冊 Service Worker,它會 precache 整個 app shell 並**攔截所有請求優先回快取**
—— cookie 路由對它完全無效。症狀是**使用者一直看到 stable 的畫面,但 `x-app-track` 顯示 `canary`**。

切換 track 時必須主動 `unregister` + 清 Cache Storage。

#### 怎麼查有沒有 Service Worker

**方法 1：瀏覽器（最準,10 秒,不需要原始碼）**

打開系統頁面 → `F12` → **Application** 分頁 → 左欄 **Service Workers**

| 看到什麼 | 意思 |
|---|---|
| `No service workers detected for this origin` | **沒有** |
| 列出一筆 registration（有 Source / Status） | **有** |

順便看左欄的 **Cache Storage**：有項目就代表 SW 真的在快取東西。

**方法 2：Console 一行**

```javascript
navigator.serviceWorker.getRegistrations().then(r => console.log(r.length, r));
```

印出 `0` 就是沒有。

**方法 3：看原始碼**

```bash
# React
grep -rn "serviceWorker\|registerSW\|workbox\|navigator.serviceWorker" \
     src/ public/ vite.config.* 2>/dev/null
grep -n "vite-plugin-pwa\|workbox" package.json

# 看實際被打進 jar 的
unzip -l target/*.jar | grep -iE 'service-worker|sw\.js|workbox|webmanifest'
```

> **【踩雷】CRA 的檔案存在不代表有啟用。** Create React App 會 scaffold 出
> `serviceWorkerRegistration.js`,但 `index.js` 裡預設呼叫的是 **`unregister()`**
> 而不是 `register()`。看到檔案先別緊張,**要看它到底呼叫哪一個**。

#### 【踩雷】最危險的情況：以前註冊過,現在移掉了

Service Worker 一旦在使用者瀏覽器註冊過,**就會一直活著,直到被明確 unregister**
—— 你把程式碼刪掉、重新發版,都不會讓它消失。

所以「我現在的原始碼裡沒有 SW」**不等於**「使用者的瀏覽器裡沒有 SW」。
如果這支 app 歷史上曾經有過 PWA 階段,可能有一批老使用者身上還掛著一個
幾年前的 SW,它會把 cookie 路由整個架空,而且症狀是
**畫面一直是舊版,但 `x-app-track` 顯示 `canary`**。

驗證方式：**找一台真正日常在用這個系統的同事的電腦**開 F12 看,
不要只看你自己的開發機（你可能清過快取）。

> 如果真的發現有殘留的 SW,處理方式是發一版「自殺 SW」——
> 註冊一個只做 `self.registration.unregister()` 的空 SW 把舊的頂掉。
> 這是獨立工項,要在 canary 機制上線前做完。

---

## Part 5：程式碼

> 以下是 Spring Boot 3.5 / Spring Security 6 的寫法。BFF 原始碼不在這個 repo,
> 所以這裡是可以直接貼進去的骨架,不是從既有程式碼改出來的 diff。

### 5.1 設定

```java
@ConfigurationProperties(prefix = "app.canary")
public class CanaryProperties {

    /** 主開關。預設 false —— canary 靜止（replicas: 0）時絕對不能發 cookie。 */
    private boolean enabled = false;

    /** 我是哪一軌。由 APP_TRACK env var 注入,兩個 Deployment 都已經有這個變數。 */
    private String track = "stable";

    private String cookieName  = "canary";
    private String cookieValue = "always";

    /** 跟 pilot-run-guide 的 bookmarklet 一致。縮短 cookie 殘留窗口。 */
    private Duration cookieMaxAge = Duration.ofHours(8);

    /** 名單檔。掛的是「目錄」,不是 subPath —— 否則 kubelet 不會更新。 */
    private Path rosterFile = Path.of("/app/canary/pilot-users.txt");

    /** 跨軌切換一律導到這裡,不用 saved request（那是舊版的 URL）。 */
    private String entryPath = "/gui_epmmFormQuery/web/";

    public boolean isCanaryTrack() { return "canary".equalsIgnoreCase(track); }

    // getters / setters 略
}
```

對應的 `application.yml`（放進 `release/10-configmap-<版本>.yaml`）：

```yaml
app:
  canary:
    enabled: ${APP_CANARY_ENABLED:false}     # 主開關,預設關
    track: ${APP_TRACK:stable}               # Deployment 已經有這個 env
    cookie-max-age: 8h
    roster-file: /app/canary/pilot-users.txt
    entry-path: /gui_epmmFormQuery/web/
```

### 5.2 名單熱讀取

```java
@Component
public class CanaryPilotRoster {

    private static final Logger log = LoggerFactory.getLogger(CanaryPilotRoster.class);

    private final CanaryProperties props;
    private volatile Set<String> users = Set.of();   // 讀不到 = 空名單 = 沒人進 canary
    private volatile String lastRaw = null;

    public CanaryPilotRoster(CanaryProperties props) { this.props = props; }

    /**
     * 每 30 秒重讀一次。
     *
     * 【為什麼比對「內容」而不是 mtime】
     * ConfigMap volume 是用 ..data symlink 原子換掉的,mtime 的行為在不同 kubelet
     * 版本上不完全一致。名單檔只有幾百 bytes,直接比對內容最單純可靠。
     *
     * 需要在啟動類別加 @EnableScheduling。
     */
    @Scheduled(fixedDelay = 30_000, initialDelay = 0)
    void reload() {
        try {
            Path f = props.getRosterFile();
            if (!Files.exists(f)) {
                if (lastRaw != null) {
                    log.warn("canary roster file disappeared: {} — 名單清空", f);
                    users = Set.of();
                    lastRaw = null;
                }
                return;
            }

            String raw = Files.readString(f, StandardCharsets.UTF_8);
            if (raw.equals(lastRaw)) return;             // 沒變就不動

            Set<String> next = raw.lines()
                    .map(String::trim)
                    .filter(s -> !s.isEmpty() && !s.startsWith("#"))
                    .map(s -> s.toLowerCase(Locale.ROOT))
                    .collect(Collectors.toUnmodifiableSet());

            users   = next;
            lastRaw = raw;
            log.info("canary pilot roster reloaded: {} user(s)", next.size());

        } catch (Exception e) {
            // 【重要】讀失敗保留舊名單 —— 一次 IO 錯誤不代表名單空了。
            // 但「檔案不存在」是明確的訊號,上面那段會清空。
            log.warn("canary roster reload failed, keeping previous roster", e);
        }
    }

    public boolean contains(String username) {
        return username != null && users.contains(username.toLowerCase(Locale.ROOT));
    }

    public int size() { return users.size(); }
}
```

### 5.3 決策

```java
public enum CanaryAction { SWITCH_TO_CANARY, EVICT_TO_STABLE, NONE }

@Component
public class CanaryTrackDecider {

    private final CanaryProperties props;
    private final CanaryPilotRoster roster;

    /** 對應 Part 4.1 的狀態機。 */
    public CanaryAction decide(String username, boolean hasCanaryCookie) {
        boolean onCanary = props.isCanaryTrack();

        // 主開關關閉：canary 側把人趕回 stable,stable 側什麼都不做
        if (!props.isEnabled()) {
            return (onCanary && hasCanaryCookie) ? CanaryAction.EVICT_TO_STABLE
                                                 : CanaryAction.NONE;
        }

        boolean pilot = roster.contains(username);

        if (!onCanary) {
            return (pilot && !hasCanaryCookie) ? CanaryAction.SWITCH_TO_CANARY
                                               : CanaryAction.NONE;
        }
        return pilot ? CanaryAction.NONE : CanaryAction.EVICT_TO_STABLE;
    }
}
```

### 5.4 Cookie 的產生

```java
@Component
public class CanaryCookies {

    private final CanaryProperties props;

    public String issue() {
        return base(props.getCookieValue())
                .maxAge(props.getCookieMaxAge())
                .build().toString();
    }

    public String clear() {
        return base("").maxAge(Duration.ZERO).build().toString();
    }

    private ResponseCookie.ResponseCookieBuilder base(String value) {
        return ResponseCookie.from(props.getCookieName(), value)
                .path("/")             // 不是 /gui_epmmFormQuery —— actuator 也要帶到
                .secure(true)
                .httpOnly(false)       // 刻意的：保留 bookmarklet 人工 override
                .sameSite("Lax");      // 【關鍵】不能 Strict,否則 Keycloak 導回不帶 cookie
    }

    public boolean present(HttpServletRequest req) {
        Cookie[] cs = req.getCookies();
        if (cs == null) return false;
        for (Cookie c : cs) {
            if (props.getCookieName().equals(c.getName())
                    && props.getCookieValue().equals(c.getValue())) return true;
        }
        return false;
    }
}
```

### 5.5 登入成功時切換

```java
public class CanarySwitchSuccessHandler extends SavedRequestAwareAuthenticationSuccessHandler {

    private static final Logger log = LoggerFactory.getLogger(CanarySwitchSuccessHandler.class);

    private final CanaryTrackDecider decider;
    private final CanaryCookies cookies;
    private final CanaryProperties props;
    private final RedirectStrategy redirects = new DefaultRedirectStrategy();

    @Override
    public void onAuthenticationSuccess(HttpServletRequest req, HttpServletResponse res,
                                        Authentication auth) throws IOException, ServletException {

        CanaryAction action = CanaryAction.NONE;
        try {
            action = decider.decide(usernameOf(auth), cookies.present(req));
        } catch (Exception e) {
            // 【重要】這段跑在 100% 正式流量的登入路徑上。
            // 任何例外都必須讓使用者正常登入,絕不能因為 canary 邏輯擋住人。
            log.warn("canary decision failed, staying on current track", e);
        }

        if (action == CanaryAction.NONE) {
            super.onAuthenticationSuccess(req, res, auth);   // 走原本的 saved request
            return;
        }

        res.addHeader(HttpHeaders.SET_COOKIE,
                action == CanaryAction.SWITCH_TO_CANARY ? cookies.issue() : cookies.clear());

        // 這個 302 的回應本身絕不能被快取
        res.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");

        // 【關鍵】不用 saved request —— 那是切換前那一軌的 URL,新版可能已經沒有那個路徑
        redirects.sendRedirect(req, res, props.getEntryPath());
    }

    private String usernameOf(Authentication auth) {
        if (auth.getPrincipal() instanceof OidcUser u) return u.getPreferredUsername();
        if (auth.getPrincipal() instanceof OAuth2User u) return u.getAttribute("preferred_username");
        return auth.getName();
    }
}
```

### 5.6 把人趕回 stable（只在 canary 生效）

```java
@Component
public class CanaryEvictionFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(CanaryEvictionFilter.class);

    private final CanaryTrackDecider decider;
    private final CanaryCookies cookies;
    private final CanaryProperties props;

    /** stable 上這個 filter 完全不做事,連判斷都省掉。 */
    @Override
    protected boolean shouldNotFilter(HttpServletRequest req) {
        return !props.isCanaryTrack();
    }

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res,
                                    FilterChain chain) throws IOException, ServletException {
        try {
            if (isNavigation(req) && cookies.present(req)
                    && decider.decide(currentUsername(), true) == CanaryAction.EVICT_TO_STABLE) {

                res.addHeader(HttpHeaders.SET_COOKIE, cookies.clear());
                res.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
                res.sendRedirect(props.getEntryPath());
                return;
            }
        } catch (Exception e) {
            log.warn("canary eviction check failed, passing through", e);
        }
        chain.doFilter(req, res);
    }

    /**
     * 【關鍵】只對「瀏覽器導航」做 302。
     *   對 POST 做 302 → 掉 request body
     *   對 XHR/fetch 做 302 → 前端拿到 HTML 而不是 JSON,錯誤訊息會非常難懂
     */
    private boolean isNavigation(HttpServletRequest r) {
        if (!"GET".equals(r.getMethod())) return false;
        if ("XMLHttpRequest".equals(r.getHeader("X-Requested-With"))) return false;

        String dest = r.getHeader("Sec-Fetch-Dest");
        if (dest != null) return "document".equals(dest);          // 現代瀏覽器最準

        String accept = r.getHeader(HttpHeaders.ACCEPT);           // 舊瀏覽器 fallback
        return accept != null && accept.contains(MediaType.TEXT_HTML_VALUE);
    }

    private String currentUsername() {
        Authentication a = SecurityContextHolder.getContext().getAuthentication();
        return (a == null) ? null : a.getName();
    }
}
```

### 5.7 快取 header（Part 3.3 條件①的實作）

> 這個 filter 只處理條件①。條件②由 build 工具（React）或 Part 3.4 的
> `ContentHashIndexTransformer`（AngularDart）負責。
>
> **這個 filter 是快取 header 的唯一來源。** 不要同時在 resource handler 上
> 呼叫 `setCacheControl(...)`,會蓋掉 `index.html` 的 `no-store`（見 Part 3.4）。
>
> 它同時也補上 Part 3.3 那個「執行期才抓的資源」缺口 —— 靠的是判斷
> **URL 有沒有版本標記**,而不是判斷路徑前綴。

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class FrontendCacheFilter extends OncePerRequestFilter {

    private final FrontendProperties fe;
    private final String indexPath;      // app.frontend.index-path
    private final String urlPrefix;      // app.frontend.url-prefix

    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res,
                                    FilterChain chain) throws IOException, ServletException {
        String uri = req.getRequestURI();

        if (isHtmlEntry(uri)) {
            // index.html 是唯一必須每次回源的檔案。快取它 = 混版 = 白畫面（Part 3.3）
            res.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
            // 前面若有共用快取（CDN / nginx / F5）,沒有這行會把 stable 的 HTML 餵給 canary 使用者
            res.setHeader(HttpHeaders.VARY, HttpHeaders.COOKIE);
        } else if (uri.startsWith(urlPrefix)) {
            // 【關鍵】用「這個 URL 分不分得出版本」決定,不是用路徑前綴。
            // 版本化機制沒觸及的檔案會自動掉進 no-cache,而不是被長快取釘住。
            boolean versioned = switch (fe.getAssetVersioning()) {
                case FILENAME -> true;                           // React：檔名自帶 hash
                case QUERY    -> req.getParameter("v") != null;  // dart：只有被改寫過的算
            };
            res.setHeader(HttpHeaders.CACHE_CONTROL, versioned
                    ? "public, max-age=31536000, immutable"
                    : "no-cache");   // 可以存,但每次都要回來驗證。見 Part 3.3 的缺口
        }
        chain.doFilter(req, res);
    }

    private boolean isHtmlEntry(String uri) {
        return uri.equals(indexPath)
                || uri.equals(urlPrefix) || uri.equals(urlPrefix + "/")
                || !uri.substring(uri.lastIndexOf('/') + 1).contains(".");  // SPA fallback
    }
}
```

### 5.8 接線

```java
@Configuration
@EnableConfigurationProperties(CanaryProperties.class)
public class CanarySecurityConfig {

    @Bean
    SecurityFilterChain filterChain(HttpSecurity http,
                                    CanarySwitchSuccessHandler success,
                                    CanaryEvictionFilter eviction) throws Exception {
        return http
                .oauth2Login(o -> o.successHandler(success))
                .addFilterAfter(eviction, SecurityContextHolderFilter.class)
                .build();
    }
}
```

### 5.9（選配）讓 canary 的畫面自己說「我是測試版」

`x-app-track` 要開 F12 才看得到,`pilot-run-guide.md` 步驟 2 一直是最容易被跳過的一步。
既然兩版畫面本來就不同,直接讓 canary 掛一條橫幅。

BFF 在回 `index.html` 時注入 meta,前端讀到就顯示：

```java
// 回 index.html 前 replace 一次即可（記得配合 no-store,不要快取這份注入結果）
html = html.replace("<head>", "<head><meta name=\"app-track\" content=\"" + track + "\">");
```

```javascript
if (document.querySelector('meta[name=app-track]')?.content === 'canary') {
  showBanner('測試版本 — 驗證中,問題請回報系統管理員');
}
```

> 同一份前端程式碼,兩版行為自動不同,**不需要為 canary 另外 build**。

### 5.10 打包成共用 starter（不要複製貼上）

你有多支 BFF（React 的、AngularDart 的）。**不要把 Part 5 這些檔案複製到每一支。**

理由是 Part 8 的風險 1：**這段程式跑在 100% 正式登入路徑上**。複製到 5 支 app,
就是 5 份要修的副本。哪天發現 `usernameOf()` 對某種 Keycloak 設定會 NPE,
你要改 5 次、發 5 個版本,而且一定會漏掉一支。

做成內部的 Spring Boot starter：`canary-routing-spring-boot-starter`

```java
@AutoConfiguration
@EnableConfigurationProperties({CanaryProperties.class, FrontendProperties.class})
public class CanaryAutoConfiguration {

    // 每一支 app 都要
    @Bean CanaryPilotRoster        roster(CanaryProperties p) { ... }
    @Bean CanaryTrackDecider       decider(...)               { ... }
    @Bean CanaryCookies            cookies(...)               { ... }
    @Bean CanarySwitchSuccessHandler successHandler(...)      { ... }
    @Bean CanaryEvictionFilter     eviction(...)              { ... }
    @Bean FrontendCacheFilter      cacheFilter(...)           { ... }

    // 只有 dart2js 的 app 需要 —— React 那批的檔名天生就帶 content hash
    @Bean
    @ConditionalOnProperty(prefix = "app.frontend",
                           name = "asset-versioning", havingValue = "query")
    ResourceTransformer contentHashIndex(ResourceLoader loader, FrontendProperties fe) {
        return new ContentHashIndexTransformer(loader, fe.getResourceLocation());
    }
}
```

#### `asset-versioning` 各 app 怎麼設

| App | `app.frontend.asset-versioning` | transformer | 快取策略 |
|---|---|:---:|---|
| React（CRA / Vite） | `filename`（預設） | 不啟用 | 前綴下全部長快取 |
| AngularDart | `query` | 啟用 | 只有帶 `?v=` 的長快取,其餘 `no-cache` |

> **React 那批要明確設成 `filename`,不是無所謂。** 如果誤設成 `query`,
> transformer 會在已經帶 hash 的檔名後面再加 `?v=` ——
> 每次發版**連沒改過的 chunk 也換 URL**,快取命中率白白變差。

#### 什麼不能進 starter

| 留在各 app | 為什麼 |
|---|---|
| 名單 ConfigMap | 每支 app 的 pilot 名單不同 |
| `app.frontend.*` 的路徑 | 每支 app 的 context prefix 不同 |
| `entry-path` | 同上,**絕不能寫死在 starter 裡** |
| `asset-versioning` | 看該支 app 的 build 工具 |

#### 「一個 starter 壞掉會炸全部」——不會

starter 是**編譯期依賴**,不是執行期服務。各 app 自己決定什麼時候升版本號,
所以 rollout 天然是分批的。

> 你甚至可以拿這套 canary 機制去驗 starter 自己的新版本 ——
> 先在一支 app 的 canary 上跑,通過了再推廣。

---

## Part 6：K8s 改動

### 6.1 新增：可變的名單 ConfigMap

建議放在新的 `track-a/runtime/` 目錄。理由：

| 目錄 | 變更頻率 | apply 時機 |
|---|---|---|
| `base/` | 極低（網路設定變更） | 單獨 stage |
| `release/` | 每次發布 | 發布 pipeline |
| **`runtime/`（新增）** | **pilot 期間可能一天數次** | **獨立,不經過發布流程** |

```yaml
# track-a/runtime/05-configmap-canary-pilot.yaml
# =============================================================================
# Canary pilot 名單（可變 —— 這是刻意的,跟 release/ 底下的 ConfigMap 相反）
#
# 【不要加 immutable: true】改名單就是要能改。
# 【不要帶版本號】帶了就會退化成「改名單要重啟 stable」,見設計文件 Part 3.2。
# 【不要在 Deployment 加對應的 annotation】
#     release/ 的 ConfigMap 靠 config-version annotation 觸發滾動更新;
#     這一份**刻意不要**觸發 —— 改名單不該重啟任何 pod。
# =============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-canary-pilot
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
data:
  pilot-users.txt: |
    # 一行一個 Keycloak preferred_username,# 開頭是註解
    # 空檔案 = 沒有人會被送進 canary
```

### 6.2 兩個 Deployment 各加一組掛載

`20-deployment-stable.yaml` 與 `21-deployment-canary.yaml` **都要加**
（stable 要發 cookie,canary 要趕人,兩邊都需要名單）：

```yaml
          volumeMounts:
            - name: canary-pilot
              mountPath: /app/canary        # 【關鍵】掛目錄,不是 subPath
              readOnly: true                #        subPath 掛的檔案永遠不會更新

      volumes:
        - name: canary-pilot
          configMap:
            name: pmc-epmmformquery-canary-pilot
            optional: true                  # 【關鍵】ConfigMap 不存在也不能卡住 pod 啟動
                                            #        這條路徑上跑的是正式流量
```

canary 那一份還要多一個 env（stable 不需要,預設就是 false）：

```yaml
            - name: APP_CANARY_ENABLED
              value: "true"                 # pilot 期間 true;收工時改 false,見 Part 7.2
```

> **`optional: true` 很重要。** 沒有它,ConfigMap 打錯名字會讓 stable pod 卡在
> `ContainerCreating` —— 那就從「canary 功能壞掉」升級成「正式環境掛掉」。

### 6.3 不用改的東西

- `base/03-virtualservice.yaml` —— 規則 1 的 regex 原樣可用
- `base/01-service.yaml`、`base/02-destinationrule.yaml` —— 完全不動
- `release/10-configmap-<版本>.yaml` —— 只多加 `app.canary` 那幾行設定

---

## Part 7：運維流程改動

### 7.1 名單維護（新流程）

```
改 track-a/runtime/05-configmap-canary-pilot.yaml
  → commit
  → kubectl apply -f track-a/runtime/
  → 等 ≤ 90 秒（kubelet 同步 60s + app reload 30s）
  → 使用者「重新登入」即生效
```

不需要重啟任何 pod,不影響正式流量。

### 7.2 【重要】canary 不通過的關閉流程要改寫

#### 現行流程會出事

`SOP-apply-only.md:256` 現在寫的是：

> | pilot 使用者說壞了 | 改 canary `replicas: 0` → commit → apply |

**改成自動發 cookie 之後,這個動作會變成 outage。**

原因：`replicas: 0` 之後 `subset: canary` 沒有任何 endpoint,但
`base/03-virtualservice.yaml` 的規則 1 還在。所以：

```
手上還有 cookie 的人
  → 規則 1 仍然把他們送進 subset: canary
  → 沒有 endpoint
  → 503（access log 的 response_flags = UH）
  → 他們永遠打不到 stable,app 端「清 cookie」的邏輯根本沒機會執行
  → 卡死到 cookie 過期為止（8 小時）
```

手動時代這風險小 —— 只有 2、3 個人自己種了 cookie,而且他們**知道**自己種了。
改成自動發之後,cookie 持有者可能是幾十個人,**而且他們不知道自己有 cookie**。

#### 新流程：換 image,不是 scale 到 0

```
改 track-a/release/21-deployment-canary.yaml：
  1. image        → 改回目前 stable 的版本
  2. config-version annotation + configMap 名稱 → 一併改回 stable 的版本
  3. APP_CANARY_ENABLED → "false"
  → commit → apply
```

效果：

```
canary pod 仍在跑,但跑的是「好的程式碼」
  → 使用者不會 503,而且看到的是正確的舊版畫面
  → CanaryEvictionFilter 看到 enabled=false
  → 下一個導航請求：清 cookie + 302
  → 使用者回到 stable
```

**一次導航就排空,零 503。** 而且完全符合 apply-only 的限制 —— 一樣只是改 YAML + apply。

等確定沒有人還帶著 cookie（或過了 8 小時 Max-Age）之後,再從容地把 `replicas` 改回 0。

#### 真正的 kill switch 仍然是 VirtualService

如果情況緊急到連「等一次導航」都不能接受,唯一瞬間生效、不依賴 app 的手段是
**把 `base/03-virtualservice.yaml` 規則 1 的 destination 改成 `subset: stable`**。

它在 `base/`,依你們的規範要用單獨 stage apply,所以列為第二道而不是第一道。
但 SOP 應該把它寫進去,讓值班的人知道有這張牌。

### 7.3 關閉手段對照

| 手段 | 生效速度 | 對 cookie 持有者 | 適用 |
|---|---|---|---|
| `APP_CANARY_ENABLED=false` + image 改回 stable | 下一次導航 | 乾淨排空 | **預設做法** |
| 規則 1 改指向 `subset: stable` | 瞬間 | 立刻全部回 stable | 緊急 |
| `replicas: 1 → 0` | 瞬間 | **503 UH,卡到 cookie 過期** | **改成自動發 cookie 後不可單獨使用** |

---

## Part 8：風險清單

| # | 風險 | 嚴重度 | 對策 |
|---|---|:---:|---|
| 1 | filter 在 stable 上出例外 | **高** | 全段 try/catch,任何例外一律放行。這段程式的品質標準要比業務程式高一級 |
| 2 | `replicas: 0` 造成 cookie 持有者 503 | **高** | 改用 Part 7.2 的 image rollback 流程 |
| 3 | `index.html` 被快取造成混版白畫面 | **高** | Part 3.3 條件① |
| 3b | 固定檔名的前端造成**靜默**混版 | **高** | Part 3.3 條件②。AngularDart 走 Part 3.4 的 startup rewrite |
| 4 | 名單檔讀不到被當成「全部都是 pilot」 | **高** | 讀不到 = 空名單（fail-safe）。程式碼已處理 |
| 5 | `SameSite=Strict` 打壞 Keycloak 導回 | 中 | 固定用 `Lax` |
| 6 | 對 XHR / POST 做 302 | 中 | `isNavigation()` 嚴格判斷 |
| 7 | localStorage 跨版污染 | 中 | canary storage key 加版本前綴 |
| 8 | Service Worker 讓 cookie 路由失效 | ~~中~~ **已排除** | 已確認沒有註冊 SW。**若日後加 PWA 必須重驗**,見 Part 4.5 |
| 9 | 名單改了但使用者沒重新登入 | 低 | 這是設計選擇（Part 2）。`CanaryEvictionFilter` 會處理「移除」方向 |
| 10 | canary 開超過 1 個 replica 導致登出 | 低 | 維持 `replicas: 1`,`21-deployment-canary.yaml` 註解已說明 |

### 「零風險」的定義變了 —— 這一點要跟主管講清楚

原設計的賣點是「權重永遠 stable 100 / canary 0,pilot 期間對正式使用者零風險」。

- **路由層仍然零風險** —— 權重沒變
- **程式層不再零風險** —— filter 跑在 stable 的每一個登入上

風險 1 是這個方案最本質的代價。換來的是 pilot 流程能規模化。這是個取捨,不是免費的。

---

## Part 9：驗收

### 9.1 機制驗證（不需要真人,照 `README.md:263` 的格式）

```bash
GW=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
URL="https://myapp.example.com/gui_epmmFormQuery/"

echo "--- 1. 不帶 cookie → 應該是 stable ---"
curl -sS -o /dev/null -D - "$URL" | grep -i 'x-app-track'

echo "--- 2. 手動帶 cookie → 應該是 canary（確認規則 1 還活著）---"
curl -sS -o /dev/null -D - -H "Cookie: canary=always" "$URL" | grep -i 'x-app-track'

echo "--- 3. index.html 必須 no-store ---"
curl -sS -o /dev/null -D - "$URL" | grep -i 'cache-control\|vary'
```

第 3 項是這次新增的,**不要跳過** —— 它是 Part 3.3 那個白畫面問題的唯一防線。

### 9.2 端對端驗證（要一個 pilot 帳號）

| # | 步驟 | 預期 |
|---|---|---|
| 1 | 把測試帳號加進名單 → apply → 等 90 秒 | — |
| 2 | 用該帳號登入 | 自動多一次跳轉,最後停在首頁 |
| 3 | F12 → Application → Cookies | 有 `canary=always` |
| 4 | F12 → Network → 第一個請求的 Response Headers | `x-app-track: canary` |
| 5 | 確認畫面是**新版** GUI | 不是舊版 |
| 6 | 從名單移除該帳號 → apply → 等 90 秒 → 點任一連結 | 自動被送回 stable,cookie 消失 |
| 7 | 確認畫面變回**舊版** GUI,而且沒有 404 / 白畫面 | ← **第 3.3 條的實測** |

第 6、7 項是關閉流程的實測,**比第 2 到 5 項更重要** —— 因為那是出事時要靠的路徑。

### 9.3 `pilot-run-guide.md` 要怎麼改

- **步驟 1（種 cookie）整段刪掉**,改成「用你的帳號登入就好」
- **步驟 2（確認 `x-app-track`）保留** —— 仍然是唯一可靠的自我確認方式
- 現行的 bookmarklet 移到附錄,標成「備援：自動切換失效時使用」
- FAQ 加一則：「我沒做任何事就看到新版畫面?」→ 正常,你在 pilot 名單裡
- 「驗證完成後請切回舊版」整段刪掉 —— 改成由管理員從名單移除

---

## Part 10：待決事項

### 已經確認的

| 問題 | 答案 | 影響 |
|---|---|---|
| React 的 build 有 content hash 嗎? | **有** —— `react-scripts build`（CRA）與 `vite build` 兩種都在用,兩者預設都開 | 條件②天生滿足,只要補條件① |
| AngularDart 有 content hash 嗎? | **沒有** —— dart2js 固定檔名,沒有選項可以開 | 要做 Part 3.4 的 startup rewrite |
| AngularDart 有用 deferred loading 嗎? | **沒有** —— build 產出裡沒有任何 `.part.js` | `*.part.js` 那段工作不用做 |
| 程式要怎麼在多支 BFF 之間共用? | **做成 starter** —— `canary-routing-spring-boot-starter` | 見 Part 5.10。不複製貼上,因為這段跑在 100% 正式登入路徑上 |
| 執行期才抓的資源（config.json、i18n、字型）怎麼辦? | 快取策略改成**看 URL 有沒有版本標記**,沒有的一律 `no-cache` | 見 Part 3.3 缺口與 Part 5.7。預設安全,新增資源不用記得改設定 |
| 前端有註冊 Service Worker 嗎? | **沒有** —— `getRegistrations()` 回傳 0 | 風險 8 排除。**日後若加 PWA 必須重驗**,見 Part 4.5 |

> **原本的否決題已經解除。** 沒有任何一支前端需要改 build ——
> AngularDart 那支多一個 15 行的 startup rewrite,如此而已。
> 這一題從「能不能做」降級成「先做哪一支」。

### 仍待決

> **技術上的未知數已經清空。** 剩下四題裡,只有第 1、2 題還算技術問題,
> 而且都不影響「能不能做」,只影響「怎麼寫」。
> **第 3、4 題才是真正的門檻 —— 它們需要有人拍板,不是寫程式能解決的。**

| # | 問題 | 類型 | 為什麼會影響設計 |
|---|---|---|---|
| 1 | **名單的 key 用什麼?** Keycloak 的 `preferred_username`?員工編號? | 技術 | 決定 `usernameOf()` 要抓哪個 claim |
| 2 | **名單需要支援群組 / 部門嗎?** 還是列舉個人就夠? | 技術 | 群組的話要從 Keycloak 的 role / group claim 判斷,或真的要打外部權限 service。這題也順帶回答「那隻外部 userinfo service 到底需不需要」 |
| 3 | **Part 7.2 改寫關閉流程,值班同仁能接受嗎?** | **決策** | 這是流程變更,不只是程式變更,要有人同意 |
| 4 | **能接受「filter 跑在 100% 正式登入路徑上」嗎?** | **決策** | 這是 Part 8 風險 1,是本方案的本質代價 |

> 原本的「前面有 CDN / nginx / F5 嗎?」併進 Part 3.3 —— 不論有沒有,
> `Vary: Cookie` 都已經寫進 Part 5.7 的實作了,所以它不再是待決事項。

### 我的建議順序

1. **先做 React 那批。** 條件②已經滿足,只要加條件①（`index.html` no-store）就可以
   直接套 Part 5 那套。這批**現在就能開始,不用等任何人**。
2. **再做 AngularDart 那支。** 多一個 Part 3.4 的 `ContentHashIndexTransformer`,不難,
   但是獨立工項,不要跟第 1 批綁在一起做。設定改成 `asset-versioning: query`。
3. **現在就把問題 3、4 送出去讓人拍板。** 這兩題的前置作業已經做完了 ——
   Part 7.2 有完整的新關閉流程、Part 8 有風險清單,可以直接拿去開會。
   **不要等實作做完才問**,萬一沒過,程式就白寫了。

實作本身大約是 300 行 Java + 3 個 YAML 改動,**不是難點**。
真正的門檻是問題 3、4 那兩個需要有人點頭的 —— 那是流程與風險承擔的決定,不是技術決定。
