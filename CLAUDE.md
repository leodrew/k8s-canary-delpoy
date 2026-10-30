# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# dev/k8s — Claude / agent guidance

## 這個 repo 沒有 build，但有一個閘門

`dev/k8s` 只有 Kubernetes / Istio 的 YAML、shell 腳本和中文文件 —— 沒有編譯器、
沒有測試框架、沒有 package 要 build。這個 repo 的 typecheck 等價物是：

```bash
bash scripts/validate.sh      # 或 npm run validate
```

從 repo root 執行，exit 0 = 通過。腳本自己會 cd 到 repo root，所以從哪裡呼叫都一樣。
第一次使用前要先在 repo root 跑一次 `npm install`（js-yaml 是 devDependency；
`node_modules/` 不進版控，`package-lock.json` 有）。

腳本**沒有**「只跑某一項」的參數 —— 刻意不用 `set -e`，每次都跑完全部檢查（約 20 秒），
每項印一行 `PASS <名稱>` / `FAIL <名稱>`，失敗項底下縮排印出原因。要看某一區段就
`bash scripts/validate.sh 2>&1 | grep -A8 FAIL`，不要為了這個去加過濾參數。

## Repo 地圖（要讀好幾個檔才拼得出來的部分）

- **`canary-manual/track-a/` 與 `track-b/` 是同一件事的兩種實作，互斥。** track-a 是
  兩份 Deployment（stable / canary）＋ Istio cookie 路由，只需要現有的 Istio；track-b
  是 Argo Rollouts 的一份 Rollout。兩者同時存在時兩個 controller 會搶 pod。
  **目前所有修正都只做在 track-a**；track-b 的 ConfigMap 還沒依附錄 C 補齊，只有
  `BOTH_TRACK_CONFIGMAPS` 那幾項回歸檢查涵蓋它。
- **track 底下按變更頻率分三層**（CANARY-COMPLETE.md 第 2 章）：`base/`（SA、Service、
  DestinationRule、VirtualService；極少動）、`release/`（ConfigMap ＋ Deployment；每次
  發布）、`runtime/`（pilot 名單 ConfigMap；pilot 期間一天改數次，**刻意不掛 config-hash**，
  改名單不該重啟 pod）。檔名的數字前綴就是 `kubectl apply -f <dir>/` 的套用順序 ——
  ConfigMap（`10-`/`11-`）必須先於 workload（`20-`/`21-`），新增檔案時照這個規則編號。
- **「軌」的權威來源是 pod template 的 `version` label**（DestinationRule 用它分 subset）。
  pilot 使用者靠 `canary=always` cookie 打到 canary；正式流量的 canary 權重永遠是 0。
- **整個 repo 只有 image tag 一處帶版本號。** ConfigMap 名稱固定為 `-stable`/`-canary`
  （US-008），Deployment 靠 `config-hash` annotation 感知設定變更（US-009）。
- **文件的地位：**
  - `canary-manual/CANARY-COMPLETE.md` —— 目標狀態的唯一真實來源。3.1（設定怎麼載入）、
    3.5（完整的目標 ConfigMap）、附錄 C（必備 key 與「漏掉會退回什麼」）最常用到。
  - `canary-manual/pilot-run-guide.md` —— 保留，讀者是做 pilot run 的使用者，不是維運。
  - `canary-manual/README.md`、`SOP.md`、`SOP-apply-only.md`、`canary-ops-runbook.md`
    —— 掛「已被取代」橫幅，含已知會造成 503 outage 的步驟（`replicas: 0`、`rollout undo`）。
  - `bffautocanarydesign.md` —— 設計提案，不是操作手冊；`k8s-ecosystem-guide.md` ——
    onboarding ＋ 速查；`tasks/prd-*.md` —— 原始需求。
- **已知過時、還沒修的東西**（不要把它們當成現況的描述）：
  - `canary-manual/scripts/canary.sh` 仍假設 US-008 之前的版本化 ConfigMap 與
    `config-version` annotation（「三處同步」），也還留著造成 outage 的指令 ——
    那是 `ralph/prd.json` 裡尚未完成的 US-010。
  - 上層 `dev/CLAUDE.md`（描述 Spring 專案）說 Deployment 用
    `SPRING_CONFIG_ADDITIONAL_LOCATION`。**在這個 repo 那是錯的**：US-006 已改成
    `SPRING_CONFIG_LOCATION`（replace 語意），validate.sh 的檢查 [6] 會擋改回去的寫法。
    兩份說法衝突時以這份和 CANARY-COMPLETE.md 為準。

