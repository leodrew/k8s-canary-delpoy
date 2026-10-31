# PRD：依查證帳本修正 k8s-ecosystem-guide.md

## Problem Statement

`k8s-ecosystem-guide.md` 是使用者理解 K8s ＋ Istio 生態的主要教材（約 8,200 行、Part 0–16）。
逐條對照官方文件（kubernetes.io、istio.io、envoyproxy.io、argo-rollouts、keda、flagger…）
查證之後，953 條可證偽的說法裡有 393 條需要處理：錯誤、過時、不精確、無法驗證，
以及 Part 14／15 裡跟 `canary-manual/CANARY-COMPLETE.md` 分歧的整段 manifest 與 SOP。
其中有些不只是「不精確」—— 照著做會出事：

- 照抄就會被 API 拒絕的 YAML（`podFailurePolicy` 配 `restartPolicy: OnFailure`、Rollout 用了
  `setHeaderRoute` 卻沒有 `managedRoutes`、gateway 的 `sidecar.istio.io/inject: "false"` 配 `image: auto`）
- 會靜默失效的設定（`paths: ["/actuator/*"]` 比對不到帶 context path 的 actuator、
  `exportTo: ["."]` 讓 gateway 看不到 ServiceEntry、DR `httpCookie` 用 `JSESSIONID` 加 `ttl`）
- 會造成 outage 的操作步驟（`replicas: 0` 關 canary、`kubectl rollout undo`、版本化＋immutable ConfigMap）
- 會誤導除錯的判讀（`NOT SENT` 當成 istiod 壞掉、`grep -v SYNCED` 漏抓、「gateway 沒 log 就是 hosts 不對」）

讀者沒有辦法自己分辨哪些段落是對的，所以這份文件目前不能當教材用。

## Solution

以 `tasks/guide-verification-ledger.md`（查證帳本）為唯一事實依據，由 Ralph loop 逐個小故事修正
guide。帳本每一列都有官方 URL、逐字引文、建議改法，而且經過使用者逐批確認（✓）。每個故事只處理
帳本裡指定的 ID；Part 14／15 的完整 manifest 與 SOP 換成「兩三句摘要＋指向 CANARY-COMPLETE.md」；
環境特定的說法集中到 guide 文末「需向他人確認」清單。每個 Part 修完時補上 `### 參考來源`，並登記到
`validate.sh` 的檢查裡，讓之後的修改不能把來源段落刪掉。

## Goals

- 帳本裡 365 條非環境特定、使用者確認 ✓ 的發現，在 guide 裡全部修正
- Part 14／15 的 8 個操作型小節改成指向 CANARY-COMPLETE.md，guide 不再保留第二份會分歧的 SOP
- 28 條環境特定說法＋2 條新增項目（Q-001／Q-002）併入「需向他人確認」清單
- Part 0–16 每一個 Part 都有 `### 參考來源`，且至少一個官方網域連結
- guide 裡每個 ```yaml 區塊都能被解析（刻意寫錯的示範要明確標記並寫原因）
- 每個故事都經過 code-review，Spec 軸逐條 WebFetch 帳本 URL 確認引文存在

## User Stories

### US-001: validate.sh 加上 guide 的兩項檢查
**Description:** 身為維護者，我要 `scripts/validate.sh` 檢查 guide 的 yaml 區塊能解析、修完的 Part 有參考來源，這樣 loop 每一輪改 guide 時都有閘門，不會把 YAML 改壞、也不會把參考來源刪掉。

**Acceptance Criteria:**
- [ ] 新增檢查 `[10]`：用本地 `node_modules/.bin/js-yaml` 同一套 js-yaml（`require('js-yaml')`）的 `loadAll` 解析 `k8s-ecosystem-guide.md` 裡每一個 ```yaml／```yml 區塊；任一區塊解析失敗就 FAIL，訊息印出區塊起始行號與錯誤原因
- [ ] 刻意寫錯或無法獨立成立的片段，在 fence 的**前一行**加 `<!-- validate:skip-yaml 原因 -->` 就略過；標記存在但原因是空的 → FAIL（原因必填）
- [ ] 處理掉目前會失敗的 6 個區塊（commit `2c26688` 的第 203、995、1227、3695、6684、7407 行附近）：同一區塊並列兩種寫法（A／B、錯／對）造成 duplicated key 的，**拆成兩個區塊**讓兩邊都被驗證；只有從大檔案截出、縮排不能獨立成立的片段才用 skip 標記
- [ ] 新增檢查 `[11]`：`VERIFIED_PARTS` 陣列（初始為空，例如 `VERIFIED_PARTS=()`）裡的每個 `Part N`，在 guide 的 `## Part N` 區段內（到下一個 `## ` 為止）必須有 `### 參考來源`，且該小節裡至少一個連結落在官方網域白名單（kubernetes.io、istio.io、envoyproxy.io、argo-rollouts.readthedocs.io、argoproj.github.io、github.com／raw.githubusercontent.com 的 kubernetes／istio／argoproj／envoyproxy 組織、keda.sh、docs.flagger.app、prometheus.io、helm.sh、keycloak.org、metallb.io、learn.microsoft.com、rfc-editor.org）
- [ ] 兩項都沿用既有的 `check` helper，加在 `# 之後的檢查加在這裡` 區段，各開 `== [n] 說明 ==` 並寫清楚「這個檢查在防什麼」；`export MSYS2_ARG_CONV_EXCL='*'` 不動；解析用 YAML parser，不 grep
- [ ] 反向測試並把過程寫進 progress.txt：(a) 暫時把一個 yaml 區塊改壞 → `[10]` FAIL；(b) 加一個原因空白的 skip 標記 → `[10]` FAIL；(c) 暫時把 `"Part 0"` 放進 `VERIFIED_PARTS`（此時 Part 0 還沒有參考來源）→ `[11]` FAIL；全部還原
- [ ] CLAUDE.md 的「擴充 `scripts/validate.sh` 的既有工具」一節補上 `VERIFIED_PARTS` 與 skip-yaml 標記的用法（照該節現有寫法：是什麼、為什麼、漏了會怎樣）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-002: 修正 Part 0：這是在解決什麼問題、Istio 本身由什麼組成：Istio / istiod…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 0 的「這是在解決什麼問題」「Istio 本身由什麼組成：Istio / istiod…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P00-001、P00-002、P00-011、P00-014

