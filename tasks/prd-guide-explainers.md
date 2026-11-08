# PRD：k8s-ecosystem-guide.md 補充說明 —— mesh、mTLS、登入 session、CronJob 的「幾份」、公司的 ipPolicy

## 1. Introduction / Overview

`k8s-ecosystem-guide.md` 經過上一個 run（`ralph/guide-verification`，US-001～US-096）逐條查證之後，
內容是正確的，但讀者（維運／開發，不是 Istio 專家）仍然卡在幾個 guide **預設你已經懂**的概念上：

1. **mesh** —— 文件到處寫「mesh 內」「VS 要加 `mesh`」，但沒有一個地方說清楚 mesh 是什麼、而且這個字有兩種意思。
2. **mTLS** —— Part 2.1 直接從 PeerAuthentication 講起，沒有說 mTLS 本身是什麼、K8s 裡有幾套、是不是每個 namespace 都有。
3. **consistentHash 為什麼解決不了登入** —— Part 6.2／7.4／9 都說「治標」，但沒有說登入**具體**是怎麼壞的。
4. **Spring Session + Redis 怎麼做** —— Part 9 發現 2 只有一句「根本修法：Spring Session + Redis」。
5. **CronJob 的 `concurrencyPolicy` vs Job 的 `parallelism`／`completions` vs Deployment 的 `replicas`** —— 三個都像「跑幾份」，Part 6.4 沒有區分。
6. **公司內部的「ipPolicy」** —— 使用者不知道它是哪個 CRD；經驗是「不加 `172.0.0.0/8`、`10.0.0.0/8` 就打不到對方的 service」。Part 2.4 只講原生 NetworkPolicy。

這個 run 把上述說明**插進既有的 Part**（不開新 Part），每一條事實都來自查證帳本
`tasks/guide-explainers-ledger.md`（E-001～E-030，全部使用者確認 ✓）。

## 2. Goals

- 每個主題都有**一個具體例子**，例子用這個 repo 的真實名字（`pmc-epmmformquerygui`、`epmm-api`、`ea-pmc`、`ea-epmm`、`canary=always` cookie），不用 foo/bar。
- 每一條新事實都能在帳本找到官方 URL 與逐字引文；「機制推得」的說法照 guide 慣例註明「這是由機制推得，不是官方逐字寫的結論」。
- 動到的每個 Part 的 `### 參考來源` 都補上新用到的官方 URL；`bash scripts/validate.sh` 每個 commit 都 exit 0。
- 每個故事 feat commit 之後跑 `code-review`（Standards ＋ Spec 兩軸），Spec 軸 WebFetch 帳本 URL 確認引文存在。

## 3. User Stories

> 共通驗收條件（每個故事都適用，下面不再重複）：
> - 只寫故事 `ledgerIds` 列出的帳本列；措辭回帳本「來源引文」欄對照，官方原文用英文逐字放進「」。
> - 新增的 ```yaml 區塊要能通過檢查 [10]（js-yaml 可解析）；不得用 `validate:skip-yaml` 逃避。
> - 新內容所在 Part 的 `### 參考來源` 補上該故事帳本列的官方 URL（裸 URL，`- 標題：https://...`，去重）。非官方網域（docs.spring.io、docs.tigera.io、github.com/spring-projects）可以列，但該 Part 必須仍有至少一個 `OFFICIAL_DOMAINS` 內的連結。
> - 不改 `canary-manual/` 底下任何 manifest、不改 `scripts/validate.sh`、不動 Spring 後端 repo。
> - `bash scripts/validate.sh` exit 0。
> - commit：`feat: US-0xx - <標題>`；之後以 BASE 跑 `code-review`，有發現就 `fix: US-0xx - address review`（最多兩輪）；最後 `chore: US-0xx - mark story complete and log progress`。

