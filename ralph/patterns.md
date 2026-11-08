# Ralph Codebase Patterns

> 代理**每一輪都完整讀這份**；`progress.txt` 是給人看的歷史紀錄，代理不讀（見 `ralph/CLAUDE.md` 第 2 步）。
> 所以值得傳給之後輪次的東西只能寫在這裡。寫的時候合併、改寫既有條目，不要一直往下加 ——
> 這份每多 1 KB，之後每一輪都要多付 1 KB。故事專屬的細節留在 progress.txt。
> （2026-11-01 從 progress.txt 開頭的 `## Codebase Patterns` 區段搬過來，內容未改；
> 結尾兩節是從 US-001～US-004 各條目的 Learnings 整理出來的。）

## Codebase Patterns

> 目前的 run 是 ralph/guide-explainers：在 k8s-ecosystem-guide.md 的既有 Part **新增**說明（不是修正既有說法）。
> 事實依據是 tasks/guide-explainers-ledger.md（E-001～E-030，沒有行號欄，插入位置看 spec 驗收條件）。
> 這個 run 不動 manifest、不改 validate.sh；閘門是 [10]（guide yaml 可解析）與 [11]（VERIFIED_PARTS 的參考來源），
> 內容正確性由 code-review 對照帳本把關。下面講 manifest／validate.sh 的條目是 repo 通用慣例，本 run 只在誤動 manifest 時才適用。


- **This is NOT a code project.** `dev/k8s` holds Kubernetes/Istio YAML, shell scripts and
  Traditional-Chinese markdown. There is no compiler, no test framework, nothing to build.
  The typecheck equivalent is `bash scripts/validate.sh` from the repo root, exit 0 = pass.

- **A story that changes a manifest adds its own assertions to `scripts/validate.sh`, in the same commit.**
  This is the most important rule in this repo (this run should not touch manifests at all). It is what keeps the script green at
  every commit and what stops story N+3 from silently undoing story N. A story that changes a
  manifest but adds no check is not finished.

- **Tooling is thin: node / npm / npx only.** There is NO `kubectl`, NO `yq`, and NO usable
  `python` (only the Microsoft Store stub, which prints an install prompt instead of running).
  Do not try to install them and do not try to reach a cluster — there isn't one.
  YAML is parsed with the local `node_modules/.bin/js-yaml` CLI, pinned as a devDependency.
  Do not use `npx --yes js-yaml`: it needs network on every run and cannot be a quality gate.

- **Git Bash 會竄改傳給 node 的參數 —— `export MSYS2_ARG_CONV_EXCL='*'` 不要拿掉。**
  MSYS2 在把參數交給原生的 node.exe 之前，會把長得像 POSIX 絕對路徑的字串翻譯成
  Windows 路徑：`node -e '...' "/gui_epmmFormQuery"` → node 收到
  `"C:/Program Files/Git/gui_epmmFormQuery"`。這個 repo 的設定值一大半是
  `/gui_epmmFormQuery` 開頭，所以任何把期望值當參數傳進 node 比對的斷言都會永遠
  FAIL，而錯誤訊息會印出 `C:\Program Files`，看起來像是 ConfigMap 被寫壞了。
  改用環境變數傳值也救不了（環境變數的值一樣被轉換，實測）。
  `scripts/validate.sh` 開頭已經關掉整支腳本的轉換；在腳本外面手動跑 `node -e`
  驗證時要自己記得在前面加 `MSYS2_ARG_CONV_EXCL='*'`。

- **Assert on parsed YAML, not on grep.** The interesting content lives inside a ConfigMap's
  `data["application.yml"]` — a YAML document embedded as a string inside another YAML
  document. Parse the outer file, then parse that string, then assert on the object.
  Grepping the raw file gives false passes on commented-out lines (there are several).

- **`canary-manual/CANARY-COMPLETE.md` is the single source of truth for the target state.**
  Read the relevant section before touching any manifest. Section 3.1 explains how config is
  loaded (and why the pod currently cannot start), section 3.5 has the complete target
  ConfigMap, and Appendix C is the required-key list with "what it falls back to if omitted".

- **Five documents under `canary-manual/` carry a "已被取代" banner** (`README.md`, `SOP.md`,
  `SOP-apply-only.md`, `canary-ops-runbook.md`). Do not follow their operational steps —
  they contain instructions that are known to cause an outage (`replicas: 0`, `rollout undo`).
  `pilot-run-guide.md` is deliberately kept: its reader is the end user, not operations.