**Acceptance Criteria:**
- [ ] 帳本 P00-001、P00-002、P00-011、P00-014 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-003: 修正 Part 0：物件之間怎麼互相找到：label、名字、host 三種連…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 0 的「物件之間怎麼互相找到：label、名字、host 三種連…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P00-024、P00-025、P00-034、P00-045

**Acceptance Criteria:**
- [ ] 帳本 P00-024、P00-025、P00-034、P00-045 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P00-034 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-004: 修正 Part 0：一句話職責表、最重要的一組區分：認證 vs 授權 vs 防火牆
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 0 的「一句話職責表」「最重要的一組區分：認證 vs 授權 vs 防火牆」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P00-058、P00-059、P00-061、P00-070

**Acceptance Criteria:**
- [ ] 帳本 P00-058、P00-059、P00-061、P00-070 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P00-070 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 0 結尾加 `### 參考來源`：列出帳本中 Part 0 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 0"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-005: 修正 Part 1：完整鏈路、逐跳職責表：出事了查哪裡
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 1 的「完整鏈路」「逐跳職責表：出事了查哪裡」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P01-002、P01-005、P01-006、P01-007

**Acceptance Criteria:**
- [ ] 帳本 P01-002、P01-005、P01-006、P01-007 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-006: 修正 Part 1：關鍵觀念一：mesh 裡的 Service「幾乎只剩 D…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 1 的「關鍵觀念一：mesh 裡的 Service「幾乎只剩 D…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P01-008、P01-009、P01-010、P01-011

**Acceptance Criteria:**
- [ ] 帳本 P01-008、P01-009、P01-010、P01-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P01-009 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-007: 修正 Part 1：關鍵觀念二：Client IP 在哪一跳被弄丟
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 1 的「關鍵觀念二：Client IP 在哪一跳被弄丟」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P01-013、P01-014、P01-015、P01-016

**Acceptance Criteria:**
- [ ] 帳本 P01-013、P01-014、P01-015、P01-016 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 1 結尾加 `### 參考來源`：列出帳本中 Part 1 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 1"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-008: 修正 Part 2：2.1 PeerAuthentication — 服務間…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.1 PeerAuthentication — 服務間…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-001、P02-002、P02-003、P02-004、P02-005

**Acceptance Criteria:**
- [ ] 帳本 P02-001、P02-002、P02-003、P02-004、P02-005 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-009: 修正 Part 2：2.2 AuthorizationPolicy — L7…（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.2 AuthorizationPolicy — L7…」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-006、P02-007、P02-008、P02-010、P02-011

**Acceptance Criteria:**
- [ ] 帳本 P02-006、P02-007、P02-008、P02-010、P02-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-010: 修正 Part 2：2.2 AuthorizationPolicy — L7…（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.2 AuthorizationPolicy — L7…」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-012、P02-013、P02-014、P02-015

**Acceptance Criteria:**
- [ ] 帳本 P02-012、P02-013、P02-014、P02-015 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-011: 修正 Part 2：2.3 Sidecar — 限制 Envoy 的視野（含…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.3 Sidecar — 限制 Envoy 的視野（含…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-201、P02-202、P02-203、P02-204、P02-205

**Acceptance Criteria:**
- [ ] 帳本 P02-201、P02-202、P02-203、P02-204、P02-205 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P02-201 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-012: 修正 Part 2：2.4 NetworkPolicy — CNI 層防火牆（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.4 NetworkPolicy — CNI 層防火牆」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-206、P02-207、P02-208、P02-209、P02-210

**Acceptance Criteria:**
- [ ] 帳本 P02-206、P02-207、P02-208、P02-209、P02-210 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-013: 修正 Part 2：2.4 NetworkPolicy — CNI 層防火牆（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.4 NetworkPolicy — CNI 層防火牆」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-211、P02-212、P02-213、P02-214

**Acceptance Criteria:**
- [ ] 帳本 P02-211、P02-212、P02-213、P02-214 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-014: 修正 Part 2：2.5 四者對照表 —— 這個需求該用哪一個？（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.5 四者對照表 —— 這個需求該用哪一個？」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-215、P02-216、P02-217、P02-218、P02-219

**Acceptance Criteria:**
- [ ] 帳本 P02-215、P02-216、P02-217、P02-218、P02-219 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P02-215 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-015: 修正 Part 2：2.5 四者對照表 —— 這個需求該用哪一個？（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 2 的「2.5 四者對照表 —— 這個需求該用哪一個？」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P02-220、P02-221

**Acceptance Criteria:**
- [ ] 帳本 P02-220、P02-221 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 2 結尾加 `### 參考來源`：列出帳本中 Part 2 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 2"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-016: 修正 Part 3：第一件事：這不是 K8s RBAC
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 3 的「第一件事：這不是 K8s RBAC」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P03-001

**Acceptance Criteria:**
- [ ] 帳本 P03-001 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-017: 修正 Part 3：Istio 版：五大成因決策樹（1/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 3 的「Istio 版：五大成因決策樹」（1/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P03-002、P03-003、P03-004、P03-005、P03-006

**Acceptance Criteria:**
- [ ] 帳本 P03-002、P03-003、P03-004、P03-005、P03-006 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-018: 修正 Part 3：Istio 版：五大成因決策樹（2/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 3 的「Istio 版：五大成因決策樹」（2/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P03-007、P03-008、P03-009、P03-010、P03-011

**Acceptance Criteria:**
- [ ] 帳本 P03-007、P03-008、P03-009、P03-010、P03-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P03-009 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-019: 修正 Part 3：Istio 版：五大成因決策樹（3/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 3 的「Istio 版：五大成因決策樹」（3/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P03-012

**Acceptance Criteria:**
- [ ] 帳本 P03-012 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-020: 修正 Part 3：精準除錯：打開 Envoy 的 RBAC debug l…、K8s RBAC 版：如果你的 403 其實是 API …
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 3 的「精準除錯：打開 Envoy 的 RBAC debug l…」「K8s RBAC 版：如果你的 403 其實是 API …」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P03-013、P03-014、P03-015、P03-016