### US-097：mesh 的兩種意思（Part 0）
**Description:** 身為第一次讀這份 guide 的人，我要知道「mesh」這個字在文件裡有兩種意思、各自長什麼樣，這樣讀到「mesh 內的流量」「VS 要加 `mesh`」時不會混淆。

**Acceptance Criteria:**
- [ ] Part 0「Istio 本身由什麼組成」的名詞表加一列 **mesh**，或在該表下方加一個「#### 『mesh』這個字的兩種意思」小節（二擇一，選比較不打斷原表的那個）
- [ ] 意思①（E-001）：service mesh = 所有帶 sidecar 的 Pod ＋ istiod。例子：pmc GUI 的 Spring 只寫 `http://epmm-api-svc.ea-epmm.svc.cluster.local`，加密與身分是兩端的 `istio-proxy` 做的；畫一張 4～6 行的 ASCII 小圖（量過 CJK 寬度再對齊）
- [ ] 意思②（E-002、E-003）：VirtualService `gateways` 的保留字 `mesh`。用三列小表說明「省略 `gateways`／只寫 gateway 名字／gateway＋`mesh`」各自套用到誰
- [ ] 例子：從 ea-pmc 的 Pod 內 curl Service，沒列 `mesh` 時看不到 `x-app-track` header；回指 Part 9 發現 3 與 Part 14.6（用 guide 既有的錨點連結）
- [ ] 不重寫 Part 0 既有的保全公司比喻；可以在比喻表加一列「整個園區的警衛網 ＝ mesh」

### US-098：mTLS 入門（Part 2.1）
**Description:** 身為要設定 PeerAuthentication 的人，我要先懂 mTLS 是什麼、K8s 裡有幾套 mTLS、是不是每個 namespace 都有，這樣才知道 STRICT／PERMISSIVE 在改的是什麼。

**Acceptance Criteria:**
- [ ] Part 2.1 的「#### 這是在解決什麼問題」**之前**加「#### 先搞懂 mTLS」
- [ ] TLS vs mTLS 一句話對比（瀏覽器驗銀行憑證、銀行不驗你 vs 雙方互驗）
- [ ] 兩欄對照表（E-029、E-030 vs E-026～E-028）：K8s 控制面 PKI（apiserver／etcd／kubelet／scheduler／controller-manager；cluster CA 簽發；身分是 CN／O；平台組管）vs Istio workload mTLS（istiod 當 CA；身分是 SPIFFE ServiceAccount；你用 PeerAuthentication 管）。明說兩套互不相干
- [ ] 握手五步驟（E-026）用 pmc GUI → epmm-api 舉例，對照 Part 4 的 ServiceAccount 與 AuthorizationPolicy `principals`
- [ ] 回答「每個 namespace 都有嗎」（E-027、E-028）：憑證是每個 workload（ServiceAccount 身分）各自的、agent 自動輪替；namespace 只是 PeerAuthentication 的**政策範圍**；全 mesh 沒設 mode 時是 PERMISSIVE；沒注入 sidecar 的 namespace 沒有 workload mTLS。回指 2.1 既有的「#### 優先序」，不要重寫一份
- [ ] E-030 的「O 欄位當 group」：寫之前 WebFetch（用 offset 讀 100000 之後）取逐字引文；取不到就只寫 CN 那一半，並把結果填回帳本 E-030 的來源引文欄
- [ ] Part 0 名詞表 PeerAuthentication 那一列（或其補充）加一句回指「先搞懂 mTLS」

### US-099：consistentHash 為什麼解決不了登入（Part 6.2）
**Description:** 身為維運，我要看懂「consistentHash 是治標」具體是怎麼讓使用者登入失敗的，這樣才知道為什麼一定要做 session 外部化。

