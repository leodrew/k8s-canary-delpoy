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

## 工具限制

這台機器上只有 node / npm。**沒有** kubectl、**沒有** yq、**沒有**可用的 python
（只有 Microsoft Store 的殼，執行時會跳安裝提示而不是跑程式）。不要嘗試安裝它們，
也不要嘗試連叢集 —— 沒有叢集可連，`kubectl apply --dry-run` 也一樣不存在。
YAML 一律用本地的 `node_modules/.bin/js-yaml` 解析，不要用 `npx --yes js-yaml`：
後者每次執行都要連網，斷網就整個閘門失效，那就不叫閘門了。
需要雜湊時用 `node -e` 搭配 `require('crypto')`，不要假設 `sha256sum` 在 Git Bash 下存在。

## 範圍

只動 `dev/k8s`。Spring Boot 後端是另一個 repo（`dev/spring_oauth2_backend`），不要編輯。
`canary-manual/CANARY-COMPLETE.md` 是目標狀態的唯一真實來源，動 manifest 前先讀對應章節。
`canary-manual/` 底下有數份文件掛著「已被取代」橫幅，不要照著它們的操作步驟做。

## YAML 註解的密度

這個 repo 的註解是用來解釋「為什麼」的，而且寫得很長。
以 `canary-manual/track-a/release/20-deployment-stable.yaml` 為基準。
加一個 key 卻沒有註解說明「少了它會壞在哪裡」，就是不符合這個 repo 的風格。
