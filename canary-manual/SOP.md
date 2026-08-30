# 上版 SOP（可列印）

> 完整說明見 `../k8s-ecosystem-guide.md` 的 Part 15。
> 這份是操作時對照用的 checklist。

```bash
# 每次開始前先設好
export NS=ea-pmc
export VER=1.3.0                          # ← 這次要上的版本
export REGISTRY=your-registry
```

---

## Track A SOP（兩個 Deployment，人工 pilot run）

### 前置檢查（第一次、或改過網路設定後）

- [ ] **Service port 有命名**
  ```bash
  kubectl -n $NS get svc pmc-epmmformquerygui-svc -o jsonpath='{.spec.ports}'
  ```
  看得到 `"name":"http"` 和 `"appProtocol":"http"`

- [ ] **VirtualService 有 `mesh`**
  ```bash
  kubectl -n $NS get vs app-routing -o jsonpath='{.spec.gateways}'
  ```
  陣列裡有 `mesh`（沒有的話，內部流量會隨機打到 canary，見 guide 14.6）

- [ ] **兩個 subset 都有 endpoint**
  ```bash
  kubectl -n $NS get endpoints pmc-epmmformquerygui-svc
  ```

- [ ] **sidecar 有注入**
  ```bash
  kubectl -n $NS get pods -l app=pmc-epmmformquerygui \
    -o jsonpath='{.items[0].spec.containers[*].name}'
  ```
  看得到 `istio-proxy`

---

### 步驟 1｜建立新版本的 ConfigMap

- [ ] 準備 `pmc-epmmformquery-config-$VER`
  ```bash
  kubectl -n $NS apply -f configmap-$VER.yaml
  kubectl -n $NS get cm pmc-epmmformquery-config-$VER
  ```

> ConfigMap 是 `immutable: true`，內容要改**必須換版本號**，不能改既有的。

---

### 步驟 2｜部署到 canary

- [ ] 執行
  ```bash
  cd scripts && ./canary.sh deploy $VER
  ```

- [ ] **確認**：`rollout status` 顯示 `successfully rolled out`
  ```bash
  ./canary.sh status
  ```
  canary 那列的 IMAGE 和 CONFIG **都要是新版**

> 此時正式流量 100% 在 stable，**canary 完全沒有正式流量**。

---

### 步驟 3｜驗證 cookie 路由（不要跳過）

- [ ] 執行
  ```bash
  ./canary.sh verify
  ```

- [ ] **確認**：不帶 cookie 回 `stable`，帶 cookie 回 `canary`

> **這一步沒過就不要往下走** —— 否則 pilot 使用者驗的其實是舊版。
> 排查見 README.md 的常見問題表。

---

### 步驟 4｜請使用者做 pilot run

- [ ] 把 `pilot-run-guide.md` 發給驗證人員
- [ ] 提醒他們**先自證**（F12 看 `x-app-track: canary`）再開始驗
- [ ] 收回填好的驗證清單（含「第 6 項實際測了什麼」）

觀察用：
```bash
kubectl -n $NS logs -l version=canary -c app --tail=100 -f
```

---

### 步驟 5｜依結果二選一

**5a 簽核通過**

- [ ] 執行
  ```bash
  ./canary.sh promote
  ```
- [ ] **確認**：`./canary.sh status` 的 stable 那列 IMAGE 和 CONFIG 都是新版

> ⚠ promote 會同時換 **image 和 ConfigMap 引用**。手動做的話兩個都不能漏，
> 否則新版程式會配到舊版設定。

**5b 簽核不通過**

- [ ] 執行
  ```bash
  ./canary.sh rollback
  ```
- [ ] 使用者完全無感（正式流量本來就沒進 canary）
- [ ] 記錄失敗原因，修好後回到步驟 1

---

### 步驟 6｜promote 後才發現問題

- [ ] 執行
  ```bash
  ./canary.sh undo
  ```

---

### 步驟 7｜清理（每月一次即可）

- [ ] 執行
  ```bash
  ./canary.sh cleanup
  ```

---
---

## Track B SOP（Argo Rollouts）

```bash
export RO=pmc-epmmformquerygui
```

### 前置檢查

- [ ] **Argo Rollouts 有裝**
  ```bash
  kubectl get crd rollouts.argoproj.io
  kubectl argo rollouts version
  ```

- [ ] **Prometheus 可達**（用指標判斷時才需要）
  ```bash
  kubectl -n $NS run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
    curl -s http://prometheus.istio-system:9090/-/healthy
  ```