**Acceptance Criteria:**
- [ ] 帳本 P03-013、P03-014、P03-015、P03-016 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 3 結尾加 `### 參考來源`：列出帳本中 Part 3 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 3"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-021: 修正 Part 4：步驟 0：DNS 要寫全名、步驟 1：兩邊各給獨立 ServiceAccount（最…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 4 的「步驟 0：DNS 要寫全名」「步驟 1：兩邊各給獨立 ServiceAccount（最…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P04-002、P04-003、P04-004、P04-006、P04-007

**Acceptance Criteria:**
- [ ] 帳本 P04-002、P04-003、P04-004、P04-006、P04-007 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-022: 修正 Part 4：步驟 2：ea-epmm 側開授權
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 4 的「步驟 2：ea-epmm 側開授權」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P04-008、P04-009、P04-010、P04-011

**Acceptance Criteria:**
- [ ] 帳本 P04-008、P04-009、P04-010、P04-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-023: 修正 Part 4：步驟 4：NetworkPolicy 版（底層防護）、步驟 5：驗證整條路徑
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 4 的「步驟 4：NetworkPolicy 版（底層防護）」「步驟 5：驗證整條路徑」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P04-013、P04-012、P04-014、P04-016、P04-017

**Acceptance Criteria:**
- [ ] 帳本 P04-013、P04-012、P04-014、P04-016、P04-017 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 4 結尾加 `### 參考來源`：列出帳本中 Part 4 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 4"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-024: 修正 Part 5：逐跳表：哪些 policy 生效、哪些失效、核心結論：身分在 ingressgateway 斷掉
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 5 的「逐跳表：哪些 policy 生效、哪些失效」「核心結論：身分在 ingressgateway 斷掉」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P05-001、P05-002

**Acceptance Criteria:**
- [ ] 帳本 P05-001、P05-002 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-025: 修正 Part 5：補救方案一：JWT（推薦，你們已經有 Keycloak）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 5 的「補救方案一：JWT（推薦，你們已經有 Keycloak）」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P05-003、P05-006、P05-004、P05-005

**Acceptance Criteria:**
- [ ] 帳本 P05-003、P05-006、P05-004、P05-005 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P05-004 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-026: 修正 Part 5：補救方案二：IP 白名單（`remoteIpBlocks…、補救方案三：TLS passthrough（保留原始憑證…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 5 的「補救方案二：IP 白名單（`remoteIpBlocks…」「補救方案三：TLS passthrough（保留原始憑證…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P05-007、P05-008、P05-009、P05-010、P05-011

**Acceptance Criteria:**
- [ ] 帳本 P05-007、P05-008、P05-009、P05-010、P05-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-027: 修正 Part 5：A cluster 這一側要準備什麼、B cluster 這一側的完整組合
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 5 的「A cluster 這一側要準備什麼」「B cluster 這一側的完整組合」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P05-201、P05-202、P05-203、P05-204

**Acceptance Criteria:**
- [ ] 帳本 P05-201、P05-202、P05-203、P05-204 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-028: 修正 Part 5：附錄：真正的 Istio multi-cluster（何…（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 5 的「附錄：真正的 Istio multi-cluster（何…」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P05-205、P05-206、P05-207、P05-208、P05-209

**Acceptance Criteria:**
- [ ] 帳本 P05-205、P05-206、P05-207、P05-208、P05-209 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-029: 修正 Part 5：附錄：真正的 Istio multi-cluster（何…（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 5 的「附錄：真正的 Istio multi-cluster（何…」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P05-210、P05-211、P05-212、P05-213

**Acceptance Criteria:**
- [ ] 帳本 P05-210、P05-211、P05-212、P05-213 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P05-213 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 5 結尾加 `### 參考來源`：列出帳本中 Part 5 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 5"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-030: 修正 Part 6：6.1 Deployment（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.1 Deployment」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-001、P06-002、P06-003、P06-004、P06-005

**Acceptance Criteria:**
- [ ] 帳本 P06-001、P06-002、P06-003、P06-004、P06-005 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-031: 修正 Part 6：6.1 Deployment（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.1 Deployment」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-006、P06-007、P06-008、P06-009、P06-010

**Acceptance Criteria:**
- [ ] 帳本 P06-006、P06-007、P06-008、P06-009、P06-010 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-032: 修正 Part 6：6.2 Service（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.2 Service」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-011、P06-012、P06-013、P06-014、P06-015

**Acceptance Criteria:**
- [ ] 帳本 P06-011、P06-012、P06-013、P06-014、P06-015 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-033: 修正 Part 6：6.2 Service（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.2 Service」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-016、P06-017、P06-018、P06-019

**Acceptance Criteria:**
- [ ] 帳本 P06-016、P06-017、P06-018、P06-019 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P06-018 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-034: 修正 Part 6：6.3 ConfigMap（與 Secret）（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.3 ConfigMap（與 Secret）」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-201、P06-202、P06-203、P06-204、P06-205

**Acceptance Criteria:**
- [ ] 帳本 P06-201、P06-202、P06-203、P06-204、P06-205 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P06-203 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-035: 修正 Part 6：6.3 ConfigMap（與 Secret）（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.3 ConfigMap（與 Secret）」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-206、P06-207

**Acceptance Criteria:**
- [ ] 帳本 P06-206、P06-207 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-036: 修正 Part 6：6.4 CronJob（1/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.4 CronJob」（1/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-208、P06-209、P06-211、P06-212、P06-213

**Acceptance Criteria:**
- [ ] 帳本 P06-208、P06-209、P06-211、P06-212、P06-213 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-037: 修正 Part 6：6.4 CronJob（2/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.4 CronJob」（2/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-214、P06-215、P06-216、P06-217、P06-218

**Acceptance Criteria:**
- [ ] 帳本 P06-214、P06-215、P06-216、P06-217、P06-218 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-038: 修正 Part 6：6.4 CronJob（3/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.4 CronJob」（3/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-219

**Acceptance Criteria:**
- [ ] 帳本 P06-219 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-039: 修正 Part 6：6.5 Gateway（Istio）（1/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.5 Gateway（Istio）」（1/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-401、P06-403、P06-402、P06-404、P06-405

**Acceptance Criteria:**
- [ ] 帳本 P06-401、P06-403、P06-402、P06-404、P06-405 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P06-403 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-040: 修正 Part 6：6.5 Gateway（Istio）（2/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.5 Gateway（Istio）」（2/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-406、P06-407、P06-408、P06-409、P06-410