- **YAML comments here explain WHY, at length.** Look at
  `canary-manual/track-a/release/20-deployment-stable.yaml` for the density to match. A key
  added with no comment saying what breaks without it is off-pattern for this repo.
  Prose and comments are Traditional Chinese.

- **Scope is `dev/k8s` only.** The Spring Boot backend is a separate repo at
  `dev/spring_oauth2_backend`. Never edit it.

- **`scripts/validate.sh` 的擴充方式**（US-001 建立）：腳本裡有一個
  `# 之後的檢查加在這裡` 標記區段，新檢查以 `== [n] 說明 ==` 區段加在那裡、
  總結區塊之前。helper 的呼叫慣例是 `check "<名稱>" <指令> [參數...]`，指令以
  參數陣列直接執行、**不經過 eval**，所以可以原樣傳一整段帶引號的 `node -e` 斷言。
  需要 pipeline 或 shell 語法時再明確包一層 `bash -c`。

- **解析 ConfigMap 內層設定的標準寫法**（從 repo root 執行，node_modules 在 root）：
  `const y=require("js-yaml"); const cm=y.load(fs.readFileSync(f,"utf8"));`
  `const app=y.load(cm.data["application.yml"]);` —— 然後對 `app` 物件下斷言。
  js-yaml CLI 也支援多文件（`---` 分隔）的 YAML，track-b/base 底下就有幾個。

- **刪除設定也要加檢查，而且是反方向的那種。** `assert_cm_key_absent <key> <為什麼不能有>`
  —— key **存在就是失敗**（跟 `assert_cm_key` 相反，那邊空字串算通過、這邊只留一行
  `cors:` 算失敗）。用在已經刪掉的死設定（`app.cors` / `app.sso` / `app.test-endpoints`）：
  它們加回來不會產生任何症狀，所以沒有人會發現加錯了。跑 `BOTH_TRACK_CONFIGMAPS`，
  因為復活最常見的路徑是「從另一個 track 整段複製設定過來」。反向測這類檢查時，
  除了「整塊加回來」還要測「整塊被註解掉」—— 後者必須維持 PASS，那正是它解析 YAML
  而不是 grep 的意義（檔案裡的說明註解本身就含有 `app.cors.*` 這些字，grep 版本永遠 FAIL）。

- **這台機器 `core.autocrlf=true`。** `git add` 噴的 "LF will be replaced by CRLF"
  是正常的、可以忽略；`*.sh` 已由 `.gitattributes` 釘成 LF，之後新增的腳本自動適用。
  但工作目錄裡的 `prd.json` / `progress.txt` 實際上是 LF，程式化改寫時沿用原檔行尾。

- **兩個互相綁定的欄位，要拿它們互相對照，不要各自釘一個常數。** manifest 裡有幾組值
  是必須一致的（`SPRING_CONFIG_LOCATION` 的路徑 ↔ `config` volumeMount 的 `mountPath`；
  US-008 之後還會有 Deployment 引用的 configMap 名字 ↔ ConfigMap 檔案裡的 `metadata.name`）。
  兩邊各自跟寫死的字串比對，只擋得住「兩邊都改錯」；真正會發生的是「改了其中一邊，
  忘了另一邊」。正確寫法是從 manifest 讀出 A、推出 B 應該長什麼樣，再跟實際的 B 比
  —— 任何一邊被單獨改動都會 FAIL。

- **「某個字串不得出現」的檢查，也要解析之後再看，不要 grep 原始檔。** 對 YAML 來說是
  `y.loadAll()` 之後對整份結果 `JSON.stringify` 再找子字串（keys / values 都掃得到，
  註解掃不到）。理由不是潔癖：這個 repo 的慣例就是在改掉一個設定的地方留一整段註解
  解釋「原本是什麼、為什麼那樣是錯的」，所以 grep 版本會被「自己剛寫的說明註解」打到、
  變成永遠 FAIL。對 shell 腳本（US-010 的 `canary.sh`）沒有 parser 可用，要另想辦法
  （先剝掉 `#` 註解再比對），同樣不能直接 grep 整個檔案。

- **一份 Deployment 屬於哪一軌，以 pod template 的 `version` label 為準**（不是檔名、
  也不是 `metadata.name`）。DestinationRule 是拿它分 subset 的，所以改了它 Istio 立刻
  分不出流量；檔名與物件名稱改了則什麼都不會壞。要從 Deployment 推導「該掛哪一份
  ConfigMap」「該用哪一段設定」時，一律從這個 label 出發。