- [ ] **VirtualService 有名為 `primary` 的 route**
  ```bash
  kubectl -n $NS get vs app-routing -o jsonpath='{.spec.http[*].name}'
  ```

- [ ] Track A 前置檢查的第 1、2、4 項同樣要過

---

### 步驟 1｜建立新版本的 ConfigMap

同 Track A 步驟 1。

---

### 步驟 2｜改 Rollout 觸發發布

- [ ] 執行
  ```bash
  kubectl -n $NS patch rollout $RO --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
     \"value\":\"$REGISTRY/pmc-epmmformquerygui:$VER\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
     \"value\":\"pmc-epmmformquery-config-$VER\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
     \"value\":\"$VER\"}
  ]"
  ```

- [ ] **確認**：看它自動走 step
  ```bash
  kubectl -n $NS argo rollouts get rollout $RO --watch
  ```

---

### 步驟 3｜觀察 analysis 結果

- [ ] 查看
  ```bash
  kubectl -n $NS get analysisrun --sort-by=.metadata.creationTimestamp | tail -3
  ```

| Phase | 意思 | 接下來 |
|---|---|---|
| `Running` | 還在量 | 等（預設 5 分鐘） |
| `Successful` | 通過 | 自動進下一步 |
| `Failed` | 不通過 | **已自動回滾**，去查原因 |
| `Inconclusive` | 沒資料 | **卡住等人**，多半是流量太少或 query 寫錯 |

---

### 步驟 4｜pilot run（steps 裡有 `pause: {}` 時）

- [ ] **先確認 Argo 真的插入了 cookie 路由**
  ```bash
  kubectl -n $NS get vs app-routing -o jsonpath='{.spec.http[*].name}'
  ```
  canary 期間應該看得到 `pilot-run`

- [ ] 驗證 cookie 路由有效（同 Track A 步驟 3）
- [ ] 把 `pilot-run-guide.md` 發給驗證人員
- [ ] 收回驗證清單

---

### 步驟 5｜依結果二選一

**5a 簽核通過**

- [ ] 前進一步
  ```bash
  kubectl -n $NS argo rollouts promote $RO
  kubectl -n $NS argo rollouts get rollout $RO --watch
  ```

- [ ] **緊急時**跳過所有剩餘步驟
  ```bash
  kubectl -n $NS argo rollouts promote $RO --full
  ```

- [ ] **確認**：`Status: ✔ Healthy`，canary 與 stable 的 revision 相同

**5b 簽核不通過**

- [ ] 執行
  ```bash
  kubectl -n $NS argo rollouts abort $RO
  ```
- [ ] 流量立刻切回 stable，canary 30 秒後縮掉

---

### 步驟 6｜promote 後才發現問題

- [ ] 執行
  ```bash
  kubectl -n $NS argo rollouts undo $RO
  ```

---

### 隨時可用的緊急煞車

```bash
kubectl -n $NS argo rollouts pause  $RO     # 暫停
kubectl -n $NS argo rollouts abort  $RO     # 立刻回滾
kubectl -n $NS argo rollouts status $RO     # 目前狀態
```

---
---

## 這次要用哪一套？

| 問自己 | 答案 | 用哪套 |
|---|---|---|
| 改了使用者看得到的畫面嗎 | 是 | **人工 pilot run** |
| 只改後端邏輯、介面沒動 | 是 | 指標判斷就夠 |
| 改了資料庫 schema | 是 | **人工 + 先準備好回滾腳本** |
| 線上正在出事要緊急修 | 是 | Track B `promote --full` |
| 現在是夜間 / 週末，沒人待命 | 是 | 全自動（或不要發） |
| 第一次用這個機制 | 是 | **人工，而且要有人盯著** |

> **一句話判斷**：問「如果這次改壞了，指標抓得到嗎？」
> - 抓得到（5xx 變多、變慢）→ 自動判斷就夠
> - 抓不到（畫面跑版、算錯數字但 HTTP 200）→ **必須人工驗**

---

## 出事時第一時間做什麼

| 症狀 | 立刻做 |
|---|---|
| pilot 使用者說壞了 | Track A: `./canary.sh rollback` / Track B: `argo rollouts abort` |
| promote 後正式使用者說壞了 | Track A: `./canary.sh undo` / Track B: `argo rollouts undo` |
| 大量 503 | 先看 `kubectl get endpoints`，多半是 subset 對不到 pod |
| 大量 403 `RBAC: access denied` | 見 guide Part 3 |
| 使用者一直被登出 | canary 開超過 1 個 replica？見 guide 14.5 前提 1 |