**Acceptance Criteria:**
- [ ] 帳本 P06-406、P06-407、P06-408、P06-409、P06-410 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-041: 修正 Part 6：6.5 Gateway（Istio）（3/3）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.5 Gateway（Istio）」（3/3）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-411、P06-412

**Acceptance Criteria:**
- [ ] 帳本 P06-411、P06-412 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P06-412 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-042: 修正 Part 6：6.6 VirtualService（Istio）（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.6 VirtualService（Istio）」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-416、P06-413、P06-415、P06-414、P06-417

**Acceptance Criteria:**
- [ ] 帳本 P06-416、P06-413、P06-415、P06-414、P06-417 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-043: 修正 Part 6：6.6 VirtualService（Istio）（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 6 的「6.6 VirtualService（Istio）」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P06-418、P06-419、P06-420

**Acceptance Criteria:**
- [ ] 帳本 P06-418、P06-419、P06-420 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P06-418 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 6 結尾加 `### 參考來源`：列出帳本中 Part 6 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 6"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-044: 修正 Part 7：7.1 為什麼 K8s 原生做不到真正的 canary、7.2 完整實作：DestinationRule sub…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 7 的「7.1 為什麼 K8s 原生做不到真正的 canary」「7.2 完整實作：DestinationRule sub…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P07-001、P07-002、P07-003、P07-004

**Acceptance Criteria:**
- [ ] 帳本 P07-001、P07-002、P07-003、P07-004 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-045: 修正 Part 7：7.4 Canary 與 session 黏著的衝突（你…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 7 的「7.4 Canary 與 session 黏著的衝突（你…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P07-006、P07-007

**Acceptance Criteria:**
- [ ] 帳本 P07-006、P07-007 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-046: 修正 Part 7：7.5 HorizontalPodAutoscaler
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 7 的「7.5 HorizontalPodAutoscaler」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P07-009、P07-010、P07-011、P07-012

**Acceptance Criteria:**
- [ ] 帳本 P07-009、P07-010、P07-011、P07-012 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P07-012 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-047: 修正 Part 7：7.6 什麼時候該升級到 Argo Rollouts /…（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 7 的「7.6 什麼時候該升級到 Argo Rollouts /…」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P07-014、P07-015、P07-016、P07-017、P07-018

**Acceptance Criteria:**
- [ ] 帳本 P07-014、P07-015、P07-016、P07-017、P07-018 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P07-014 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-048: 修正 Part 7：7.6 什麼時候該升級到 Argo Rollouts /…（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 7 的「7.6 什麼時候該升級到 Argo Rollouts /…」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P07-019、P07-020、P07-021、P07-022、P07-023

**Acceptance Criteria:**
- [ ] 帳本 P07-019、P07-020、P07-021、P07-022、P07-023 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 7 結尾加 `### 參考來源`：列出帳本中 Part 7 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 7"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-049: 修正 Part 8：8.1 istioctl 常用指令
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 8 的「8.1 istioctl 常用指令」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P08-001、P08-002

**Acceptance Criteria:**
- [ ] 帳本 P08-001、P08-002 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-050: 修正 Part 8：8.2 Envoy access log 判讀
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 8 的「8.2 Envoy access log 判讀」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P08-003、P08-004、P08-005、P08-006

**Acceptance Criteria:**
- [ ] 帳本 P08-003、P08-004、P08-005、P08-006 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-051: 修正 Part 8：8.3 一分鐘分流診斷
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 8 的「8.3 一分鐘分流診斷」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P08-007、P08-008、P08-009

**Acceptance Criteria:**
- [ ] 帳本 P08-007、P08-008、P08-009 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 8 結尾加 `### 參考來源`：列出帳本中 Part 8 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 8"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-052: 修正 Part 9：發現 1：Deployment 沒有 `serviceA…、發現 2：`sessionAffinity: Clien…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 9 的「發現 1：Deployment 沒有 `serviceA…」「發現 2：`sessionAffinity: Clien…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P09-002、P09-003、P09-004、P09-005、P09-006

**Acceptance Criteria:**
- [ ] 帳本 P09-002、P09-003、P09-004、P09-005、P09-006 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-053: 修正 Part 9：發現 3：VirtualService 沒有 `mesh…、發現 4：Service port 沒有命名，Istio…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 9 的「發現 3：VirtualService 沒有 `mesh…」「發現 4：Service port 沒有命名，Istio…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P09-007、P09-008、P09-009

**Acceptance Criteria:**
- [ ] 帳本 P09-007、P09-008、P09-009 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-054: 修正 Part 9：發現 5：沒有 PDB，也沒有 HPA、發現 6：缺少 `preStop` hook（滾動更新期…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 9 的「發現 5：沒有 PDB，也沒有 HPA」「發現 6：缺少 `preStop` hook（滾動更新期…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P09-011、P09-012、P09-013、P09-014、P09-015

**Acceptance Criteria:**
- [ ] 帳本 P09-011、P09-012、P09-013、P09-014、P09-015 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 9 結尾加 `### 參考來源`：列出帳本中 Part 9 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 9"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-055: 修正 Part 10：10.1 這是在解決什麼問題
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 10 的「10.1 這是在解決什麼問題」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P10-001

**Acceptance Criteria:**
- [ ] 帳本 P10-001 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-056: 修正 Part 10：10.4 雙 VIP 架構：routable 與 non…（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 10 的「10.4 雙 VIP 架構：routable 與 non…」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P10-003、P10-006、P10-004、P10-005、P10-007

**Acceptance Criteria:**
- [ ] 帳本 P10-003、P10-006、P10-004、P10-005、P10-007 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P10-003 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-057: 修正 Part 10：10.4 雙 VIP 架構：routable 與 non…（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 10 的「10.4 雙 VIP 架構：routable 與 non…」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P10-008、P10-009

**Acceptance Criteria:**
- [ ] 帳本 P10-008、P10-009 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-058: 修正 Part 10：10.5 兩個 VIP 的安全設定不一樣、10.6 踩雷
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 10 的「10.5 兩個 VIP 的安全設定不一樣」「10.6 踩雷」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P10-010、P10-012、P10-013、P10-014