- **「兩份檔案必須相同」這類斷言，要在註解裡寫明它預期會有壽命、以及到期時該怎麼改。**
  例：track-a 的 `-stable` / `-canary` 兩份 ConfigMap 目前 `data` 逐字相同，但 3.5.1
  允許 `csp-policy`、`downstream`／`third-party` 的 `base-url`、`logging.level.*` 分歧。
  沒寫的話，第一個要讓 canary 分歧的人會直接把斷言刪掉，兩份從此無聲漂移。
  正確的到期處理是**改寫成「只有那幾個 key 可以不同」**，不是刪掉。

- **`cat > file <<'FRAG'` 寫「內容含 ASCII 單引號」的 fragment 會整段 parse 失敗**
  （`unexpected EOF while looking for matching '`），即使結束標記已經加了單引號。
  validate.sh 的 `XXX_SCRIPT='...'` node 斷言正好都含單引號。那種 fragment 改用 Write
  工具直接寫檔，再用 node 拼接（記得 `.replace(/\r\n/g, "\n")`，腳本是 LF）。
  只有中文與 `${...}` 的 fragment 用 heredoc 沒問題 —— 前幾個 story 就是那樣過的。

- **改名或刪檔之後 grep 一次舊檔名。** 這個 repo 用「完整說明在 `<另一個檔案>` 的同一個
  位置」這種指路註解來避免重複，代價是每次改名都會留下死連結
  （`git mv` 之後 track-b 就有 2 處指向 track-a 的舊檔名）。
- **反向測之前，先確認「壞掉的版本真的寫進檔案了」。** US-006 有一次 `sed` 沒改到任何
  東西，於是閘門照樣 exit 0，看起來像是「這個檢查沒防護力」，其實是根本沒測到。
  改壞之後先 `grep` 一下改動處，再跑 validate.sh。
- **腳本改 manifest 用「文字取代 ＋ 寫回後重新解析自我驗證」，不要 `y.dump()`。**
  這個 repo 的 manifest 有大量中文註解在解釋「為什麼」，dump 一次就全部消失。
  取代前先數過目標行（0 次或 2 次以上都要失敗並說明，不要「有就改、沒有就算了」），
  行尾的 `\r` 用捕獲群組原樣接回去，寫完重新解析確認改到的是預期的那個位置 ——
  最後這步不是多餘：`config-hash` 有一個看起來一樣、實際完全沒作用的位置
  （Deployment 自己的 `metadata.annotations`，不是 pod template 的一部分）。
  找不到目標行時要叫人自己加上那一行連同註解，不要自動插入一個沒有註解的 key。

- **`validate.sh` 裡驗證「會改檔案的腳本」：備份 → 跑 → 比對位元組 → 無條件還原。**
  `mktemp -d` ＋ `cp` ＋ `cmp` 都是 bash 這邊處理，不會踩到 node 看不見 `/tmp` 的坑。
  **不要用 `git diff --quiet`**：它比對 HEAD，工作目錄有任何未 commit 的改動就失敗，
  而「改完 manifest 跑一次 validate.sh」正是這裡的標準工作流程 —— 那會變成一個開發途中
  永遠是紅的檢查，下場跟永遠綠燈的檢查一樣是被無視。還原要無條件做：閘門不改工作目錄。

- **掃 markdown（guide）的檢查共用 validate.sh 的 `GUIDE_FENCE_JS`（OPEN/CLOSE）。** 不要自己再寫一套
  fence 判定：兩套規則一分歧，同一行在 [10] 眼中在區塊裡、在 [11] 眼中在區塊外。guide 的 fence 可能帶縮排、
  帶 info string，也可能長在 blockquote 裡（`> ```yaml`；用 fenceOpen／fenceClose／fenceBody，它們會剝掉 `>` 前綴與縮排）。

- **改了 ConfigMap 的內容就要跑 `bash scripts/sync-config-hash.sh`，並跟 ConfigMap 放
  同一個 commit。** 名稱固定之後，改設定不會改到 pod template → apply 不重啟 →
  Spring 只在啟動時讀一次設定檔 → 設定沒有生效，而且不會報錯。忘了跑會被檢查 [9] 擋下。
  雜湊算的是**解析後**的 `data['application.yml']` 字串（跟叢集端 `kubectl ... | sha256sum`
  一致），不是原始檔位元組 —— 否則改一行註解就會讓全部 pod 滾動重啟。

## 改 guide 的慣例（ralph/guide-verification 累積下來，本 run 沿用）

- **帳本是唯一依據，措辭含糊時回官方原句。** 帳本「建議改法」寫得含糊時，回到官方頁看原句的限定範圍再寫
  （US-002 第 1 輪 Spec 就抓到寫反）。為了讓 Standards 滿意而改措辭時，要回頭對照帳本建議改法，
  否則下一輪 Spec 會說偏離帳本，兩軸拉鋸。
- **引用的規矩。** 官方原文用英文逐字放進「」，不要把翻譯放進「」當原文。用「」引用 guide 自己的字樣要逐字複製
  （reviewer 會 grep）；被引用的字樣如果同一次改動刪掉了，改用不加引號的敘述，否則 reviewer 說引用落空。
- **建議改法塞不進表格格子時**，格子寫一句結論＋「（見表下說明）」，細節放表下清單；不要格子和段落各寫一份
  （第 1 輪 Standards 會抓重複）。
- **`### 參考來源` 用裸 URL**（`- 標題：https://...`），[11] 就認得。來源取「已修（✓ 且非正確）各列」的 URL 欄、去重。
  中文段落裡的裸 URL 後面常接全形標點，寫 URL regex 時字元類別要排除它們。
