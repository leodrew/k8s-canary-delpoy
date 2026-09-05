# 人工 pilot run 閘門的 Canary 發布

> ⚠ **已被 [`CANARY-COMPLETE.md`](CANARY-COMPLETE.md) 取代。** 設計理由仍值得一讀，
> 但**操作步驟不要照這份做** —— 本文「簽核不通過 → `replicas: 1 → 0`」的指示已被判定為 outage 動作
> （會讓還握著 cookie 的人吃 503 直到 8 小時後過期），正確做法見總集手冊第 8 章。

保留「**使用者 pilot run 簽核通過才能把 canary 變成 stable**」的流程，但用 Istio 讓它做得更可靠。

## 核心設計

```
   正式使用者 ──────────────────────▶ stable（舊版，100% 流量）
                                        ▲
   pilot 使用者                         │  簽核通過後
   （帶 canary=always cookie）          │  把 canary 的 image
        └──────────────────────────▶ canary（新版，0% 正式流量）
```

**關鍵性質：pilot run 期間，正式流量 100% 在 stable，canary 的權重永遠是 0。**
只有帶 cookie 的人打得到新版本 —— 所以驗證期間對正式使用者是**零風險**，
即使 canary 整個掛掉也不影響任何人。

這跟一般「權重分流」的 canary 有本質差異：

| | 權重分流 canary | **本方案（cookie 指定）** |
|---|---|---|
| pilot 使用者能保證看到新版嗎 | **不能**（每個請求各自擲骰子） | **能**（100% 確定） |
| 驗證期間正式使用者的風險 | 有（5% 流量真的進新版） | **零** |
| 使用者驗到一半被切回舊版 | 會 | 不會 |
| 適合人工簽核流程 | 不適合 | **適合** |

## 兩種實作方式（擇一，不可同時使用）

| | **Track A** | **Track B** |
|---|---|---|
| 需要安裝 | **不用**，只要現有的 Istio | Argo Rollouts controller + CLI |
| 資源型別 | 兩個 Deployment | 一個 Rollout CRD |
| 切換流量 | 你自己 `kubectl` | Argo 自動改 VirtualService |
| 人工閘門 | 天生就是（你不做事就不會前進） | `pause: {}` + `promote` 指令 |
| promote 的動作 | 把 stable 的 image 改成 canary 的 | `kubectl argo rollouts promote` |
| 回滾 | `kubectl rollout undo` | `kubectl argo rollouts abort` |
| 適合 | **現在就能開始用** | 之後想加自動化指標分析時 |

> **建議先用 Track A。** 它不需要任何新工具，而且「人工閘門」是天然的 ——
> 沒有人執行 promote，就永遠不會有正式使用者看到新版本。
> 等到之後想加自動 smoke test / 指標分析時再換 Track B（見 guide Part 12）。

> **⚠ 兩軌互斥**：Rollout 會自己管理 ReplicaSet，若同時存在 Deployment，
> 兩個 controller 會互搶 pod。切換到 Track B 前必須先刪掉 Track A 的兩個 Deployment。

---

## 前置檢查（**做這個之前先確認，否則 cookie 路由不會生效**）

```bash
NS=ea-pmc

# 1. Service 的 port 有沒有 name / appProtocol？
#    沒有的話 Istio 可能用 L4 處理，cookie 比對（L7）會直接失效
kubectl -n $NS get svc pmc-epmmformquerygui-svc -o jsonpath='{.spec.ports}' | head -c 300; echo

# 2. VirtualService 的 gateways 有沒有包含 mesh？
#    沒有的話，cluster 內部呼叫會繞過所有路由規則，隨機打到 stable 或 canary
kubectl -n $NS get virtualservice app-routing -o jsonpath='{.spec.gateways}'; echo

# 3. sidecar 有沒有正常注入？
kubectl -n $NS get pods -l app=pmc-epmmformquerygui \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
```

三項都要通過。第 1、2 項若不通過，先修好再繼續（對應 guide Part 9 的發現 3 和 4）。

---

## Track A 完整操作流程

### 首次部署

