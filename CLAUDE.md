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
- **`TRACK_A_CONFIGMAPS`** —— ConfigMap 檔案清單。ConfigMap 拆成 `-stable` / `-canary`
  兩份之後，把新檔名加進這個陣列就好，所有既有的 key 檢查會自動對兩份都跑，
  不需要把檢查複製一遍。
- **`BOTH_TRACK_CONFIGMAPS`** —— 涵蓋 track-a ＋ track-b 兩份 ConfigMap 的清單，
  給「兩個 track 都有同一個回歸」的檢查用（目前是 `user-name-attribute`）。
  刻意跟 `TRACK_A_CONFIGMAPS` 分開：後者的語意是「track-a 必須完整」，把 track-b
  塞進去會讓附錄 C 的每一項 key 檢查都跑到 track-b 上，噴出一整排假失敗
  —— track-b 這次沒有被補齊。
- **`cm_label <檔案路徑>`** —— 兩個 track 的 ConfigMap 檔名一模一樣（都叫
  `10-configmap-1.2.3.yaml`），所以跨 track 的檢查名稱不能用 `basename`：
  兩行 PASS 會長得完全一樣，失敗時看不出是哪一份壞了。這個 helper 印出
  `track-a/10-configmap-1.2.3.yaml`。
- **`check "<名稱>" <指令> [參數...]`** —— 指令以參數陣列直接執行，**不經過 eval**，
  所以可以原樣傳一整段帶引號的 `node -e` 斷言進去。需要 pipeline 或 shell 語法時
  再明確包一層 `bash -c`。

新檢查加在腳本的 `# 之後的檢查加在這裡` 標記區段、總結區塊之前，開一個
`== [n] 說明 ==` 區段並寫清楚「這個檢查在防什麼」。

**盡量比對「值」而不只是「key 存在」。** 這個 repo 最危險的一類錯誤是「key 被刪掉之後
Spring 用自己的預設值頂上」—— 設定看起來還在，行為已經變了。`redirect-uri` 就是標準
案例：少了 `/gui_epmmFormQuery` 前綴，登入 callback 進不來，而錯誤訊息不會指向 ConfigMap。

加完檢查一定要**反向測一次**：把該 key 改壞、跑一次確認真的 FAIL、再還原。
一個永遠綠燈的檢查比沒有檢查更糟，因為它會讓人以為有防護。

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

## 範圍

只動 `dev/k8s`。Spring Boot 後端是另一個 repo（`dev/spring_oauth2_backend`），不要編輯。
`canary-manual/CANARY-COMPLETE.md` 是目標狀態的唯一真實來源，動 manifest 前先讀對應章節。
`canary-manual/` 底下有數份文件掛著「已被取代」橫幅，不要照著它們的操作步驟做。

## YAML 註解的密度

這個 repo 的註解是用來解釋「為什麼」的，而且寫得很長。
以 `canary-manual/track-a/release/20-deployment-stable.yaml` 為基準。
加一個 key 卻沒有註解說明「少了它會壞在哪裡」，就是不符合這個 repo 的風格。