**Acceptance Criteria:**
- [ ] 帳本 P10-010、P10-012、P10-013、P10-014 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 10 結尾加 `### 參考來源`：列出帳本中 Part 10 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 10"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-059: 修正 Part 11：11.2 模式 A：單一 DNS 指向 FZ1、11.3 模式 B：兩座 cluster 各自建 ing…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 11 的「11.2 模式 A：單一 DNS 指向 FZ1」「11.3 模式 B：兩座 cluster 各自建 ing…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P11-002、P11-004、P11-003

**Acceptance Criteria:**
- [ ] 帳本 P11-002、P11-004、P11-003 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-060: 修正 Part 11：11.4 模式 B 實際要準備的 manifest（哪些…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 11 的「11.4 模式 B 實際要準備的 manifest（哪些…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P11-005、P11-006、P11-007、P11-008

**Acceptance Criteria:**
- [ ] 帳本 P11-005、P11-006、P11-007、P11-008 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-061: 修正 Part 11：11.5 session 的致命細節（直接關係到你的架構…、11.10 踩雷
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 11 的「11.5 session 的致命細節（直接關係到你的架構…」「11.10 踩雷」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P11-009、P11-010、P11-011、P11-014、P11-015

**Acceptance Criteria:**
- [ ] 帳本 P11-009、P11-010、P11-011、P11-014、P11-015 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P11-010、P11-015 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 11 結尾加 `### 參考來源`：列出帳本中 Part 11 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 11"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-062: 修正 Part 12：12.2 先回答：怎麼指定哪些 request 去 v2、12.3 路線一：Job-based smoke tes…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.2 先回答：怎麼指定哪些 request 去 v2」「12.3 路線一：Job-based smoke tes…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-001、P12-002、P12-004

**Acceptance Criteria:**
- [ ] 帳本 P12-001、P12-002、P12-004 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-063: 修正 Part 12：12.4 路線二：Prometheus 指標分析
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.4 路線二：Prometheus 指標分析」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-005、P12-006、P12-007、P12-008

**Acceptance Criteria:**
- [ ] 帳本 P12-005、P12-006、P12-007、P12-008 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-064: 修正 Part 12：12.7 怎麼從人工過渡到全自動（最重要的一節）、12.8 安全網設定
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.7 怎麼從人工過渡到全自動（最重要的一節）」「12.8 安全網設定」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-009、P12-010、P12-011、P12-012、P12-013

**Acceptance Criteria:**
- [ ] 帳本 P12-009、P12-010、P12-011、P12-012、P12-013 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-065: 修正 Part 12：12.10 先確認環境有什麼
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.10 先確認環境有什麼」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-014

**Acceptance Criteria:**
- [ ] 帳本 P12-014 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-066: 修正 Part 12：12.11 完整 manifest（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.11 完整 manifest」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-015、P12-016、P12-021、P12-017、P12-018

**Acceptance Criteria:**
- [ ] 帳本 P12-015、P12-016、P12-021、P12-017、P12-018 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-067: 修正 Part 12：12.11 完整 manifest（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.11 完整 manifest」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-019、P12-020、P12-022、P12-023、P12-024

**Acceptance Criteria:**
- [ ] 帳本 P12-019、P12-020、P12-022、P12-023、P12-024 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-068: 修正 Part 12：12.12 用 metric 判斷：最小可用的例子
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 12 的「12.12 用 metric 判斷：最小可用的例子」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P12-025、P12-026

**Acceptance Criteria:**
- [ ] 帳本 P12-025、P12-026 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 12 結尾加 `### 參考來源`：列出帳本中 Part 12 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 12"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-069: 修正 Part 13：13.3 誰需要 routable、誰不需要、13.4 完整寫法
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 13 的「13.3 誰需要 routable、誰不需要」「13.4 完整寫法」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P13-002、P13-003、P13-004、P13-005

**Acceptance Criteria:**
- [ ] 帳本 P13-002、P13-003、P13-004、P13-005 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-070: 修正 Part 13：13.7 踩雷
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 13 的「13.7 踩雷」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P13-006、P13-007、P13-009

**Acceptance Criteria:**
- [ ] 帳本 P13-006、P13-007、P13-009 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 13 結尾加 `### 參考來源`：列出帳本中 Part 13 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 13"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-071: 修正 Part 14：14.2 解法：用 cookie 指定，而不是用權重、14.3 命名採「固定 stable / canary」…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 14 的「14.2 解法：用 cookie 指定，而不是用權重」「14.3 命名採「固定 stable / canary」…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P14-001、P14-002、P14-003、P14-004、P14-005

**Acceptance Criteria:**
- [ ] 帳本 P14-001、P14-002、P14-003、P14-004、P14-005 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-072: Part 14 14.4 完整 manifest 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「14.4 完整 manifest」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P14-018、P14-019、P14-021、P14-023、P14-020、P14-024、P14-022、P14-025、P14-026、P14-028、P14-027、P14-029

**Acceptance Criteria:**
- [ ] 把「14.4 完整 manifest」小節的內容換成兩三句摘要＋指標，指向帳本 P14-018 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P14-018 的「建議改法」
- [ ] 換掉之後，帳本 P14-019、P14-021、P14-023、P14-020、P14-024、P14-022、P14-025、P14-026、P14-028、P14-027、P14-029 指出的錯誤說法都不再出現在 guide（這些列落在被取代的小節裡，隨取代一起解決；逐列確認，不要只看整段刪掉）
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-073: 修正 Part 14：14.5 三個必須注意的前提
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 14 的「14.5 三個必須注意的前提」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P14-006、P14-007

**Acceptance Criteria:**
- [ ] 帳本 P14-006、P14-007 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-074: 修正 Part 14：14.6 為什麼 VirtualService 一定要加…
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 14 的「14.6 為什麼 VirtualService 一定要加…」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P14-008、P14-009、P14-010、P14-011

**Acceptance Criteria:**
- [ ] 帳本 P14-008、P14-009、P14-010、P14-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P14-010 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-075: 修正 Part 14：14.7 讓 pilot 使用者能「自證」在新版上、14.9 兩種實作方式
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 14 的「14.7 讓 pilot 使用者能「自證」在新版上」「14.9 兩種實作方式」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P14-012、P14-013、P14-014、P14-015、P14-016