```bash
NS=ea-pmc
kubectl -n $NS apply -f track-a/base/         # 建置時一次
kubectl -n $NS apply -f track-a/release/      # 每次發布

# 一開始 canary 不用跑，縮到 0
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0
```

> 記得先把檔案裡的 `your-registry` 換成實際 registry，並確認 ConfigMap 的版本號跟 image tag 一致。

### 每次發布的循環

```bash
cd scripts

# 【1】把新版部署到 canary（正式流量完全不受影響）
./canary.sh deploy 1.3.0

# 【2】確認 cookie 路由真的有效（很重要，別跳過）
./canary.sh verify

# 【3】把 pilot-run-guide.md 發給驗證人員，等他們回報
#      期間可以隨時看狀態
./canary.sh status

# 【4-a】簽核通過 → 升級
./canary.sh promote

# 【4-b】簽核不通過 → 關掉 canary（使用者完全無感）
./canary.sh rollback

# 【5】promote 之後才發現問題 → 回退
./canary.sh undo
```

### 如果不想用腳本，等效的原生指令

> **⚠ ConfigMap 是版本化的，所以每次都要同時改三個地方**：image、`volumes[0].configMap.name`、
> 以及 `config-version` annotation。**只改 image 的話，新版程式會配到舊版設定** ——
> 如果新版需要新的設定項，啟動就會失敗或行為異常。

```bash
NS=ea-pmc
VER=1.3.0
REGISTRY=your-registry

# 先確認新版的 ConfigMap 已經存在
kubectl -n $NS get cm pmc-epmmformquery-config-$VER

# 部署到 canary（三處一起改）
kubectl -n $NS patch deploy pmc-epmmformquerygui-canary --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
   \"value\":\"$REGISTRY/pmc-epmmformquerygui:$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
   \"value\":\"pmc-epmmformquery-config-$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
   \"value\":\"$VER\"}
]"
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=1
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-canary

# 簽核通過 → promote（同樣三處一起改）
kubectl -n $NS patch deploy pmc-epmmformquerygui-stable --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
   \"value\":\"$REGISTRY/pmc-epmmformquerygui:$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
   \"value\":\"pmc-epmmformquery-config-$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
   \"value\":\"$VER\"}
]"
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-stable
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0

# 簽核不通過 → 直接關掉 canary
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0

# promote 後發現問題 → 回退（image 與 ConfigMap 引用會一起還原）
kubectl -n $NS rollout undo deploy/pmc-epmmformquerygui-stable
```

**確認兩者成對：**

```bash
kubectl -n $NS get deploy -l app=pmc-epmmformquerygui -o custom-columns=\
'NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
```

### 選配：簽核通過後不要一次全換，再漸進放量

`promote` 是一次把所有使用者換到新版（雖然已經有 pilot run 背書）。
若想更保守，簽核後先放一部分流量到 canary 觀察：

```bash
NS=ea-pmc
# 放 10% 正式流量到 canary
kubectl -n $NS patch virtualservice app-routing --type=json -p='[
  {"op":"replace","path":"/spec/http/1/route/0/weight","value":90},
  {"op":"replace","path":"/spec/http/1/route/1/weight","value":10}
]'

# 觀察一段時間後，30% → 50% → 100%
# 確認沒問題再執行 promote，最後把權重改回 100/0
kubectl -n $NS patch virtualservice app-routing --type=json -p='[
  {"op":"replace","path":"/spec/http/1/route/0/weight","value":100},
  {"op":"replace","path":"/spec/http/1/route/1/weight","value":0}
]'
```

> ⚠ 放量期間會有使用者在 stable / canary 之間跳。因為你的 app 用
> in-memory session，**這些使用者會被登出**。若要用這個選配，
> 建議先做 session 外部化（guide Part 9 發現 2）。

---

## Track B 完整操作流程

### 安裝 Argo Rollouts

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# CLI 外掛
kubectl krew install argo-rollouts
kubectl argo rollouts version
```

### 從 Track A 切換過來

```bash
NS=ea-pmc