## Ralph 工作流（`ralph/`）

這個分支的改動是由 Ralph 自動代理迴圈逐個 user story 完成的：`ralph/prd.json` 是故事
清單（`passes` 欄位標示完成與否），`ralph/progress.txt` 是**只能附加**的進度紀錄，
開頭的 Codebase Patterns 區段是累積下來的慣例，`ralph/CLAUDE.md` / `prompt.md` 是
代理的指令，`ralph/ralph.ps1` 是迴圈本體。照這個流程做一個故事時，commit 分兩個：
`feat: US-0xx - <故事標題>`（改動＋對應的 validate.sh 檢查）、然後
`chore: US-0xx - mark story complete and log progress`（只動 `prd.json` 與 `progress.txt`）。

## 改 manifest 就要加檢查，而且要在同一個 commit

這是這個 repo 最重要的規則。每一次修改 `canary-manual/` 底下的 manifest，都必須在
**同一個 commit** 裡往 `scripts/validate.sh` 加上對應的斷言。原因是這裡沒有別的
安全網：一個被誤刪的 ConfigMap key 要等到 `kubectl apply` 之後 Pod 起不來才會被
發現，而一個被改回去的設定值（例如 `user-name-attribute` 從 `sub` 變回
`preferred_username`）可能永遠不會被發現。改了 manifest 卻沒加檢查，這件事就沒做完。

## 斷言 ConfigMap 內容時，解析 YAML，不要 grep

真正的設定藏在 ConfigMap 的 `data["application.yml"]` 裡 —— 那是一份被當成字串塞進
另一份 YAML 的 YAML。要先解析外層檔案、再解析那個字串、最後對物件下斷言。
直接 grep 原始檔會被「被註解掉的行」騙過去（這些檔案裡有好幾處這種行），給出假的 PASS。

## 擴充 `scripts/validate.sh` 的既有工具

不要每加一個 key 就重寫一次「解析外層 → 解析內層 → 下斷言」的樣板。腳本裡已經有：

- **`assert_cm_key <dotted.key.path> [期望值]`** —— 對 `TRACK_A_CONFIGMAPS` 陣列裡的
  每一份 ConfigMap 各跑一次檢查。省略期望值時只檢查 key 存在。行為上有三種結果要分清楚：
  key 沒寫 → 失敗；寫了 key 但沒有值（解析成 `null`）→ 失敗；寫成空字串 `""` → 通過
  （`app.security.required-role` 就是刻意的空字串）。
- **`assert_cm_key_contains <dotted.key.path> <子字串>`** —— 值會演進、但骨架不能掉的
  設定用這個。目前只有 `app.security.csp-policy`：那條政策照設計就是會被改的
  （附錄 A.2、3.5.1 說 canary 那份可以先加新 origin），整串釘死等於每次調政策都要改
  腳本；但只檢查 key 存在又擋不住 `csp-policy: ""` —— 空字串正好就是「CSP header
  完全不送」的那個值，而 `assert_cm_key` 會放它過。
- **`TRACK_A_CONFIGMAPS`** —— track-a 的 ConfigMap 檔案清單，US-008 之後是兩份
  （`10-configmap-stable.yaml` / `11-configmap-canary.yaml`）。所有 key 檢查都對這個
  陣列裡的每一份各跑一次，所以新增一份 track-a ConfigMap 時只要把檔名加進來，
  附錄 C 的檢查就自動涵蓋它，不需要把檢查複製一遍。
  **加的時候 `BOTH_TRACK_CONFIGMAPS` 也要一起加**：漏掉前者會少掉附錄 C 的 key 檢查，
  漏掉後者會少掉「不得寫回 `preferred_username`」和「死設定不得復活」——
  兩種都是無聲地少檢查一整份檔案，不會有任何 FAIL 提醒你漏了。