- **WebFetch 預設只讀前 100000 字。** kubernetes.io 的 Service 頁、Pod API 頁都超過；Endpoints deprecated、
  EndpointSlice 建議、containerPort 那句都在 offset 100000 之後。查不到引文前先用 offset 讀後段。
- **縮寫撞名**：Part 11 的「DR」是災難備援，講 DestinationRule 時寫全名。
- **guide 裡的「Gateway」有兩種**：Istio 的 `networking.istio.io` Gateway 與 Gateway API 的
  `gateway.networking.k8s.io` Gateway。Istio 官方頁講 `targetRefs` 時指的是後者，引用時要寫明。
- **ASCII 圖改字之後要重新對齊**：用 node 量寬度（CJK 算 2）再調空白，不量會歪。
- **拆「錯／對」並列的 yaml 區塊**時，每段註解跟著留在對的那一塊（`# 錯的寫法` 在上、`# ✅` 在下），
  只在中間插 ``` ＋空行＋```yaml，內容一字不動。
- **review 的收斂。** Standards reviewer 不看帳本，會把同一個詞在其他帳本列範圍內的出現也當成本故事的硬性違規；
  判定前先查帳本的行號欄，屬於別列就記觀察、不改。兩輪上限之後才修的東西，下一個 iteration 以同一個 BASE
  （或「那次修正之前」的 commit）再 review 一次即可，不要重做故事、也不要每次從故事起點全量重審 ——
  否則永遠找得到新的邊界情況。第 2 輪只剩「大聲 FAIL」的判斷題時就收，上限之後再改就又是一段沒 review 的程式。
- **反向測插入內容前，先確認插入點不在既有 fence 裡**（guide 開頭就有大段 ASCII 圖的 fence），否則「該 FAIL 卻 PASS」
  看起來像檢查壞了，其實是測錯位置。用 `## Part N` 標題的前一行當插入點比較保險。

### shell／node 的坑（這個 run 踩過的）
- 傳給 `node -e` 的參數以 `-` 開頭會被 node 當成選項吃掉（`bad option`）；測試字串用 `*` 當清單符號。
- 在 bash 的 `node -e '...'` 或 heredoc 裡寫含 `\s`／`\n` 的 regex 或 template literal，跳脫層數會出乎意料
  （實際比對的是 `s*`、寫進檔案的是真換行）。改 validate.sh 的 JS 片段直接用 Edit 工具；
  含單引號的 node 片段用 Write 寫成 repo 內暫存 .js 再跑、跑完刪掉。
- `GUIDE_FENCE_JS` 包在 bash 單引號裡，在裡面加註解不能出現 ASCII 單引號。
- 用 node 腳本改 guide 時，要寫進檔案的反斜線（如 ``）會在跳脫層裡消失（實測留下空的 ``）；改完 grep／印出該處確認，必要時用 `String.fromCharCode(92)`。
- 用 node 寫 ASCII 圖時，行首的 `` 會在跳脫層消失（US-097 實測）；用 `String.fromCharCode(92)` 組，並用 node 量寬度（CJK／全形算 2）確認各行等寬、行數符合驗收條件，否則 review 兩軸都會抓。
- Bash 工具裡不要在 heredoc 前面留 `cat > /dev/null;` 之類讀 stdin 的指令 —— 會卡到 timeout。

## 留給特定帳本列的提醒（修到那一列時照做；做完就把該條刪掉）

（目前沒有待辦提醒。）