**Acceptance Criteria:**
- [ ] 帳本 P14-012、P14-013、P14-014、P14-015、P14-016 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-076: Part 14 14.10 完整流程速查 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「14.10 完整流程速查」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P14-030、P14-031、P14-032、P14-033、P14-034、P14-035

**Acceptance Criteria:**
- [ ] 把「14.10 完整流程速查」小節的內容換成兩三句摘要＋指標，指向帳本 P14-030 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P14-030 的「建議改法」
- [ ] 換掉之後，帳本 P14-031、P14-032、P14-033、P14-034、P14-035 指出的錯誤說法都不再出現在 guide（這些列落在被取代的小節裡，隨取代一起解決；逐列確認，不要只看整段刪掉）
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-077: 修正 Part 14：14.11 這套流程未來怎麼演進
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 14 的「14.11 這套流程未來怎麼演進」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P14-017

**Acceptance Criteria:**
- [ ] 帳本 P14-017 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 14 結尾加 `### 參考來源`：列出帳本中 Part 14 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 14"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-078: 修正 Part 15：15.1 先講一個現實限制、15.2 兩種可行的「同時保有兩套」
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.1 先講一個現實限制」「15.2 兩種可行的「同時保有兩套」」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-001、P15-002、P15-003、P15-004

**Acceptance Criteria:**
- [ ] 帳本 P15-001、P15-002、P15-003、P15-004 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-079: 修正 Part 15：15.3 YAML 逐項差異對照（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.3 YAML 逐項差異對照」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-005、P15-006、P15-007、P15-008、P15-009

**Acceptance Criteria:**
- [ ] 帳本 P15-005、P15-006、P15-007、P15-008、P15-009 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-080: 修正 Part 15：15.3 YAML 逐項差異對照（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.3 YAML 逐項差異對照」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-010、P15-011

**Acceptance Criteria:**
- [ ] 帳本 P15-010、P15-011 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-081: Part 15 15.4 Track A 的 SOP（人工 pilot … 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「15.4 Track A 的 SOP（人工 pilot …」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P15-012、P15-013、P15-014、P15-015、P15-016、P15-017、P15-018、P15-019、P15-020

**Acceptance Criteria:**
- [ ] 把「15.4 Track A 的 SOP（人工 pilot …」小節的內容換成兩三句摘要＋指標，指向帳本 P15-012 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P15-012 的「建議改法」
- [ ] 換掉之後，帳本 P15-013、P15-014、P15-015、P15-016、P15-017、P15-018、P15-019、P15-020 指出的錯誤說法都不再出現在 guide（這些列落在被取代的小節裡，隨取代一起解決；逐列確認，不要只看整段刪掉）
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-082: Part 15 15.5 Track B 的 SOP（Argo Roll… 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「15.5 Track B 的 SOP（Argo Roll…」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P15-021

**Acceptance Criteria:**
- [ ] 把「15.5 Track B 的 SOP（Argo Roll…」小節的內容換成兩三句摘要＋指標，指向帳本 P15-021 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P15-021 的「建議改法」
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-083: 修正 Part 15：15.6 什麼情況用哪一套
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.6 什麼情況用哪一套」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-022

**Acceptance Criteria:**
- [ ] 帳本 P15-022 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-084: Part 15 15.7 兩種 track 之間的切換 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「15.7 兩種 track 之間的切換」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P15-024、P15-025、P15-026、P15-027、P15-028

**Acceptance Criteria:**
- [ ] 把「15.7 兩種 track 之間的切換」小節的內容換成兩三句摘要＋指標，指向帳本 P15-024 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P15-024 的「建議改法」
- [ ] 換掉之後，帳本 P15-025、P15-026、P15-027、P15-028 指出的錯誤說法都不再出現在 guide（這些列落在被取代的小節裡，隨取代一起解決；逐列確認，不要只看整段刪掉）
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-085: 修正 Part 15：15.8 CD 只能 apply 時的限制對照
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.8 CD 只能 apply 時的限制對照」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-029、P15-030、P15-031、P15-032

**Acceptance Criteria:**
- [ ] 帳本 P15-029、P15-030、P15-031、P15-032 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P15-031 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-086: 修正 Part 15：15.9 檔案分層：base 與 release
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.9 檔案分層：base 與 release」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-033、P15-034、P15-035、P15-036

**Acceptance Criteria:**
- [ ] 帳本 P15-033、P15-034、P15-035、P15-036 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P15-036 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-087: Part 15 15.10 Track A 的 apply-only S… 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「15.10 Track A 的 apply-only S…」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P15-037、P15-038、P15-039、P15-040、P15-041、P15-042、P15-043

**Acceptance Criteria:**
- [ ] 把「15.10 Track A 的 apply-only S…」小節的內容換成兩三句摘要＋指標，指向帳本 P15-037 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P15-037 的「建議改法」
- [ ] 換掉之後，帳本 P15-038、P15-039、P15-040、P15-041、P15-042、P15-043 指出的錯誤說法都不再出現在 guide（這些列落在被取代的小節裡，隨取代一起解決；逐列確認，不要只看整段刪掉）
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-088: 修正 Part 15：15.11 回滾完全靠 Git
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 15 的「15.11 回滾完全靠 Git」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P15-044、P15-045、P15-046、P15-047

**Acceptance Criteria:**
- [ ] 帳本 P15-044、P15-045、P15-046、P15-047 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-089: Part 15 15.12 Track B 在 apply-only 下… 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「15.12 Track B 在 apply-only 下…」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P15-048

**Acceptance Criteria:**
- [ ] 把「15.12 Track B 在 apply-only 下…」小節的內容換成兩三句摘要＋指標，指向帳本 P15-048 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P15-048 的「建議改法」
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-090: Part 15 15.13 Azure Pipeline 的設定建議 改成指標
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要「15.13 Azure Pipeline 的設定建議」不再保留一份會跟 CANARY-COMPLETE.md 分歧、而且含 outage 步驟的完整副本，改成摘要＋指標，這樣我照著做的永遠是唯一的真實來源。

**帳本 ID：** P15-049、P15-050、P15-051