- **`BOTH_TRACK_CONFIGMAPS`** —— 涵蓋 track-a（`-stable` / `-canary` 兩份）＋ track-b 的清單，
  給「兩個 track 都有同一個回歸」的檢查用（目前是 `user-name-attribute`）。
  刻意跟 `TRACK_A_CONFIGMAPS` 分開：後者的語意是「track-a 必須完整」，把 track-b
  塞進去會讓附錄 C 的每一項 key 檢查都跑到 track-b 上，噴出一整排假失敗
  —— track-b 這次沒有被補齊。
- **`assert_cm_key_absent <dotted.key.path> <為什麼不能有>`** —— 反方向的斷言：這個 key
  **存在就是失敗**。給「已經刪掉、而且不可以長回來」的死設定用（`app.cors`、`app.sso`、
  `app.test-endpoints`）。跑的是 `BOTH_TRACK_CONFIGMAPS`。第二個參數會原樣印進 FAIL
  訊息，寫「為什麼這塊是死的」，讓想加回來的人在錯誤訊息裡就讀到理由。
  注意「寫了 key 但沒有值」（只留一行 `cors:`）算**失敗** —— 那仍然是一個會被讀到的
  key，語意跟 `assert_cm_key` 那邊「空字串算通過」是不同的判斷，不要混用。
- **`TRACK_A_DEPLOYMENTS`** —— track-a 那兩份 Deployment（`20-deployment-stable.yaml`
  ／`21-deployment-canary.yaml`）的清單，給「兩份 Deployment 都要有同一項設定」的
  檢查用（目前是 `SPRING_CONFIG_LOCATION`；探針路徑、`config-hash` 註解也會用到）。
  這兩個檔名彼此不同，所以這一組的檢查名稱直接用 `basename` 就夠，不必走 `cm_label`。
- **`cm_label <檔案路徑>`** —— ConfigMap 的檢查名稱要帶上 track，不要只用 `basename`。
  US-008 之前兩個 track 的檔名一模一樣（都叫 `10-configmap-1.2.3.yaml`），兩行 PASS
  會長得完全相同、失敗時看不出是哪一份壞了；現在 track-a 那兩份改名成 `-stable`／
  `-canary` 之後檔名不再撞，但「哪一軌」仍然是讀 FAIL 訊息時第一個要知道的事，
  而且 track-b 哪天照附錄 C 補齊、跟著改名就又撞回去了。這個 helper 印出
  `track-a/10-configmap-stable.yaml`。
- **`check "<名稱>" <指令> [參數...]`** —— 指令以參數陣列直接執行，**不經過 eval**，
  所以可以原樣傳一整段帶引號的 `node -e` 斷言進去。需要 pipeline 或 shell 語法時
  再明確包一層 `bash -c`。

新檢查加在腳本的 `# 之後的檢查加在這裡` 標記區段、總結區塊之前，開一個
`== [n] 說明 ==` 區段並寫清楚「這個檢查在防什麼」。

**盡量比對「值」而不只是「key 存在」。** 這個 repo 最危險的一類錯誤是「key 被刪掉之後
Spring 用自己的預設值頂上」—— 設定看起來還在，行為已經變了。`redirect-uri` 就是標準
案例：少了 `/gui_epmmFormQuery` 前綴，登入 callback 進不來，而錯誤訊息不會指向 ConfigMap。

**兩個互相綁定的欄位，要拿它們互相對照，不要各自釘一個常數。** manifest 裡有幾組值
是必須一致的 —— `SPRING_CONFIG_LOCATION` 的路徑與 `config` volumeMount 的
`mountPath` 是最典型的一組。把兩邊各自跟一個寫死的字串比對，只擋得住「兩邊都改錯」；
真正會發生的是「改了 mountPath 卻沒回頭改 env」，而改 mountPath 的人根本不會想到
env 也綁著這個值。正確的寫法是從 manifest 讀出 `mountPath`、推出 env 應該長什麼樣，
再跟實際的 env 比 —— 這樣任何一邊被單獨改動都會 FAIL。

**刪掉設定也是一種修改，一樣要加檢查 —— 而且是反方向的那種。** 刪除死設定
（沒有任何程式讀的 key）之後，唯一會出事的方式是有人把它加回來；而加回來同樣不會
產生任何症狀，所以沒有人會發現。這種情況用 `assert_cm_key_absent`，並且把「為什麼
這塊是死的」寫進 FAIL 訊息裡。復活最常見的路徑是「從舊版本或另一個 track 整段複製
設定過來」，所以這類檢查要跑 `BOTH_TRACK_CONFIGMAPS` 而不是只擋一個 track。