# ⚠ 必須先刪掉 Deployment，否則兩個 controller 會搶 pod
kubectl -n $NS delete deploy pmc-epmmformquerygui-stable pmc-epmmformquerygui-canary

kubectl -n $NS apply -f track-b/base/
kubectl -n $NS apply -f track-b/release/
```

### 每次發布的循環

```bash
NS=ea-pmc
RO=pmc-epmmformquerygui

# 【1】改 image → 自動觸發發布，會停在 pause: {} 等你
kubectl -n $NS argo rollouts set image $RO app=your-registry/pmc-epmmformquerygui:1.3.0

# 【2】看進度（會顯示卡在哪一個 step）
kubectl -n $NS argo rollouts get rollout $RO --watch

# 【3】此時 canary 已就緒、cookie 路由已開，正式流量仍 100% 在 stable
#      把 pilot-run-guide.md 發給驗證人員

# 【4-a】簽核通過 → 前進一步（會繼續執行剩下的 steps）
kubectl -n $NS argo rollouts promote $RO

# 【4-b】簽核不通過 → 中止並回滾
kubectl -n $NS argo rollouts abort $RO

# 【5】其他常用指令
kubectl -n $NS argo rollouts pause  $RO          # 手動暫停
kubectl -n $NS argo rollouts promote $RO --full  # 跳過剩餘所有 step 直接全量
kubectl -n $NS argo rollouts undo   $RO          # 回到上一個版本
kubectl -n $NS argo rollouts status $RO          # 目前狀態
```

> **`promote` 只前進一步**（跳過當前的 pause），不是直接全量。
> 要一次做完剩下的所有步驟用 `promote --full`。

---

## 驗證 cookie 路由確實生效

這是整套機制唯一的關鍵假設，一定要實際驗一次：

```bash
NS=ea-pmc

# 從 cluster 內部測（Track A 用 -svc；Track B 用 -stable / -canary）
kubectl -n $NS run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  sh -c '
    echo "--- 不帶 cookie ---"
    curl -sS -o /dev/null -D - \
      http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
    echo "--- 帶 cookie ---"
    curl -sS -o /dev/null -D - -H "Cookie: canary=always" \
      http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
  '
```

**期望結果**：第一次 `stable`，第二次 `canary`。

從外部測（要能解析到 gateway 的 VIP）：

```bash
curl -sS -o /dev/null -D - https://myapp.example.com/gui_epmmFormQuery/ | grep -i x-app-track
curl -sS -o /dev/null -D - -H "Cookie: canary=always" \
  https://myapp.example.com/gui_epmmFormQuery/ | grep -i x-app-track