**Acceptance Criteria:**
- [ ] 把「15.13 Azure Pipeline 的設定建議」小節的內容換成兩三句摘要＋指標，指向帳本 P15-049 列出的 `canary-manual/CANARY-COMPLETE.md` 章節；小節標題保留，摘要內容照 P15-049 的「建議改法」
- [ ] 換掉之後，帳本 P15-050、P15-051 指出的錯誤說法都不再出現在 guide（這些列落在被取代的小節裡，隨取代一起解決；逐列確認，不要只看整段刪掉）
- [ ] 摘要裡不得出現 CANARY-COMPLETE.md 禁止的操作：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、`canary.sh`
- [ ] 小節裡被刪掉的 yaml 區塊若前一行有 `<!-- validate:skip-yaml … -->` 標記，標記一起刪掉
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 15 結尾加 `### 參考來源`：列出帳本中 Part 15 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 15"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-091: 修正 Part 16：16.2 資料路徑：封包真正經過什麼、16.4 FZ1 缺什麼 → 什麼症狀、16.5 驗證：確認 request 真的落在哪一邊
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 16 的「16.2 資料路徑：封包真正經過什麼」「16.4 FZ1 缺什麼 → 什麼症狀」「16.5 驗證：確認 request 真的落在哪一邊」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P16-002、P16-003、P16-004、P16-006、P16-008

**Acceptance Criteria:**
- [ ] 帳本 P16-002、P16-003、P16-004、P16-006、P16-008 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-092: 修正 Part 16：16.6 用 service mesh 把 FZ1 收到…（1/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 16 的「16.6 用 service mesh 把 FZ1 收到…」（1/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P16-009、P16-010、P16-011、P16-012、P16-013

**Acceptance Criteria:**
- [ ] 帳本 P16-009、P16-010、P16-011、P16-012、P16-013 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 判定為「無法驗證」的 P16-013 只改成帳本建議的保守寫法或刪除，不新增帳本沒有的來源或數字
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-093: 修正 Part 16：16.6 用 service mesh 把 FZ1 收到…（2/2）
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 16 的「16.6 用 service mesh 把 FZ1 收到…」（2/2）裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P16-014

**Acceptance Criteria:**
- [ ] 帳本 P16-014 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-094: 修正 Part 16：16.8 踩雷
**Description:** 身為從這份 guide 學 K8s／Istio 的讀者，我要 Part 16 的「16.8 踩雷」裡經官方文件查證為錯誤、過時或不精確的說法被修正，這樣我學到的是對的。

**帳本 ID：** P16-016

**Acceptance Criteria:**
- [ ] 帳本 P16-016 每一列都依「建議改法」修正：guide 不再包含該列「原文摘錄」的錯誤說法，改後的說法與「來源引文」一致（行號會漂移，以原文摘錄定位）
- [ ] 改到的 yaml 區塊仍可解析（validate.sh 檢查 [10]），而且保留原本「解釋為什麼」的註解密度
- [ ] 沒有改動上列帳本 ID 以外的說法；若為了同一小節前後一致而連動修改，在 progress.txt 寫明改了哪句、為什麼
- [ ] Part 16 結尾加 `### 參考來源`：列出帳本中 Part 16 各列（含先前故事已修的列）用到的官方 URL，去重；並把 `"Part 16"` 加進 `scripts/validate.sh` 的 `VERIFIED_PARTS`（檢查 [11]）
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-095: 環境特定說法併入「需向他人確認」清單
**Description:** 身為讀者，我要所有「只在我們環境才成立、要問人才知道」的說法都集中在文末清單，並在原處標明，這樣我分得清哪些是通則、哪些要去跟網路組／平台組／CD 團隊確認。

**帳本 ID：** P01-001、P01-003、P01-004、P01-012、P02-009、P04-001、P04-005、P04-015、P06-210、P07-005、P07-008、P07-013、P09-001、P09-010、P10-002、P10-011、P11-001、P11-012、P11-013、P12-003、P13-001、P13-008、P13-010、P15-023、P16-001、P16-005、P16-007、P16-015、Q-001、Q-002

**Acceptance Criteria:**
- [ ] guide 文末「文件中標示為『需向他人確認』的項目」表格，對上列每一個環境特定 ID 都有對應的一列（同一件事可合併成一列，在「在哪一節」欄列出全部出處）；已經在表裡的項目不重複新增
- [ ] Q-001（FZ2 ingressgateway 憑證由哪個 CA 簽發）與 Q-002（環境有沒有開 access log）照帳本的「項目／問誰／在哪一節」加進表格
- [ ] 帳本「建議改法」要求在原處加註的列（例如「加註依你的 kubeconfig 調整」「加上『若 controller 跑在 UTC』的前提」），在 guide 原處加上簡短的前提說明或「見文末需向他人確認」
- [ ] 不替環境特定說法編造答案或預設值
- [ ] `bash scripts/validate.sh` exits 0
- [ ] code-review（fixed point＝故事開始時記下的 BASE）沒有未處理的發現；兩輪修不完就依 ralph/CLAUDE.md 寫進 notes、passes 維持 false

### US-096: retro 並更新 CLAUDE.md
**Description:** 身為下一個在這個 repo 工作的人（或代理），我要這次 loop 學到的導覽與陷阱寫進 CLAUDE.md，而且 CLAUDE.md 裡已知不正確的說法被修正，這樣下次不用重新踩一次。

**帳本 ID：** X-002

**Acceptance Criteria:**
- [ ] 執行 `retro` skill，完整的回顧候選寫進 `tasks/retro-k8s-guide-verification.md`
- [ ] 只把「可重複使用」的導覽與陷阱寫進 CLAUDE.md（照 CLAUDE.md 現有風格：講為什麼、漏了會怎樣），不寫只跟這次 loop 有關的流水帳
- [ ] 修正帳本 X-002：CLAUDE.md「兩者同時存在時兩個 controller 會搶 pod」改成正確原因 —— Argo 官方 "The Rollout won't try to manage existing Deployment Pods."；兩軌互斥的規則不變，真正原因是共用 `app` label（會被對方的 Service 選進 endpoint）與同一條 VirtualService
- [ ] CLAUDE.md 有指向帳本與這份 PRD 的導覽，並說明 `VERIFIED_PARTS` 規則（之後任何改 guide 某個 Part 的人都要維持它的 `### 參考來源`）
- [ ] CLAUDE.md 的改動是獨立的 commit（`docs: US-096 - retro and CLAUDE.md update`），再跑一次 code-review
- [ ] `bash scripts/validate.sh` exits 0

## Functional Requirements

