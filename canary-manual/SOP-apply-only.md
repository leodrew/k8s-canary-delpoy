# 上版 SOP — CD 只能 kubectl apply 的版本（可列印）

> ⚠ **已被 [`CANARY-COMPLETE.md`](CANARY-COMPLETE.md) 取代**（apply-only 的版本）。
> 本文的「canary 不通過」流程是對的，但 **promote 流程（步驟 5a）仍以 `replicas: 0` 收尾**，
> 那是同一個 503 outage 的另一條路徑。正確的排空順序見總集手冊第 5 章步驟 4a。

> 完整說明見 `../k8s-ecosystem-guide.md` 的 Part 15.8–15.13。
> **這份適用於：CD pipeline 只能 `kubectl apply`，不能下 `scale` / `patch` / `rollout undo` / `argo rollouts`。**
> 如果你的 pipeline 能跑任意 kubectl 指令，改用 `SOP.md`（操作簡單很多）。

---

## 兩件事要先分清楚

| | pipeline（CD） | 你本人 |
|---|---|---|
| 能做什麼 | **只有 `kubectl apply`** | `get` / `describe` / `logs`（唯讀） |
| 用途 | **改變狀態** | **驗證狀態** |

本文標記：
- **【改動】** = 編輯 YAML → commit → pipeline apply
- **【驗證】** = 你自己下唯讀指令（pipeline 不需要）

---

## 檔案分層

```
track-a/
├── base/       ← 建置時 apply 一次，之後只有網路/身分設定變更才動
│   ├── 00-serviceaccount.yaml
│   ├── 01-service.yaml
│   ├── 02-destinationrule.yaml
│   └── 03-virtualservice.yaml
└── release/    ← 每次發布都改、都 apply
    ├── 10-configmap-1.2.3.yaml    ← 舊版保留（回滾要用，不能刪）
    ├── 20-deployment-stable.yaml
    └── 21-deployment-canary.yaml
```

**pipeline 的 release stage 只 apply `release/`。**
`base/` 要另外一個手動觸發的 stage，並且加額外核准。

---

## 發布流程（假設現在線上是 1.2.3，要發 1.3.0）

### 步驟 0｜開分支

- [ ] `git checkout -b release/1.3.0`

---

### 步驟 1【改動】新增 ConfigMap

- [ ] **新增**檔案 `release/10-configmap-1.3.0.yaml`
      （從 `10-configmap-1.2.3.yaml` 複製後修改內容）

- [ ] **不要改** `10-configmap-1.2.3.yaml`
      它設了 `immutable: true`，而且回滾要用

---

### 步驟 2【改動】把 canary 指向新版並打開

- [ ] 編輯 `release/21-deployment-canary.yaml`，改**四個**地方：

```diff
 spec:
-  replicas: 0
+  replicas: 1
   template:
     metadata:
       annotations:
-        config-version: "1.2.3"
+        config-version: "1.3.0"
     spec:
       containers:
         - name: app
-          image: your-registry/pmc-epmmformquerygui:1.2.3
+          image: your-registry/pmc-epmmformquerygui:1.3.0
       volumes:
         - name: config
           configMap:
-            name: pmc-epmmformquery-config-1.2.3
+            name: pmc-epmmformquery-config-1.3.0
```

- [ ] **commit 前自己檢查**（最常見的失誤是只改 image 忘了 ConfigMap）：
  ```bash
  grep -n '1\.3\.0\|1\.2\.3' release/21-deployment-canary.yaml
  ```
  應該看到 **三個 1.3.0**，沒有殘留的 1.2.3

- [ ] commit + push + 跑 pipeline（apply `release/`）

- [ ] **【驗證】** canary 起來了、三處都是新版：
  ```bash
  kubectl -n ea-pmc get deploy -l app=pmc-epmmformquerygui -o custom-columns=\
  'NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
  ```

> 此時正式流量 100% 在 stable，**canary 沒有任何正式流量**。

---

### 步驟 3【驗證】確認 cookie 路由有效（不要跳過）

- [ ] 執行
  ```bash
  kubectl -n ea-pmc run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- sh -c '
    echo "--- 不帶 cookie ---"
    curl -sS -o /dev/null -D - \
      http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
    echo "--- 帶 cookie ---"
    curl -sS -o /dev/null -D - -H "Cookie: canary=always" \
      http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
  '
  ```
  期望：第一次 `stable`，第二次 `canary`

- [ ] **沒有建立 Pod 的權限？** 改用瀏覽器：
  開正式網址 → F12 → Network → 看 `x-app-track` 應為 `stable`；
  照 `pilot-run-guide.md` 種 cookie → 重整 → 應變成 `canary`

> **這一步沒過就不要往下走** —— 否則 pilot 使用者驗的其實是舊版。

---

### 步驟 4｜請使用者做 pilot run

- [ ] 把 `pilot-run-guide.md` 發給驗證人員
- [ ] 提醒先自證（F12 看 `x-app-track: canary`）再開始驗
- [ ] 收回填好的驗證清單