**Acceptance Criteria:**
- [ ] Part 6.2「> **但這仍然是治標。**」那段之後加「#### 為什麼登入會壞：兩種壞法」
- [ ] 先引 E-004 的官方原句（soft session affinity、guarantees are weaker）
- [ ] 壞法一「登入到一半」（E-005、E-006）：時序圖（ASCII，量寬度對齊）——① 打 Pod A → 302 到 Keycloak，`OAuth2AuthorizationRequest` 存在 Pod A 的 HttpSession ② 使用者在 Keycloak 輸入密碼期間 Pod A 被滾動更新／縮容／canary cookie 改變 ③ callback `/gui_epmmFormQuery/login/oauth2/code/...` 落到 Pod B → 找不到 → 錯誤碼 `authorization_request_not_found`（註明出處是 Spring Security 原始碼）→ 被導回登入頁
- [ ] 壞法二「登入之後」（E-007）：`SecurityContext` 也在 HttpSession 裡，Pod 重啟＝那個 Pod 上的人全部被登出
- [ ] 結論一句：consistentHash 兩種都只能降低機率；根本解法指到 Part 9 發現 2（US-100 會在那裡展開）
- [ ] callback 路徑要跟 repo 現況一致：寫之前 grep `canary-manual/track-a/release/10-configmap-stable.yaml` 的 `redirect-uri`，照它寫

### US-100：Spring Session + Redis 解法（Part 9 發現 2）
**Description:** 身為要改 Spring 後端的開發，我要知道 Spring Session + Redis 要加什麼依賴、什麼設定、K8s 這邊要準備什麼，這樣可以跟後端 repo 的人對齊工作項目。

**Acceptance Criteria:**
- [ ] Part 9 發現 2 的「**根本修法**」那一句展開成「#### 根本修法：Spring Session + Redis」
- [ ] 一句話機制（E-009）：加依賴之後 Boot 自動建 `springSessionRepositoryFilter`，`HttpSession` 的實作換成 Redis 版，程式碼不用改；US-099 的兩種壞法因此都消失
- [ ] pom 片段（E-008）：`org.springframework.session:spring-session-data-redis`，註明 Spring Boot 4 改名 `spring-boot-starter-session-data-redis`。pom 是 xml，用 ```xml fence（不受 [10] 檢查）
- [ ] `application.yml` 片段（E-010、E-012，```yaml，要過 [10]）：`spring.data.redis.host: ${REDIS_HOST}`、`port: 6379`、`password: ${REDIS_PASSWORD}`、`spring.session.redis.namespace: spring:session:pmc-epmmformquerygui`（註解說明三個 GUI 服務要各自不同）、`server.servlet.session.timeout`；註解提一句 Boot 預設 `RedisSessionRepository`
- [ ] 註明這段是**給後端 repo 的參考**，這個 repo 的 ConfigMap 目前沒有這些 key、這次也不加（加的話要依 CLAUDE.md 同時加 validate.sh 檢查與跑 sync-config-hash）
- [ ] 踩雷（E-011）：canary 與 stable 共用 Redis 時 Java 序列化的類別版本問題；引官方原句；回指 Part 7.4
- [ ] K8s 端清單（E-013、E-014）：① Secret 放 `REDIS_PASSWORD` ② Redis Service port 命名 `tcp-redis`（或 `appProtocol: tcp`），引 protocol selection 官方原句 ③ default-deny 的 namespace 要放行到 Redis 6379 的 egress ④ DestinationRule 黏著變成可有可無（E-014 照慣例註明「由機制推得」）⑤ 這是 Part 7.4 canary 的前提
- [ ] Part 7.4 解法 C 那一列或其下方加一句回指 Part 9 發現 2 的新小節
- [ ] 不寫 Redis 本體的部署 manifest（StatefulSet／Sentinel／HA）

### US-101：三個「幾份」—— concurrencyPolicy、parallelism／completions、replicas（Part 6.4）
**Description:** 身為寫 CronJob 的人，我要分清楚 `concurrencyPolicy`、`parallelism`、`completions` 和 Deployment 的 `replicas` 各管哪一層，這樣不會以為設了 `Forbid` 就不用管 `parallelism`。