```

---

## 常見問題排查

| 症狀 | 最可能原因 | 怎麼查 |
|---|---|---|
| 帶了 cookie 還是進 stable | Service 的 port 沒命名 → Istio 用 L4 處理，cookie 比對失效 | `kubectl get svc ... -o jsonpath='{.spec.ports}'` |
| 帶了 cookie 還是進 stable | cookie 規則沒放在 `match` 最前面 | `kubectl get vs app-routing -o yaml` 看順序 |
| 內部呼叫隨機打到 canary | VirtualService 缺 `mesh` | `kubectl get vs app-routing -o jsonpath='{.spec.gateways}'` |
| 503，`response_flags` 是 `UH` / `NC` | subset 對不到 pod（label 打錯） | `istioctl proxy-config endpoint deploy/... -n ea-pmc` |
| pilot 使用者一直被登出 | canary 開了超過 1 個 replica | `kubectl get deploy ...-canary` 看 replicas |
| 完全沒有 `x-app-track` header | VirtualService 沒套用到 | `istioctl proxy-config route deploy/istio-ingressgateway -n istio-system` |
| Track B：`setHeaderRoute` 沒作用 | Rollout 缺 `managedRoutes` 宣告 | 檢查 `01-rollout.yaml` 的 `trafficRouting.managedRoutes` |
| Track B：Argo 一直被改回去 | Argo CD 在同步 VirtualService 的 weight | 設定 Argo CD 忽略該欄位差異 |

更完整的除錯流程見 `../k8s-ecosystem-guide.md` 的 Part 3（403）與 Part 8（除錯速查表）。

---

## 檔案清單

```
canary-manual/
├── README.md                     ← 你正在看的（設計原理 + 操作流程）
├── SOP.md                        ← 可列印 checklist（有完整 kubectl 權限時）
├── SOP-apply-only.md             ← 可列印 checklist（CD 只能 apply 時）★
├── pilot-run-guide.md            ← 發給驗證人員的說明（含書籤按鈕）
├── track-a/                      ← 不需額外安裝（apply-only 環境建議用這個）
│   ├── base/                     建置時 apply，之後只有網路/身分設定變更才動
│   │   ├── 00-serviceaccount.yaml
│   │   ├── 01-service.yaml
│   │   ├── 02-destinationrule.yaml
│   │   └── 03-virtualservice.yaml
│   └── release/                  每次發布都改、都 apply
│       ├── 10-configmap-1.2.3.yaml   每版一個檔，舊的保留（回滾要用）
│       ├── 20-deployment-stable.yaml
│       └── 21-deployment-canary.yaml
├── track-b/                      ← Argo Rollouts 版本
│   ├── base/
│   │   ├── 00-serviceaccount.yaml
│   │   ├── 01-services.yaml
│   │   ├── 02-destinationrule.yaml
│   │   ├── 03-virtualservice.yaml    ⚠ Argo 會改它，絕不能進 release 流程
│   │   └── 04-analysistemplate.yaml
│   └── release/
│       ├── 10-configmap-1.2.3.yaml
│       └── 20-rollout.yaml
└── scripts/
    └── canary.sh                 ← 有 kubectl 權限時的捷徑（apply-only 環境用不到）
```

## 套用前要改的值

| 檔案 | 要換掉的 placeholder |
|---|---|
| `*/release/20-*`, `*/release/21-*` | `your-registry` → 實際 registry |
| `*/release/10-configmap-*.yaml` | 版本號（`1.2.3`）→ 你的實際版本，檔名也要一起改 |
| `*/base/03-virtualservice.yaml` | `myapp.example.com` → 實際 host |
| `*/base/03-virtualservice.yaml` | `istio-system/my-gateway` → 實際 Gateway |
| 全部 | `ea-pmc` → 實際 namespace（若不同） |

> **這些 YAML 尚未在真實叢集驗證過。** 套用前請先跑：
> `kubectl apply --dry-run=server -f track-a/base/ && kubectl apply --dry-run=server -f track-a/release/`

---

## 如果你的 CD 只能 `kubectl apply`

公司管控的 pipeline（例如 Azure release pipeline）常常只給 `kubectl apply`，不能下
`scale` / `patch` / `rollout undo` / `argo rollouts`。這種情況下：

1. **用 `SOP-apply-only.md`**，不要用 `SOP.md`
2. **選 Track A** —— 權重和 replicas 都在你自己的 YAML 裡，沒有 controller 跟你搶控制權
3. **pipeline 切成兩個 stage**：
   - `deploy-release`（每次發布）→ apply `track-a/release/`
   - `deploy-base`（手動觸發、額外核准）→ apply `track-a/base/`
4. **回滾靠 `git revert`**，所以舊的 ConfigMap **絕對不能刪**

完整說明見 `../k8s-ecosystem-guide.md` 的 Part 15.8–15.13。

### 三個核心操作對照

| 操作 | 改哪個檔 | 改什麼 |
|---|---|---|
| 部署到 canary | 新增 `10-configmap-<新版>.yaml`<br>改 `21-deployment-canary.yaml` | 三處版本號 + `replicas: 0` → `1` |
| promote | 改 `20-deployment-stable.yaml`<br>改 `21-deployment-canary.yaml` | 三處版本號<br>`replicas: 1` → `0` |
| 回滾 | `git revert` promote 的 commit | — |

> **三處版本號**指的是：container `image` tag、`volumes[0].configMap.name`、
> pod template 的 `config-version` annotation。**漏改任何一個都會出問題。**