- [ ] **【驗證】**期間觀察 log：
  ```bash
  kubectl -n ea-pmc logs -l version=canary -c app --tail=100 -f
  ```

---

### 步驟 5a【改動】簽核通過 → promote

- [ ] 編輯 `release/20-deployment-stable.yaml`，改**三處版本號**：

```diff
       annotations:
-        config-version: "1.2.3"
+        config-version: "1.3.0"
       containers:
         - name: app
-          image: your-registry/pmc-epmmformquerygui:1.2.3
+          image: your-registry/pmc-epmmformquerygui:1.3.0
       volumes:
         - name: config
           configMap:
-            name: pmc-epmmformquery-config-1.2.3
+            name: pmc-epmmformquery-config-1.3.0
```

- [ ] 編輯 `release/21-deployment-canary.yaml`，**關掉 canary**：

```diff
 spec:
-  replicas: 1
+  replicas: 0
```

> canary 的三處版本號**留在 1.3.0 不用改回去**，下次發布再一起改成 1.4.0。

- [ ] 檢查：
  ```bash
  grep -n '1\.3\.0\|1\.2\.3' release/20-deployment-stable.yaml
  ```
  三個 1.3.0，沒有殘留

- [ ] commit（訊息帶版本號，例如 `release: promote pmc-epmmformquerygui 1.3.0 to stable`）
- [ ] 跑 pipeline

- [ ] **【驗證】**
  ```bash
  kubectl -n ea-pmc get deploy -l app=pmc-epmmformquerygui -o custom-columns=\
  'NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'

  kubectl -n ea-pmc get pods -l app=pmc-epmmformquerygui -L version -w
  ```
  stable 的 IMAGE 和 CONFIG 都要是 1.3.0，READY = replicas

---

### 步驟 5b【改動】簽核不通過 → 關掉 canary

- [ ] 只改一個地方：

```diff
 # release/21-deployment-canary.yaml
 spec:
-  replicas: 1
+  replicas: 0
```

- [ ] commit + apply
- [ ] 使用者完全無感（正式流量本來就沒進 canary）
- [ ] 記錄失敗原因，修好後回到步驟 1

---

### 步驟 6【改動】promote 之後才發現問題 → 回滾

- [ ] 找出 promote 的 commit：
  ```bash
  git log --oneline -- release/20-deployment-stable.yaml
  ```

- [ ] revert 它：
  ```bash
  git revert <commit-sha>
  git push
  ```

- [ ] 重跑 pipeline apply `release/`

- [ ] **【驗證】** stable 回到 1.2.3：
  ```bash
  kubectl -n ea-pmc get deploy pmc-epmmformquerygui-stable -o custom-columns=\
  'IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
  ```

> **revert 會把 image 和 ConfigMap 一起改回去**，不會出現「只回滾了 image、設定還是新版」的半吊子狀態。

---

## ⚠ 絕對不要做的三件事

| 不要做 | 為什麼 |
|---|---|
| **刪掉舊的 ConfigMap** | 回滾時 Deployment 會引用回舊名稱，刪掉就回不去了。**保留至少 3 個版本** |
| **在 release stage apply `base/`** | 會動到 VirtualService，一個手滑影響所有使用者 |
| **只改 image 不改 ConfigMap** | 新版程式配舊版設定，可能啟動失敗或行為異常 |

---

## 操作對照總表

| 操作 | 改哪個檔 | 改什麼 |
|---|---|---|
| 部署到 canary | 新增 `10-configmap-<新版>.yaml`<br>改 `21-deployment-canary.yaml` | 三處版本號 + `replicas: 0` → `1` |
| promote | 改 `20-deployment-stable.yaml`<br>改 `21-deployment-canary.yaml` | 三處版本號<br>`replicas: 1` → `0` |
| **canary 不通過** | 改 `21-deployment-canary.yaml` | **image + 三處版本號改回 stable 版<br>`APP_CANARY_ENABLED` → `"false"`**<br>**不是 `replicas: 0`**，見下方 |
| 加 / 移除 pilot 使用者 | 改 `runtime/05-configmap-canary-pilot.yaml` | 改名單 → apply → 等 ≤90 秒。**不重啟任何 pod** |
| promote 後回滾 | `git revert` | — |
| 改網路設定 | `base/` 底下的檔 | 用單獨的 stage apply |

---

## Pilot 名單維護

名單放在 `track-a/runtime/05-configmap-canary-pilot.yaml`，**跟發布流程完全分開**：

| 目錄 | 變更頻率 | apply 時機 |
|---|---|---|
| `base/` | 極低（網路設定變更） | 單獨 stage |
| `release/` | 每次發布 | 發布 pipeline |
| **`runtime/`** | **pilot 期間可能一天數次** | **獨立，不經過發布流程** |