**Acceptance Criteria:**
- [ ] Part 6.4「#### `concurrencyPolicy` 怎麼選」之後加「#### 三個『幾份』不要搞混」
- [ ] 三層 ASCII 圖：CronJob →（`concurrencyPolicy` 管：Job 與 Job 之間）→ Job →（`parallelism`／`completions` 管：同一個 Job 裡的 Pod）→ Pod；旁邊 Deployment →（`replicas`）→ Pod。量寬度對齊
- [ ] 對照表四列（E-015～E-018）：欄位／屬於哪個物件／管什麼／預設值／Pod 跑完會怎樣。明寫 Job 沒有 `replicas` 欄位、`parallelism: 0` 等於暫停
- [ ] 例子（E-017，```yaml 要過 [10]）：每晚同步 1000 筆，`completions: 4`、`parallelism: 4`、`completionMode: Indexed`，每個 Pod 讀 `JOB_COMPLETION_INDEX` 處理 250 筆；只寫 `jobTemplate.spec` 相關片段，註解說明其他欄位見本節上方的全註解 YAML
- [ ] 一句話收尾：`concurrencyPolicy: Forbid` 擋的是「昨晚那個 Job 還沒跑完、今晚又來一個」，不是這 4 個 Pod；兩者要一起想（例：parallelism 4 × 每晚一次，Forbid 確保同時最多 4 個 Pod 寫資料庫）

### US-102：公司的「ipPolicy」vs NetworkPolicy（Part 2.4）
**Description:** 身為在公司叢集上開網路權限的人，我要知道「不是 NetworkPolicy、但能寫 CIDR 的 policy」通常是什麼、為什麼要放行 10.x／172.x 才打得到對方、以及 `172.0.0.0/8` 哪裡有問題，這樣能跟平台組問對問題。

**Acceptance Criteria:**
- [ ] Part 2.4 結尾、「### 2.5」之前加「#### 公司的 ipPolicy 可能是什麼（通用說明）」，開頭明說「本文不知道貴公司 ipPolicy 的實際 kind，以下是通用說明；實際規格見文末『需向他人確認』」
- [ ] 原生 NetworkPolicy 做不到的三件事（E-019，引官方原句）：explicit deny、套用到所有 namespace 的預設政策、記錄被擋的連線 —— 名字不是 NetworkPolicy 又能寫 CIDR 的，幾乎都是補這幾個缺口的 CNI／廠商 CRD
- [ ] 對照表（E-019～E-021）：原生 NetworkPolicy／Calico GlobalNetworkPolicy／K8s SIG ClusterNetworkPolicy（前身 AdminNetworkPolicy）；欄位：範圍（namespaced／cluster）、能不能 deny、有沒有排序（`order`／`priority`）、誰在寫（開發／平台）
- [ ] 「為什麼不加 10.0.0.0/8 就打不到」（E-022、E-023）：egress 預設全擋；有 sidecar 時實際目的地是對方 **Pod IP**（回指 Part 1 關鍵觀念一），所以 CIDR 要涵蓋 Pod CIDR，只放 Service CIDR 不夠；引官方「NAT 在 NetworkPolicy 之前或之後沒有定義」原句；E-023 註明「由機制推得」
- [ ] 踩雷框（E-024）：RFC 1918 三個私有網段；`172.0.0.0/8` 涵蓋 172.0–172.15、172.32–172.255 的公網位址，建議確認是否應為 `172.16.0.0/12` 或直接寫叢集實際的 Pod CIDR／Service CIDR
- [ ] E-025 加進 guide 文末「## 文件中標示為『需向他人確認』的項目」：公司 ipPolicy 的 apiVersion／kind、維護者、跟 NetworkPolicy 疊加時誰優先；附 `kubectl api-resources | grep -i policy`（格式照該清單既有列）
- [ ] 不改 Part 2.4 既有的 NetworkPolicy 範例與 `ipBlock.cidr` 那列說明（那列的「用來放行叢集外部」是官方原意，新小節解釋公司實務為什麼不同，而不是改掉它）

### US-103：retro 並更新 CLAUDE.md
**Description:** 身為下一個在這個 repo 工作的人（或代理），我要這次 loop 學到的東西寫進 CLAUDE.md，而且 CLAUDE.md 的「目前的 run」描述是對的。

**Acceptance Criteria:**
- [ ] 執行 `retro` skill，回顧寫進 `tasks/retro-guide-explainers.md`
- [ ] CLAUDE.md「Ralph 工作流」的「目前的 run」改成 `ralph/guide-explainers`（帳本 `tasks/guide-explainers-ledger.md`、spec 本檔），上一個 run 封存在 `ralph/archive/2026-11-08-guide-verification/`
- [ ] 只把可重複使用的導覽與陷阱寫進 CLAUDE.md（照現有風格：講為什麼、漏了會怎樣）
- [ ] CLAUDE.md 的改動是獨立 commit（`docs: US-103 - retro and CLAUDE.md update`），再跑一次 code-review

## 4. Functional Requirements

- FR-1：所有新內容插在既有 Part 的指定小節位置，不新增 `## Part N`，所以不改 `VERIFIED_PARTS`。
- FR-2：每一條新事實對應帳本一列（E-001～E-030）；帳本沒有的事實不寫。
- FR-3：新增的 yaml 區塊必須能被 js-yaml `loadAll` 解析（檢查 [10]）。
- FR-4：動到的每個 Part 的 `### 參考來源` 必須仍至少有一個 `OFFICIAL_DOMAINS` 內的連結（檢查 [11]），並補上該故事帳本列的 URL。
- FR-5：「機制推得」的列（E-006、E-014、E-023）在 guide 裡註明不是官方逐字結論；E-006 註明出處是原始碼。
- FR-6：例子一律用這個 repo 的真實資源名稱與路徑。
- FR-7：ASCII 圖寫完用 node 量寬度（CJK 算 2）對齊。