**ConfigMap 拆成 `-stable` / `-canary` 之後有四條不能破的規則**（檢查 [8] 各釘一條，
四條被破壞時都不會有指向真正原因的錯誤訊息）：

1. **不得有 `immutable: true`。** 名稱固定代表這個物件會被同一個名字反覆 apply 覆寫，
   而 immutable 的 ConfigMap 建立後連 `data` 都不能改 —— `kubectl apply` 會直接以
   `field is immutable` 失敗，時間點是**發布當下**，唯一的出路是先 delete 再 create，
   那個空窗期裡任何一個掛著它的 pod 只要重啟就卡在 `ContainerCreating`。
2. **`metadata.name` 不得帶版本號**（連 label 也不要留 `config-version`）。版本號只留在
   image tag 一處；帶回來就是把「三處人工同步」整套問題帶回來，而且跟 cleanup 互咬。
3. **兩份的 `data['application.yml']` 目前必須逐字相同。** 拆檔案本身不該引進設定差異。
   這條斷言**預期會有壽命** —— canary 遲早要分歧（3.5.1 允許 `csp-policy`、
   `downstream`／`third-party` 的 `base-url`、`logging.level.*` 不同）。那一天要把它
   **改寫成「只有那幾個 key 可以不同」，不是刪掉**：刪掉之後兩份開始無聲漂移，而 promote
   的做法是把 canary 的 `data` 整段複製進 stable，差異越多越容易把不該帶的一起帶過去。
4. **每份 Deployment 掛自己那一軌的 ConfigMap。** 掛錯軌是這四條裡最安靜的一種：pod
   正常起來、探針正常綠燈，只是讀著另一軌的設定 —— 症狀是「改了 canary 的設定卻沒生效」。
   檢查的寫法不是各自釘常數，而是從 Deployment 的 pod template `version` label 推出
   它屬於哪一軌（那個 label 也是 DestinationRule 分 subset 的依據，是全 repo 對「軌」
   最權威的來源），再拿 `volumes[config].configMap.name` 去查 ConfigMap 的 `labels.track`。
**跨檔案的對照要走「Deployment 引用的名字 → ConfigMap 的 `metadata.name`」，不要靠檔名。**
Deployment 不認識檔案，它引用的是 `volumes[config].configMap.name`。所以要拿 ConfigMap 的
內容來推導 Deployment 應該長什麼樣時（探針路徑推自 `management.endpoints.web.base-path`，
US-009 的 config-hash 推自 `data['application.yml']`），正確的做法是先把
`TRACK_A_CONFIGMAPS` 每一份的 `metadata.name` 建成索引，再用 Deployment 讀到的名字去查。
這樣 US-008 把 ConfigMap 拆成 `-stable` / `-canary` 之後，每一份 Deployment 會自動對到
自己那一軌，檢查完全不用改。**推導的來源查不到時必須 FAIL**（印出「這個名字不在
`TRACK_A_CONFIGMAPS` 裡」），不可以 skip —— 查不到就跳過等於改個名字就能讓檢查靜靜消失，
那正是「永遠綠燈的檢查」的另一種長相。

加完檢查一定要**反向測一次**：把該 key 改壞、跑一次確認真的 FAIL、再還原。
一個永遠綠燈的檢查比沒有檢查更糟，因為它會讓人以為有防護。
「某個字串不得出現在任何 manifest 裡」這類掃描檢查，一樣要解析 YAML 之後再看
（對整份解析結果 `JSON.stringify` 再找子字串就夠了），不要 grep 原始檔：這個 repo
的慣例是在改掉一個設定的地方留一整段註解解釋「原本是什麼、為什麼那樣是錯的」，
那段註解本身就含有要禁止的字串，grep 版本會被自己的說明文字打到、變成永遠 FAIL。
掃描如果有刻意排除的檔案（例如 `SPRING_CONFIG_ADDITIONAL_LOCATION` 的掃描排除了
`track-b/release/20-rollout.yaml`：track-b 的 ConfigMap 還沒依附錄 C 補齊，
在那個狀態下把它翻成 replace 語意會讓設定悄悄退回 Java 預設值，是把 manifest 改得
更糟），要把「為什麼排除」和「什麼條件下可以拿掉」一起寫在排除清單旁邊。