- FR-1：每個故事只修改它「帳本 ID」欄列出的說法；每一處修改都要能追溯到帳本某一列的「建議改法」與「來源引文」。
- FR-2：判定「錯誤／過時／不精確」的列，改後的說法必須與該列「來源引文」一致；判定「無法驗證」的列只能改成帳本建議的保守寫法或刪除。
- FR-3：判定「改成指標」的列，整個小節改成兩三句摘要＋指向 `canary-manual/CANARY-COMPLETE.md` 的章節；落在該小節裡的其他列隨取代一起解決，但要逐列確認錯誤說法確實消失。
- FR-4：guide 不得再出現 CANARY-COMPLETE.md 明文禁止的操作建議：`replicas: 0`／`kubectl scale` 關 canary、`kubectl rollout undo`、版本化＋`immutable: true` 的 ConfigMap、`SPRING_CONFIG_ADDITIONAL_LOCATION`、使用 `canary.sh`。
- FR-5：guide 每個 ```yaml 區塊都要能用 js-yaml `loadAll` 解析，除非 fence 前一行有原因非空的 `<!-- validate:skip-yaml 原因 -->`。
- FR-6：每個 Part 的最後一個故事在該 Part 結尾加 `### 參考來源`（帳本中該 Part 各列的官方 URL，去重），並把該 Part 加進 `VERIFIED_PARTS`；`VERIFIED_PARTS` 裡的 Part 少了參考來源或沒有官方網域連結時 `validate.sh` FAIL。
- FR-7：每個故事 commit 前 `bash scripts/validate.sh` 必須 exit 0；commit 後跑 code-review，Spec 軸逐條 WebFetch 該故事帳本列的 URL 確認引文存在。

## Implementation Decisions

- **事實依據只有帳本。** loop 不重新查證、不自行判斷官方文件的意思；帳本有疑義時寫進 notes 交回給人，不自己改帳本的判定。
- **故事切法：** 一個故事＝同一 Part 內相鄰的一到數個 `###` 小節，帳本發現合計不超過 5 條（較大的小節切成 1/2、2/3…）；「改成指標」的小節各自一個故事，不設 5 條上限。共 93 個修正故事＋1 個閘門故事＋1 個「需向他人確認」故事＋1 個 retro 故事。
- **順序：** US-001 先建閘門；修正故事依 guide 由上到下；`需向他人確認` 與 retro 放最後。
- **行號會漂移。** 帳本行號是 commit `2c26688` 的位置；前面的故事改過之後就不準了，一律用帳本的「原文摘錄」定位。
- **保留註解密度。** guide 的 YAML 註解解釋「為什麼」，修正時要一起改註解，不可以只改值而留下互相矛盾的註解。
- **Part 14／15 採「概念＋指標」**：概念小節逐行修正；14.4、14.10、15.4、15.5、15.7、15.10、15.12、15.13 改成指標。
- **超出範圍的帳本列（X-001、X-003）不在這次 loop 修**：那是 `canary-manual/track-a/` manifest 本身落後 CANARY-COMPLETE.md，要另開 PRD 並照「改 manifest 就要加檢查」的規則做。guide 修正時可以提到「track-a 目前還沒落地」，但不要改 manifest。

## Testing Decisions

- **閘門＝`scripts/validate.sh`**（這個 repo 唯一的 typecheck 等價物），只加兩項：`[10]` guide yaml 可解析、`[11]` 已登記的 Part 有官方參考來源。好的檢查只看外部可觀察的結果（解析成不成功、該段落與連結存不存在），不檢查行文措辭。
- **每項檢查都要反向測**（改壞 → 確認 FAIL → 還原），一個永遠綠燈的檢查比沒有檢查更糟。
- **內容正確性靠 code-review 的 Spec 軸**：fixed point 是故事開始時的 HEAD，spec 是這份 PRD＋帳本；Spec sub-agent 對該故事每一列帳本 URL 做 WebFetch，確認引文存在、改後說法與引文一致。
- **既有的範例：** validate.sh 裡 `check` helper、`assert_cm_key*` 的「解析 YAML 再斷言」寫法、`[9]` 的「備份 → 跑 → 比對 → 無條件還原」寫法。

## Non-Goals (Out of Scope)

- 不修改 `canary-manual/` 底下任何 manifest（X-001、X-003 另開 PRD）
- 不修改 `canary-manual/scripts/canary.sh`（US-010，在舊分支）
- 不修改帳本的判定、不重新查證已確認的列、不查證帳本以外的新說法
- 不改寫 guide 的整體結構或文風；判定為「正確」的段落不動
- 不碰 Spring Boot 後端 repo（`dev/spring_oauth2_backend`）
- 不連任何叢集（這台機器沒有 kubectl）

## Technical Considerations

- 只有 node／npm；YAML 用本地 js-yaml，不用 `npx --yes`；node 看不到 Git Bash 的 `/tmp`；`MSYS2_ARG_CONV_EXCL='*'` 必須保留（CLAUDE.md「工具限制」）。
- guide 在工作目錄是 CRLF（`core.autocrlf=true`）；用腳本改寫時要保留行尾。
- 每個故事兩到三個 commit：`feat: US-xxx - <title>`（＋最多兩個 `fix: US-xxx - address review`）＋`chore: US-xxx - mark story complete and log progress`（流程見 `ralph/CLAUDE.md`）。
- loop 指令：`.\ralph\ralph.ps1 --model <m> --effort <e> <max_iterations>`；96 個故事、每輪含 code-review，屬於長時間的 loop。

## Success Metrics

- 帳本 365 條修正列＋30 條「需向他人確認」列全部有對應的已完成故事
- `VERIFIED_PARTS` 包含 Part 0 到 Part 16 全部 17 個 Part，`validate.sh` exit 0
- guide 裡沒有 `validate:skip-yaml` 以外的 yaml 解析失敗
- 每個故事在 git log 都有 feat（＋fix）＋chore，progress.txt 有 review 摘要

## Open Questions

- 叢集的實際 K8s／Istio 版本還沒確認。帳本以官方最新版為準並註明最低版本；版本確認後，可能有幾條「過時」要回頭降級成「視版本而定」。
- P11-014（`kubectl get gateway` 名稱衝突）只有廠商文件佐證；code-review 若查不到 istio.io 的對應說法，維持帳本的保守改法即可。