## 5. Non-Goals

- 不改 `canary-manual/` 底下任何 manifest（所以不加 validate.sh 檢查、不跑 sync-config-hash）。
- 不改 Spring 後端 repo（`dev/spring_oauth2_backend`）；Redis 設定只是 guide 裡給後端參考的片段。
- 不寫 Redis 本體的部署 manifest（StatefulSet／Sentinel／HA）。
- 不把 docs.spring.io、docs.tigera.io 加進 `OFFICIAL_DOMAINS`。
- 不猜公司 ipPolicy 的實際 kind；只寫通用說明＋需向他人確認。
- 不碰 CLAUDE.md 列出的「已知過時、還沒修的東西」（X-001／X-003、US-010）。

## 6. Technical Considerations

- WebFetch 預設只讀前 100000 字；kubernetes.io 的 Job、NetworkPolicy、authentication 頁都超過，引文在後段時用 `offset`。
- Part 0、6.4 附近有大段 ASCII 圖的 fence；插入點要確認不在既有 fence 裡。
- guide 的 fence 判定共用 `GUIDE_FENCE_JS`；新的 yaml 區塊不要放在 blockquote 裡，避免 `>` 前綴問題。
- Git Bash 跑 `node -e` 時要 `MSYS2_ARG_CONV_EXCL='*'`（`/gui_epmmFormQuery` 會被改寫）。

## 7. Success Metrics

- 使用者讀完 Part 0、2.1、2.4、6.2、6.4、9 發現 2 後，能自己回答這次提出的六個問題。
- 7 個故事全部 `passes: true`，每個都有 feat ＋ chore（＋ 可能的 fix）commit，`validate.sh` 每個 commit 都 exit 0。

## 8. Open Questions

- 公司 ipPolicy 的實際 apiVersion／kind（E-025，問平台組）。
- 三個 GUI 服務是否共用同一個 Redis（影響 `spring.session.redis.namespace` 是否必要；guide 先寫「要各自不同」當安全預設）。