反向測「不得存在」這類檢查時，除了「整塊加回來」，記得也測
「只留一行 `cors:`（key 有、值是 null）」和「整塊被註解掉」—— 後者必須維持 PASS，
那正是這個檢查解析 YAML 而不是 grep 的意義。

## 改了 ConfigMap 的內容，就要跑 `scripts/sync-config-hash.sh`

ConfigMap 的名稱固定之後（US-008），改設定內容【不會】改到 pod template 的任何欄位，
而 `kubectl apply` 只在 pod template 變了的時候才滾動更新、Spring 又只在啟動時讀一次
設定檔 —— 所以「改 ConfigMap → apply → 什麼事都沒發生 → 新設定沒有生效」，而且沒有
錯誤訊息、`kubectl get` 也看不出異常。兩份 Deployment 的 `config-hash` annotation
（ConfigMap `data['application.yml']` 的 sha256 前 8 碼）就是把那條因果鏈接回來的東西。

```bash
bash scripts/sync-config-hash.sh     # 改完 ConfigMap 跑一次；從哪個目錄呼叫都可以
```

**ConfigMap 與 Deployment 的改動必須放進同一個 commit** —— 那是 `git revert` 能一次
回滾兩者的前提（CANARY-COMPLETE.md 2.2）。`kubectl rollout undo` 因此是禁止動作：
它還原 pod template（含舊的 hash）但 ConfigMap 內容已經是新的，pod 用舊 hash 重啟卻
掛到新設定，一樣沒有錯誤訊息。忘了跑同步腳本會被 `validate.sh` 的檢查 [9] 擋下來
（它自己重算一次跟檔案裡的值比對）—— 那是這個安靜失效唯一的攔截點。

雜湊的對象是**解析後**的 `data['application.yml']` 字串，不是原始檔的位元組。理由有二：
叢集那一端（第 6.3 節的 `kubectl get cm -o jsonpath=... | sha256sum | cut -c1-8`）算的
也是這個，兩邊可以直接對照；而且對原始檔算的話，改一行註解就會讓 hash 變 → 全部 pod
滾動重啟，但那不是設定變更。

## 腳本改 manifest：文字取代 ＋ 重新解析自我驗證，不要 `y.dump()`

`sync-config-hash.sh` 是這個 repo 第一支會**改寫** manifest 的腳本，它的寫法值得照抄：

- **只取代那一行，不要「解析 → 改物件 → dump 回去」。** 這個 repo 的 manifest 有大量
  中文註解在解釋「為什麼」，`y.dump()` 一次就全部消失 —— 而那些註解是這裡最貴的資產。
  取代時用捕獲群組把行尾的 `\r` 原樣接回去，CRLF 的工作目錄才不會產生整檔 diff。
- **先數過再取代。** 目標字串出現 0 次或 2 次以上都要**失敗並說明**，不要「有就改、
  沒有就算了」。找不到時的正確反應是叫人自己把那一行連同註解加上去（註解只有人寫得
  出來），而不是自動插入一個沒有註解的 key。
- **寫完重新解析，確認改到的是預期的那個位置。** 文字取代永遠有「改到長得很像的另一個
  地方」的風險，而 `config-hash` 正好有一個看起來一樣、實際完全沒有作用的位置：
  Deployment 自己的 `metadata.annotations`（那不是 pod template 的一部分，改了不會
  觸發任何滾動更新）。重新解析後對 `spec.template.metadata.annotations` 下斷言才擋得住。
- **要冪等。** 連跑兩次第二次不得產生任何 diff，否則「跑一次同步腳本」會變成製造雜訊
  diff 的動作，而雜訊 diff 會讓人在 review 時看不見真正的改動。