```
改 track-a/runtime/05-configmap-canary-pilot.yaml
  → commit
  → kubectl apply -f track-a/runtime/
  → 等 ≤ 90 秒（kubelet 同步 60s + app reload 30s）
```

**不需要重啟任何 pod，不影響正式流量。**

| 動作 | 什麼時候生效 |
|---|---|
| **加入**一個人 | 他**下次登入**時（已登入的要先登出） |
| **移除**一個人 | 他**下一次頁面導航**時自動被送回 stable（不用他配合） |

名單一行一個 Keycloak 的 `preferred_username`（使用者登入時打的帳號名），
不是 OIDC 的 `sub`。確認名單真的讀到了：

```bash
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui-stable | grep 'roster reloaded'
# canary pilot roster reloaded: 3 user(s)
```

> 讀不到檔案 = **空名單**（沒有人進 canary），不是「全部都是」。這是刻意的 fail-safe。

---

## 【重要】canary 不通過的關閉流程 —— 自動分流上線後已改寫

### 為什麼不能再用 `replicas: 0`

自動分流之前，cookie 是 pilot 使用者自己種的，只有 2、3 個人，而且他們**知道**自己種了。
現在 cookie 是系統自動發的，持有者可能是幾十個人，**而且他們不知道自己有**。

`replicas: 0` 之後 `subset: canary` 沒有任何 endpoint，但
`base/03-virtualservice.yaml` 的規則 1 還在：

```
手上還有 cookie 的人
  → 規則 1 仍然把他們送進 subset: canary
  → 沒有 endpoint
  → 503（access log 的 response_flags = UH）
  → 他們永遠打不到 stable，app 端「清 cookie」的邏輯根本沒機會執行
  → 卡死到 cookie 過期為止（8 小時）
```

**這不是「比較不方便」，這是 outage。**

### 正確做法：換 image，不是 scale 到 0

改 `track-a/release/21-deployment-canary.yaml`：

1. `image` → 改回目前 stable 的版本
2. `config-version` annotation + `configMap.name` → 一併改回 stable 的版本
3. `APP_CANARY_ENABLED` → `"false"`

→ commit → apply

效果：

```
canary pod 仍在跑，但跑的是「好的程式碼」
  → 使用者不會 503，而且看到的是正確的舊版畫面
  → CanaryEvictionFilter 看到 enabled=false
  → 下一次頁面導航：清 cookie + 302
  → 使用者回到 stable
```

**一次導航就排空，零 503。** 完全符合 apply-only 的限制 —— 一樣只是改 YAML + apply。

等確定沒有人還帶著 cookie（或過了 8 小時 Max-Age）之後，再從容地把 `replicas` 改回 0。

### 緊急時的第二張牌

如果情況緊急到連「等一次導航」都不能接受，唯一瞬間生效、不依賴 app 的手段是把
`base/03-virtualservice.yaml` 規則 1 的 destination 改成 `subset: stable`。

它在 `base/`，依規範要用單獨 stage apply，所以列為第二道而不是第一道 ——
但值班的人要知道有這張牌。

### 三種手段對照

| 手段 | 生效速度 | 對 cookie 持有者 | 適用 |
|---|---|---|---|
| `APP_CANARY_ENABLED=false` + image 改回 stable | 下一次導航 | 乾淨排空 | **預設做法** |
| 規則 1 改指向 `subset: stable` | 瞬間 | 立刻全部回 stable | 緊急 |
| `replicas: 1 → 0` | 瞬間 | **503 UH，卡到 cookie 過期** | **自動分流上線後不可單獨使用** |

---

## 出事時第一時間做什麼

| 症狀 | 立刻做 |
|---|---|
| pilot 使用者說壞了 | image 改回 stable 版 + `APP_CANARY_ENABLED="false"` → commit → apply。**不要用 `replicas: 0`**，見上方 |
| promote 後正式使用者說壞了 | `git revert` promote 的 commit → apply |
| Pod 卡在 `ContainerCreating` | `kubectl describe pod` 看 Events —— 多半是 ConfigMap 不存在（版本號打錯，或被刪了） |
| 大量 503 | `kubectl get endpoints` —— 多半是 subset 對不到 pod |
| 帶了 cookie 還是進 stable | 見 guide 14.6 與 README 排查表 |
| 使用者一直被登出 | canary 開超過 1 個 replica？見 guide 14.5 前提 1 |
| 在名單裡卻進不了 canary | `kubectl logs deploy/...-stable \| grep 'roster reloaded'` 確認名單有讀到；名單用的是 Keycloak 帳號名（`preferred_username`），不是 sub；改名單後使用者要**重新登入** |
| pilot 使用者被踢來踢去 | 兩軌讀到的名單不一致（reload 時間差）。等 90 秒後仍如此就查 ConfigMap 是否兩邊都掛到了 |
| 剛登入完又被要求登入一次 | 跨軌切換會重新認證一次；若那一刻 Keycloak SSO session 剛好過期就會這樣。重登即可，非故障 |