在 `validate.sh` 裡驗證這種會改檔案的腳本，用**備份 → 跑 → 比對位元組 → 無條件還原**
（`mktemp -d` ＋ `cp` ＋ `cmp` 都是 bash 這邊在處理，不會踩到 node 看不見 `/tmp` 的坑）。
**不要用 `git diff --quiet` 判定**：它比對的是 HEAD，只要工作目錄有任何未 commit 的改動
就會失敗 —— 而「改完 manifest 跑一次 validate.sh」正是這個 repo 的標準工作流程，
那會變成一個在正常開發途中永遠是紅的檢查，下場是被刪掉或被無視。備份比對問的是
「跑這支腳本有沒有改到東西」，那才是冪等的定義，而且不管工作目錄乾不乾淨都成立。
還原要無條件做：品質閘門不應該順手改你的工作目錄，即使改對了也一樣。

## 工具限制

這台機器上只有 node / npm。**沒有** kubectl、**沒有** yq、**沒有**可用的 python
（只有 Microsoft Store 的殼，執行時會跳安裝提示而不是跑程式）。不要嘗試安裝它們，
也不要嘗試連叢集 —— 沒有叢集可連，`kubectl apply --dry-run` 也一樣不存在。
YAML 一律用本地的 `node_modules/.bin/js-yaml` 解析，不要用 `npx --yes js-yaml`：
後者每次執行都要連網，斷網就整個閘門失效，那就不叫閘門了。
需要雜湊時用 `node -e` 搭配 `require('crypto')`，不要假設 `sha256sum` 在 Git Bash 下存在。

**node 是 Windows 執行檔，Git Bash 的 `/tmp` 它看不到** —— node 會把 `/tmp/x` 解讀成
`C:\tmp\x`，於是 shell 那邊寫出去的暫存檔在 node 這邊是 `ENOENT`（實測過）。
要在 shell 與 node 之間傳檔案，用 repo 內的相對路徑，用完刪掉。

**Git Bash 會竄改傳給 node 的參數**（實測，比上面那個 `/tmp` 的坑更容易中）。MSYS2 在把
參數交給 Windows 原生執行檔之前，會把長得像 POSIX 絕對路徑的字串翻譯成 Windows 路徑：

```
node -e '...' "/gui_epmmFormQuery"   →  node 實際收到 "C:/Program Files/Git/gui_epmmFormQuery"
```

這個 repo 的設定值有一大半是 `/gui_epmmFormQuery` 開頭的，所以任何「把期望值當參數傳進
node 去比對」的斷言都會【永遠 FAIL】，而且錯誤訊息會印出 `C:\Program Files`，看起來像是
ConfigMap 被寫壞了。改用環境變數傳值也救不了（環境變數的值一樣會被轉換）。
`scripts/validate.sh` 開頭已經 `export MSYS2_ARG_CONV_EXCL='*'` 關掉整支腳本的轉換，
新增檢查時不要拿掉那一行；在腳本外面手動跑 `node -e` 驗證時則要自己記得加。

**行尾：** 這台機器是 `core.autocrlf=true`，YAML / markdown checkout 出來是 CRLF；
`.gitattributes` 把 `*.sh` 釘成 LF（否則 Linux / CI 上會死在 `bad interpreter`）。
新增 shell 腳本不用另外設定，但改寫 manifest 的腳本要把行尾的 `\r` 原樣接回去（見上一節）。

## 範圍

只動 `dev/k8s`。Spring Boot 後端是另一個 repo（`dev/spring_oauth2_backend`），不要編輯。
`canary-manual/CANARY-COMPLETE.md` 是目標狀態的唯一真實來源，動 manifest 前先讀對應章節。
`canary-manual/` 底下有數份文件掛著「已被取代」橫幅，不要照著它們的操作步驟做。

`.claude/skills/` 底下的 skill 是由 `skills-lock.json` 從上游安裝的，**本地有改過**：
`to-spec` 與 `retro` 刪掉了 `disable-model-invocation: true`，好讓 Ralph loop 能自己呼叫。
重新安裝或更新 skill 會把那一行蓋回來，loop 的最後一個故事（retro）就會叫不到 skill ——
更新 skill 之後記得檢查這兩份的 frontmatter。

## YAML 註解的密度

這個 repo 的註解是用來解釋「為什麼」的，而且寫得很長。
以 `canary-manual/track-a/release/20-deployment-stable.yaml` 為基準。
加一個 key 卻沒有註解說明「少了它會壞在哪裡」，就是不符合這個 repo 的風格。
