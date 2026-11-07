# K8s + Istio 生態全解：從 VIP 到 Pod

> **這份文件的定位**：團隊 onboarding（第一次接觸這套架構的人從 Part 0 讀到 Part 5）+ 日常速查（知道問題在哪就直接跳章節）。
>
> **範例環境**：所有 YAML 都用真實環境的名稱，可以直接對照修改。
> - Namespace `ea-pmc`：`pmc-epmmformquerygui`（Spring Boot + Keycloak，context path `/gui_epmmFormQuery`，port 8080）
> - Namespace `ea-epmm`：`epmm-api`（本文假想的後端 API，用來示範跨 namespace / 跨 cluster 呼叫）

## 目錄

| Part | 內容 | 什麼時候看 |
|---|---|---|
| [Part 0](#part-0名詞速查表) | 名詞速查表 | 第一次接觸，先建立心智模型 |
| [Part 1](#part-1流量入口鏈-vip-到-pod) | 流量入口鏈：VIP → Pod | 「我的請求到底怎麼進來的」 |
| [Part 2](#part-2namespace-內的四層管控) | namespace 內四層管控（PeerAuth / AuthzPolicy / Sidecar / NetworkPolicy） | 要做服務間權限管控 |
| [Part 3](#part-3rbac-access-denied-除錯專章) | `RBAC: access denied` 除錯專章 | **看到 403 就跳這裡** |
| [Part 4](#part-4同-cluster-跨-namespace-互打) | 同 cluster 跨 namespace 互打 | `ea-pmc` → `ea-epmm` |
| [Part 5](#part-5獨立-cluster-互打走對方-vip-與-virtualservice) | 獨立 cluster 互打（走對方 VIP） | 跨機房 / 跨環境呼叫 |
| [Part 6](#part-6六種常用-kind-詳解) | 六種 kind 詳解（全註解 YAML） | 寫 manifest 時查 key |
| [Part 7](#part-7canary-發布與自動擴縮容) | Canary 發布 + 自動擴縮容 | 要做灰度發布 / HPA |
| [Part 8](#part-8除錯速查表) | 除錯速查表（istioctl / access log） | 出事了要下指令 |
| [Part 9](#part-9你目前環境的具體發現) | **你目前環境的具體發現** | 想知道現在有什麼隱患 |
| [Part 10](#part-10istio-ingressgateway-與一般-service-的差別含雙-vip-架構) | ingressgateway vs 一般 Service、雙 VIP（routable / non-routable） | 要開新入口、或搞不清楚 VIP 差別 |
| [Part 11](#part-11fz1-與-fz2-雙-cluster-的入口設計dns-record-放哪) | FZ1 / FZ2 雙 cluster 入口設計 | CD 問你 DNS record 要建在哪 |
| [Part 12](#part-12用-argo-rollouts-取代人工-pilot-run) | **用 Argo Rollouts 取代人工 pilot run** | 想讓發布不用等人確認 |
| [Part 13](#part-13node-排程與-routable-網段) | node 排程與 routable 網段 | 看到 nodeSelector / tolerations 的 routable |
| [Part 14](#part-14保留人工-pilot-run-的-canary-發布) | **保留人工 pilot run 的 Canary 發布** | 要 user 簽核才能上線，但想做得可靠 |
| [Part 15](#part-15兩種上版方式的完整對照與-sop) | **兩種上版方式的對照與 SOP** | 要決定用哪套、或要照 SOP 上版 |
| [Part 16](#part-16active-zone-dns-下-request-落在哪fz2-部好卻-404用-mesh-送到-fz2) | active zone DNS 下 request 落在哪、用 mesh 送到 FZ2 | **FZ2 部好了，打 host 卻 404** |

---

## Part 0：名詞速查表

### 這是在解決什麼問題

只用 K8s 核心的 Service 時，就只有「Service → Pod」這一層抽象，它解決的是**服務發現**（我怎麼找到後端）與**基本負載平衡**。（K8s 另有 Ingress，以及 Gateway API 這個 add-on —— 它支援依權重分流；但身分、mTLS、L7 授權（以及下面的可觀測性）仍然要靠 mesh。）光靠 Service 管不了：

- 我想讓 10% 流量走新版本（只用 Service 時，流量比例只能靠 replica 數量去湊 —— 官方的 canary 範例就是 stable 3 份、canary 1 份湊出 3:1）
- 我想只讓某個服務呼叫我，其他人一律擋掉（K8s Service 沒有身分概念）
- 我想知道 A 打 B 的 P99 延遲（K8s 完全不知道）
- 我想讓服務之間全部走加密（要每個 app 自己實作 TLS）

Istio 把這些抽出來，變成 sidecar（Envoy proxy）+ 一組 CRD。所以你會看到「兩套系統疊在一起」——**K8s 管的是「東西在哪、跑幾份」，Istio 管的是「流量怎麼走、誰能打誰」**。

> **本文只講 sidecar 模式。** Istio 另有 ambient 模式：資料面是每個節點一個 ztunnel（Rust 寫的，不是 Envoy），加上選用的 waypoint proxy（Envoy），Pod 裡沒有 sidecar。兩種模式的 Pod 可以共存在同一個 mesh 裡。下文說的「資料面所有 Envoy」、每個 Pod 裡的 `istio-proxy`，都是指 sidecar 模式。

### Istio 本身由什麼組成：Istio / istiod / istio-system / Envoy

後面每一個 Part 都預設你分得清這四個詞。它們常被混著講，但指的是完全不同層次的東西：

| 名詞 | 是什麼 | 一句話 |
|---|---|---|
| **Envoy** | 一支開源的代理程式（proxy），C++ 寫的 | **真正收封包、轉封包的那支程式** |
| **Istio** | 一個產品，用來管理一大群 Envoy | 整套系統的名字（sidecar 模式下：控制面 istiod ＋ 資料面所有 Envoy；ambient 模式見上方說明） |
| **istiod** | Istio 的大腦，在 cluster 裡是一個 Deployment | 讀你寫的 Gateway / VS / DR / AuthorizationPolicy，翻成 Envoy 看得懂的設定（xDS），推給每一個 Envoy。**它自己不轉任何流量** |
| **istio-system** | 一個 namespace —— 跟 `ea-pmc` 一樣，就是 namespace | 放 Istio 自己元件的地方（istiod、ingressgateway、gateway 用的 TLS secret） |

#### Envoy 在 cluster 裡出現在兩個位置（同一支程式）

```
$ kubectl get pods -n istio-system
NAME                                   READY
istiod-7d4f9c8b6-x2k9p                 1/1    ← 大腦，不轉流量
istio-ingressgateway-5c8d7f6b9-abcde   1/1    ← 位置一：只有 Envoy，站在大門口
istio-ingressgateway-5c8d7f6b9-fghij   1/1

$ kubectl get pods -n ea-pmc
NAME                                          READY
pmc-epmmformquerygui-stable-6b9f8-k2j4l       2/2    ← 兩個容器！

$ kubectl -n ea-pmc get pod pmc-epmmformquerygui-stable-6b9f8-k2j4l \
    -o jsonpath='{.spec.containers[*].name}'
app istio-proxy
# ↑ 你的 Spring Boot（20-deployment-stable.yaml 裡 containers[].name: app）
#     ↑ 位置二：Envoy sidecar，Istio 自動塞進來的
```

- **`istio-ingressgateway`**：一個**只有 Envoy、沒有業務容器**的 Pod，前面掛一個 `type: LoadBalancer` 的 Service 拿 VIP。外部流量的第一站（Part 1、Part 10）
- **`istio-proxy`**：每個 AP Pod 裡的第二個容器。進出這個 Pod 的封包都會先被 iptables 導到它（Part 1 關鍵觀念一）

**sidecar 是自動加的，所以你的 Deployment YAML 裡看不到它。** namespace 帶著 `istio-injection=enabled`（或 `istio.io/rev=<版本>`）這個 label 時，Pod 建立的那一刻 API server 會呼叫 istiod 的 mutating webhook，由它把 `istio-proxy` 容器加進 Pod spec。

所以 namespace 沒有 `istio-injection=enabled`／`istio.io/rev`、Pod 也沒標 `sidecar.istio.io/inject: "true"` 時，通常就不會注入，Pod 是 `1/1`。（反過來，namespace 或 Pod 任一邊明確設成 `disabled`／`"false"`，Pod 就不會被注入。同一個 namespace 同時帶 `istio-injection` 和 `istio.io/rev` 時，`istio-injection` 優先。）後果要分兩邊看：

- **它自己的 inbound 政策失效** —— 打到它身上的 AuthorizationPolicy、PeerAuthentication 沒有 Envoy 可以執行，等於沒寫
- **但別人呼叫它時，client 端的設定仍然套用** —— mesh 裡其他帶 sidecar 的 client 打它時，VirtualService / DestinationRule 是在 client 那一側的 Envoy 執行的，照樣生效

```bash
kubectl get ns ea-pmc --show-labels      # 找 istio-injection=enabled 或 istio.io/rev
```

#### 全景圖

```
┌─────────────────────── 一座 cluster（例如 FZ1）──────────────────────────┐
│                                                                          │
│  ns: istio-system                         ns: ea-pmc                     │
│  ┌──────────────────┐                     ┌──────────────────────────┐   │
│  │ istiod（大腦）   │ ┄┄┄┄推設定┄┄┄┄┄┄┄┄▶│ Pod                      │   │
│  │  watch API server│                     │ ┌──────────────────────┐ │   │
│  └───────┬──────────┘                     │ │ istio-proxy (Envoy)  │ │   │
│          ┊ 推設定                         │ └──────────┬───────────┘ │   │
│          ▼                                │            │ localhost   │   │
│  ┌──────────────────────┐   直連 Pod IP   │ ┌──────────▼───────────┐ │   │
│  │ istio-ingressgateway │ ───────────────▶│ │ Spring Boot :8080    │ │   │
│  │ （只有 Envoy）       │                 │ └──────────────────────┘ │   │
│  └──────────▲───────────┘                 └──────────────────────────┘   │
│             │                                                            │
└─────────────┼────────────────────────────────────────────────────────────┘
              │  VIP（Service istio-ingressgateway 的 EXTERNAL-IP）
           使用者

  實線 ── 流量      虛線 ┄┄ istiod 推設定（xDS）
```

**比喻：保全公司。**

| 比喻 | 對應 |
|---|---|
| 整家保全公司 | **Istio** |
| 總部大樓 | **istio-system** |
| 總部（把規則手冊印好、發給每個警衛） | **istiod** |
| 警衛 | **Envoy** |
| 園區大門的警衛室 | **istio-ingressgateway** |
| 各棟大樓門口的警衛 | 每個 Pod 裡的 **istio-proxy** |
| 規則手冊 | 你寫的 **Gateway / VS / DR / AuthorizationPolicy** |

#### 你 `kubectl apply` 一份 VirtualService 之後，實際發生什麼

```
① API server 把 YAML 存進 etcd           ← 到這裡為止，什麼效果都還沒有
② istiod（watch 著 API server）發現新的 VS，把它翻成 Envoy 的 route 設定
③ 幾秒內推給 ingressgateway 的 Envoy（VS 有寫 mesh 的話，也推給所有相關的 sidecar）
④ 下一個 request 進來，Envoy 用新規則查表
```

**你寫的 YAML 自己不會執行任何東西。** 它只是存在 API server 裡的一份資料，要被 istiod 讀到、推到 Envoy 才算生效。兩個直接推論：

- **istiod 只從「自己這座 cluster」（config cluster）讀 Istio 設定（VS / DR / Gateway…）** —— 所以 FZ2 的 VS 對 FZ1 的 Envoy 完全不存在（Part 16.3）。有設 multicluster（給 istiod 一份 remote secret，裡面是存取其他 cluster API server 的憑證）時，它還會去讀其他 cluster 的 Service / Endpoints 做服務發現，但仍然不讀它們的 VS
- **設定「apply 成功」≠「Envoy 拿到了」** —— 要確認 Envoy 手上的版本，用 `istioctl proxy-status`（`SYNCED` 才算到位，Part 8.1）

### 物件之間怎麼互相找到：label、名字、host 三種連結

Gateway、VirtualService、DestinationRule、Service、Deployment 之間**只有三種連結方式**：

- **label selector** —— 「選出帶著這些 label 的 Pod」
- **名字引用** —— 「我要的是叫這個名字的那個物件」
- **host 字串** —— 「兩邊寫的字串必須對得上」

最常見的誤解是以為 VS 跟 DR 之間也是靠 selector。**不是**：VS 跟 DR 是靠 **host 字串**和 **subset 名字**對上的，真正用到 label 的是 DR 裡面那個 subset 去選 Pod 的那一步。

#### 整條鏈（用 `canary-manual/track-a` 的真實值）

```
Gateway  (istio-system/my-gateway)
  │ ① Gateway.spec.selector  istio: ingressgateway  ──▶ ingressgateway Pod 的 label   【label】
  │     決定「哪一組 Envoy 載入這個 Gateway」
  │
  │ ② VS.spec.gateways: istio-system/my-gateway                                  【名字】
  │ ③ VS.spec.hosts: myapp.example.com  必須落在 Gateway.servers.hosts 裡          【host】
  ▼
VirtualService  (ea-pmc/app-routing)
  │ ④ route.destination.host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  │      == DR.spec.host  == Service 的全名                                       【host】
  │ ⑤ route.destination.subset: stable  == DR.subsets[].name                     【名字】
  │ ⑥ route.destination.port.number: 8080  == Service.ports[].port               【數字】
  ▼
DestinationRule  (ea-pmc/pmc-epmmformquerygui-dr)
  │ ⑦ subsets[stable].labels  version: stable  ──▶ 比對 Pod 的 label              【label】
  ▼
Service  (ea-pmc/pmc-epmmformquerygui-svc)
  │ ⑧ spec.selector  app: pmc-epmmformquerygui  ──▶ 比對 Pod，產生 EndpointSlice 【label】
  │ ⑨ ports[].targetPort: 8080  == 程式實際 listen 的 port                       【數字】
  ▼
Pod  labels: app=pmc-epmmformquerygui, version=stable
  ▲
  │ ⑩ Deployment.spec.selector.matchLabels  ⊆  template.metadata.labels         【label】
Deployment  (track-a/release/20-deployment-stable.yaml)
```

⑧ 和 ⑨ 各有一個常被講錯的細節：

- **⑧ 產生的是 EndpointSlice，不是 Endpoints。** 舊的 Endpoints API 從 Kubernetes v1.33 起 deprecated，官方建議所有 client 改用 EndpointSlice。EndpointSlice 靠 `kubernetes.io/service-name` 這個 label 綁回 Service，所以要看 Service 實際選到哪些 Pod：`kubectl get endpointslices -n ea-pmc -l kubernetes.io/service-name=pmc-epmmformquerygui-svc`
- **⑨ 要對上的是程式實際 listen 的 port，不是 `containerPort`。** `containerPort` 主要是宣告用 —— 官方 API 文件寫的是 "Not specifying a port here DOES NOT prevent that port from being exposed." 也就是說，程式只要在 `0.0.0.0` 上 listen，不寫 `containerPort` 照樣連得到。只有 `targetPort` 寫成 named port（例如 `targetPort: http`）時，才必須在 container 的 `ports` 裡定義同名的 port。`targetPort` 省略時預設等於 `port`。

④⑦⑧ 合起來，就是 Envoy 手上那份「通訊錄」的產生方式：

```
Service selector  app=pmc-epmmformquerygui   → 選出全部 Pod（stable 和 canary 都有）
       ∩
DR subset labels  version=stable             → 再篩一次，只留 stable
       =
Envoy cluster  outbound|8080|stable|pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
```

這就是為什麼 `01-service.yaml` 的 selector **只寫 `app`、不寫 `version`**：Service 負責把兩軌的 Pod 都撈進來，DR 負責切成兩組。Service 也寫了 `version: stable` 的話，canary subset 一個 Pod 都選不到 → 503 `UH`。

#### 每一個連結斷掉時的症狀

| 斷掉的連結 | 症狀 |
|---|---|
| ① Gateway selector 對不到 gateway Pod | 那組 Envoy 根本沒有這個 listener，連不上或 404 |
| ② `gateways` 名字寫錯 ／ ③ host 不在 Gateway 的 hosts 裡 | 404 |
| ④ host 拼錯（registry 裡沒有這個 Service） | 503 `NC` |
| ⑤ subset 名字在任何 DR 裡都找不到 | 503 `NC` |
| ⑦ subset label ／ ⑧ Service selector 對不到任何 Pod | 503 `UH` |
| ⑥ VS 的 `port.number` 不是 Service 的 `port` | 對應的 Envoy cluster 不存在 → 503 `NC`（經驗值） |
| ⑨ `targetPort` 不是程式實際 listen 的 port | Envoy 連上游失敗 → 503 `UF`／`URX`，body 是 `upstream connect error … connection refused`（經驗值） |
| ⑩ Deployment selector 不是 template labels 的子集 | `kubectl apply` 直接被拒 |

標「經驗值」的兩列沒有官方文件逐條寫出這個對應，是實際排查時的典型症狀；response flag 的意思見 Part 8.2。

**踩雷：VS 的 host 寫短名。** `destination.host: pmc-epmmformquerygui-svc` 會被 Istio 用 **VS 自己所在的 namespace** 補全，而不是 Service 所在的 namespace。VS 放在別的 namespace 時，就補成一個不存在的名字 → 503 `NC`。所以這個 repo 的 VS / DR 一律寫 FQDN。

#### selector 的兩種寫法

```yaml
# A. 等值比對：每一個 key=value 都要符合（AND）
selector:
  matchLabels:
    app: pmc-epmmformquerygui
    version: stable
```

```yaml
# B. 運算式比對：In / NotIn / Exists / DoesNotExist
selector:
  matchExpressions:
    - { key: version, operator: In, values: [stable, canary] }
    - { key: deprecated, operator: DoesNotExist }
```

兩種同時寫時是 AND。不是每個欄位都支援 B —— 見下表。

#### 各物件的 selector 一覽

| 物件.欄位 | 選的是什麼 | 支援 `matchExpressions`？ | 特殊行為 |
|---|---|:---:|---|
| `Service.spec.selector` | Pod → 產生 EndpointSlice | ✗ 只能等值，而且直接寫 map，沒有 `matchLabels` 這一層 | 不寫 selector 就不會自動產生 EndpointSlice |
| `Deployment.spec.selector` | 自己管的 Pod | ✔ | **建立後不能改**；必須是 template labels 的子集 |
| `DestinationRule.subsets[].labels` | `spec.host` 那個 Service 的 EndpointSlice 裡的 Pod | ✗ 只能等值 | 只在該 Service 選到的 Pod 範圍內再篩 |
| `Gateway.spec.selector` | ingressgateway 的 Pod | ✗ | 決定哪一組 Envoy 載入這個 Gateway |
| `AuthorizationPolicy` / `PeerAuthentication` / `RequestAuthentication` 的 `spec.selector.matchLabels` | 要套用的 workload Pod | ✗ | **省略 selector（AuthorizationPolicy 還要沒寫 `targetRefs`）= 整個 namespace**；放在 **root namespace**（`meshConfig.rootNamespace`，預設 `istio-system`）且省略 = 整個 mesh。AuthorizationPolicy 另可用 `targetRefs` 取代 selector，例如指定同 namespace 的 Gateway API `Gateway`（`gateway.networking.k8s.io`，不是上面那個 Istio Gateway） |
| `Sidecar.spec.workloadSelector.labels` | 要套用的 Pod | ✗ | 省略 = 這個 namespace 的預設值（Part 2.3） |
| `NetworkPolicy.spec.podSelector` | 要保護的 Pod | ✔ | `{}` = 這個 namespace 全部 Pod |
| `NetworkPolicy` 的 `from/to.namespaceSelector` | 來源 / 目的 namespace | ✔ | 常用 `kubernetes.io/metadata.name: istio-system` |
| `PodDisruptionBudget.spec.selector` | 要保護的 Pod | ✔ | |
| `topologySpreadConstraints` / `podAntiAffinity` 的 `labelSelector` | 要彼此分散的 Pod | ✔ | `20-deployment-stable.yaml` 就有一段 |
| `VirtualService.http[].match[].sourceLabels` | **呼叫方** Pod 的 label | ✗ | 只對 mesh 內部呼叫有效；從 gateway 進來的流量沒有來源 Pod label 可比 |

**selector 共通的危險：對不到時不會報錯。** Service 選不到 Pod 只是 EndpointSlice 變空；AuthorizationPolicy 選不到 Pod 等於沒寫、規則無聲地不生效。這也是 `scripts/validate.sh` 要拿兩邊的值互相對照、而不是只檢查 key 存不存在的原因。

### 一句話職責表

| 資源 | 屬於 | 一句話職責 | 沒有它會怎樣 |
|---|---|---|---|
| **Deployment** | K8s | 宣告「這個 app 要跑幾份、用什麼 image」 | Pod 掛了不會自己補 |
| **Service** | K8s | 給一組 Pod 一個穩定的 DNS 名稱與 VIP | 你得自己追 Pod IP（會變） |
| **ConfigMap / Secret** | K8s | 把設定與機密從 image 裡拆出來 | 改個參數要重 build image |
| **CronJob** | K8s | 定時跑一次性任務 | 要自己養一台機器跑 crontab |
| **Gateway** | Istio | 定義**入口的 L4/TLS**：開哪個 port、收哪些 host、憑證是誰 | 外面的流量進不來 |
| **VirtualService** | Istio | 定義**路由規則**：這個 path/header 要送去哪個服務、幾成流量 | 只能靠 Service 名稱一對一直連 |
| **DestinationRule** | Istio | 定義**路由決定之後**、送往該服務的策略：subset 分組、負載平衡演算法、連線池、client 端對上游連線的 TLS 設定（如 `ISTIO_MUTUAL`） | 同一個 Service 底下無法分版本（見表下說明） |
| **ServiceEntry** | Istio | 把「mesh 外部的服務」註冊進來，讓 sidecar 認得它 | `REGISTRY_ONLY` 模式下打不出去（見表下說明） |
| **Sidecar** | Istio | 限制**這個 workload 的 Envoy 能看見哪些服務** | 每個 sidecar 都載入全 mesh 設定，吃記憶體 |
| **PeerAuthentication** | Istio | 決定**服務間連線要不要 mTLS**（身分驗證） | 預設 `PERMISSIVE`，明文也收（見表下說明） |
| **AuthorizationPolicy** | Istio | 決定**誰可以打誰的哪個 path/method**（授權） | 任何人打得到就進得去 |
| **RequestAuthentication** | Istio | 驗 **JWT**（end-user 身分） | 沒辦法認「人」，只能認「服務」 |
| **NetworkPolicy** | K8s + CNI | L3/L4 封包層的防火牆（Pod IP / CIDR / port） | 網路層完全互通 |
| **HorizontalPodAutoscaler** | K8s | 依指標自動調整 replica 數 | 尖峰要人工擴容 |
| **PodDisruptionBudget** | K8s | 保證自願中斷時至少留幾個 Pod | 節點維護可能一次砍光你所有 Pod |

**表中三列的補充：**

- **DestinationRule：** 只有「同一個 Service 底下分版本」才需要 subset；兩個版本是不同 Service 時，VirtualService 用 `weight` 分到兩個 Service 照樣能分流。它的 `tls` 是 client 這一端對上游連線的 TLS 設定（例如 `ISTIO_MUTUAL`）；server 端要不要**強制** mTLS（拒收明文）由 PeerAuthentication 決定。
- **ServiceEntry：** 「打不出去」只發生在 mesh 設成 `outboundTrafficPolicy.mode: REGISTRY_ONLY` 時。預設是 `ALLOW_ANY`，沒有 ServiceEntry 也會放行，但流量走 passthrough，拿不到 VirtualService／DestinationRule 的功能。（這裡的模式跟 mTLS 的 `STRICT` 無關。）
- **PeerAuthentication：** 沒寫時 mesh 預設是 `PERMISSIVE` —— 明文與 mTLS 都收，兩端都有 sidecar 的連線會自動升級成 mTLS，身分照樣存在。所以真正的風險不是「沒有身分」，而是沒有 sidecar 的 client 可以用明文繞過身分。AuthorizationPolicy 裡依賴 mTLS 的只有 `principals`／`notPrincipals`、`namespaces`／`notNamespaces` 與 `source.principal`、`source.namespace` 條件；path、method 這類規則不受影響。

### 最重要的一組區分：認證 vs 授權 vs 防火牆

這三個東西常被混講，但**生效層級完全不同**，這是後面所有除錯的基礎：

```
封包進入 Pod 的順序：

  ①  NetworkPolicy      ← CNI（Calico/Cilium）在網路層擋，比對「IP / CIDR / port」
      ↓ 通過
  ②  PeerAuthentication ← Envoy 驗 mTLS 憑證，決定「你是誰」（身分 = ServiceAccount）
      ↓ 通過
  ③  AuthorizationPolicy← Envoy RBAC filter，決定「你能不能做這件事」（L7：path/method/header）
      ↓ 通過
  ④  你的 App           ← Spring Security 再做一次應用層授權
```

- ① 擋掉的：**通常是 timeout**（多數 CNI 直接丟封包）；會不會回 RST、讓 client 看到 `connection refused`，看 CNI 怎麼實作。NetworkPolicy API 本身沒有阻擋紀錄，要用 CNI 自己的工具（Calico／Cilium）查
- ② 擋掉的：TLS handshake 失敗、連線被 reset，**沒有 403**
- ③ 擋掉的：**HTTP 403 + body `RBAC: access denied`** ← Part 3 專章
- ④ 擋掉的：你自己 app 的 401/403 頁面

**記住：`RBAC: access denied` 是 ③，跟 K8s 的 RBAC（Role/RoleBinding）一點關係都沒有。** 這是最常見的誤判，詳見 Part 3。

### 參考來源

本 Part 經查證修正的說法所依據的官方文件（查證帳本 `tasks/guide-verification-ledger.md` 的 P00 各列）：

- Kubernetes — Managing Workloads：https://kubernetes.io/docs/concepts/workloads/management/
- Kubernetes — Gateway API：https://kubernetes.io/docs/concepts/services-networking/gateway/
- Kubernetes — Service：https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes — Pod v1 API（containerPort）：https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/
- Kubernetes — Network Policies：https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Istio — Ambient mode overview：https://istio.io/latest/docs/ambient/overview/
- Istio — Installing the Sidecar（sidecar injection）：https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio — Deployment Models：https://istio.io/latest/docs/ops/deployment/deployment-models/
- Istio — Security concepts：https://istio.io/latest/docs/concepts/security/
- Istio — AuthorizationPolicy reference：https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — DestinationRule reference：https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Accessing External Services（egress control）：https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/

---

## Part 1：流量入口鏈 VIP 到 Pod

### 這是在解決什麼問題

當你在瀏覽器打 `https://myapp.example.com/gui_epmmFormQuery/`，這個請求要經過 7~8 跳才會到你的 Spring Boot。**每一跳都可能是 404/503 的兇手**，而且每一跳的錯誤長得不一樣。這節的目的是讓你看到錯誤碼就知道要去哪一跳查。

### 完整鏈路

```
  ① Client 瀏覽器
     │  DNS: myapp.example.com → VIP
     ▼
  ② VIP (F5 / 硬體 LB / 雲端 LB)
     │  轉發到 K8s node 的 NodePort，或直接到 LB Service
     ▼
  ③ Service: istio-ingressgateway  (ns: istio-system, type=LoadBalancer/NodePort)
     │
     ▼
  ④ Pod: istio-ingressgateway (純 Envoy，沒有業務容器)
     │  ┌─ Gateway CRD 決定：這個 port 收不收？host 對不對？TLS 憑證用哪張？
     │  └─ VirtualService CRD 決定：這個 path 要送去哪個服務？切幾成？
     ▼
  ⑤ 套用 DestinationRule → 以 subset labels 篩選 endpoint → 選負載平衡演算法 → 從 Pod IP 清單挑一個
     │  ⚠ 注意：這份 Pod IP 清單是 istiod 從 service registry（K8s Service／EndpointSlice）推給 Envoy 的；
     │    DestinationRule 不提供 IP，subset 的 `labels` 只是篩選這份清單，另外決定 LB 演算法和連線設定。
     │    Envoy 直接連 Pod IP，不經過 Service 的 kube-proxy VIP
     ▼
  ⑥ 目標 Pod 的 istio-proxy sidecar（inbound）
     │  ┌─ PeerAuthentication：驗 mTLS，確認來源身分
     │  └─ AuthorizationPolicy：Envoy RBAC filter 判斷放不放行
     ▼
  ⑦ 你的 App (localhost:8080)
     └─ Spring Security / PrivilegeCheckFilter 再做一次應用層授權
```

### 逐跳職責表：出事了查哪裡

| 跳 | 誰決定 | 設錯的典型症狀 | 查法 |
|---|---|---|---|
| ② VIP | 網路組 / F5 設定 | 完全連不上、TLS 憑證錯誤 | `curl -v` 看憑證 CN、`dig` 看 DNS |
| ③ Service | `istio-ingressgateway` Service 的 port 定義 | `Connection refused` | `kubectl get svc -n istio-system istio-ingressgateway` |
| ④a **Gateway** | `servers.port` + `servers.hosts` + `tls` | **host 對不上 → 404＋`NR`**，跟 VS 沒匹配長得一樣（見表下說明） | `istioctl proxy-config listener <gw-pod> -n istio-system` |
| ④b **VirtualService** | `hosts` + `gateways` + `match` | **404＋`response_flags: NR`** ← 沒有 route 匹配（前提：access log 已開啟，見表下說明） | `istioctl proxy-config route <gw-pod> -n istio-system` |
| ⑤ DestinationRule | `subsets.labels` | **503 `UH`** ← subset 選不到任何 Pod（其他 503 旗標見表下說明） | `istioctl proxy-config endpoint <gw-pod> -n istio-system` |
| ⑥ Sidecar 授權 | AuthorizationPolicy | **403 `RBAC: access denied`** | Part 3 |
| ⑥ Sidecar mTLS | PeerAuthentication | **連線 reset、`response_flags: UF`** | `istioctl proxy-config secret <pod>` |
| ⑦ App | 你的 Spring Security | 你自己的登入頁 / access-denied 頁 | `kubectl logs` |

表中 ④a／④b／⑤ 的補充：

* **④a 與 ④b 不能靠「有沒有 access log」分辨。** HTTP host 對不上 Gateway 時，回 404 的是 Envoy 自己（route 表裡沒有符合的 virtual host），flag 一樣是 `NR`；兩者要用 `istioctl proxy-config route <gw-pod> -n istio-system` 看 virtual host 清單才分得出來。HTTPS 的 SNI 對不上則是 TLS 握手就失敗，不會有 404。
* **access log 預設不開**（官方只說 `demo` profile 會開）。要先用 Telemetry API 或 `meshConfig.accessLogFile=/dev/stdout` 打開，否則 ④b 的 `NR` 根本看不到；完全沒有 log 時，先查這一項、再查該 port 有沒有 listener。
* **⑤ 的 503 要拆開看，`UF` 不是「subset 選不到 Pod」。** Envoy 的定義：UH 是 「No healthy upstream hosts in upstream cluster」（加上 503），subset labels 選不到任何 Pod 時看到的是它；NC 是 「Upstream cluster not found」，VS 引用了 DR 沒定義的 subset 時通常是這個；UF 是 「Upstream connection failure」（加上 503），是連線失敗，常見於 mTLS 衝突。

### 關鍵觀念一：mesh 裡的 Service「幾乎只剩 DNS」

這是最反直覺、也最容易踩雷的一點。

**沒有 Istio 時**：Pod A 打 `pmc-epmmformquerygui-svc:8080` → DNS 解析到 Service 的 ClusterIP（VIP）→ 封包送到 VIP → **kube-proxy 的 iptables（目前預設）或 nftables 規則**做 DNAT，挑一個 Pod IP（iptables 模式預設隨機挑；IPVS 模式則依 scheduler）。IPVS 模式自 v1.35 起 deprecated，KEP-5495 規劃 v1.40 預設停用、v1.43 移除。負載平衡、session affinity 都發生在 kube-proxy。

**有 Istio 時**：Pod A 打 `pmc-epmmformquerygui-svc:8080` → DNS 一樣解析到 ClusterIP → 但封包在離開 Pod 前就被 **iptables 攔截導向自己的 sidecar（port 15001）** → sidecar 認出這個 ClusterIP 對應哪個 Service → **sidecar 自己從 endpoint 清單挑一個 Pod IP，直接連過去**。

```
沒有 Istio：  Pod A ──→ ClusterIP ──[kube-proxy DNAT]──→ Pod B
有 Istio：    Pod A ──→ sidecar A ──[Envoy LB，直連 Pod IP]──→ sidecar B ──→ Pod B
                         ↑ kube-proxy 的規則在這裡就被繞過了
```

**這造成三個直接後果：**

1. **`Service.spec.sessionAffinity: ClientIP` 在 mesh 內失效。** 因為那是 kube-proxy 選 backend 時套用的功能，而流量根本沒經過 kube-proxy 的負載平衡邏輯。（這一點是由機制推得，不是 Istio 官方逐字寫的結論；可用 `istioctl proxy-config endpoint` 與實測驗證。）要在 Istio 下做黏著，應改用 DestinationRule 的 `consistentHash`（見 Part 6 Service 章節與 Part 7）。注意它只是軟性黏著（Istio 官方：「soft session affinity」、「the guarantees are weaker」）：Pod 增減時部分請求會被重新分配，不能取代共享 session。從 ingressgateway 進來的流量若用 `useSourceIp`，雜湊到的會是 gateway 的 IP，應優先用 `httpCookie` 或 header。
2. **Istio 用 L4 還是 L7 處理，由 `appProtocol`（優先）或 Service port 名稱前綴決定。** 兩者都沒寫時，sidecar 會自動偵測 HTTP／HTTP2，偵測不出來時才當純 TCP，此時 `VirtualService` 的 header/path 比對才會失效。建議明確寫 `appProtocol: http`，不要靠偵測。
3. **Headless Service（`clusterIP: None`）行為不同**，因為沒有 VIP 可攔截，sidecar 走的是原始目的地路徑。

### 關鍵觀念二：Client IP 在哪一跳被弄丟

你要做 IP 白名單（Part 2.2 的 `ipBlocks` / `remoteIpBlocks`）時，第一個問題永遠是「我現在拿到的 IP 是誰的 IP」。

| 情境 | ingressgateway 看到的 source IP | 真實 client IP 在哪 |
|---|---|---|
| VIP 做 SNAT（多數 F5 預設） | VIP／F5 的 SNAT 位址 | **只在 `X-Forwarded-For` 裡**，而且 F5 要有加 |
| Service `externalTrafficPolicy: Cluster`（預設） | 經過 node SNAT，看到 node IP | 通常**完全遺失**，除非更前面的 L7 proxy 先寫進 `X-Forwarded-For`（見表下說明） |
| Service `externalTrafficPolicy: Local` | 保留真實 client IP 到 gateway | gateway 會把它寫進 `X-Forwarded-For` |

表中 `externalTrafficPolicy: Cluster` 那一列的補充：封包送到 `Type=NodePort`／LoadBalancer Service 時預設會被 SNAT（K8s 官方：「Packets sent to Services with `Type=NodePort` are source NAT'd by default.」），node 在 L4 就把來源換成自己的 IP，kube-proxy 不會寫 `X-Forwarded-For`，Envoy 之後 append 進去的只是那個 node IP；真實 client IP 只有在更前面的 L7 proxy（例如 F5）先寫進 `X-Forwarded-For` 時才拿得到。表中欄位是 **ingressgateway** 看到的 source IP；經 gateway 轉進 mesh 的流量，目標 Pod 看到的則是 gateway Pod IP。

**所以：在 mesh 內部做 IP 比對，`ipBlocks` 幾乎永遠是錯的**（你比到的是 ingressgateway 的 IP）。要比對真實 client 必須用 `remoteIpBlocks`，而且**必須先設定 `numTrustedProxies`**（可設在全域 MeshConfig，也可在 gateway Pod 加 `proxy.istio.io/config` annotation 個別設；改完已在跑的 ingressgateway Pod 要重啟才生效），否則 Envoy 不知道 `X-Forwarded-For` 裡哪一段可以信。

```yaml
# IstioOperator 的 spec.meshConfig（Helm 的 values 則是頂層 meshConfig:）
# 直接改 istio ConfigMap 時，key 是 mesh、內容從 defaultConfig: 開始，沒有 meshConfig: 這一層
# 此設定只對 gateway 生效（個別 gateway 的覆蓋方式見上方說明）
meshConfig:
  defaultConfig:
    gatewayTopology:
      numTrustedProxies: 1   # ← VIP/F5 算一層 proxy，就填 1；前面再多一層 CDN 就填 2
      forwardClientCertDetails: SANITIZE_SET
```

`numTrustedProxies: N` 的意思是：以 gateway **收到**的 `X-Forwarded-For` 來看，從最右邊往左數第 N 個位址是受信任的 client 位址（Envoy：「the trusted client address is the Nth address from the right end of XFF.」）。gateway 轉發時會再 append 一個下游 IP，所以 app 端看到的 XFF 裡它變成第 N+1 個。Envoy 把結果寫進 `X-Envoy-External-Address`；XFF 項數少於 N 時，退回使用直接連線的來源 IP。**填錯 = 白名單擋錯人**，這個數字要跟網路組確認實際有幾層 proxy。

---

> **延伸閱讀**：istio-ingressgateway 跟一般 Service 到底差在哪、以及 routable / non-routable 雙 VIP 怎麼配，見 [Part 10](#part-10istio-ingressgateway-與一般-service-的差別含雙-vip-架構)。
> Gateway / VirtualService / DestinationRule 為什麼是「查表」不是「跳點」、以及兩座 cluster 時 request 落在哪一邊，見 [Part 16](#part-16active-zone-dns-下-request-落在哪fz2-部好卻-404用-mesh-送到-fz2)。

### 參考來源

本 Part 經查證修正的說法所依據的官方文件（查證帳本 `tasks/guide-verification-ledger.md` 的 P01 各列）：

- Istio — DestinationRule reference：https://istio.io/latest/docs/reference/config/networking/destination-rule/
- Istio — Access logging：https://istio.io/latest/docs/tasks/observability/logs/access-log/
- Envoy — Access log substitution formatter：https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter
- Kubernetes — Virtual IPs and Service Proxies：https://kubernetes.io/docs/reference/networking/virtual-ips/
- KEP-5495 — Deprecate IPVS mode in kube-proxy：https://github.com/kubernetes/enhancements/blob/master/keps/sig-network/5495-deprecate-ipvs-mode-in-kube-proxy/README.md
- Istio — Protocol Selection：https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/
- Kubernetes — Using Source IP：https://kubernetes.io/docs/tutorials/services/source-ip/
- Istio — Gateway Network Topologies：https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/
- Istio — MeshConfig reference：https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/
- Envoy — HTTP header manipulation（X-Forwarded-For）：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers

---

## Part 2：namespace 內的四層管控

這一節把「誰能打誰」的四種工具全部攤開。**先看 2.5 的對照表決定要用哪一個，再回頭看細節。**

### 2.1 PeerAuthentication — 服務間 mTLS（決定「你是誰」）

#### 這是在解決什麼問題

沒有它，Envoy 收到一個連線時**完全不知道對方是誰**。你可以用 IP 猜，但 Pod IP 每次重啟都會變，而且同一個 node 上的 Pod 可能共用出口。

mTLS 解決的是：Istio 的 CA（istiod）幫每個 workload 簽發一張憑證，憑證的 SAN 欄位寫著 `spiffe://cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui`。連線時雙方交換憑證，**Envoy 就能拿到一個密碼學上可信的身分**，而不是靠 IP 猜。

**身分欄位依賴 mTLS。** AuthorizationPolicy 的 `principals` / `namespaces` 這些欄位要有 mTLS 才比對得到東西（哪些欄位依賴 mTLS，見 Part 0「表中三列的補充」的 PeerAuthentication 一條；Part 3 成因 #3 也會用到）。前置條件是「mTLS」，不是「PeerAuthentication 物件」：兩端都有 sidecar 時，沒有 PeerAuthentication 也會自動升級成 mTLS（Istio：「For peer authentication, Istio automatically upgrades all traffic between two PEPs to mutual TLS.」）。真正的陷阱在 `PERMISSIVE`：明文請求沒有 principal，ALLOW 規則擋得掉明文，但 DENY 裡的 `principals` 規則會被明文繞過。所以官方強烈建議搭配 `STRICT`（Istio：「it is strongly recommended to always use these fields with strict mutual TLS mode」）。

#### 最小可用 YAML

```yaml
# 整個 ea-pmc namespace 強制 mTLS
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default          # 注意：namespace 層級慣例上叫 default
  namespace: ea-pmc
spec:
  mtls:
    mode: STRICT         # 只收 mTLS 連線，明文一律拒絕
```

```yaml
# 只針對單一 workload，且開一個 port 的例外
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: pmc-query-mtls
  namespace: ea-pmc
spec:
  selector:                          # portLevelMtls 必須搭配非空的 selector.matchLabels（細節見下方「常用 key」表）
    matchLabels:
      app: pmc-epmmformquerygui
  mtls:
    mode: STRICT
  portLevelMtls:
    8080:                            # 這裡填「容器 port（targetPort）」，不是 Service port
      mode: PERMISSIVE               # 這個 port 允許明文（例如給沒有 sidecar 的健康檢查用）
```

#### 常用 key

| Key | 值 | 說明 |
|---|---|---|
| `mtls.mode` | `STRICT` | 只收 mTLS。**正式環境目標狀態** |
| | `PERMISSIVE` | mTLS 和明文都收。**遷移期用**，Istio 預設值 |
| | `DISABLE` | 完全不用 mTLS |
| | `UNSET` | 繼承上層設定 |
| `selector.matchLabels` | label | 不填 = 整個 namespace；填了 = 只針對符合的 workload |
| `portLevelMtls.<port>` | port → mode | 針對單一容器 port 覆寫，**需要非空的 `selector.matchLabels`**（沒有的話 Istio ≥1.23 會在 apply 時被 CRD 驗證直接拒絕；更舊版本才是靜默忽略） |

#### 優先序

```
workload-level（有 selector）  >  namespace-level（無 selector）  >  mesh-level（在 istio-system）
```

放在 **root namespace（預設 `istio-system`）且沒有 `selector`（或 selector 為空）** 的 PeerAuthentication 會套用到**整個 mesh**（Istio：「Mesh-wide policy: A policy specified for the root namespace without or with an empty `selector` field.」）。名稱跟範圍無關，叫 `default` 只是慣例；換個名字照樣全 mesh 中招。這是最容易誤傷的一招——你以為只改一個 namespace，結果全 mesh 都被 STRICT 了。

#### 踩雷

- **直接跳到 STRICT = 全面斷線。** 正確流程是：先 `PERMISSIVE` → 觀察 Grafana/Kiali 確認所有流量都已經是 mTLS（`istio_requests_total` 的 `connection_security_policy="mutual_tls"`）→ 再切 `STRICT`。
- **沒有 sidecar 的 Pod 打不進來。** 例如 `kubectl exec` 進一個沒注入的 debug pod 去 curl，STRICT 下必定失敗，這不是 bug。
- **kubelet 的 health probe**：Istio 預設會改寫 HTTP、TCP、gRPC 三種 probe（Istio：「Istio uses probe rewrite to implement HTTP, TCP, and gRPC probes by default.」），所以 STRICT 下一般不會壞。HTTP probe 改寫後改打 pilot-agent 的 **15020** port（路徑 `/app-health/<container>/livez` 或 `readyz`）；15021 是 sidecar 自己的 `/healthz/ready`，不是改寫目標。要關掉改寫，是在 **pod template 的 annotation** 寫 `sidecar.istio.io/rewriteAppHTTPProbers: "false"`（結尾是 Probers；`rewriteAppHTTPProbe` 是全域 Helm 值，不是 annotation）。關掉之後：HTTP probe 在 STRICT 下會失敗（kubelet 沒有 mesh 憑證）；TCP probe 則因所有 port 都由 sidecar 接聽而**永遠成功**，變成假綠燈，偵測不到 app 掛掉。
- **`portLevelMtls` 填錯 port**：填 Service 的 `port` 而不是 `targetPort`，設定會靜默不生效。

---

### 2.2 AuthorizationPolicy — L7 授權（決定「你能不能做」）

#### 這是在解決什麼問題

mTLS 只告訴你「對方是 `ea-pmc/pmc-epmmformquerygui`」，但沒說他能不能呼叫 `DELETE /api/users`。AuthorizationPolicy 就是那張「誰 × 能對什麼資源 × 做什麼動作」的表，而且**在 sidecar 就判掉，你的 app 完全不會收到那個請求**。

比起在 Spring Security 裡寫，它的優勢是：改權限不用重新部署 app、對所有語言的服務一致、而且攻擊者連你的 app 都碰不到。

#### 最小可用 YAML

```yaml
# 只允許 ea-pmc 的 pmc-epmmformquerygui 呼叫 epmm-api 的 GET /api/**
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-pmc-query
  namespace: ea-epmm                    # 放在「被呼叫方」的 namespace
spec:
  selector:
    matchLabels:
      app: epmm-api                     # 保護誰
  action: ALLOW
  rules:
    - from:
        - source:
            principals:                 # 誰可以來（來自 mTLS 憑證）
              - "cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"
      to:
        - operation:
            methods: ["GET"]
            paths: ["/api/*"]
```

#### action 四種模式

| action | 語意 | 什麼時候用 |
|---|---|---|
| `ALLOW` | 白名單。**一旦有任何 ALLOW policy 選中這個 workload，不符合的一律拒絕** | 最常用 |
| `DENY` | 黑名單。優先於 ALLOW 判斷 | 緊急封鎖某來源、擋掉 `/actuator` 外部存取 |
| `AUDIT` | 不影響放行／拒絕，只把命中的請求標記成要稽核；要有另外設定並啟用的稽核 plugin 才會真的產生紀錄 | **不能拿來預演**（見「踩雷」的「上線前的預演不要用 `AUDIT`」那條） |
| `CUSTOM` | 交給外部授權服務（ext_authz，如 OPA） | 需要複雜商業邏輯授權 |

**判斷順序（非常重要）：**

```
CUSTOM  →  DENY  →  ALLOW
   |         |         |
 拒絕就停  拒絕就停   沒有任何 ALLOW policy 選中 → 全部放行
                     有 ALLOW policy 選中 → 只有符合的放行，其餘 403
```

最關鍵的一句：**「沒有 policy = 全部允許」，但「有一條 ALLOW policy = 沒列到的全部拒絕」。** 很多人只寫了一條 ALLOW 給 A 服務，結果把 B、C、D 和 Prometheus 全部一起擋掉了。

#### 來源比對：五種寫法的差別

| 欄位 | 比對什麼 | 需要 mTLS？ | 常見誤用 |
|---|---|---|---|
| `principals` | mTLS 憑證裡的 **ServiceAccount** 身分 | **必須** | 填 app 名稱（如 `pmc-epmmformquerygui`）而不是 **SA 名稱** |
| `namespaces` | 來源 namespace（一樣從憑證取） | **必須** | 以為是比對封包來源 IP |
| `ipBlocks` | **封包的來源位址**（L3 的 source IP） | 不用 | 以為 client IP 一定在這裡——前面隔著 LB／ingressgateway 時，比到的是上一跳（LB、node 或 gateway Pod）的 IP，不是原始 client |
| `remoteIpBlocks` | **原始 client IP**（由 `X-Forwarded-For` 或 PROXY protocol 決定） | 不用 | 沒設 `numTrustedProxies`（或 PROXY protocol）就會取到錯的那一段 |
| `requestPrincipals` | **JWT 的 `iss/sub`**（end-user 身分） | 不用（但要有 RequestAuthentication） | 忘了配一條 RequestAuthentication，JWT 根本沒被驗 |

`principals` 的格式一定是：

```
<trust-domain>/ns/<namespace>/sa/<serviceaccount-name>
      |              |                    |
  cluster.local  / ns/ea-pmc  /  sa/pmc-epmmformquerygui
                                     ^
                        這是 ServiceAccount，不是 Deployment 名、
                        不是 app label、不是 Pod 名
```

> **直接關係到你目前環境**：`spring_full_v4.md` 裡的 Deployment **沒有設 `serviceAccountName`**，所以所有 Pod 都跑在 `default` SA 下，身分是 `cluster.local/ns/ea-pmc/sa/default`。這代表**你無法用 principals 區分 ea-pmc 裡的三個 GUI 服務**——它們身分完全一樣。要做細粒度授權，第一步就是給每個 Deployment 獨立 SA（Part 4 有完整做法）。

#### 三種 IP 白名單寫法對照（Q1 的核心）

```yaml
# 寫法 A：ipBlocks —— 比對「直接連進來的 IP」
# 適用：擋 mesh 外部直連、或明確知道對方是固定 IP 的 Pod/node
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-by-direct-ip
  namespace: ea-epmm
spec:
  selector:
    matchLabels:
      app: epmm-api
  action: ALLOW
  rules:
    - from:
        - source:
            ipBlocks: ["10.244.3.0/24"]      # 這是「上一跳」的 IP
```

```yaml
# 寫法 B：remoteIpBlocks —— 比對原始 client IP（來自 X-Forwarded-For 或 PROXY protocol）
# 適用：在 ingressgateway 上做「只有公司內網能進」的白名單
# 前置：必須設 numTrustedProxies（值 = gateway 前面受信任的 proxy 層數）。
#       可設在全域 meshConfig.defaultConfig.gatewayTopology，或用 gateway Pod 的
#       proxy.istio.io/config annotation 個別設。
#       走 PROXY protocol 時，LB 與 gateway 都要支援。
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-corp-network
  namespace: istio-system                    # 放在 gateway 所在的 namespace
spec:
  selector:
    matchLabels:
      istio: ingressgateway                  # 保護 ingressgateway 本身
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks:                  # remote 才是真實 client
              - "10.0.0.0/8"
              - "172.16.0.0/12"
```

```yaml
# 寫法 C：DENY + notRemoteIpBlocks —— 黑名單式（DENY 優先於 ALLOW 判斷）
# 前置：跟寫法 B 一樣，必須設 numTrustedProxies（或走 PROXY protocol）。
#       沒設時 remote IP 退回上一跳（LB 或 node IP，通常就在 10.0.0.0/8 內），
#       notRemoteIpBlocks: ["10.0.0.0/8"] 永遠成立不了 → DENY 不觸發 →
#       所有外部流量靜默放行，而且沒有任何錯誤訊息。
# 注意：內網範圍要與寫法 B 一致（10/8 與 172.16/12），只排除 10/8 的話 172.16/12 的內網來源會被誤擋。
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-external
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: DENY
  rules:
    - from:
        - source:
            notRemoteIpBlocks: ["10.0.0.0/8", "172.16.0.0/12"]   # 「不是內網的」一律擋（與寫法 B 的內網範圍一致）
```

> **A 跟 B 的選擇準則**：問自己「我要擋的那個 IP，在到達這個 Envoy 之前經過幾層 proxy？」
> - client IP 在 L3 就被保留（Pod 直連 Pod，或 LB Service 設了 `externalTrafficPolicy: Local`）→ 用 `ipBlocks`
> - client IP 只存在 `X-Forwarded-For` 或 PROXY protocol 裡 → 用 `remoteIpBlocks`，並確認 `numTrustedProxies`

#### 目標比對與條件

```yaml
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"]
      to:
        - operation:
            methods: ["GET", "POST"]
            paths:   ["/api/v1/*"]
            ports:   ["8080"]              # 字串！寫成數字 8080 會被 API server 拒絕
            notPaths: ["/api/v1/admin/*"]  # 排除
      when:
        - key: request.headers[x-tenant-id]
          values: ["pmc"]
        - key: request.auth.claims[groups]  # JWT claim（需搭配 RequestAuthentication）
          values: ["epmm-user"]
```

| `when` 常用 key | 說明 |
|---|---|
| `request.headers[<name>]` | HTTP header，不分大小寫（見表下說明） |
| `request.auth.claims[<claim>]` | JWT claim |
| `request.auth.principal` | JWT 的 `iss/sub` |
| `source.namespace` / `source.principal` | 來源身分 |
| `destination.port` | workload（容器）port，不是 Service port（見表下說明） |
| `connection.sni` | TLS SNI |

- `request.headers[<name>]`：只支援 HTTP；name 放在 `[]` 內、不加引號，不分大小寫。官方原文：「Istio authorization policy will compare the header name with a case-insensitive approach.」
- `destination.port`：是 workload（容器）上的 port，**不是** Service port；`when.values` 是字串陣列，寫成 `values: ["8080"]`。

#### 踩雷

- **`hosts` 是對 Host header 做精確比對**：client 用短名（`epmm-api-svc`）、或 Host 帶 port（`...:8080`）都比對不到，ALLOW 不命中就 403。官方建議 `hosts`／`notHosts` 只用在 gateway 擋外部流量，sidecar 上不要寫；真要用就同時寫 `host` 與 `host:*` 兩種。
- **`paths` 的單一 `*` 只能放開頭或結尾，中間要改用 URI template**：`/api/*`、`*/health` 可以，`/api/*/detail` 這種中間的 `*` 不支援。但 Istio 1.22 起 `paths` 支援 URI template：`/api/{*}/detail` 比對中間的單一段，`{**}` 比對零到多段且必須放在最後；`/foo/{*}.txt` 這種同一段混字元的寫法不合法。
- **`paths` 比對的是正規化之後的路徑**：預設的 `BASE` 正規化已在授權前依 RFC 3986 處理 `/./` 與 `/../`（`/api/v1/../admin` 預設就被當成 `/api/admin`）。預設**沒有**做的是合併 `//`（`MERGE_SLASHES`）與解碼 `%2F`／`%5C`（`DECODE_AND_MERGE_SLASHES`）；後端若把 `//` 或 `%2F` 視為等價，就把 `meshConfig.pathNormalization.normalization` 調成 `MERGE_SLASHES` 或 `DECODE_AND_MERGE_SLASHES`。
- **`ports` 一定要用字串**。
- **policy 放錯 namespace**：AuthorizationPolicy 要放在**被保護方**的 namespace，不是呼叫方。放在 `istio-system`（root ns）= 全 mesh 生效。
- **上線前的預演不要用 `AUDIT`**：`AUDIT` 沒有另外設稽核 plugin 就不會有任何紀錄，也無法預演 `ALLOW` 會擋掉什麼。預演改用 `istio.io/dry-run: "true"` annotation（Alpha，目前只支援 `ALLOW`、`DENY`）：加在原本的 policy 上，看 Envoy log 與 metrics 的 shadow 結果，確認沒誤傷後把 annotation 拿掉。

---

### 2.3 Sidecar — 限制 Envoy 的視野（含 workloadSelector 最佳實踐）

#### 這是在解決什麼問題

**預設情況下，每一個 sidecar 都載入「整個 mesh 所有服務」的設定。** Istio 官方（Configuration Scoping）：「Each proxy instance will receive configuration for all namespaces as well.」而 proxy 的記憶體用量跟著它持有的設定總量成長（官方效能頁：「The memory consumption of the proxy depends on the total configuration state the proxy holds.」）。所以設定量越大（例如 mesh 裡的服務越多），每個 sidecar 的記憶體可能越多；實際數字依你的 mesh 而異，用 `istioctl proxy-config` 看設定量、`kubectl top pod --containers` 量 `istio-proxy` 的實際用量，不要套別人的數字。

`Sidecar` 資源就是告訴 Envoy：「你只需要認識這幾個服務就好」。它有三個效果：

1. **省記憶體 / 加快啟動**（主要目的）
2. **軟性 egress 管控**——沒列進來的服務，sidecar 根本沒有它的路由設定
3. **減少 config push 風暴**

> **重要澄清**：`Sidecar` **不是安全邊界**。它讓 sidecar「不知道」某個服務，但如果 `outboundTrafficPolicy` 是 `ALLOW_ANY`（Istio 預設），流量還是可能以 passthrough 的方式出去。`outboundTrafficPolicy: REGISTRY_ONLY` 也只是盡力而為的防呆（抓漏寫的 ServiceEntry），官方 Sidecar 參考頁明講它「does not act as one, or as any form of an outbound firewall」。官方建議的強制做法是 Egress Gateway ＋ NetworkPolicy（Pod 的 egress 只允許打到 egress gateway；Istio security best practices：「When combined with a Network Policy, you can enforce all traffic, or some subset, goes through the egress gateway.」）。

#### 最小可用 YAML

```yaml
# ea-pmc 的預設 Sidecar：所有 workload 都套用（沒有 workloadSelector）
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default                    # 慣例：namespace 預設的 Sidecar 命名為 default
  namespace: ea-pmc
spec:
  egress:
    - hosts:
        - "./*"                    # 自己 namespace 的所有服務
        - "istio-system/*"         # 控制平面 / 監控（幾乎一定要留）
        - "ea-epmm/epmm-api-svc.ea-epmm.svc.cluster.local"   # 明確列出跨 ns 依賴
  outboundTrafficPolicy:
    mode: ALLOW_ANY                # 未知目的地放行（預設）。REGISTRY_ONLY 只擋沒註冊的目的地，不是防火牆
```

`egress.hosts` 的語法是 `<namespace>/<dns-name>`：

| 寫法 | 意思 |
|---|---|
| `"./*"` | 自己 namespace 的全部服務 |
| `"*/*"` | 全 mesh（等於沒限制，Istio 預設行為） |
| `"ea-epmm/*"` | `ea-epmm` 的全部服務 |
| `"ea-epmm/epmm-api-svc.ea-epmm.svc.cluster.local"` | 只有這一個服務 |
| `"istio-system/*"` | 控制平面所在 namespace |

#### workloadSelector 怎麼用才是最好的

這是實務上最容易做錯的地方。規則本身很簡單，但**組合起來的行為很反直覺**：

**規則一：一個 namespace 只能有「一個」沒有 `workloadSelector` 的 Sidecar。**

沒有 selector 的 Sidecar = 這個 namespace 的預設值。如果你在同一個 namespace 放了兩個沒有 selector 的 Sidecar，**Istio 的行為是未定義的**（官方只說未定義，沒說會挑哪一個），而且 `kubectl apply` 不會擋。能抓到它的是 `istioctl analyze -n ea-pmc`，會報 IST0111（More than one sidecar resource in a namespace has no workload selector）；多個 selector 命中同一個 workload 則報 IST0110。建議把 `istioctl analyze` 放進 CI。這是最陰的雷。

**規則二：有 `workloadSelector` 的會完全覆蓋（不是合併）namespace 預設值。**

```yaml
# 特例：這個 batch job 需要打外部 API，其他 workload 不需要
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: batch-job-egress
  namespace: ea-pmc
spec:
  workloadSelector:
    labels:
      app: pmc-nightly-sync        # 只套用在這個 workload
  egress:
    - hosts:
        - "./*"                    # 必須重寫一遍！不會自動繼承 default Sidecar 的內容
        - "istio-system/*"
        - "ea-epmm/*"
        - "external/*"             # 這個 job 特有的需求
```

**覆蓋不是合併**——如果你在特例 Sidecar 裡忘了寫 `"./*"`，這個 workload 連自己 namespace 的服務都連不到。這是 `workloadSelector` 最常見的災難。

**規則三：多個帶 selector 的 Sidecar 同時命中同一個 workload = 行為未定義。**

所以 selector 的 label 要選**唯一識別這個 workload 的那一個**（通常是 `app: xxx`），不要用 `tier: backend` 這種會命中多個的。

#### 建議的實務做法

```
每個 namespace：
├── 一份 default Sidecar（無 workloadSelector）  ← 涵蓋 90% 的 workload
│   └── egress: ./*  +  istio-system/*  +  明確列出的跨 ns 依賴
└── 少數特例才加 workloadSelector 的 Sidecar
    └── 用 app label 精準命中，且「完整重寫」egress 清單
```

**收斂順序：先寬後窄，不要一開始就精準。**

1. **第一階段**：先不套任何 Sidecar，跑 `istioctl proxy-config cluster <pod> -n ea-pmc` 看目前這個 sidecar 到底載入了哪些服務
2. **第二階段**：套一份寬鬆的 default Sidecar（`./*` + `istio-system/*` + `*/*`），確認沒壞
3. **第三階段**：把 `*/*` 拿掉，改成明確列出的跨 ns 依賴，**再跑一次 `proxy-config cluster` 比對前後差異**
4. **第四階段**：觀察一週，確認沒有偶發性的連線失敗（有些依賴只在月結、報表時才會用到）

**驗證指令：**

```bash
# 套用前後各跑一次，比對數量與內容
istioctl proxy-config cluster deploy/pmc-epmmformquerygui -n ea-pmc | wc -l
istioctl proxy-config cluster deploy/pmc-epmmformquerygui -n ea-pmc | grep ea-epmm

# 看這個 pod 的 sidecar 記憶體有沒有真的降下來
kubectl top pod -n ea-pmc --containers | grep istio-proxy
```

#### 踩雷

- **忘了留 `istio-system/*`**：官方範例都保留這一項。指標是 Prometheus 主動去 scrape 的，跟 sidecar 的 egress 無關；受影響的是 sidecar 要主動連過去的 istio-system 服務（例如裝在 istio-system 的 tracing collector、egress gateway）。拿掉前先用 `istioctl proxy-config cluster` 確認沒有東西依賴它。
- **跨 namespace 卻用短名呼叫**：從 ea-pmc 呼叫 `http://epmm-api-svc/` 會被 K8s DNS 的 search domain 展開成 `epmm-api-svc.ea-pmc.svc.cluster.local`，本來就查不到（K8s 官方：「DNS queries that don't specify a namespace are limited to the Pod's namespace」），沒套 Sidecar 也一樣。跨 namespace 一定要寫 `epmm-api-svc.ea-epmm` 或完整 FQDN（見 Part 4）。Sidecar `hosts` 的 dnsName 要寫 FQDN 是另一件事。
- **`REGISTRY_ONLY` 沒配 ServiceEntry**：所有外部呼叫（Keycloak、外部 API）全掛。切換前先確認所有外部依賴都有 ServiceEntry。

---

### 2.4 NetworkPolicy — CNI 層防火牆

#### 這是在解決什麼問題

前面三個都在 Envoy 裡。但如果攻擊者拿到一個 Pod 的 shell，他能繞過的是**自己這個 Pod 的 sidecar**；Istio 官方的說法是「the security boundary is that a client may not bypass another pod's sidecar」——只要他打的是對方被攔截的 TCP port，封包仍會經過**對方**的 sidecar 與 AuthorizationPolicy。真正的缺口在 sidecar 管不到的地方：UDP／ICMP（官方：「Redirection only handles TCP based traffic. Any UDP or ICMP packets will not be captured or modified.」）、port 22、sidecar 自己的 port，以及被 `excludeInboundPorts` 排除在攔截之外的 port。NetworkPolicy 在 CNI 層擋（前提是 CNI 有實作 NetworkPolicy），補的就是這幾塊。

這是「深度防禦」的最底層：Istio policy 保護的是「經過 mesh 的流量」，NetworkPolicy 管的是 Pod 層級的 L3/L4 流量（CNI 有實作時）；但 Pod 所在節點進出的流量永遠放行（官方：「traffic to and from the node where a Pod is running is always allowed, regardless of the IP address of the Pod or the node」）。

#### 最小可用 YAML

```yaml
# 步驟 1：ea-epmm 預設全部拒絕（進出都擋）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ea-epmm
spec:
  podSelector: {}              # {} = 選中這個 namespace 的所有 Pod
  policyTypes: [Ingress, Egress]
  # 沒有 ingress/egress 區塊 = 全部拒絕
---
# 步驟 2：一定要先開 DNS，不然什麼都解析不了
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: ea-epmm
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system   # 這個 label 從 1.21 起預設自動加（beta，feature gate NamespaceDefaultLabelName），1.22 GA 後不能關、值不能改
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
---
# 步驟 3：允許 ea-pmc 的 query GUI 打進來
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ea-pmc
  namespace: ea-epmm
spec:
  podSelector:
    matchLabels:
      app: epmm-api
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ea-pmc
          podSelector:                       # 與上面同一個 "-" 項目 = AND（同時滿足）
            matchLabels:
              app: pmc-epmmformquerygui
      ports:
        - { protocol: TCP, port: 8080 }
---
# 步驟 4：Istio 環境必開——放行 ingressgateway 與控制平面
# 注意：下面只用 istio-system 比對。官方建議 gateway 裝在跟控制平面不同的 namespace
# （範例是 istio-ingress），gateway 若在那裡就會被擋，要另加一個 namespaceSelector；
# 先用 kubectl get pod -A -l istio=ingressgateway 確認 gateway 在哪。
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-istio
  namespace: ea-epmm
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
      ports:
        - { protocol: TCP, port: 15012 }    # istiod XDS
        # 不需要 15017：那是 kube-apiserver 打進 istiod 的 webhook 方向，工作負載不會往外連。
        # 若 istio-system 也套了 default-deny，要在 istio-system 那邊另外放行 API server 打進 15017 的 ingress。
```

#### 常用 key

| Key | 說明 |
|---|---|
| `podSelector: {}` | 選中 namespace 內全部 Pod |
| `policyTypes` | `[Ingress]` / `[Egress]` / 兩者。有寫 `policyTypes` 時，**沒列到的方向完全不受此 policy 管**；省略時預設一定含 `Ingress`，只有在有 `egress` 規則時才加上 `Egress`——所以只寫 `egress` 規則、沒寫 `policyTypes` 的 policy，一樣會讓被選中 Pod 的 ingress 進入隔離狀態（官方：「by default `Ingress` will always be set and `Egress` will be set if the NetworkPolicy has any egress rules」） |
| `from` / `to` 的 `podSelector` | 同 namespace 的 Pod |
| `namespaceSelector` | 依 namespace label 選 |
| `namespaceSelector` + `podSelector` **同一項** | AND（某 ns 的某些 pod） |
| `namespaceSelector` / `podSelector` **不同項** | OR |
| `ipBlock.cidr` + `except` | IP 網段（用來放行**叢集外部**；官方：「These should be cluster-external IPs, since Pod IPs are ephemeral and unpredictable.」。叢集內但不在 mesh 裡的 Pod 一樣用 selector，不要寫 `ipBlock`） |

#### 踩雷

- **`-` 的位置決定 AND 還是 OR**，這是 NetworkPolicy 最經典的坑：

```yaml
  # AND：ea-pmc 這個 ns 裡面、且 label 是 app=xxx 的 Pod
  - from:
      - namespaceSelector: {...}
        podSelector: {...}          # <- 沒有 "-"，同一個 element

  # OR：ea-pmc 的所有 Pod，或者 policy 所在 namespace（ea-epmm）裡 label 是 app=xxx 的 Pod
  #     （單獨寫 podSelector 只選 policy 所在 namespace 的 Pod，不是任何 ns）
  - from:
      - namespaceSelector: {...}
      - podSelector: {...}          # <- 有 "-"，不同 element
```

- **多條 NetworkPolicy 是「聯集」**：只要有任何一條放行就通。沒有「拒絕」規則，只有「沒被任何一條允許 = 拒絕」。
- **CNI 必須支援**：官方：「Creating a NetworkPolicy resource without a controller that implements it will have no effect.」flanneld 本身不實作 NetworkPolicy，設了等於沒設，而且不會報錯；但 Flannel 的 Helm chart 有 `netpol.enabled` 選項，可另外裝 Kubernetes SIGs 的 network policy controller。用 `kubectl get pods -n kube-system | grep -Ei "calico|cilium|weave"` 看名字會漏掉其他實作（例如雲端供應商的 dataplane），可靠的做法是在測試 namespace 套一條 deny-all，再實際 curl 看是否真的被擋。
- **忘記開 DNS = 全部掛掉**，而且症狀是 `UnknownHostException` 不是連線被拒，很容易誤判成 DNS 壞了。
- **NetworkPolicy 比對的是 Pod IP，不是 ServiceAccount**。Pod 重建 IP 會變，所以一定要用 selector 而不是寫死 IP。

---

### 2.5 四者對照表 —— 這個需求該用哪一個？

#### 執行順序

```
封包 ──▶ ① NetworkPolicy ──▶ ② PeerAuthentication ──▶ ③ AuthorizationPolicy ──▶ ④ App
         (CNI, L3/L4)         (Envoy, mTLS 身分)       (Envoy RBAC, L7)         (Spring Security)
              |                      |                        |                      |
        擋掉的症狀:              擋掉的症狀:               擋掉的症狀:             擋掉的症狀:
        通常是 timeout         連線 reset /              HTTP 403               你自己的
        (RST 與否依 CNI)       TLS handshake fail        RBAC: access denied    403 頁面
        (無 Istio log)          (無 403)
```

`Sidecar` 不在這條鏈上——它是**設定下發**的過濾器，決定 Envoy 有沒有那個目的地的路由設定，主要作用在「送得出去嗎」（`egress`）而不是「進得來嗎」。它也有 `ingress` 欄位可替 workload 設定 inbound listener，但本節只用到 `egress`，而且 Sidecar 不是授權機制（不會依身分允許或拒絕請求）。

#### 能力對照

| 能力 | NetworkPolicy | PeerAuth | AuthzPolicy | Sidecar |
|---|:---:|:---:|:---:|:---:|
| 比對來源 **IP / CIDR** | 可以 | 不行 | 可以（`ipBlocks`） | 不行 |
| 比對來源 **ServiceAccount 身分** | 不行 | 提供身分 | 可以（`principals`） | 不行 |
| 比對 **HTTP path / method / header** | 不行 | 不行 | 可以 | 不行 |
| 比對 **JWT claim** | 不行 | 不行 | 可以 | 不行 |
| 加密傳輸 | 不行 | 可以 | 不行 | 不行 |
| 控制 **出向**（我能打誰） | 可以 | 不行 | 有限 | 可以（軟性） |
| 擋得住繞過 sidecar 的直連 | 可以 | 部分 | 部分 | 不行 |
| 不需要 Istio | 可以 | 不行 | 不行 | 不行 |
| 省 sidecar 記憶體 | 不行 | 不行 | 不行 | 可以 |

#### 決策表

| 你的需求 | 用這個 | 為什麼不用別的 |
|---|---|---|
| 只讓 A 服務呼叫 B 服務 | **AuthorizationPolicy** `principals` | NetworkPolicy 只認 label 和 IP，不認密碼學身分（`principals` 認的是 mTLS 憑證裡的 ServiceAccount 身分），也看不到 L7 |
| 只讓某個 IP 網段從外部進來 | **AuthorizationPolicy** `remoteIpBlocks`（放 ingressgateway 上） | `ipBlocks` 會比到 LB 的 IP；`remoteIpBlocks` 有前提（見表下說明） |
| 只讓 B 的 `GET /api/*` 被呼叫，`DELETE` 不行 | **AuthorizationPolicy** `to.operation` | 只有它懂 L7 |
| 服務間流量要全加密 | **PeerAuthentication** `STRICT` | 其他三個都不做加密 |
| 防止被入侵的 Pod 橫向掃描整個網段 | **NetworkPolicy** default-deny | Istio policy 管不到 UDP／ICMP、被排除在攔截之外的 port，也管不到被入侵 Pod 自己的出向流量 |
| 限制某個服務只能連特定外部網址 | **ServiceEntry** + **Egress Gateway**（在 gateway 上限制主機名）+ **NetworkPolicy egress**（Pod 只允許打到 egress gateway） | NetworkPolicy 不能依主機名過濾，Sidecar `REGISTRY_ONLY` 也不是安全邊界（見表下說明） |
| sidecar 記憶體太大 / config push 太慢 | **Sidecar** `egress.hosts` | 這是它的主要用途；它也能設每個 workload 的 `outboundTrafficPolicy` 與 `ingress` listener（見 2.3 的「重要澄清」與本節執行順序下方的說明） |
| 只讓帶特定 JWT group 的使用者存取 | **AuthorizationPolicy** + **RequestAuthentication** | 前三個都不看 JWT |

**外部網址限制的組合：** 主機名的限制放在 Egress Gateway 上，NetworkPolicy 只負責讓 Pod 的 egress 打不出 egress gateway 以外的地方；官方「Security Best Practices」寫的是「When combined with a Network Policy, you can enforce all traffic, or some subset, goes through the egress gateway.」`REGISTRY_ONLY` 只能當防呆，為什麼不能單獨當限制見 Sidecar 一節的「重要澄清」（Sidecar 管的是 sidecar 自己的設定下發，被入侵的 Pod 可以繞過自己的 sidecar——這是由機制推得，不是官方逐字寫的結論）。

**`remoteIpBlocks` 的前提：** 要先設 `gatewayTopology.numTrustedProxies`（或在 gateway 加 annotation），前面的 LB 要追加 `X-Forwarded-For`；純 TCP LB 改用 PROXY protocol。沒設的話 `remote.ip` 拿不到真正的 client IP（細節見 Part 1 關鍵觀念二）。

#### 一句話總結

> **NetworkPolicy 管「封包能不能到」，PeerAuthentication 管「你是誰」，AuthorizationPolicy 管「你能做什麼」，Sidecar 管「你看得到誰」。**
>
> 正式環境四個都要有。只有 Istio policy 而沒有 NetworkPolicy，等於前門上鎖後門大開。

### 參考來源

本 Part 經查證修正的說法所依據的官方文件（查證帳本 `tasks/guide-verification-ledger.md` 的 P02 各列）：

- Istio — Security concepts：https://istio.io/latest/docs/concepts/security/
- Istio — CRD 定義（crd-all.gen.yaml）：https://raw.githubusercontent.com/istio/istio/master/manifests/charts/base/files/crd-all.gen.yaml
- Istio — PeerAuthentication reference：https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Health Checking of Istio Services：https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/
- Istio — AuthorizationPolicy reference：https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Authorization Policy Dry Run：https://istio.io/latest/docs/tasks/security/authorization/authz-dry-run/
- Istio — Authorization for Ingress Gateway：https://istio.io/latest/docs/tasks/security/authorization/authz-ingress/
- Istio — Authorization Policy Conditions：https://istio.io/latest/docs/reference/config/security/conditions/
- Envoy — HTTP header manipulation (x-forwarded-for)：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers
- Istio — Security Best Practices：https://istio.io/latest/docs/ops/best-practices/security/
- Istio — Authorization Policy Normalization：https://istio.io/latest/docs/reference/config/security/normalization/
- Istio — 1.22 change notes：https://istio.io/latest/news/releases/1.22.x/announcing-1.22/change-notes/
- Istio — Performance and Scalability：https://istio.io/latest/docs/ops/deployment/performance-and-scalability/
- Istio — Scoping Configuration：https://istio.io/latest/docs/ops/configuration/mesh/configuration-scoping/
- Istio — Sidecar reference：https://istio.io/latest/docs/reference/config/networking/sidecar/
- Istio — Configuration Analysis Messages：https://istio.io/latest/docs/reference/config/analysis/
- Istio — Prometheus integration：https://istio.io/latest/docs/ops/integrations/prometheus/
- Kubernetes — DNS for Services and Pods：https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes — Network Policies：https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Well-Known Labels, Annotations and Taints：https://kubernetes.io/docs/reference/labels-annotations-taints/
- Kubernetes — KEP-2161（namespace 預設 label）：https://www.kubernetes.dev/resources/keps/2161/
- Istio — Installing Gateways：https://istio.io/latest/docs/setup/additional-setup/gateway/
- Istio — Application Requirements：https://istio.io/latest/docs/ops/deployment/application-requirements/
- Kubernetes — Admission Controllers（extensible）：https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Flannel — 專案首頁（netpol.enabled）：https://github.com/flannel-io/flannel
- Istio — Network Topologies：https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/

---

## Part 3：`RBAC: access denied` 除錯專章

### 第一件事：這不是 K8s RBAC

看到 `RBAC: access denied` 第一直覺是去查 Role / RoleBinding —— **方向完全錯了**。

這行字是 **Envoy 的 RBAC http filter** 印出來的，而 Istio 的 `AuthorizationPolicy` 就是被翻譯成這個 filter。兩者完全無關：

| | **Istio AuthorizationPolicy** | **K8s RBAC** |
|---|---|---|
| 錯誤訊息 | `RBAC: access denied` | `User "system:serviceaccount:ea-pmc:default" cannot get resource "pods" in API group "" in the namespace "ea-epmm"` |
| HTTP 狀態 | **403**，body 只有 `RBAC: access denied` 這一行純文字 | 403，body 是一整段 JSON |
| 誰擋的 | 目標 Pod 的 **istio-proxy sidecar**（或 ingressgateway） | **kube-apiserver** |
| 管什麼 | 服務之間的**業務流量** | 誰能對 **K8s API** 做什麼（`kubectl get pods` 之類） |
| 相關資源 | `AuthorizationPolicy` / `PeerAuthentication` | `Role` / `ClusterRole` / `RoleBinding` |
| 怎麼查 | `istioctl x authz check` | `kubectl auth can-i` |

**一句話判斷法：**
- 你的請求是「**服務打服務的業務 API**」（`GET /api/v1/forms`）→ 是 **Istio**，往下讀
- 你的請求是「**程式呼叫 K8s API**」（Spring Cloud Kubernetes、operator、`kubectl`）→ 是 **K8s RBAC**，跳到本章最後一節

---

### Istio 版：五大成因決策樹

```
收到 403 + "RBAC: access denied"
        |
        ├─ [1] 先確認是哪個 Envoy 擋的：ingressgateway 還是目標 sidecar？
        |      最可靠：看各個 proxy 的 access log，response code details 出現
        |      rbac_access_denied_matched_policy[...] 的那個 Envoy 就是擋下的那個
        |      （輔助線索：response header 的 x-envoy-upstream-service-time 只代表
        |      回應那一跳的 Envoy 有把請求轉給上游；服務直接打服務、沒經 gateway 時，
        |      據此推論沒有該 header 就是 gateway 擋的並不可靠，不能單靠它下結論）
        |
        ├─ [2] 這個 workload 到底被哪些 policy 選中？
        |      istioctl x authz check <pod> -n <ns>
        |
        ├─ [3] 有 DENY policy 命中嗎？（DENY 優先於 ALLOW）
        |
        ├─ [4] 有 ALLOW policy 選中但條件沒對上嗎？
        |      → 90% 的案例在這裡，往下看四個子原因
        |
        └─ [5] policy 是不是放在 istio-system（全 mesh 生效）？
```

#### 成因 1：有 ALLOW policy 選中，但你不在名單裡

**這是最常見的。** 記住 Part 2.2 的規則：**只要有任何一條 ALLOW policy 的 `selector` 命中這個 workload，所有不符合規則的請求就一律 403。**

典型情境：你替 `epmm-api` 寫了一條「允許 pmc-epmmformquerygui」的 ALLOW policy，結果 **其他沒被列進名單的服務全部被擋**，因為它們沒被列進去。

> 注意：預設情況下 Prometheus 與 kubelet probe 通常**不會**被擋。Istio 預設會把 kubelet 的 health check probe 改寫到 sidecar 的 15020 port（probe rewrite，官方文件說明在所有內建的 Istio configuration profile 中預設啟用），Prometheus 也是從 `:15020/stats/prometheus` 抓合併後的 metrics（metrics merging），這兩條路徑都不經過 inbound RBAC filter。只有在你關掉 probe rewrite 或 metrics merge、讓 kubelet 或 Prometheus 直接打 app port 時，它們才會被這條 ALLOW policy 擋下。

```bash
# 看這個 pod 被哪些 policy 管
istioctl x authz check deploy/epmm-api -n ea-epmm
```

輸出會列出所有作用在這個 workload 上的 policy 與 action。**如果你只期待一條卻看到三條，先搞清楚另外兩條哪來的。**

修法：把遺漏的來源補進同一條 policy 的 `rules`（多個 `rules` 之間是 OR）：

```yaml
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"]
    - from:                                    # 第二條 rule = OR
        - source:
            namespaces: ["istio-system"]       # 放行 ingressgateway
    - to:                                      # 第三條：任何來源都能打 health
        - operation:
            paths: ["/gui_epmmFormQuery/actuator/health"]
```

#### 成因 2：`principals` 寫成 app 名稱而不是 ServiceAccount

**這條你一定會中**，因為你現在的 Deployment 沒設 `serviceAccountName`。

```yaml
# 錯的寫法
principals: ["cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"]
#                                       ^^^^^^^^^^^^^^^^^^^^^
#            這是 Deployment 名 / app label，但 SA 其實叫 default
```

```yaml
# 目前實際的身分是這個
principals: ["cluster.local/ns/ea-pmc/sa/default"]
```

**怎麼確認真正的身分：**

```bash
# 方法 1：看 Pod 用哪個 SA
kubectl get pod -n ea-pmc -l app=pmc-epmmformquerygui \
  -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'

# 方法 2：直接看 sidecar 拿到的憑證裡的身分（最權威）
# JSON 裡的憑證是 base64 編碼的 inlineBytes，直接 grep 找不到 spiffe://；
# 要先解 base64、再用 openssl 展開，看 Subject Alternative Name（官方 Istio 排錯文件的寫法）
istioctl proxy-config secret deploy/pmc-epmmformquerygui -n ea-pmc -o json \
  | jq -r '[.dynamicActiveSecrets[] | select(.name == "default")][0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
# 應該看到 URI:spiffe://cluster.local/ns/ea-pmc/sa/<serviceAccount>
```

**正確做法是給每個 Deployment 獨立 SA**（Part 4 步驟 1），而不是把 policy 改成 `sa/default` —— 因為 `sa/default` 等於「這個 namespace 裡所有沒指定 `serviceAccountName` 的 Pod」（有指定其他 SA 的不算），授權粒度等於沒有。

#### 成因 3：mTLS 沒開，principal 是空的

`principals` / `namespaces` 的值**全部來自 mTLS 憑證**。如果連線是明文（PERMISSIVE 模式下的明文連線），Envoy 拿不到對方身分，`principals` 條件**永遠不匹配**，結果就是 403。

**症狀特徵：policy 看起來完全正確，但就是不通。**

```bash
# 檢查 1：這個 namespace 的 mTLS 模式
kubectl get peerauthentication -A

# 檢查 2：來源 Pod 有沒有 sidecar？（沒 sidecar = 沒身分）
# Istio 1.27 起（符合條件的 Pod）istio-proxy 是 native sidecar，放在 initContainers；
# 舊版或不符合條件的 Pod 則在 containers。只查 containers 會誤判成沒注入，所以兩處都查
kubectl get pod -n ea-pmc -l app=pmc-epmmformquerygui \
  -o jsonpath='{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}{"\n"}'
# 兩處合起來應該要看到 istio-proxy

# 檢查 3：實際流量是不是 mTLS
# 用 pilot-agent request 而不是 curl：官方範例都這樣用，預設映像和 distroless variant 都能跑
# （distroless variant 沒有 curl，也沒有 shell）
# 注意 ssl.handshake 是 listener 層級的累計計數，判斷不了「某個來源」有沒有走 mTLS；
# 要判斷個別來源，看請求進來時的 XFCC header（見下面「精準除錯」一節）
kubectl exec -n ea-epmm deploy/epmm-api -c istio-proxy -- \
  pilot-agent request GET stats | grep ssl.handshake
```

如果來源 Pod 根本沒被注入 sidecar，就一定沒有身分。什麼條件下會注入、什麼條件下不會，見 Part 0 的 sidecar 注入段落。

#### 成因 4：`to.operation` 的條件沒對上

四個常見的細節錯誤：

| 錯誤 | 症狀 | 修法 |
|---|---|---|
| `ports: [8080]` 寫成數字 | **apply 時就會被拒絕** | 改成 `ports: ["8080"]` |
| `ports` 填 Service port；它比對的是連線實際的目的 port | 靜默 403 | 用 Pod 的 containerPort（Service 的 `targetPort`） |
| `paths: ["/api"]` 但實際請求是 `/api/v1/forms` | 403 | 改成 `/api/*`（前綴） |
| `paths` 忘了算 context path | 403 | 你的 app 是 `/gui_epmmFormQuery/rs/gui/*`，不是 `/rs/gui/*` |

> **對你的環境特別提醒**：`app.context-prefix: /gui_epmmFormQuery` 代表所有實際路徑都帶這個前綴。AuthorizationPolicy 的 `paths` 比對的是**正規化後的 path**（預設是 BASE 正規化，依 RFC 3986，並把 `\` 轉成 `/`），不是 client 送來的原樣字串；所以一定要寫全 `/gui_epmmFormQuery/...`。

#### 成因 5：policy 放在 root namespace，全 mesh 生效

放在 `istio-system`（預設的 root namespace）的 AuthorizationPolicy **會套用到整個 mesh 的所有 workload**。

典型災難：有人為了保護 ingressgateway 寫了一條 ALLOW policy 放在 `istio-system`，**但忘了加 `selector`**，結果整個 mesh 的所有服務都被那條規則管住，沒列到的全部 403。

```bash
# 一定要檢查這個
kubectl get authorizationpolicy -n istio-system \
  -o custom-columns=NAME:.metadata.name,SELECTOR:.spec.selector,TARGETREFS:.spec.targetRefs
# SELECTOR 和 TARGETREFS 兩欄都是 <none> 的 policy，就是作用到全 mesh 的那一條
# （不要用 grep selector：它只列出「有」selector 的，危險的「沒有」反而看不到）
```

放在 `istio-system` 的 policy **必須有 `selector` 或 `targetRefs`**（兩者擇一即可），兩者都沒有才會套用到全 mesh（Istio：「If the selector and the targetRef are not set, the selector will match all workloads.」）。

---

### 精準除錯：打開 Envoy 的 RBAC debug log

這是最快找出「到底哪條規則擋的」的方法：

```bash
# 1. 把目標 pod 的 rbac logger 調成 debug
istioctl proxy-config log deploy/epmm-api -n ea-epmm --level rbac:debug

# 2. 重打一次失敗的請求，然後看 log
kubectl logs -n ea-epmm deploy/epmm-api -c istio-proxy --tail=100 | grep -i rbac

# 3. 查完記得調回來（debug log 很吵，會拖慢效能）
istioctl proxy-config log deploy/epmm-api -n ea-epmm --level rbac:warning
```

被 **DENY policy** 命中時，log 會印出 `enforced denied, matched policy ns[ea-epmm]-policy[xxx]-rule[0]` —— 這時 policy 名稱和第幾條 rule 都看得到。

但最常見的成因 1（有 ALLOW policy、請求沒命中任何 rule）不是這樣：Envoy 的 RBAC filter 會印 `enforced denied, matched policy none`。**看到 `matched policy none`，就是 ALLOW 名單沒對上**，回頭檢查 ALLOW policy 的 `from`／`to`／`when`，而不是找哪條 policy 擋的。

**看實際下發到 Envoy 的 RBAC 設定：**

```bash
istioctl proxy-config listener deploy/epmm-api -n ea-epmm \
  --port 15006 -o json | grep -A50 envoy.filters.http.rbac
```

sidecar 的 inbound 流量全部由 iptables 導到 `0.0.0.0:15006` 這個 listener（Istio：「every sidecar has a listener bound to `0.0.0.0:15006` which is where IP tables routes all inbound pod traffic to.」），所以要看 `15006`；`--port 8080` 篩到的頂多是 outbound listener，裡面沒有 inbound 的 RBAC filter。輸出裡再找 destination port 為 8080 的那條 filter chain。官方也示範另一種寫法：`pilot-agent request GET config_dump`（在 `-c istio-proxy` 容器裡執行）再 grep。

**看來源身分有沒有正確傳過來：**

```bash
# config_dump 只看得到 Envoy「怎麼處理 XFCC」的設定（forward_client_cert_details），
# 看不到某個請求實際收到的 header，所以不能用它來確認來源身分
kubectl exec -n ea-epmm deploy/epmm-api -c istio-proxy -- \
  pilot-agent request GET config_dump | grep -i forward_client_cert
```

要看**實際收到**的 XFCC header（`x-forwarded-client-cert`），用下面任一種方式：

* 讓目標 app 回顯 request header（例如 httpbin 的 `/headers`，或在 Spring 裡印出 `X-Forwarded-Client-Cert`）。
* 把 `%REQ(X-FORWARDED-CLIENT-CERT)%` 加進 sidecar 的 access log 格式。

header 裡出現 `URI=spiffe://…` 就是來源的身分；Istio 文件也說「That header's presence is evidence that mutual TLS is used.」

---

### K8s RBAC 版：如果你的 403 其實是 API server 擋的

判斷特徵：錯誤訊息裡有 `cannot <verb> resource` 和 `in API group`，而且發生在你的程式呼叫 K8s API 時（例如 Spring Cloud Kubernetes 讀 ConfigMap、或 operator）。

```bash
# 1. 確認這個 SA 到底能做什麼
kubectl auth can-i list pods \
  --as=system:serviceaccount:ea-pmc:pmc-epmmformquerygui -n ea-pmc

kubectl auth can-i --list \
  --as=system:serviceaccount:ea-pmc:pmc-epmmformquerygui -n ea-pmc

# 2. 找出這個 SA 有哪些「直接」綁定；同時 grep 它所屬的群組名
#    （SA 的群組是 system:serviceaccounts 與 system:serviceaccounts:<ns>，
#     另外所有已驗證身分都屬於 system:authenticated）
kubectl get rolebinding,clusterrolebinding -A -o json \
  | grep -E -B5 -A5 'pmc-epmmformquerygui|system:serviceaccounts|system:authenticated'
```

注意 grep 只找得到字面上寫了名字的綁定。SA 也會透過群組拿到權限（K8s：「ServiceAccounts have names prefixed with `system:serviceaccount:`, and belong to groups that have names prefixed with `system:serviceaccounts:`.」），所以**最終以步驟 1 的 `kubectl auth can-i --list --as=…` 為準**。

補權限（最小權限原則，只給讀自己 namespace 的 ConfigMap）：

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: config-reader
  namespace: ea-pmc
rules:
  - apiGroups: [""]
    resources: ["configmaps"]           # 只給 configmap，不要給 secrets
    verbs: ["get", "list", "watch"]     # 只給讀，不給 create/delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pmc-query-config-reader
  namespace: ea-pmc
subjects:
  - kind: ServiceAccount
    name: pmc-epmmformquerygui
    namespace: ea-pmc
roleRef:
  kind: Role                            # Role = 只在這個 ns 生效
  name: config-reader
  apiGroup: rbac.authorization.k8s.io
```

> **K8s RBAC 的原則**：`Role` + `RoleBinding` 是 namespace 範圍；`ClusterRole` + `ClusterRoleBinding` 是全 cluster。第三種組合 `ClusterRole` + `RoleBinding` 很有用——定義一次通用的角色，綁到不同 namespace 各自生效。

---

### 一頁速查

| 症狀 | 最可能原因 | 一行指令 |
|---|---|---|
| 403 `RBAC: access denied` | 有 ALLOW policy 但你不在名單 | `istioctl x authz check <pod> -n <ns>` |
| policy 看起來對卻不通 | mTLS 沒開 / 來源沒 sidecar | `kubectl get peerauthentication -A` |
| principals 比對不到 | SA 名稱寫錯（多半是 `default`） | `kubectl get pod -o jsonpath='{..serviceAccountName}'` |
| 全 mesh 突然大量 403 | root ns 有沒帶 selector 的 policy | `kubectl get authorizationpolicy -n istio-system` |
| 不確定哪條規則擋的 | — | `istioctl proxy-config log <pod> --level rbac:debug` |
| `cannot get resource ... API group` | 這是 K8s RBAC，不是 Istio | `kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>` |

### 參考來源

本 Part 經查證修正的說法所依據的官方文件（查證帳本 `tasks/guide-verification-ledger.md` 的 P03 各列）：

- Envoy — rbac_filter.cc 原始碼：https://raw.githubusercontent.com/envoyproxy/envoy/main/source/extensions/filters/http/rbac/rbac_filter.cc
- Envoy — RBAC filter：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter
- Envoy — Router filter：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter
- Envoy — HTTP connection manager（forward_client_cert_details）：https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto
- Istio — Security Problems：https://istio.io/latest/docs/ops/common-problems/security-issues/
- Istio — Health Checking of Istio Services：https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/
- Istio — Prometheus integration：https://istio.io/latest/docs/ops/integrations/prometheus/
- Istio — 1.27 upgrade notes：https://istio.io/latest/news/releases/1.27.x/announcing-1.27/upgrade-notes/
- Istio — Harden Docker Container Images：https://istio.io/latest/docs/ops/configuration/security/harden-docker-images/
- Istio — Installing the Sidecar：https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/
- Istio — AuthorizationPolicy reference：https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Security Best Practices：https://istio.io/latest/docs/ops/best-practices/security/
- Istio — Debugging Your Configuration（proxy-config）：https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- Istio — istioctl reference：https://istio.io/latest/docs/reference/commands/istioctl/
- Istio — Authentication Policy：https://istio.io/latest/docs/tasks/security/authentication/authn-policy/
- Kubernetes — Service Accounts：https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes — Using RBAC Authorization：https://kubernetes.io/docs/reference/access-authn-authz/rbac/

---

## Part 4：同 cluster 跨 namespace 互打

**場景**：`ea-pmc` 的 `pmc-epmmformquerygui` 要呼叫 `ea-epmm` 的 `epmm-api`。

### 這是在解決什麼問題

K8s 的 namespace **預設不是網路邊界** —— 不裝任何東西的話，`ea-pmc` 的 Pod 可以自由打 `ea-epmm` 的任何 Pod 任何 port。namespace 只是名稱空間與 RBAC 的邊界，不是安全邊界。

所以「跨 namespace 互打」真正要處理的是四件事：**DNS 怎麼寫、Sidecar 看不看得到、對方允不允許、以及網路層通不通。**

### 步驟 0：DNS 要寫全名

```java
// 錯：從 ea-pmc 的 Pod 打這個名字，DNS 解析不到
restTemplate.getForObject("http://epmm-api-svc/api/v1/forms", ...);

// 可以：至少要帶 namespace
"http://epmm-api-svc.ea-epmm/api/v1/forms"

// 可讀性最好：完整 FQDN（但它只有 4 個點、少於 ndots:5，照樣會先跑 search domain，不會比上一行省查詢）
"http://epmm-api-svc.ea-epmm.svc.cluster.local:8080/api/v1/forms"

// 真的要省 DNS 查詢：FQDN 尾端加一個點（絕對名稱，不經過 search domain）
"http://epmm-api-svc.ea-epmm.svc.cluster.local.:8080/api/v1/forms"
```

原因：Pod 的 `/etc/resolv.conf` 是這樣的

```
search ea-pmc.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

短名 `epmm-api-svc` 會先被補成 `epmm-api-svc.ea-pmc.svc.cluster.local`（自己的 namespace）→ 找不到 → 再試下一個 search domain。**跨 namespace 時第一次一定會失敗**。`ndots:5` 的意思是：少於 5 個點的名字會**先**依序套 search domain、**命中就停**，全部都 miss 才查原名（resolv.conf(5)：「Resolver queries having fewer than ndots dots (default is 1) in them will be attempted using each component of the search path in turn until a match is found.」）。所以 `epmm-api-svc.ea-epmm` 第 2 次就命中；完整 FQDN `epmm-api-svc.ea-epmm.svc.cluster.local` 只有 4 個點，反而要先把前面的 search domain 全試完（都失敗）才查到原名，查詢次數更多。只有找不到的名字（例如外部網域）才會跑完整串。要真正繞過 search list，在 FQDN 尾端加點，或在 Pod 的 `dnsConfig.options` 調低 `ndots`。

**驗證：**

```bash
# 預設的 istio-proxy 映像只裝了 knot-dnsutils、沒有 nslookup（distroless 變體連 shell 都沒有），
# 所以用臨時除錯容器來查
# （kubectl debug 要指定 Pod，不能直接寫 deploy/…，所以先取一個 Pod 名字）
POD=$(kubectl get pod -n ea-pmc -l app=pmc-epmmformquerygui -o jsonpath='{.items[0].metadata.name}')
kubectl debug -n ea-pmc "$POD" -it --image=busybox:1.36 --target=app -- \
  nslookup epmm-api-svc.ea-epmm.svc.cluster.local
# 確定是預設 proxyv2 映像時，也可以直接在 sidecar 裡用 kdig：
#   kubectl exec -n ea-pmc deploy/pmc-epmmformquerygui -c istio-proxy -- kdig epmm-api-svc.ea-epmm.svc.cluster.local
```

### 步驟 1：兩邊各給獨立 ServiceAccount（最重要的一步）

**沒有這步，後面的授權全部做不到粒度。** 你現在兩邊都是 `default` SA，等於「整個 namespace 一個身分」。

```yaml
# ea-pmc 側
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
---
# ea-epmm 側
apiVersion: v1
kind: ServiceAccount
metadata:
  name: epmm-api
  namespace: ea-epmm
```

然後在 Deployment 的 **`spec.template.spec`** 加一行（注意是 Pod spec，不是 Deployment spec）：

```yaml
spec:
  template:
    spec:
      serviceAccountName: pmc-epmmformquerygui   # <- 加這行
      automountServiceAccountToken: false        # <- 順便：不需要呼叫 K8s API 就關掉
      containers:
        - name: app
          # ...（其餘欄位不變）
```

> `automountServiceAccountToken: false` 是免費的安全強化——它只影響「呼叫 K8s API 的 token」，**不影響 Istio mTLS 身分**（Istio 用的是 SDS 下發的憑證）。除非你的 app 真的要打 K8s API，否則都應該關掉。

**既有 Pod 的 SA 改不了，一定要換成新 Pod 才會拿到新身分**（K8s：「You cannot update the `.spec.serviceAccountName` field of a Pod that already exists.」）。但改 `spec.template.spec.serviceAccountName` 本身就是改 pod template，`kubectl apply` 會自動觸發滾動更新，不用另外 `rollout restart`（多跑只是再滾一輪）：

```bash
kubectl apply -f <含 serviceAccountName 的 Deployment>.yaml
kubectl rollout status deploy/pmc-epmmformquerygui -n ea-pmc
# 確認新身分：憑證是 base64 的 inlineBytes，直接 grep 找不到 spiffe://，要解碼後用 openssl 看 SAN（同步驟 2 的方法 2）
istioctl proxy-config secret deploy/pmc-epmmformquerygui -n ea-pmc -o json \
  | jq -r '[.dynamicActiveSecrets[] | select(.name == "default")][0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
```

### 步驟 2：ea-epmm 側開授權

```yaml
# 2a. STRICT：拒絕沒有 sidecar 的明文流量。
#     principals 本身不需要它：沒有 PeerAuthentication 時是 PERMISSIVE ＋ auto-mTLS，
#     兩端都有 sidecar 的連線照樣走 mTLS、principal 照樣有值（見 Part 0「表中三列的補充」的 PeerAuthentication 一條）。
#     STRICT 的作用是讓沒有 sidecar 的 client 無法用明文繞過身分檢查。
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: ea-epmm
spec:
  mtls:
    mode: STRICT
---
# 2b. 授權 ea-pmc 的 query GUI
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: epmm-api-access
  namespace: ea-epmm
spec:
  selector:
    matchLabels:
      app: epmm-api
  action: ALLOW
  rules:
    # 規則 1：pmc 的 query GUI 可以讀 API
    - from:
        - source:
            principals:
              - "cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/*"]

    # 規則 2（OR）：放行 ingressgateway，否則從外面進來的流量全掛
    - from:
        - source:
            principals:
              # 這個 SA 名稱要先查實際值再填，寫錯時規則 2 永遠不命中、外部流量全被拒：
              #   istioctl / operator 預設裝法是 istio-ingressgateway-service-account；
              #   Helm gateway chart 則等於 release 名稱。
              #   查法：kubectl get pod -n istio-system -l istio=ingressgateway -o jsonpath='{..serviceAccountName}'
              - "cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"

    # 規則 3（OR）：health / metrics 放行。注意它沒有 from，等於對「所有來源」開放這些 path。
    #   預設情況下用不到：probe 預設被改寫到 sidecar 的 15020、Prometheus metrics 預設也合併後從 15020 抓，
    #   都不經過 inbound AuthorizationPolicy。只有你關掉 probe 改寫或 metrics merge
    #   （meshConfig.enablePrometheusMerge=false）時才需要這條；需要時 paths 也請縮到最小。
    - to:
        - operation:
            paths: ["/actuator/health*", "/metrics"]
```

> **務必記得規則 2。** 「加了 AuthorizationPolicy 之後服務就掛了」常見的原因就是漏了 ingressgateway。規則 3 只有在關掉 probe 改寫或 metrics merge 時才需要（見上面規則 3 的註解）。

**上線前先用 dry-run 預演一輪（不要用 `AUDIT`）**

`AUDIT` 不影響放行／拒絕，記錄的是「命中規則」的請求，而且沒有另外設定並啟用稽核 plugin 就什麼都不會記，無法預演 `ALLOW` 會擋掉什麼。保留 `action: ALLOW`，改加 dry-run annotation（Alpha）：

```yaml
metadata:
  annotations:
    istio.io/dry-run: "true"   # 只預演、不執行；跑幾天，確認沒有該放行卻被標成 shadow denied 的來源
```

結果看 proxy log 中的 `shadow denied`，或 proxy 指標上的 `authz_dry_run_result` label（要先把 rbac 的 log level 調成 debug 才看得到 `shadow denied`）；確認沒誤傷後把 annotation 拿掉才會真正生效。

### 步驟 3：ea-pmc 側的 Sidecar 要看得到對方

如果你有套 `Sidecar` 資源做收斂，**必須把 `ea-epmm` 加進 egress**，否則 sidecar 根本沒有對方的路由設定：

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: ea-pmc
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
        - "ea-epmm/epmm-api-svc.ea-epmm.svc.cluster.local"   # <- 加這行
```

**驗證 sidecar 真的看得到：**

```bash
istioctl proxy-config cluster deploy/pmc-epmmformquerygui -n ea-pmc \
  --fqdn epmm-api-svc.ea-epmm.svc.cluster.local
# 有輸出 = 看得到；空的 = Sidecar 把它濾掉了
```

### 步驟 4：NetworkPolicy 版（底層防護）

Istio policy 是由**被呼叫端自己的 sidecar** 執行的。攻擊者在自己的 Pod 裡能繞過的只有**自己**的 sidecar（官方：「the security boundary is that a client may not bypass _another_ pod's sidecar.」），所以 AuthorizationPolicy 管不到的是 sidecar 不處理的流量（UDP／ICMP 等非 TCP）與被排除在攔截之外的 port；NetworkPolicy 補的是 L3/L4 的縱深防禦，也防 sidecar 被拿掉或設錯。加上 NetworkPolicy：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: epmm-api-ingress
  namespace: ea-epmm
spec:
  podSelector:
    matchLabels:
      app: epmm-api
  policyTypes: [Ingress]
  ingress:
    # 只允許 ea-pmc 的 query GUI
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ea-pmc
          podSelector:
            matchLabels:
              app: pmc-epmmformquerygui
      ports:
        - { protocol: TCP, port: 8080 }
    # 必開：ingressgateway
    # 只寫 namespaceSelector（沒有 podSelector）會放行 istio-system 的【所有 Pod】
    # （官方範例裡單獨一個 namespaceSelector 元素的語意是「from any Pod in any namespace with the label user=alice」）；
    # 少了 ports 則不限 port。所以把 podSelector 寫進【同一個】from 元素 ——
    # 官方：「A single to/from entry that specifies both namespaceSelector and podSelector selects particular Pods within particular namespaces.」
    # 並限定 8080，收斂到 ingressgateway 的 Pod。
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              istio: ingressgateway
      ports:
        - { protocol: TCP, port: 8080 }
```

**兩者的分工（這是 Q1 對照表在真實場景的應用）：**

| 攻擊情境 | NetworkPolicy 擋得住？ | AuthorizationPolicy 擋得住？ |
|---|:---:|:---:|
| `ea-other` 的 Pod 打 `epmm-api:8080` | 可以 | 可以 |
| `ea-pmc` 的**別的** Pod 打 `epmm-api` | 可以（podSelector 有比對） | 可以（principals 不同） |
| `ea-pmc` 的 query GUI 打**不該打的** `DELETE /api/admin` | **不行**（只看 IP/port） | **可以**（L7） |
| 攻擊者在 pod 裡直接連 Pod IP，繞過**自己**的 sidecar | **可以** | **可以**（見表下說明） |
| 攻擊者偽造 `X-User-Id` header | 不行 | 不精確（見表下說明） |

**直連 Pod IP 的補充：** 攻擊者直連 `epmm-api` 的 Pod IP 時，`epmm-api` 的 inbound 仍被它自己的 sidecar 攔下；沒有 mTLS 憑證就沒有 principal，ALLOW 不命中，STRICT 下明文直接被拒。

**偽造 header 的補充：** `when: request.headers[...]` 只比對值，看不出 header 是不是偽造的（官方：`request.headers` 是「HTTP request headers.」）。要防偽造，用 RequestAuthentication 驗 JWT，再用 `request.auth.claims[...]`（官方：「Raw claims of the authenticated JWT token.」）或 `requestPrincipals` 授權；或在 ingress 端剝掉外部帶進來的 `X-User-Id`。

**結論：兩個都要。** NetworkPolicy 是網路層的粗篩，AuthorizationPolicy 是應用層的細篩。

### 步驟 5：驗證整條路徑

```bash
# 1. 從來源 pod 直接打（會經過完整的 sidecar 鏈路）
kubectl exec -n ea-pmc deploy/pmc-epmmformquerygui -c app -- \
  curl -sS -o /dev/null -w "%{http_code}\n" \
  http://epmm-api-svc.ea-epmm.svc.cluster.local:8080/api/v1/health

# 2. 200 = 通；403 = 授權問題（Part 3，RBAC: access denied）；
#    503（Envoy 回應旗標 UF，「Upstream connection failure in addition to 503 response code」）= 多半是網路層
#    （NetworkPolicy 擋掉時 Envoy 連上游失敗，通常要等到 connect timeout）或 mTLS 不一致；
#    000 = 多半是 DNS 失敗（curl exit 6）或來源端沒有 sidecar。
#    來源端有 sidecar 時 curl 連的是本機 Envoy，TCP 一定建得起來，所以 NetworkPolicy 擋掉不會看到 000。

# 3. 確認【設定上】會走 mTLS（describe 是設定推論、且為 experimental，不是實際流量）
istioctl x describe pod -n ea-epmm $(kubectl get pod -n ea-epmm -l app=epmm-api -o name | head -1 | cut -d/ -f2)

# 4. 確認【實際流量】是 mTLS：看 istio_requests_total{connection_security_policy="mutual_tls"} 或 access log
```

### 參考來源

- Kubernetes — Network Policies：https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — DNS for Services and Pods：https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes — Service Accounts：https://kubernetes.io/docs/concepts/security/service-accounts/
- Kubernetes — Configure Service Accounts for Pods：https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Kubernetes — Deployments：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- man7 — resolv.conf(5)：https://www.man7.org/linux/man-pages/man5/resolv.conf.5.html
- Istio — Dockerfile.base：https://raw.githubusercontent.com/istio/istio/master/docker/Dockerfile.base
- Istio — SPIRE integration：https://istio.io/latest/docs/ops/integrations/spire/
- Istio — PeerAuthentication reference：https://istio.io/latest/docs/reference/config/security/peer_authentication/
- Istio — Security concepts：https://istio.io/latest/docs/concepts/security/
- Istio — Security Policy Examples：https://istio.io/latest/docs/ops/configuration/security/security-policy-examples/
- Istio — Health Checking of Istio Services：https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/
- Istio — Prometheus integration：https://istio.io/latest/docs/ops/integrations/prometheus/
- Istio — AuthorizationPolicy reference：https://istio.io/latest/docs/reference/config/security/authorization-policy/
- Istio — Authorization dry-run：https://istio.io/latest/docs/tasks/security/authorization/authz-dry-run/
- Istio — Security Best Practices：https://istio.io/latest/docs/ops/best-practices/security/
- Istio — Authorization conditions：https://istio.io/latest/docs/reference/config/security/conditions/
- Istio — istioctl describe：https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/
- Istio — istioctl reference：https://istio.io/latest/docs/reference/commands/istioctl/
- Envoy — Substitution formatter（response flags）：https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter

---

## Part 5：獨立 cluster 互打，走對方 VIP 與 VirtualService

**場景**：Cluster A 的 `ea-pmc/pmc-epmmformquerygui`，要呼叫 Cluster B 的 `ea-epmm/epmm-api`。兩個 cluster **完全獨立**（各自的 istiod、各自的 CA、沒有 multi-cluster 設定），只能透過 Cluster B 的對外 VIP 進去。

### 這是在解決什麼問題

Part 4 的做法在同一個 cluster 內成立，是因為**兩邊的 sidecar 由同一個 istiod 管、憑證由同一個 CA 簽**，所以 B 的 sidecar 看得懂 A 的憑證。

跨到兩個獨立 cluster，這個前提就沒了：**A 的憑證由 A 的 CA 簽，B 的 istiod 根本不認識這張憑證。** 所以流量只能走「一般的南北向 HTTP」——跟外部使用者從瀏覽器打進來是同一條路。

這帶來的核心後果就是你問的那句：**「前面 namespace 的設定還會用到嗎？」** 答案是 —— **對方 namespace 的設定全部照樣生效，但你的身分傳不過去，所以那些設定「看到的來源」變了。**

### 完整封包路徑

```
   Cluster A                                      Cluster B
┌──────────────────────────────┐          ┌────────────────────────────────────┐
│  ea-pmc                      │          │  istio-system                      │
│  ┌────────────────────────┐  │          │  ┌──────────────────────────────┐  │
│  │ pmc-epmmformquerygui   │  │          │  │ istio-ingressgateway (Envoy) │  │
│  │  app container         │  │          │  │  身分: sa/istio-ingressgateway│ │
│  │        ↓ localhost     │  │          │  └──────────────────────────────┘  │
│  │ ⓵ istio-proxy(outbound)│  │          │            ↑ ⓸ Gateway 收 host/TLS │
│  └────────┬───────────────┘  │          │            │ ⓹ VirtualService 選路由│
│           │                  │          │            │                       │
│   ⓶ ServiceEntry / Sidecar   │          │  ea-epmm   ↓ ⓺ mTLS(B 的 CA 簽)     │
│      決定出不出得去           │          │  ┌──────────────────────────────┐  │
│           │                  │          │  │ ⓻ istio-proxy (inbound)      │  │
└───────────┼──────────────────┘          │  │    PeerAuth / AuthzPolicy    │  │
            │                             │  │        ↓ localhost           │  │
            └──── ⓷ 出 cluster ─────▶ VIP ─┤  │ ⓼ epmm-api container         │  │
                  (公司網路 / F5)          │  └──────────────────────────────┘  │
                                          └────────────────────────────────────┘
```

### 逐跳表：哪些 policy 生效、哪些失效

| # | 位置 | 資源 | 還有用嗎？ | 說明 |
|---|---|---|:---:|---|
| ⓵ | A 的來源 sidecar | **A 的 AuthorizationPolicy** | **幾乎沒用** | AuthzPolicy 主要管 inbound。出向要管得用 egress gateway |
| ⓶ | A 的來源 sidecar | **A 的 Sidecar `egress.hosts`** | **要！** | 若有收斂過，沒列進 `egress.hosts` 的目的地會被當成 unmatched traffic：`REGISTRY_ONLY` 時丟棄（出不去）；預設 `ALLOW_ANY` 時通常仍經 PassthroughCluster 放行，只是失去 ServiceEntry／DR 的設定（TLS origination、逾時等） |
| ⓶ | A 的 mesh 設定 | **ServiceEntry** | **`REGISTRY_ONLY` 時必須** | 把外部 host 註冊進 mesh；`ALLOW_ANY`（預設）可省略但不建議 |
| ⓶ | A 的 mesh 設定 | **DestinationRule** | **看情況** | 要做 TLS origination（http→https）、連線池、逾時就要 |
| ⓷ | A 的網路層 | **A 的 NetworkPolicy egress** | **要！** | default-deny 的話要放行對方 VIP 的 CIDR |
| ⓷ | 中間 | 公司防火牆 / F5 | 要 | 這段 Istio 完全管不到 |
| ⓸ | B 的 gateway | **B 的 Gateway** | **要，且是唯一入口** | host 沒對上 → 404，TLS 沒配好 → handshake 失敗 |
| ⓹ | B 的 gateway | **B 的 VirtualService** | **要，且是唯一路由規則** | path 沒 match → 404 |
| ⓹ | B 的 gateway | **B 的 AuthorizationPolicy（掛在 gateway 上）** | **要** | 這裡是你做 IP 白名單的最佳位置（`remoteIpBlocks`） |
| ⓺ | B 的內部 | **B 的 DestinationRule** | 要 | subset / LB 策略照常 |
| ⓻ | B 的目標 sidecar | **B 的 PeerAuthentication** | **照樣生效** | gateway→app 這段是 B 內部的 mTLS，STRICT 沒問題 |
| ⓻ | B 的目標 sidecar | **B 的 AuthorizationPolicy** | **照樣生效，但來源身分變了** | ← **這是關鍵，見下節** |
| ⓻ | B 的目標 sidecar | **B 的 Sidecar** | 生效（inbound 部分） | |
| ⓻ | B 的網路層 | **B 的 NetworkPolicy** | **要，但條件要改** | 要放行 **istio-system 的 ingressgateway**，不是 A 的 Pod CIDR |

### 核心結論：身分在 ingressgateway 斷掉

這是整節最重要的一句話：

> **A 的 workload 身分在進入 B 的 ingressgateway 那一刻就消失了。B 的 `epmm-api` sidecar 看到的來源是 ingressgateway 自己的身分，格式為 `<trust-domain>/ns/<gateway 的 namespace>/sa/<gateway 的 ServiceAccount>`，不再是 A 的身分。**

實際的值要先查，不要照抄：istioctl／operator 預設裝法的 SA 是 `istio-ingressgateway-service-account`，Helm gateway chart 則跟 release 名稱走；trust domain 也不一定是 `cluster.local`。

```bash
kubectl get pod -n istio-system -l istio=ingressgateway -o jsonpath='{..serviceAccountName}'
```

為什麼：A→B 的 TLS 連線在 B 的 ingressgateway 就被終止（terminate）了。ingressgateway 接著用**自己的身分**、B 的 CA 簽的憑證，重新發起一條到 `epmm-api` 的 mTLS 連線。A 的憑證資訊到此為止。

**所以 Part 4 那條 policy 直接搬過來一定 403：**

```yaml
# 在跨 cluster 場景下，這條永遠不會命中
    - from:
        - source:
            principals: ["cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"]
#                                    ^^^^^^ A cluster 的身分，B 看不到
```

必須改成：

```yaml
    - from:
        - source:
            # SA 名稱先用上面的指令查實際值再填；寫錯的話這條永遠不命中，全部 403。
            #   istioctl 預設裝法是 istio-ingressgateway-service-account，Helm 則等於 release 名稱
            principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]
```

但這樣等於「**只要能進 ingressgateway 的人都能打 epmm-api**」—— 粒度全失。所以要用下面三種補救之一，把「A 是誰」這個資訊用別的方式帶過去。

### 補救方案一：JWT（推薦，你們已經有 Keycloak）

**原理**：既然 mTLS 身分傳不過去，就改用 HTTP 層的憑證——JWT。它是應用層的東西，穿透 gateway 沒問題。

**你的環境特別適合這個**，因為已經有 Keycloak 了：A 的服務用 client credentials grant 拿一個 service account token，帶著它打 B。

```yaml
# B cluster：ea-epmm 驗 JWT
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: epmm-api-jwt
  namespace: ea-epmm
spec:
  selector:
    matchLabels:
      app: epmm-api
  jwtRules:
    - issuer: "https://keycloak.example.com/realms/my-realm"
      jwksUri: "https://keycloak.example.com/realms/my-realm/protocol/openid-connect/certs"
      forwardOriginalToken: true      # 讓後端 app 也拿得到原始 token
      # issuer 必須跟 token 的 iss 逐字相同，否則所有 token 都 401；以 Keycloak 的
      # /realms/my-realm/.well-known/openid-configuration 回傳的 issuer 為準。
      # Keycloak 17 以後的 Quarkus 版預設沒有 /auth 前綴，只有設了 http-relative-path=/auth
      # 或用舊版 WildFly 才要保留 /auth（requestPrincipals 的前綴也要一起改）。
---
# 只有帶正確 JWT 的才放行
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: epmm-api-require-jwt
  namespace: ea-epmm
spec:
  selector:
    matchLabels:
      app: epmm-api
  action: ALLOW
  rules:
    - from:
        - source:
            # 格式: <issuer>/<subject>
            requestPrincipals:
              - "https://keycloak.example.com/realms/my-realm/*"
      when:
        # 進一步用 claim 區分是「哪個 cluster 的哪個服務」
        # azp = authorized party。Keycloak 的 azp 是否等於 client_id 以實際 decode 出來的 token 為準；
        # Istio 也有內建的 request.auth.presenter，內容就是 azp claim。
        - key: request.auth.claims[azp]
          values: ["pmc-cluster-a-client"]
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/*"]
```

> **重要**：`RequestAuthentication` 不擋**沒帶** token 的請求，但會直接以 401 拒絕帶了**無效** token（簽章錯、過期、iss 不符）的請求。它只做「如果有 JWT 就驗，驗過就把 claim 放進 metadata」。**沒帶 token 的請求會直接通過**（只是沒有已驗證的身分）。要真的擋，必須另外寫一條 AuthorizationPolicy 用 `requestPrincipals` 要求「必須有已驗證的 JWT」。這是初學者最常見的誤解。

**補一條「沒 JWT 就擋」的保險：**

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: epmm-api-deny-no-jwt
  namespace: ea-epmm
spec:
  selector:
    matchLabels:
      app: epmm-api
  action: DENY
  rules:
    - from:
        - source:
            notRequestPrincipals: ["*"]     # 「沒有任何已驗證 JWT 身分的」一律擋
      to:
        - operation:
            notPaths: ["/actuator/health*"]  # 只是不被這條 DENY 擋；放不放行仍取決於 ALLOW（見下方說明）
```

> 注意：`notPaths` 只讓 health 路徑躲過這條 DENY。同一個 workload 上已經有 `epmm-api-require-jwt` 這條 ALLOW（只放 `/api/*` 的 GET/POST），沒有任何 ALLOW 命中的請求仍會被拒絕（403），所以這裡的「除外」並不會讓 `/actuator/health` 被放行。要讓外部呼叫者也能打 health，得在 ALLOW 另加一條 rule 放行該路徑；kubelet 探針則經 probe rewrite 走 pilot-agent，本來就不受這些政策影響。另外，有 `requestPrincipals` 的 ALLOW 在，這條 DENY 其實是多餘的保險。

### 補救方案二：IP 白名單（`remoteIpBlocks`）

如果 A cluster 的出口 IP 是固定的（通常是 NAT gateway 或 node 的固定 IP），可以在 **B 的 ingressgateway** 上做白名單。

> ⚠️ **不要在共用的 `istio: ingressgateway` 上寫 `action: ALLOW`。** 官方語意是：workload 上只要出現任何一條 ALLOW，沒有命中任何 ALLOW 的請求就會被拒絕（"If there are no ALLOW policies for the workload, allow the request." 只在「完全沒有 ALLOW」時才成立）。ingressgateway 通常是整個 cluster 共用的，一條 ALLOW 掛上去，**其他所有 host 的流量**沒命中就 403，整個 cluster 對外服務一起中斷。所以改用 `DENY` + `notRemoteIpBlocks`，並用 `to.operation.hosts` 把影響範圍限縮在 epmm-api 這一個 host（理由見下方 yaml 註解）。

```yaml
# B cluster：epmm-api 這個 host 只允許 A cluster 的出口網段進來
# 用 DENY + notRemoteIpBlocks 而不是 ALLOW（原因見上方警告）；
# DENY 只作用在 to.operation.hosts 列出的 host，其他 host 不受影響。
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-a
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: DENY
  rules:
    - from:
        - source:
            notRemoteIpBlocks:
              - "10.20.30.0/24"        # A cluster 的出口 NAT 網段；不在這個網段的一律擋
      to:
        - operation:
            hosts: ["epmm-api.b-cluster.example.com"]   # 只寫 epmm-api，不要漏掉這行
```

**前置條件（一定要做，否則比對到錯的 IP）：** gateway 必須真的拿得到 client IP。官方說法是 gateway 前面的 proxy 必須解析 HTTP 流量並在每一跳 append `X-Forwarded-For`（"proxies in front of the Istio gateway proxy must parse HTTP traffic and append to the X-Forwarded-For header at each hop."），拿不到時 Envoy 退回使用直接連線的來源位址（"Envoy falls back to using the immediate downstream address as the trusted client address."）——也就是 LB／node IP，這時上面的 DENY **永遠不會觸發，所有來源都被靜默放行**（見 Part 1 關鍵觀念二）。

- **前面是 L7 LB**（F5 做 HTTP 終止並附加 XFF）：設 `numTrustedProxies`，見下方。
- **前面是 L4 LB**（TCP 透傳、不會加 XFF）：`numTrustedProxies` 沒有用；改用 PROXY protocol（gateway 要設定成接受 PROXY protocol；官方說它不適用 L7 流量，且設了 `numTrustedProxies` 時會被忽略，兩者不要混用），或把 Service 設 `externalTrafficPolicy: Local` 保留來源 IP，再用 `ipBlocks` 比對。
- 本節假設 TLS 在 gateway 終止（圖上 ⓸）；若是這樣，F5 就是 L4 透傳、加不了 XFF，要走上面第二條路。

```yaml
meshConfig:
  defaultConfig:
    gatewayTopology:
      numTrustedProxies: 1     # 只有 F5 做 L7 終止並附加 XFF 時，才算一層
```

**怎麼確認 `numTrustedProxies` 該填幾：**

```bash
# access log 預設沒開：先開（meshConfig.accessLogFile=/dev/stdout，或用 Telemetry API）
# 預設 TEXT 格式只印 XFF 的「值」（引號內那一欄），不印 header 名稱，所以 grep x-forwarded-for 永遠是空的。
# 實際打一次，直接看最近幾行 log，找引號內的 IP 串：
kubectl logs -n istio-system deploy/istio-ingressgateway --tail=20
# 如果某行有 "1.2.3.4, 10.0.0.5" 兩段，代表中間有 1 層 proxy → numTrustedProxies: 1
# 另一個做法：打 httpbin 的 /get，看它回報收到的 X-Forwarded-For
```

**限制**：IP 白名單只能證明「來自那個網段」，不能證明「是哪個服務」。A cluster 裡任何一個 Pod 都共用同一個出口 IP。**所以 IP 白名單應該當作 JWT 的補強，不是替代。**

### 補救方案三：TLS passthrough（端到端 TLS，由 app 自行做 mTLS，複雜度高）

讓 B 的 Gateway 不終止 TLS，直接把加密流量透傳給後端（"pass the ingress traffic “as is”, without terminating TLS"）。保留下來的是 A 的 **app** 自己發起的 TLS，不是 A 的 Istio workload 身分：A 的 app 要自備 B 的 app 信任的 client cert，由 **B 的應用程式**（不是 B 的 sidecar）驗證。B 的 sidecar 上 `principals` 看到的仍是 gateway 那條 mTLS 的身分，而且透傳之後只能做 L4 判斷。

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: passthrough-gw
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
    - port: { number: 443, name: tls, protocol: TLS }
      tls:
        mode: PASSTHROUGH        # 不解密，直接透傳
      hosts: ["epmm-api.b-cluster.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: passthrough-vs
  namespace: istio-system
spec:
  hosts: ["epmm-api.b-cluster.example.com"]
  gateways: [passthrough-gw]
  tls:                                       # PASSTHROUGH 用 tls 區塊，不是 http
    - match:
        - port: 443
          sniHosts: ["epmm-api.b-cluster.example.com"]
      route:
        - destination:
            host: epmm-api-svc.ea-epmm.svc.cluster.local
            port: { number: 8443 }
```

**代價很大**：因為不解密，所以 **VirtualService 的所有 L7 功能全部失效**——沒有 path 路由、沒有 header 比對、沒有 L7 metrics（`tls` route 仍可用 `weight` 做連線層級的比例分流，只是不能依 header 或 path）。而且憑證管理要自己做。**除非有強制的端到端加密合規要求，否則不建議。**

### A cluster 這一側要準備什麼

```yaml
# 1. ServiceEntry：把 B 的入口註冊進 A 的 mesh
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: epmm-api-cluster-b
  namespace: ea-pmc
spec:
  hosts:
    - epmm-api.b-cluster.example.com
  location: MESH_EXTERNAL          # mesh 外部服務
  resolution: DNS                  # 用 DNS 解析（VIP 可能會換）
  ports:
    # app 打明文 http://epmm-api.b-cluster.example.com（port 80），由 sidecar 做 TLS origination。
    # targetPort: 443 把 80 轉去 B 實際的 443；少了它，sidecar 會真的連 B 的 80，連不上。
    # protocol 必須是 HTTP：DR 的 connectionPool.http 與 L7 功能只對 HTTP port 生效。
    - number: 80
      name: http
      protocol: HTTP
      targetPort: 443
    # 這個 port 只給「app 自己已經在講 https」的情況：sidecar 當成不透明 TLS，依 SNI 透傳，
    # 不會替你加密、也不會套下面 DR 的 tls 設定（DR 的 tls 只設在 port 80）。
    - number: 443
      name: https
      protocol: HTTPS
  exportTo:
    - "."                          # 只有 ea-pmc 看得到，減少其他 sidecar 的設定量
---
# 2. DestinationRule：TLS origination（app 打 http:80，sidecar 幫你升級成 https:443）
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: epmm-api-cluster-b-tls
  namespace: ea-pmc
spec:
  host: epmm-api.b-cluster.example.com
  trafficPolicy:
    # TLS 只能設在 port 80 的 portLevelSettings：若設在 host 層級，連 port 443 那條 app 自己
    # 已加密的連線也會被再加密一次（雙重 TLS）
    portLevelSettings:
      - port: { number: 80 }
        tls:
          mode: SIMPLE                      # 單向 TLS（只驗對方）
          # SNI 在 HTTP port 上會依 Host header 自動帶入，不寫 sni 也可以。
          # 真正會讓自簽憑證失敗的是沒給 CA：沒有 caCertificates／credentialName 時，
          # sidecar 用 OS 信任庫驗 B 的憑證，自簽（內部 CA）一定 handshake 失敗。
          caCertificates: /etc/certs/b-cluster-ca.pem    # 要先把內部 CA 掛進 sidecar 的這個路徑
          # 或改用 credentialName: b-cluster-ca（secret 放在 ea-pmc，也就是 sidecar 所在的 ns），
          # 此時這份 DR 必須加 workloadSelector 指到 app 的 Pod
          subjectAltNames:
            - epmm-api.b-cluster.example.com             # 驗證 B 憑證上的名字，避免只驗到「有簽過」
    connectionPool:
      tcp:  { maxConnections: 100, connectTimeout: 3s }
      http: { http2MaxRequests: 100, maxRequestsPerConnection: 10 }
    outlierDetection:                       # 對方掛了自動剔除，避免拖垮自己
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
---
# 3. Sidecar：把它加進 egress，否則出不去
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: default
  namespace: ea-pmc
spec:
  egress:
    - hosts:
        - "./*"
        - "istio-system/*"
        - "ea-pmc/epmm-api.b-cluster.example.com"   # ServiceEntry 屬於它所在的 ns
---
# 4. NetworkPolicy：放行出向
#    注意這份是「疊加式」的：Pod 一被任何含 Egress 的 policy 選到，就進入 egress 隔離，
#    沒被放行的出向全部擋掉——包括 DNS（resolution: DNS 時是 Envoy 自己要經 kube-dns 解析 B 的名字）
#    和 sidecar 連 istiod 的 15012。所以這份必須搭配「既有的、允許 kube-dns 53/UDP+TCP 與
#    istiod 15012 的 egress policy」一起套用；單獨套用，Pod 會解析不了名字、也拿不到 xDS 設定。
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-cluster-b
  namespace: ea-pmc
spec:
  podSelector:
    matchLabels:
      app: pmc-epmmformquerygui
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock:
            cidr: 10.99.88.0/24        # B cluster 的 VIP 網段
      ports:
        - { protocol: TCP, port: 443 }
```

### B cluster 這一側的完整組合

```yaml
# 1. Gateway：收 A 打過來的 host
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: b-cluster-gw
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
    - port: { number: 443, name: https, protocol: HTTPS }
      tls:
        mode: SIMPLE
        credentialName: b-cluster-cert       # secret 要放在 istio-system
      hosts:
        - "epmm-api.b-cluster.example.com"
---
# 2. VirtualService：路由到 ea-epmm
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: epmm-api-route
  namespace: ea-epmm
spec:
  hosts: ["epmm-api.b-cluster.example.com"]
  gateways: ["istio-system/b-cluster-gw"]
  http:
    - match:
        - uri: { prefix: /api/ }
      route:
        - destination:
            host: epmm-api-svc.ea-epmm.svc.cluster.local
            port: { number: 8080 }
      timeout: 10s
---
# 3. gateway 層：IP 白名單
#    前提：remoteIpBlocks 讀的是 X-Forwarded-For／PROXY protocol，所以前面要有 L7 LB 或 PROXY protocol，
#    且 gateway 要設 numTrustedProxies，否則比對到的不是你以為的 IP。
#    若 A 直接打 B 的 gateway LB VIP（中間沒有 L7 LB），改用 ipBlocks，
#    而且 gateway 的 LB Service 要 externalTrafficPolicy: Local 才保得住來源 IP。
#    另外 gateway 看到的通常是 A 的 node／NAT 出口 IP，不是 A 的 Pod CIDR——下面的 10.20.30.0/24 要填那個。
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-a-only
  namespace: istio-system
spec:
  selector: { matchLabels: { istio: ingressgateway } }
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks: ["10.20.30.0/24"]
---
# 4. workload 層：JWT 驗證（見補救方案一）
# 5. NetworkPolicy：放行 istio-system 進 ea-epmm
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-gateway
  namespace: ea-epmm
spec:
  podSelector: { matchLabels: { app: epmm-api } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
      ports:
        - { protocol: TCP, port: 8080 }
```

### 直接回答：「前面 namespace 的設定還會用到嗎？」

| 你在 Part 2/4 學的設定 | 跨 cluster 後 |
|---|---|
| **B 的 PeerAuthentication STRICT** | **照用，而且沒問題**。gateway→app 這段是 B 內部 mTLS |
| **B 的 AuthorizationPolicy** | **照用，但 `principals` 必須改成 ingressgateway 的 SA**，細粒度改用 JWT |
| **B 的 Sidecar** | **照用**（inbound 部分不受影響） |
| **B 的 NetworkPolicy** | **照用，但來源改成 `istio-system` namespace**，不是 A 的 Pod CIDR |
| **A 的 Sidecar egress** | **變得更重要**——沒設就出不去 |
| **A 的 AuthorizationPolicy** | **基本用不到**（那是管 inbound 的） |
| **跨 ns 的 `principals` 寫法** | **完全失效**，這是最大的差異 |

**一句話**：**namespace 內的四層管控結構完全沒變，變的只有「第二層（身分）看到的來源是誰」。** 你不需要重學一套東西，只需要把「來源身分」從 A 的 workload SA 換成「ingressgateway SA + JWT claim」。

### 附錄：真正的 Istio multi-cluster（何時值得換過去）

如果你受不了「身分傳不過去」，正解是把兩個 cluster 併成**一個 mesh**：

**控制面模型**（istiod 怎麼擺）：

| 模式 | 說明 | 代價 |
|---|---|---|
| **Multi-Primary** | 兩個 cluster 各有 istiod，每個 istiod 直接 watch 對方 cluster 的 API server 取得 endpoint（istiod 之間不互相同步；機制見下方必要條件第 2 點） | 每個 istiod 都要能連到對方的 API server |
| **Primary-Remote** | 一個 istiod 管兩個 cluster | 遠端 cluster 依賴主 cluster，istiod 掛了就完蛋 |

**網路模型**（pod 之間能不能直連）是另一個獨立的選擇：single-network 時各 cluster 的 pod 可以直接互通；multi-network 時，官方的說法是「the workload instances in different networks can only reach each other through one or more Istio gateways.」，流量要靠 east-west gateway 轉發，設定最複雜。這兩個維度可以自由組合，例如官方有 Multi-Primary on different networks 的安裝指南。

**必要條件（依模式而定，各點內說明適用條件）：**

1. **共用 root CA** —— 共用同一個 root CA，替每個 cluster 簽一張各自的 intermediate CA 放進 `cacerts` secret，istiod 用 intermediate 簽發 workload 憑證（istiod 不直接用 root 簽），否則憑證互不信任
2. **每個 primary 要有所有 cluster 的 API server 存取權** —— `istioctl create-remote-secret` 產生的 kubeconfig secret。Multi-Primary 是雙向（各自讀對方）；Primary-Remote 是單向（primary 的 istiod 讀 remote 的 API server）
3. **east-west gateway（視網路模型而定）** —— 專門處理跨 cluster 流量的 gateway（跟 ingressgateway 分開）。只有 multi-network（跨網路流量）時才必要；同一個網路的 Multi-Primary 不需要，pod 之間直連（官方：「Service workloads communicate directly (pod-to-pod) across cluster boundaries.」）；Primary-Remote 即使在同一個網路，也常用它把 istiod 暴露給 remote cluster
4. **network label（只有 multi-network 才需要）** —— multi-network 時，在每個 cluster 的 `istio-system` namespace 標上 `topology.istio.io/network`（官方：「If the istio-system namespace is already created, we need to set the cluster's network there:」）；單一網路的指南不設這個 label，只在安裝設定寫 `network: network1`
5. **真正共通的前提（不論單網路或多網路）** —— 每個 cluster 的 `clusterName` 要唯一、整個 mesh 用相同的 `meshID`；單一網路時，各 cluster 的 Pod／Service CIDR 不可重疊

**換過去之後得到什麼：**

```yaml
# 跨 cluster 也能直接寫 workload 身分，就跟同 cluster 一樣
    - from:
        - source:
            principals: ["cluster.local/ns/ea-pmc/sa/pmc-epmmformquerygui"]

# 而且可以做跨 cluster 的 locality failover
# A cluster 的服務掛了，流量可依 locality（region／zone）failover 到 B cluster
# 前提：DestinationRule 必須設 outlierDetection（官方：「This is required in order for failover to function properly.」），
#       需要時再加 localityLbSetting／failover；沒設 outlierDetection 就不會生效
# failover 要等錯誤累積到 ejection 才觸發，這之前會有請求先失敗，
#       所以要搭配 retry 才能讓 app「幾乎無感」，不是完全無感
# 注意：failover 是依 locality（region／zone）決定，不是依 cluster
```

**什麼時候值得換：**

| 情境 | 建議 |
|---|---|
| 兩個 cluster 是不同環境（prod / dr） | **不用換**，走 VIP 就好 |
| 兩個 cluster 屬於不同團隊 / 不同安全域 | **不要換**，mesh 打通等於信任邊界打通 |
| 連 API server 與 east-west gateway 都無法對外開放，只有幾個開放的 VIP | **不能換**（見表下說明） |
| 同一個應用需要跨 cluster 高可用 failover | **值得換** |
| 服務間呼叫非常頻繁，走 VIP 延遲受不了 | **值得換** |
| 需要細粒度的跨 cluster 服務身分授權 | **值得換** |

**「不能換」那一列的說明**：multi-network 本來就是給 Pod 不能直連的網路用的，不需要 Pod 互通；需要的是 east-west gateway 與 API server（Primary-Remote 再加 istiod）可達（官方：「The API Server in each cluster must be accessible to the other clusters in the mesh.」）。所以只有連這兩者都無法開放時才不能換。

> **給你的實務建議**：以你目前「透過對方 VIP 打對方 VirtualService」的架構，**維持現狀 + JWT 授權**是正確選擇。multi-cluster 的維運成本（憑證輪替、跨 cluster 除錯、control plane／data plane 的版本差要遵守官方支援規則）遠高於它解決的問題，除非你真的需要跨 cluster failover。

### 參考來源

- istio.io — security-policy-examples：https://istio.io/latest/docs/ops/configuration/security/security-policy-examples/
- istio.io — network-topologies：https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/
- istio.io — deployment-models：https://istio.io/latest/docs/ops/deployment/deployment-models/
- istio.io — destination-rule：https://istio.io/latest/docs/reference/config/networking/destination-rule/
- istio.io — service-entry：https://istio.io/latest/docs/reference/config/networking/service-entry/
- istio.io — sidecar：https://istio.io/latest/docs/reference/config/networking/sidecar/
- istio.io — virtual-service：https://istio.io/latest/docs/reference/config/networking/virtual-service/
- istio.io — authorization-policy：https://istio.io/latest/docs/reference/config/security/authorization-policy/
- istio.io — conditions：https://istio.io/latest/docs/reference/config/security/conditions/
- istio.io — request_authentication：https://istio.io/latest/docs/reference/config/security/request_authentication/
- istio.io — before-you-begin：https://istio.io/latest/docs/setup/install/multicluster/before-you-begin/
- istio.io — multi-primary：https://istio.io/latest/docs/setup/install/multicluster/multi-primary/
- istio.io — multi-primary_multi-network：https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/
- istio.io — primary-remote：https://istio.io/latest/docs/setup/install/multicluster/primary-remote/
- istio.io — access-log：https://istio.io/latest/docs/tasks/observability/logs/access-log/
- istio.io — egress-tls-origination：https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/
- istio.io — ingress-sni-passthrough：https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/
- istio.io — failover：https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/failover/
- kubernetes.io — network-policies：https://kubernetes.io/docs/concepts/services-networking/network-policies/
- www.keycloak.org — migrating-to-quarkus：https://www.keycloak.org/migration/migrating-to-quarkus
- www.keycloak.org — oidc-layers：https://www.keycloak.org/securing-apps/oidc-layers

---

> **延伸閱讀**：如果你有兩座 cluster（FZ1 / FZ2），入口該建一個還是兩個、DNS record 放哪，見 [Part 11](#part-11fz1-與-fz2-雙-cluster-的入口設計dns-record-放哪)。

---

## Part 6：六種常用 kind 詳解

每個 kind 都是四段式：**解決什麼問題 → 全註解 YAML → 常用 key 表 → 踩雷**。

---

### 6.1 Deployment

#### 解決什麼問題

裸 Pod 掛了就沒了。Deployment 提供三件事：**維持指定數量的副本**、**滾動更新不中斷服務**、**出事可以一鍵回滾**。它自己不直接管 Pod，而是管 ReplicaSet，每次改 `template` 就產生一個新的 ReplicaSet，然後逐步調整新、舊 ReplicaSet 的 Pod 數量。Deployment 本身不搬流量：流量會不會轉移，取決於 Service／EndpointSlice 依 Pod 的 ready 狀態更新後端清單（在 mesh 裡則是 Envoy）。

#### 全註解 YAML

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
spec:
  # ---------- 副本與更新策略 ----------
  replicas: 2                        # 用 HPA 時「不要寫這行」，否則每次 apply 都會把 HPA 調好的數字打回來
  revisionHistoryLimit: 5            # 保留幾個舊 ReplicaSet 可供回滾（預設 10，會佔 etcd）
  progressDeadlineSeconds: 600       # 超過這麼久還沒 rollout 完就標記為失敗（預設 600）
  minReadySeconds: 10                # Pod ready 後還要穩定這麼久，Deployment 才把它算進 available（影響滾動更新推進速度；Pod 一 ready 仍會進 EndpointSlice 接流量，這個欄位擋不住）

  strategy:
    type: RollingUpdate              # 另一個選項是 Recreate（先全殺再全起，會有 downtime）
    rollingUpdate:
      maxSurge: 1                    # 更新時最多可以「超出」desired 幾個（可填數字或 25% 這種百分比）
      maxUnavailable: 0              # 更新時最多可以「少」幾個。設 0 = 絕不減少可用數，最安全

  selector:
    matchLabels:
      app: pmc-epmmformquerygui      # 必須與 template.metadata.labels 相符，且「建立後不可修改」

  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui
        version: v1                  # Istio DestinationRule subset 靠這個做版本分流（Part 7）
      annotations:
        # ConfigMap 內容變更時，讓 checksum 跟著變 → 觸發滾動更新
        checksum/config: "REPLACE_WITH_SHA256_OF_CONFIGMAP"
        # Istio：確保 sidecar 先起來再啟動 app，避免啟動瞬間的連線失敗
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      # ---------- 身分 ----------
      serviceAccountName: pmc-epmmformquerygui   # Istio principals 的來源，務必顯式指定
      automountServiceAccountToken: false        # 不呼叫 K8s API 就關掉，減少攻擊面

      # ---------- 排程控制 ----------
      nodeSelector:                  # 最簡單的硬性條件：只能排到有這些 label 的 node
        node-role: application

      affinity:
        nodeAffinity:                # 比 nodeSelector 更彈性，支援 In/NotIn/Exists 與「偏好」
          requiredDuringSchedulingIgnoredDuringExecution:   # 硬性：不滿足就不排
            nodeSelectorTerms:
              - matchExpressions:
                  - key: topology.kubernetes.io/zone
                    operator: In
                    values: ["zone-a", "zone-b"]
          preferredDuringSchedulingIgnoredDuringExecution:  # 軟性：盡量滿足
            - weight: 100            # 1~100，多個偏好時的權重
              preference:
                matchExpressions:
                  - key: node-type
                    operator: In
                    values: ["high-memory"]

        podAntiAffinity:             # 讓同一個 app 的 Pod 盡量分散在不同 node
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: pmc-epmmformquerygui
                topologyKey: kubernetes.io/hostname   # 以 node 為分散單位
                # 換成 topology.kubernetes.io/zone 就是跨可用區分散

      topologySpreadConstraints:     # 比 antiAffinity 更精確的分散控制（推薦用這個）
        - maxSkew: 1                 # 盡量讓各 zone 的 Pod 數量差距不超過 1（只有 DoNotSchedule 才是硬上限）
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway   # 不滿足時還是排，maxSkew 只是排程偏好、實際差距可能超過 1（DoNotSchedule = 寧可 Pending）
          labelSelector:
            matchLabels:
              app: pmc-epmmformquerygui

      tolerations:                   # 「容忍」node 上的 taint，讓 Pod 排得上有污點的 node
        - key: "dedicated"
          operator: "Equal"          # Equal 要比對 value；Exists 只要 key 存在就容忍
          value: "application"
          effect: "NoSchedule"       # NoSchedule / PreferNoSchedule / NoExecute
        - key: "node.kubernetes.io/unreachable"   # node 失聯（Ready=Unknown）；not-ready 指的是 Ready=False
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 300     # 系統本來就會自動加 not-ready／unreachable 各 300 秒的 toleration，這裡寫 300 只是重複預設值；只有要調整秒數時才需要寫

      priorityClassName: high-priority   # 優先權決定排程佇列順序，資源不足時可搶占（preempt）低優先權的 Pod；叢集須先建好名為 high-priority 的 PriorityClass，否則 Pod 在 admission 階段就被拒絕

      # ---------- 關機行為 ----------
      terminationGracePeriodSeconds: 60  # 從 Pod 開始終止就起算的總預算（預設 30），preStop 執行的時間也算在裡面
                                         # 本例 preStop 睡 10 秒，app 收到 SIGTERM 後實際只剩約 50 秒優雅關閉
                                         # 你有 in-memory session，這個值要夠大

      imagePullSecrets:
        - name: registry-credential

      # ---------- Pod 層級安全 ----------
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000                # 掛載的 volume 的 group owner
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.2.3   # 用明確 tag，不要 latest
          imagePullPolicy: IfNotPresent   # 用明確 tag 時比 Always 好（少一次 registry 查詢）

          ports:
            - name: http             # 命名 port，Service 可以用名字引用
              containerPort: 8080
              protocol: TCP

          # ---------- 設定注入 ----------
          envFrom:
            - secretRef:
                name: pmc-epmmformquery-secret
          env:
            - name: SPRING_CONFIG_ADDITIONAL_LOCATION
              value: "file:/app/config/application.yml"
            - name: POD_NAME         # 把 Pod 資訊注入成環境變數，log 追蹤很有用
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP

          # ---------- 資源 ----------
          resources:
            requests:                # 排程依據 + HPA 計算 utilization 的分母
              memory: "512Mi"
              cpu: "250m"
            limits:                  # 上限。memory 超過 = OOMKilled；cpu 超過 = 被 throttle
              memory: "1Gi"
              cpu: "1000m"

          # ---------- 三種 probe ----------
          startupProbe:              # 給慢啟動的 app 用（Spring Boot + Keycloak 很適合）
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            failureThreshold: 30     # 最多容忍 30 次失敗
            periodSeconds: 10        # 每 10 秒一次 → 總共給 300 秒啟動時間
                                     # startupProbe 成功前，liveness/readiness 都不會執行

          readinessProbe:            # 失敗 = 從 Service endpoint 移除（不接流量，但不重啟）
            httpGet:
              path: /gui_epmmFormQuery/actuator/health/readiness   # Spring Boot 的 readiness group；與 liveness 分開，兩者才能設不同的敏感度
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
            successThreshold: 1

          livenessProbe:             # 失敗 = 重啟容器。條件要比 readiness 寬鬆！
            httpGet:
              path: /gui_epmmFormQuery/actuator/health/liveness   # 只反映 app 自己活著，不含 DB 等外部依賴；liveness 打含依賴的 health 會讓 DB 一慢就全部重啟
              port: 8080
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3      # 30s x 3 = 90 秒沒回應才重啟

          lifecycle:
            preStop:
              exec:
                # 先跑 preStop，結束後才送 SIGTERM；先睡幾秒，讓終止中的 endpoint 狀態傳遞到所有 kube-proxy／Envoy
                # 這是消除「滾動更新時零星 502」的關鍵
                # 注意 exec 寫法要求 image 裡有 /bin/sh；distroless 之類沒有 sh 的 image，hook 會失敗、等於沒睡，502 照樣出現
                # K8s v1.30 起 beta、v1.34 起 GA 的 sleep action 由 kubelet 執行、不依賴 shell，可改寫成 preStop: { sleep: { seconds: 10 } }
                command: ["/bin/sh", "-c", "sleep 10"]

          # ---------- 容器層級安全 ----------
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true    # 需要寫入的地方用 emptyDir 掛上去
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
            - name: tmp                     # readOnlyRootFilesystem 的配套
              mountPath: /tmp

      volumes:
        - name: config
          configMap:
            name: pmc-epmmformquery-config
        - name: tmp
          emptyDir: {}
```

#### 常用 key 對照

| Key | 預設值 | 什麼時候要改 |
|---|---|---|
| `replicas` | 1 | **用 HPA 時整行刪掉** |
| `strategy.rollingUpdate.maxUnavailable` | 25% | 不容許容量下降就設 `0` |
| `strategy.rollingUpdate.maxSurge` | 25% | 資源緊繃時設小 |
| `minReadySeconds` | 0 | app 需要暖機時設 10~30 |
| `revisionHistoryLimit` | 10 | 通常 3~5 就夠 |
| `progressDeadlineSeconds` | 600 | 啟動很慢的 app 要加大 |
| `terminationGracePeriodSeconds` | 30 | **有 in-memory session 或長連線要加大** |
| `nodeSelector` | — | 簡單的 node 篩選 |
| `affinity.nodeAffinity` | — | 需要 In/NotIn/軟性偏好時 |
| `affinity.podAntiAffinity` | — | 高可用：同 app 不要擠在同一台 |
| `topologySpreadConstraints` | — | **比 antiAffinity 更推薦**，可精確控制傾斜度 |
| `tolerations` | — | 要排到專用 node（有 taint）時 |
| `priorityClassName` | — | 關鍵服務要優先保住 |
| `serviceAccountName` | `default` | **Istio 授權必設** |
| `securityContext` | — | 正式環境都該設 |

#### 三種 probe 的分工

| Probe | 失敗的後果 | 設定原則 |
|---|---|---|
| `startupProbe` | 重啟容器 | 只在啟動期跑。`failureThreshold x periodSeconds` = 允許的最長啟動時間 |
| `readinessProbe` | **移出 Service endpoint**（不接流量） | 要**敏感**：後端 DB 斷了就該立刻拿掉流量 |
| `livenessProbe` | **重啟容器** | 要**遲鈍**：只偵測「真的死了」。太敏感會造成雪崩式重啟 |

> **最常見的錯誤**：liveness 和 readiness 用同樣嚴格的門檻（或 liveness 打會檢查 DB 等外部依賴的 endpoint）。結果後端 DB 一慢，所有 Pod 同時被判定 liveness 失敗一起重啟，把小問題放大成全面停機。官方說 liveness 與 readiness 共用同一個低成本 HTTP endpoint 是常見做法（「A common pattern for liveness probes is to use the same low-cost HTTP endpoint as for readiness probes, but with a higher `failureThreshold`.」），重點在 liveness 的 `failureThreshold` 要比 readiness 高；幾倍沒有官方依據，3 倍左右只是經驗值。上面範例的做法是讓 liveness、readiness 各打自己的 health group，並讓 liveness 的 `periodSeconds` 拉長到 30 秒。

#### 踩雷

- **`selector.matchLabels` 建立後不能改**。要改只能砍掉重建 Deployment。
- **只設 `limits` 不設 `requests`**：K8s 會把 requests 設成等於 limits，但 Pod 不會因此就是 Guaranteed，還會讓排程變困難（node 必須有完整的 limit 空間）。要成為 Guaranteed，Pod 裡**每一個**容器的 cpu 和 memory 都得設 limit，且 request 等於 limit（官方：「Every Container in the Pod must have a CPU limit and a CPU request, both greater than zero.」）；只設 memory limit 的話是 Burstable。Istio 注入的 `istio-proxy` 也算一個容器，它的 requests／limits 不相等時，整個 Pod 就不會是 Guaranteed。
- **memory `limits` 是硬上限**，超過直接 OOMKilled，沒有寬限。Java 應用要確認 JVM 的 `-XX:MaxRAMPercentage` 有對齊 limit。
- **cpu `limits` 會造成 throttling**。Java app 在 GC 時很容易撞到，症狀是「CPU 用量沒滿但延遲飆高」。可考慮不設 cpu limit，只設 requests。
- **沒有 `preStop` sleep**：滾動更新時，Pod 已經開始終止，但「終止中」的 endpoint 狀態（官方：終止中的 endpoint 不會馬上從 EndpointSlice 移除，而是標成 terminating）還沒傳遞到所有 kube-proxy／Envoy；在這個 mesh 裡延遲主要來自 istiod 把 EDS 更新推到各個 sidecar，那幾百毫秒的流量會變成 502。**加一個 `sleep 10` 就能消除大部分零星 502。**
- **`readOnlyRootFilesystem: true` 沒配 emptyDir**：Java 要寫 `/tmp`，不掛上去會啟動失敗。

---

> **延伸閱讀**：`nodeSelector` / `tolerations` 裡的 routable 是什麼、label 與 taint 為什麼要成對出現，見 [Part 13](#part-13node-排程與-routable-網段)。

---

### 6.2 Service

#### 解決什麼問題

Pod IP 隨時會變（重啟、重排、擴縮容）。Service 提供一個**穩定的 DNS 名稱 + 虛擬 IP**，並自動維護後端 Pod 清單（endpoint）。

**但在 Istio mesh 裡它的角色縮小了**（見 Part 1）：Service 主要負責「服務發現」與「定義 endpoint 清單」，**實際的負載平衡是 sidecar 做的**。這個差別直接導致 `sessionAffinity` 失效。

#### 全註解 YAML

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pmc-epmmformquerygui-svc
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
spec:
  type: ClusterIP                # 預設。只有 cluster 內部可以連

  selector:
    app: pmc-epmmformquerygui    # 選中哪些 Pod（比對 Pod 的 label，不是 Deployment 的）

  ports:
    - name: http                 # 【Istio 關鍵】appProtocol 或 port 名稱前綴擇一明確宣告協定（兩者都寫最好）；appProtocol 優先於名稱
      port: 8080                 # Service 對外的 port
      targetPort: 8080           # Pod 容器的 port（可以填 containerPort 的名字，如 "http"）
      protocol: TCP
      appProtocol: http          # 【Istio 推薦】比 port 命名更明確的協定宣告

  # ---------- session 黏著（Istio 下失效，見踩雷）----------
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800      # 3 小時

  internalTrafficPolicy: Cluster # Local = 只導到同一個 node 上的 Pod（省跨節點流量，但可能沒 Pod）
```

**其他型別：**

```yaml
# Headless：不分配 ClusterIP，DNS 直接回傳所有 Pod IP
# 用途：StatefulSet、需要自己做客戶端負載平衡、或要連特定 Pod
spec:
  clusterIP: None
  selector: { app: my-statefulset }
---
# NodePort：在每個 node 上開一個 port
spec:
  type: NodePort
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30080            # 30000-32767，不填會自動分配
---
# LoadBalancer：跟雲端/F5 要一個外部 VIP（istio-ingressgateway 就是這種）
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local   # Local 保留 client 真實 IP；Cluster（預設）會 SNAT 掉
  loadBalancerSourceRanges:      # LB 層級的 IP 白名單（比 AuthorizationPolicy 更前面）
    - 10.0.0.0/8
---
# ExternalName：純 DNS CNAME，沒有 selector 也沒有 endpoint
spec:
  type: ExternalName
  externalName: db.external.example.com
```

#### 常用 key 對照

| Key | 說明 | 踩雷 |
|---|---|---|
| `type` | ClusterIP / NodePort / LoadBalancer / ExternalName | Headless 是 `clusterIP: None`，不是 type |
| `ports[].name` | **Istio 靠這個判協定** | **沒命名也沒 `appProtocol` 時只靠自動偵測，偵測失敗才當 TCP（L4）** |
| `ports[].appProtocol` | 明確宣告 `http` / `grpc` / `tcp` | 比 name 更可靠，優先用 |
| `ports[].targetPort` | Pod 的 port，可用名稱 | 填錯 = endpoint 有但連不上 |
| `sessionAffinity` | `ClientIP` / `None` | **Istio 下失效** |
| `externalTrafficPolicy` | `Local` 保留 client IP | `Local` 時，沒有該 Pod 的 node 會直接丟棄（drop）封包，client 看到的是 timeout 而不是 connection refused；外部 LB 會用 `healthCheckNodePort` 把這種 node 排除 |
| `internalTrafficPolicy` | `Local` 只走本機 Pod | 本機沒 Pod 就連不到 |
| `loadBalancerSourceRanges` | LB 層白名單 | 需要 LB 供應商支援 |

#### Istio 的協定判定：port 命名規則

Istio 用 **port 名稱的前綴**判斷要用 L7 還是 L4 處理：

| port name | 判定協定 | 能用 L7 功能？ |
|---|---|:---:|
| `http` / `http-api` / `http2` | HTTP | 可以 |
| `grpc` / `grpc-web` | gRPC | 可以 |
| `https` / `tls` | TLS（不解密） | 不行 |
| `tcp` / `tcp-db` / `mysql` | TCP | 不行 |
| **未命名** | 自動偵測 | 不穩定，不建議 |

新版 Istio 有自動協定偵測，未命名的 port 通常也能認出 HTTP，但**偵測需要看 client 送出的第一批資料，所以 server-first 協定（server 先開口，例如 SMTP、MySQL、MongoDB）與自動偵測及 PERMISSIVE mTLS 不相容，必須明確宣告為 TCP**；Istio 官方文件說 SMTP 25、DNS 53、MySQL 3306、MongoDB 27017 這些標準 port 會自動當成 TCP，非標準 port 就要自己宣告。（Redis 是 client 先送命令，不屬於 server-first。）而且偵測結果不可預期，除錯時很痛苦。

> **對你的環境**：`spring_full_v4.md` 的 Service ports **沒有 `name` 也沒有 `appProtocol`**。建議補上 `name: http` + `appProtocol: http`，這樣 VirtualService 的 path 比對、header 路由、L7 metrics 才有明確保證。

#### 踩雷：`sessionAffinity: ClientIP` 在 Istio 下不生效

**這直接影響你的架構**——你有 2 個 replica + in-memory `HttpSession`，靠 `sessionAffinity: ClientIP` 保證同一個使用者固定打到同一個 Pod。

**但在 Istio mesh 裡這個設定不會生效**，因為 `sessionAffinity` 是 kube-proxy 的功能，而 mesh 內的流量由 sidecar 直接送到 Pod IP，繞過了 kube-proxy 的負載平衡（Part 1 關鍵觀念一）。

**正確做法：用 DestinationRule 的 `consistentHash`**

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: pmc-query-affinity
  namespace: ea-pmc
spec:
  host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        # 方案 A（最推薦）：用 session cookie 做黏著
        httpCookie:
          # 不要跟 Spring 的 JSESSIONID 共用名稱：設了 ttl 之後，請求沒帶這個 cookie 時
          # Envoy 會自己產生一個同名 cookie，與 Spring 的 session cookie 撞名，
          # Spring 收到不認得的 session id 又會重發 JSESSIONID，雜湊值跟著變，黏著反而被破壞。
          # 所以用專用名稱 + ttl，交給 Envoy 管理。
          # （若一定要用 JSESSIONID 就拿掉 ttl，但第一個請求落在哪個 Pod，不保證就是之後雜湊對到的那個 Pod）
          name: istio-session-affinity
          ttl: 10800s

        # 方案 B：用自訂 header
        # httpHeaderName: x-user-id

        # 方案 C：用來源 IP（最接近原本 ClientIP 的行為）
        # useSourceIp: true
```

`consistentHash` 是一致性雜湊（演算法可選 `ringHash` 或 `maglev`，在 `consistentHash` 底下設定）：**Pod 數量變動時，只有一小部分 session 會被重新分配**，比單純的 modulo hash 好很多。

> **但這仍然是治標。** 只要 Pod 重啟，那個 Pod 上的 session 就沒了。根本解法是把 session 外部化（Spring Session + Redis）。canary 發布時這個問題會更嚴重（Part 7）。

#### 其他踩雷

- **`selector` 比對的是 Pod label，不是 Deployment label**。改 Deployment 的 `metadata.labels` 不會影響 Service 選中誰。
- **endpoint 是空的**：`kubectl get endpointslices -n ea-pmc -l kubernetes.io/service-name=<svc>` 裡沒有 endpoint（舊的 `kubectl get endpoints` 對應的 Endpoints API 自 v1.33 起已 deprecated）= selector 沒對上，或所有 Pod 都 not ready。
- **`targetPort` 填了不存在的名稱**：官方只說字串會被當成目標 Pod 的 container port 名稱去查，沒寫查不到時的行為；名稱對不到 containerPort 時，該 port 不會產生可用的 endpoint，API 也不會報錯。要確認就看 EndpointSlice 的 `ports` 欄位有沒有那個 port。
- **`externalTrafficPolicy: Local` + 節點沒有 Pod** = 打到該節點的請求拿不到 endpoint。正規做法是讓 LB 透過 Service 的 `healthCheckNodePort` 判斷節點有沒有 endpoint，自動避開沒有的節點；`topologySpreadConstraints` 保證不了每個 node 都有 Pod（例如只有 2 個 replica 時），真的要每台都有只能用 DaemonSet。

---

### 6.3 ConfigMap（與 Secret）

#### 解決什麼問題

把設定從 image 裡拆出來。同一個 image 可以跑在 dev / uat / prod，只換 ConfigMap。改一個參數不需要重新 build。

**ConfigMap 存明文設定，Secret 存機密**——但要注意 **Secret 預設只是 base64 編碼，不是加密**。有 `kubectl get secret` 權限的人就能看到內容；能存取 etcd 的人也看得到；在該 namespace 能建 Pod 或 Deployment 的人，也能把任何 Secret 掛進 Pod 讀出來。所以只收 `get secret` 權限不夠。官方建議的做法有四步：

1. 對 Secret 開 encryption at rest（etcd 層加密）
2. 以最小權限設定 RBAC
3. 只讓需要的特定容器存取 Secret
4. 改用外部 secret store（如 Vault / External Secrets Operator）

#### 全註解 YAML

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-config
  namespace: ea-pmc
immutable: false          # 設 true 效能較好且防誤改，但之後只能刪掉重建（適合有版本號的 ConfigMap）
data:
  # 方式 1：整個檔案（用 | 保留換行）
  application.yml: |
    server:
      port: 8080
    app:
      context-prefix: /gui_epmmFormQuery

  # 方式 2：單一 key-value（適合注入成環境變數）
  LOG_LEVEL: "INFO"
  FEATURE_X_ENABLED: "true"     # 一定要加引號，否則 YAML 會解析成 boolean 而 API 拒絕

binaryData:                     # 二進位內容用 base64
  keystore.p12: MIIKX...
```

**三種消費方式：**

```yaml
spec:
  template:
    spec:
      containers:
        - name: app
          # 方式 A：整個 ConfigMap 變成環境變數
          envFrom:
            - configMapRef:
                name: pmc-epmmformquery-config
            - secretRef:
                name: pmc-epmmformquery-secret

          # 方式 B：挑單一 key 變成環境變數
          env:
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: pmc-epmmformquery-config
                  key: LOG_LEVEL
                  optional: true        # key 不存在時不要讓 Pod 起不來

          volumeMounts:
            # 方式 C-1：整個目錄掛載（會自動更新）
            - name: config
              mountPath: /app/config
              readOnly: true

            # 方式 C-2：subPath 掛單一檔案（不會自動更新！見踩雷）
            - name: pages
              mountPath: /app/access-denied.html
              subPath: access-denied.html
              readOnly: true

      volumes:
        - name: config
          configMap:
            name: pmc-epmmformquery-config
            defaultMode: 0444
            items:                      # 只挑特定 key 掛載，並改名
              - key: application.yml
                path: application.yml
        - name: pages
          configMap:
            name: pmc-epmmformquery-pages
```

#### 三種消費方式的對照（最重要的表）

| 方式 | 改 ConfigMap 後會自動更新嗎 | 說明 |
|---|:---:|---|
| `envFrom` / `env` 環境變數 | **不會，永遠不會** | 環境變數在容器啟動時就固定了，**必須重啟 Pod** |
| volume 掛整個目錄 | **會**（最長約 2 分鐘，見表下說明） | kubelet 定期同步，用 symlink 原子替換 |
| volume + **`subPath`** | **不會** | subPath 綁定的是掛載當下那個檔案，看不到之後的更新，**這是最陰的雷** |

「最長約 2 分鐘」的出處：官方說從 ConfigMap 更新到新 key 投射進 Pod 的總延遲，最長可到「kubelet sync period (1 minute by default) + TTL of ConfigMaps cache (1 minute by default) in kubelet」，也就是預設約 2 分鐘；改一下 Pod 的 annotation 可以立刻觸發刷新。

#### 讓 ConfigMap 變更自動觸發滾動更新

即使檔案會自動更新，**你的 Spring Boot 也不會重新讀取它**（除非用了 Spring Cloud Kubernetes 的 reload）。所以實務上最可靠的做法是：**改 ConfigMap 就重啟 Pod**。

```yaml
# 在 Deployment 的 pod template annotation 放 ConfigMap 的 checksum
spec:
  template:
    metadata:
      annotations:
        checksum/config: "8f3a2b1c..."   # ConfigMap 內容變 → checksum 變 → template 變 → 觸發滾動更新
```

```bash
# 產生 checksum（CI/CD 裡自動做）
# 只對 data 算，不要對整份 -o yaml 算：那會把 server 填的 uid / resourceVersion /
# creationTimestamp / managedFields 一起算進去，資料沒變、重建物件或改 metadata 時 hash 也會變
kubectl get configmap pmc-epmmformquery-config -n ea-pmc -o jsonpath='{.data.application\.yml}' | sha256sum | cut -c1-8

# Helm 使用者可以直接寫：
#   checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}

# 沒有 CI 的話，手動觸發也可以
kubectl rollout restart deploy/pmc-epmmformquerygui -n ea-pmc
```

#### 常用 key 對照

| Key | 說明 |
|---|---|
| `data` | 字串內容 |
| `binaryData` | base64 二進位 |
| `immutable: true` | 不可修改。**減少 API server watch 負擔**，大型 cluster 建議用（搭配版本化命名） |
| `volumes[].configMap.items` | 只掛特定 key，可改檔名 |
| `volumes[].configMap.defaultMode` | 檔案權限（八進位，如 `0444`） |
| `optional: true` | ConfigMap/key 不存在時不擋 Pod 啟動 |

#### 踩雷

- **`subPath` 掛載不會更新**——這是最常見的困惑。你的 `access-denied.html` / `fallback.html` 就是用 subPath 掛的，**改了 ConfigMap 之後必須重啟 Pod 才會生效**。
- **引用的 ConfigMap 不存在、又沒標 `optional: true` 時，Pod 起不來**（官方原文：「If you reference a ConfigMap that doesn't exist and you don't mark the reference as optional, the Pod won't start.」）。官方沒指定狀態名稱：以 volume 掛載時通常停在 `ContainerCreating`（Events 會有 `FailedMount`）；以 `env`／`envFrom` 引用時通常是 `CreateContainerConfigError`（此細節官方文件未列出）。兩種都要看 `kubectl describe pod` 的 Events，不是 log。
- **1 MiB 大小上限**。放不下就改用 volume 或 image。
- **YAML 的 boolean/數字陷阱**：`data` 的值必須是字串。`ENABLED: true` 會被 API 拒絕，要寫 `ENABLED: "true"`。沒加引號的 `VERSION: 1.10` 是 YAML 浮點數，同樣會被拒絕，不會被靜默存成 `1.1`；透過 Helm values 等工具帶入時，值可能在進 ConfigMap 之前就先被重新序列化成 `1.1`，所以一律加引號（`VERSION: "1.10"`）。
- **跨 namespace 不能共用**。ConfigMap 是 namespace 範圍的，`ea-pmc` 的 Pod 不能掛 `ea-epmm` 的 ConfigMap。要共用只能複製（或用 Reflector / Kyverno 這類工具同步）。

---

### 6.4 CronJob

#### 解決什麼問題

定時任務。以前要養一台機器跑 crontab，還要處理「機器掛了怎麼辦」「同時跑兩份怎麼辦」。CronJob 把這些交給 K8s：**按排程建立 Job，Job 建立 Pod，跑完就結束**。

#### 全註解 YAML

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pmc-form-daily-sync
  namespace: ea-pmc
spec:
  # ---------- 排程 ----------
  schedule: "0 2 * * *"              # 標準 cron 格式：分 時 日 月 週。這裡是每天 02:00
  timeZone: "Asia/Taipei"            # K8s 1.27+ 正式支援。不設的話用 controller 的時區（通常 UTC）

  # ---------- 併發控制 ----------
  concurrencyPolicy: Forbid          # Allow(預設,可併發) / Forbid(前一個沒跑完就跳過) / Replace(殺掉舊的)

  # ---------- 錯過排程的處理【最重要的一個】----------
  startingDeadlineSeconds: 300       # 錯過排程後，還有 300 秒的補跑窗口，超過就當作這次沒跑
                                     # 不設 = controller 會往前找所有錯過的排程（見踩雷）

  # ---------- 歷史紀錄 ----------
  successfulJobsHistoryLimit: 3      # 保留 3 個成功的 Job（可以看 log）
  failedJobsHistoryLimit: 5          # 保留 5 個失敗的（失敗的更需要查，可以多留）

  suspend: false                     # 設 true 暫停排程，不影響已在跑的

  jobTemplate:
    metadata:
      labels:
        app: pmc-form-daily-sync     # 讓 kubectl get jobs -l app=pmc-form-daily-sync 只列出這個 CronJob 的 Job
                                     # （job-name 是每個 Job 都有的 label，只寫 key 會列出整個 namespace 的 Job）
    spec:
      # ---------- 失敗重試 ----------
      backoffLimit: 3                # Pod 失敗後最多重試 3 次（指數退避：10s, 20s, 40s...）
      activeDeadlineSeconds: 3600    # 整個 Job 最多跑 1 小時，超時強制終止
                                     # 注意：這個計時包含重試，且優先於 backoffLimit
      ttlSecondsAfterFinished: 86400 # Job 結束 24 小時後自動刪除（含它的 Pod）

      completions: 1                 # 需要成功幾次才算完成
      parallelism: 1                 # 同時跑幾個 Pod

      # 官方：要用 .spec.podFailurePolicy，Job 的 pod template 必須把 restartPolicy 設成 Never，
      # 否則 API 會拒絕這份 YAML（重試改由 Job controller 重建 Pod）。
      podFailurePolicy:              # K8s 1.31+ GA：依 exit code 決定要不要重試
        rules:
          - action: FailJob          # 遇到這個 exit code 直接失敗，不浪費時間重試
            onExitCodes:
              containerName: sync
              operator: In
              values: [2]            # 例如 2 = 設定錯誤，重試也沒用

      template:
        metadata:
          labels:
            # 【Istio 必看】選項 A：這個 job 不需要 mesh，直接不注入 sidecar
            # 官方建議用 label 形式；annotation 形式的 sidecar.istio.io/inject 已 deprecated
            sidecar.istio.io/inject: "false"
        spec:
          restartPolicy: Never       # Job 只能用 OnFailure 或 Never，不能用 Always；
                                     # 用了 podFailurePolicy 就必須是 Never（OnFailure 會被 API 拒絕）
          serviceAccountName: pmc-form-sync

          containers:
            - name: sync
              image: your-registry/pmc-form-sync:1.0.0
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -e
                  java -jar /app/sync.jar
                  # 【Istio 選項 B】如果需要 sidecar（要打 mesh 內的服務），
                  # 跑完必須主動叫 sidecar 結束，否則 Job 永遠不會完成
                  # curl -sf -X POST http://localhost:15020/quitquitquit || true

              envFrom:
                - secretRef:
                    name: pmc-epmmformquery-secret

              resources:
                requests: { memory: "256Mi", cpu: "100m" }
                limits:   { memory: "512Mi", cpu: "500m" }
```

#### 常用 key 對照

| Key | 預設 | 說明 |
|---|---|---|
| `schedule` | 必填 | cron 格式。也支援 `@daily` `@hourly` |
| `timeZone` | controller 時區 | **一定要設**，否則 UTC 跟你想的差 8 小時 |
| `concurrencyPolicy` | `Allow` | 資料庫同步類的一定要設 `Forbid` |
| `startingDeadlineSeconds` | 無 | **強烈建議設定**，見踩雷 |
| `successfulJobsHistoryLimit` | 3 | 設 0 = 跑完就刪 |
| `failedJobsHistoryLimit` | 1 | 建議加大到 3~5 方便查問題 |
| `suspend` | false | 維護時暫停用 |
| `backoffLimit` | 6 | Job 層級的重試次數 |
| `activeDeadlineSeconds` | 無 | **建議設**，避免卡死的 Job 永遠佔資源 |
| `ttlSecondsAfterFinished` | 無 | 自動清理，避免 Job 物件堆積 |
| `restartPolicy` | 必填 | 只能 `OnFailure` / `Never` |

#### `concurrencyPolicy` 怎麼選

| 值 | 行為 | 適用 |
|---|---|---|
| `Allow` | 前一個還在跑就再開一個 | 彼此獨立的任務 |
| `Forbid` | 前一個還在跑就**跳過這次** | **資料同步、報表產生**（避免重複寫入） |
| `Replace` | 殺掉舊的，跑新的 | 只在乎最新結果的任務（快取更新） |

#### 成功 / 失敗的判定與觀察

```bash
# 看排程狀態（LAST SCHEDULE 是關鍵）
kubectl get cronjob -n ea-pmc

# 看這個 CronJob 產生的所有 Job
kubectl get jobs -n ea-pmc -l app=pmc-form-daily-sync --sort-by=.metadata.creationTimestamp

# 看某次執行的 log（Job 的 Pod 跑完不會馬上消失，除非被 ttlSecondsAfterFinished 或 CronJob 的歷史上限 successfulJobsHistoryLimit／failedJobsHistoryLimit 清掉）
kubectl logs -n ea-pmc job/pmc-form-daily-sync-28912345

# 為什麼沒跑？看 controller 的事件
kubectl describe cronjob pmc-form-daily-sync -n ea-pmc

# 手動觸發一次測試（不用等排程）
kubectl create job --from=cronjob/pmc-form-daily-sync manual-test-1 -n ea-pmc
```

| Job 狀態 | 意義 |
|---|---|
| `Complete` | 成功數達到 `completions` |
| `Failed` | 重試超過 `backoffLimit`，或超過 `activeDeadlineSeconds`，或 Pod 命中 `podFailurePolicy` 裡 `FailJob` 動作的規則（本節範例就用了）；Indexed Job 另有 `backoffLimitPerIndex`／`maxFailedIndexes` |
| `Active` 一直不變 | 卡住了。**Istio 環境九成是 sidecar 沒結束**（見下） |

#### 踩雷 1：`startingDeadlineSeconds` 不設的後果

CronJob controller 掛掉或 cluster 維護一段時間後恢復，它會回頭檢查「錯過了哪些排程」：

- **不設 `startingDeadlineSeconds`**：controller 從 `lastScheduleTime` 一路往現在數。如果錯過超過 **100 次**排程，現行 controller 會發一個 `TooManyMissedTimes` Warning 事件（訊息：too many missed start times. Set or decrease .spec.startingDeadlineSeconds or check clock skew）。官方概念頁寫的是「it does not start the Job and logs the error」，但原始碼仍會回傳最近一次排程時間，兩者並不一致，所以**不要依賴這個行為**；設了 `startingDeadlineSeconds` 就不會碰到它。（舊版 controller 會卡死、不再排程，現行版本不是這樣。）
- controller 只會為最近一次錯過的排程建一個 Job，不會把錯過的排程一次補跑完。官方說法是「the Jobs will always run at least once」，所以 Job 要能容忍重複執行。

**設了 `startingDeadlineSeconds: 300` 之後**：controller 只回頭看 300 秒內的排程，超過窗口的那次會被跳過（`MissSchedule` 事件）。這樣就不會觸發 >100 次的警告。

> 建議值：設成「比排程間隔小」的值。每小時跑一次就設 `1800`（30 分鐘）；每天跑一次可以設 `3600`。

#### 踩雷 2（Istio 環境必踩）：Job 永遠不會結束

**現象**：主容器早就跑完了，但 Job 一直是 `Active`，Pod 一直是 `Running` 或 `NotReady 1/2`。

**原因**：Job 要「所有容器都結束」才算完成。但 `istio-proxy` 是常駐服務，它不會自己結束。所以主容器跑完後，sidecar 還在跑，Job 就永遠卡住。

**三種解法：**

```yaml
# 解法 A（最簡單）：這個 Job 不需要 mesh 功能，直接不注入
spec:
  jobTemplate:
    spec:
      template:
        metadata:
          labels:                  # 官方建議用 label；annotation 形式已 deprecated
            sidecar.istio.io/inject: "false"
```

```yaml
# 解法 B：需要 mesh（要打 mesh 內的服務、要 mTLS），跑完主動叫 sidecar 退出
          containers:
            - name: sync
              command: ["/bin/sh", "-c"]
              args:
                - |
                  # 不要加 set -e：有它的話 java 一失敗 shell 就直接退出，
                  # 下面的 RC=$? 和 curl 都不會執行，sidecar 沒被叫停，Job 正好在失敗時卡住
                  set +e
                  java -jar /app/sync.jar
                  RC=$?
                  # app image 裡要有 curl；這個端點只接受 localhost 的 POST，所以打 127.0.0.1
                  curl -sf -X POST http://127.0.0.1:15020/quitquitquit || true
                  exit $RC
```

```yaml
# 解法 C（最乾淨，需要 K8s 支援 native sidecar 且 Istio 啟用）
# sidecar 變成 native init container，K8s 會在主容器結束後自動關掉它
# K8s：SidecarContainers 1.28 alpha、1.29 起預設開啟、1.33 GA
# Istio 1.27 起預設就是 native sidecar，不需要再設；舊版 Istio 才要在 istiod 設
# ENABLE_NATIVE_SIDECARS=true，或像下面這樣在 Pod 加 annotation
spec:
  jobTemplate:
    spec:
      template:
        metadata:
          annotations:
            sidecar.istio.io/nativeSidecar: "true"
```

> **選擇建議**：Job 如果只是打外部 API 或寫資料庫（不需要 mesh 內的 mTLS 身分），用**解法 A** 最省事。需要以特定身分呼叫 mesh 內服務時，用**解法 B**。環境版本夠新就直接上**解法 C**（Istio 1.27+ 搭配 K8s 1.29+ 時預設就是這樣，Job 卡住本來就不該發生；排查時先確認 `istio-proxy` 是不是在 `initContainers` 裡）。

#### 其他踩雷

- **`schedule` 的時區**：不設 `timeZone` 時用 kube-controller-manager 的本地時區（多數 cluster 是 UTC），所以「每天 2 點」若 controller 是 UTC，實際上是台北時間早上 10 點。
- **`restartPolicy: Always`** 會被 API server 拒絕（Job 不接受）。
- **Job 名稱長度**：CronJob 名稱必須不超過 52 字元：controller 會自動在你給的名稱後面再加 11 個字元，而 Job 名稱上限是 63 字元，超過 52 就違反限制。
- **失敗的 Job 不會自動清**：`failedJobsHistoryLimit` 之外的會被清掉，但範圍內的會一直留著。搭配 `ttlSecondsAfterFinished` 更保險。

---

### 6.5 Gateway（Istio）

#### 解決什麼問題

K8s 的 Service 只能做到 `type: LoadBalancer` 開一個 port。但你需要的是：**同一個 VIP 上，依 hostname 分流到不同服務、每個 host 用不同 TLS 憑證、HTTP 自動轉 HTTPS**。

Istio 的 Gateway 就是在描述 **ingressgateway 這個 Envoy 的「接聽設定」**：開哪些 port、收哪些 host、TLS 怎麼配。

**Gateway 只管 L4 + TLS 終止，不管路由。** 路由是 VirtualService 的事。這是兩者最重要的分工。

#### 全註解 YAML

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: istio-system         # 慣例放在 gateway pod 所在的 namespace
spec:
  selector:
    istio: ingressgateway         # 【關鍵】對應到哪個 ingressgateway Pod 的 label
                                  # 選錯 = istiod 照樣接受、apply 不會被拒絕，但設定沒有套到任何 Pod；
                                  # `istioctl analyze` 會回報 IST0101「Referenced selector not found」

  servers:
    # ---------- HTTPS ----------
    - port:
        number: 443
        name: https               # port.name 必填（官方只說是 port 的 label）；要求唯一的是選填的 servers[].name
        protocol: HTTPS           # HTTP / HTTPS / GRPC / GRPC-WEB / HTTP2 / TCP / TLS / MONGO
      tls:
        mode: SIMPLE              # 見下方 TLS mode 表
        credentialName: myapp-tls-cert   # 對應到 K8s Secret：TLS Secret（tls.crt／tls.key）
                                         # 或 generic Secret（cert／key）都可以
                                         # 【踩雷】secret 必須在 ingressgateway 的 namespace
        minProtocolVersion: TLSV1_2
      hosts:
        - "myapp.example.com"     # 只收這個 Host header
        # - "*.example.com"       # 支援萬用字元
        # - "ea-pmc/myapp.example.com"   # 限定只有 ea-pmc 的 VirtualService 能綁這個 host

    # ---------- HTTP 自動轉 HTTPS ----------
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "myapp.example.com"
      tls:
        httpsRedirect: true       # 回 301 導到 https

    # ---------- mTLS（要求 client 出示憑證）----------
    - port:
        number: 8443
        name: https-mtls
        protocol: HTTPS
      tls:
        mode: MUTUAL              # 驗 client 憑證
        credentialName: myapp-tls-cert      # CA 憑證可放在同一個 secret 的 ca.crt key，
                                            # 也可另建名為 <secret>-cacert、key 為 cacert 的 secret
      hosts:
        - "api.example.com"
```

#### TLS mode

| mode | 行為 | 用途 |
|---|---|---|
| `SIMPLE` | 標準單向 TLS，gateway 出示憑證並解密 | **最常用** |
| `MUTUAL` | 雙向 TLS，額外驗 client 憑證 | B2B API、跨 cluster 高安全需求 |
| `PASSTHROUGH` | **不解密**，依 SNI 直接轉發 | 端到端加密（代價：失去所有 L7 功能） |
| `OPTIONAL_MUTUAL` | 同 `MUTUAL`，但 client 憑證可有可無（有出示才驗證） | 同一個入口同時接受有／無 client 憑證的連線 |
| `ISTIO_MUTUAL` | gateway 使用 Istio 自動簽發、代表 gateway workload 身分的憑證，跟 sidecar 之間走 mTLS | sidecar 到 egress gateway 這一段的 mTLS |
| `AUTO_PASSTHROUGH` | 自動 passthrough，不需要 VirtualService | multi-cluster 的 east-west gateway 專用 |

#### 常用 key 對照

| Key | 說明 | 踩雷 |
|---|---|---|
| `selector` | 對到 ingressgateway 的 **Pod label**（label 依安裝方式而定，請先 `kubectl get deploy -A` 找出實際的 gateway 再查它的 label） | 選錯時 apply 不會被拒絕，設定也不會生效（`istioctl analyze` 能抓到，見上方 YAML 註解） |
| `servers[].port.protocol` | 協定 | `HTTPS` 會終止 TLS 再做 L7 路由；`TLS` 搭 `SIMPLE`／`MUTUAL` 也會終止 TLS（給非 HTTP 流量用），搭 `PASSTHROUGH` 則不解密、只看 SNI |
| `servers[].hosts` | 接受的 Host header | 多個 Gateway 的 host 重疊、或共用同一張憑證時會出問題（見下方「踩雷」） |
| `servers[].tls.credentialName` | TLS secret 名稱 | **secret 必須在 gateway pod 的 namespace** |
| `servers[].tls.httpsRedirect` | 80 → 443 | 只在 `protocol: HTTP` 的 server 上設 |
| `servers[].tls.minProtocolVersion` | 最低 TLS 版本 | 合規要求常見 |

#### 踩雷

- **`credentialName` 的 secret 放錯 namespace**：secret 必須在 **ingressgateway Pod 所在的 namespace**（istioctl 預設安裝在 `istio-system`；Helm 則依安裝時的 release 名稱與 namespace 而定，官方 Helm 範例用的是 `istio-ingress`，請先 `kubectl get deploy -A` 找出實際位置），不是 Gateway 資源所在的 namespace，也不是你 app 的 namespace。這是 Gateway 最常見的錯誤。
- **多個 Gateway 共用同一張（萬用字元）憑證，第二個 host 會 404**：瀏覽器會重用已建立的 HTTP/2 連線，連到第一個 host 之後再存取第二個 host 時，請求被送到不對的 Gateway 而得到 404（Istio 官方 common-problems 文件記載的情況）。官方的解法是把它們合併成單一個萬用字元 Gateway。**避免多個 Gateway 用重疊的 host 或共用憑證。**
- **`selector` 對不到 Pod**：設定會被 istiod 接受但完全沒有作用。驗證方式：

```bash
# 看 gateway pod 有沒有真的收到這個 listener
# （deploy 名稱與 namespace 依安裝方式而定：istioctl 預設是 istio-system 的 istio-ingressgateway，
#   Helm 則跟 release 名稱與 namespace 走，請先 kubectl get deploy -A 確認）
istioctl proxy-config listener deploy/istio-ingressgateway -n istio-system

# 一次檢查所有設定問題
istioctl analyze -n istio-system
```

- **憑證更新後沒生效**：Istio 透過 SDS 下發憑證，理論上不用重啟 gateway；更新後請用 `istioctl proxy-config secret` 確認新憑證已經生效。如果沒生效，檢查 secret 的 key 是否正確：TLS Secret 要有 `tls.crt` / `tls.key`，generic Secret 要有 `cert` / `key`（兩種格式 Istio 都接受）。
- **Gateway 和 VirtualService 的 host 必須有交集**，否則 404。

---

### 6.6 VirtualService（Istio）

#### 解決什麼問題

Gateway 決定「收不收這個連線」，VirtualService 決定「**這個請求要送去哪裡**」。它能做的事情是 K8s Service 完全做不到的：

- 依 **path / header / method / query** 分流
- 把流量按**百分比**切到不同版本（canary）
- **改寫 path**、重導向
- **逾時、重試、故障注入、流量鏡射**

#### 全註解 YAML

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app-routing
  namespace: ea-pmc
spec:
  # ---------- 這條規則管哪些 host ----------
  hosts:
    - myapp.example.com                                   # 外部進來的 host
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   # mesh 內部呼叫的 host

  # ---------- 這條規則綁在哪 ----------
  gateways:
    - istio-system/my-gateway    # 從這個 gateway 進來的流量
    - mesh                       # 【關鍵】保留字：所有 sidecar（= mesh 內部流量）
                                 # 不寫 mesh，內部 pod 互打就完全不會套用這條規則

  http:
    # ===== 規則 1：header 比對（canary / 內部測試用）=====
    # 【重要】match 是「由上而下，第一個命中就停」，所以特例一定要放前面
    - name: canary-by-header
      match:
        - headers:
            x-canary:
              exact: "true"      # exact / prefix / regex
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: v2           # 對應 DestinationRule 的 subset
            port: { number: 8080 }

    # ===== 規則 2：path 前綴 + 權重分流 =====
    - name: query-gui
      match:
        - uri: { prefix: /gui_epmmFormQuery/ }
        - uri: { exact: /gui_epmmFormQuery }    # 同一個 match 陣列的多項之間是 OR
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: v1
            port: { number: 8080 }
          weight: 90                            # weight 是相對比例：拿到 weight ÷ 全部 weight 總和
                                        # 習慣湊成 100 比較好讀，但現行版本不是硬性規定
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: v2
            port: { number: 8080 }
          weight: 10

      # ---------- 逾時與重試 ----------
      timeout: 15s                              # Istio 預設「不設逾時」，強烈建議明確設定
      retries:
        attempts: 2                             # 重試次數，不含第一次呼叫：最多送出 1 + 2 = 3 次請求
        perTryTimeout: 5s                       # 單次嘗試的逾時：(1 + attempts) x perTryTimeout 要 <= timeout
                                        # 3 x 5s = 15s，剛好等於下面的 timeout: 15s；超過的話後面的重試會被總 timeout 截斷
        retryOn: "5xx,reset,connect-failure,refused-stream"
        retryRemoteLocalities: false

      # ---------- header 操作 ----------
      headers:
        request:
          set:   { x-forwarded-prefix: /gui_epmmFormQuery }
          add:   { x-request-source: istio-gateway }
          remove: ["x-internal-token"]
        response:
          set: { x-frame-options: DENY }

      # ---------- CORS（在 mesh 層做，app 就不用管）----------
      corsPolicy:
        allowOrigins:
          - exact: https://myapp.example.com
          - prefix: https://internal.
        allowMethods: [GET, POST, PUT, DELETE, OPTIONS]
        allowHeaders: [authorization, content-type, x-requested-with]
        allowCredentials: true
        maxAge: "24h"

    # ===== 規則 3：路徑改寫 =====
    - name: rewrite-example
      match:
        - uri: { prefix: /legacy-api/ }
      rewrite:
        uri: /api/                              # /legacy-api/foo → /api/foo
        # authority: new-host.example.com       # 同時改寫 Host header
      route:
        - destination:
            host: epmm-api-svc.ea-epmm.svc.cluster.local
            port: { number: 8080 }

    # ===== 規則 4：流量鏡射（把正式流量複製一份給新版本，但不回應）=====
    - name: mirror-to-v2
      match:
        - uri: { prefix: /api/ }
      route:
        - destination: { host: epmm-api-svc.ea-epmm.svc.cluster.local, subset: v1 }
      mirror:
        host: epmm-api-svc.ea-epmm.svc.cluster.local
        subset: v2
      mirrorPercentage: { value: 10.0 }        # 只鏡射 10%
      # 鏡射流量的回應會被丟棄，client 完全無感。測新版本最安全的方式

    # ===== 規則 5：故障注入（混沌測試）→ 拆到下方獨立的 VirtualService =====
    # 官方 common-problems 寫明：Istio 目前不支援把 fault 跟 retries／timeout 放在同一個
    # VirtualService，而規則 2 已經設了 timeout／retries，所以 fault 不能留在這裡

    # ===== 規則 6：重導向 =====
    - name: redirect-root
      match:
        - uri: { exact: / }
      redirect:
        uri: /gui_epmmFormQuery/
        redirectCode: 302

    # ===== 最後：預設路由（沒有 match = 全部命中，一定放最後）=====
    - name: default
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            port: { number: 8080 }
```

#### 故障注入：要放在獨立的 VirtualService

官方 common-problems 頁面寫明：「Currently, Istio does not support configuring fault injections and retry or timeout policies on the same `VirtualService`.」所以上面規則 2 的 timeout／retries 不能跟 fault 放在同一個 VirtualService。下面是拆出來的獨立版本，只在測試環境單獨套用；它跟上面的 VirtualService 是二選一的示範，不要在同一個叢集同時 apply 兩份管同一個 host 的 VirtualService（多份 VirtualService 對同一個 host 的合併順序沒有保證）：

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: epmm-api-fault-test
  namespace: ea-epmm
spec:
  hosts:
    - epmm-api-svc.ea-epmm.svc.cluster.local
  http:
    # match 是由上而下第一個命中就停（"The first rule matching an incoming request is used."）
    # 所以帶 x-chaos-test 的請求要由這條先接走；沒帶 header 的請求落到最後的預設路由
    - name: fault-injection
      match:
        - headers: { x-chaos-test: { exact: "true" } }
      fault:
        delay:
          percentage: { value: 50.0 }
          fixedDelay: 5s
        abort:
          percentage: { value: 10.0 }
          httpStatus: 503
      route:
        - destination: { host: epmm-api-svc.ea-epmm.svc.cluster.local }
    # 沒有 match = 全部命中，一定放最後；少了它，沒帶 x-chaos-test 的請求在這個 VirtualService 裡沒有路由可走
    - name: default
      route:
        - destination: { host: epmm-api-svc.ea-epmm.svc.cluster.local }
```

#### 常用 key 對照

| Key | 說明 | 踩雷 |
|---|---|---|
| `hosts` | 這條規則管哪些 host | 內部呼叫要寫 **FQDN** |
| `gateways` | 綁哪個 gateway | **不寫 = 預設只有 `mesh`**；寫了 gateway 就**不含 mesh**，要自己加 |
| `http[].match` | 比對條件 | **first-match-wins**，順序決定一切 |
| `match[].uri` | `exact` / `prefix` / `regex` | `prefix: /api` 也會命中 `/apixyz`，要寫 `/api/` |
| `route[].weight` | 相對比例 | 每個 destination 拿到 weight ÷ 全部 weight 總和的流量；只有一個 destination 時拿到全部。習慣湊成 100，但不是硬性規定 |
| `route[].destination.subset` | DestinationRule 的 subset | subset 不存在 = **503**，且不會有明顯錯誤 |
| `timeout` | 請求逾時 | **預設不逾時**，一定要設 |
| `retries` | 重試 | `attempts` 不含第一次呼叫，最多送 1 + `attempts` 次；(1 + `attempts`) x `perTryTimeout` 要 <= `timeout`，否則後面的重試會被總 timeout 截斷 |
| `rewrite.uri` | 改寫路徑 | 配 `prefix` match 時只取代命中的那段前綴；配 `exact` 或 `regex` match 時會取代整段 path。要用 regex 改寫請用 `uriRegexRewrite` |
| `mirror` | 流量鏡射 | 最安全的新版本驗證方式 |
| `corsPolicy` | CORS | 跟 app 層的 CORS 會疊加，見下 |

#### 踩雷 1：`gateways` 少了 `mesh`，內部流量完全不受管

這是最容易忽略、影響最大的一個。

```yaml
# 目前你的設定
spec:
  gateways: [istio-system/my-gateway]
```

**效果**：只有「從 my-gateway 進來的流量」會套用這些路由規則。`ea-pmc` 裡的另一個 Pod 直接呼叫 `pmc-epmmformquerygui-svc:8080` 時，**完全不會經過這條 VirtualService**——它仍然經過 sidecar，但套用的是預設路由：送到該 Service 的所有 endpoint，負載平衡演算法預設是 least request（Istio 官方：「By default, the Envoy proxies distribute traffic across each service’s load balancing pool using a least requests model.」）。

**後果**：

- **canary 權重對內部呼叫無效**（內部流量會依 endpoint 數量——v1、v2 各有幾個 Pod——用 least request 分配，跟 90/10 的設定無關；只有兩版 Pod 數量相同時才大約是 50/50）
- 逾時、重試、header 改寫，內部呼叫通通吃不到

**修法**：

```yaml
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   # 內部 host 也要列
  gateways:
    - istio-system/my-gateway
    - mesh                                                 # 加這個
```

> **注意**：`gateways` 欄位完全不寫時，預設值是 `["mesh"]`（只管內部）。一旦你寫了任何 gateway，就**必須顯式加上 `mesh`** 才會同時管內部流量。

> **完整機制**（為什麼會這樣、內部流量實際走什麼路、`hosts` 為什麼也要一起改）見 [Part 14](#part-14保留人工-pilot-run-的-canary-發布) 的 14.6。

#### 踩雷 2：match 的順序

```yaml
  http:
    - route: [...]                    # 沒有 match = 全部命中
    - match:
        - uri: { prefix: /api/ }      # 永遠不會被執行到！
      route: [...]
```

**沒有 `match` 的規則等於「全部命中」，一定要放在最後。** 同理，`prefix: /` 也要放最後。

#### 踩雷 3：`prefix` 的邊界

```yaml
  - uri: { prefix: /api }      # 也會命中 /apixyz、/apiadmin
  - uri: { prefix: /api/ }     # 只命中 /api/ 開頭（推薦）
```

要同時支援 `/api` 和 `/api/`，就寫兩個 match（你現有的 VirtualService 就是這樣寫的，這是對的）。

#### 踩雷 4：CORS 與 app 層重複

你的 Spring Boot 已經有 `CorsConfig` 在處理 CORS（`spring_boot_fix_cors.md`）。如果 VirtualService 也設 `corsPolicy`，**兩邊可能互相干擾**（header 重複或被覆寫；官方文件沒有說明 `corsPolicy` 與上游 CORS header 並存時是疊加還是覆寫，請實測確認），而且 origin 沒命中的 preflight 預設會被轉給 app（官方：「Default is forward to upstream.」）。若出現重複的 header，瀏覽器會報錯，例如：

```
The 'Access-Control-Allow-Origin' header contains multiple values '*, *', but only one is allowed.
```

**擇一即可。** 建議放在 app 層（你已經做了，而且能跟 Spring Security 一起管），VirtualService 就不要再設 `corsPolicy`。

#### 踩雷 5：subset 不存在 = 503

`route[].destination.subset` 指向的 subset 必須在 DestinationRule 裡定義，而且 subset 的 label 要真的有 Pod 命中。否則是 **503 且 access log 的 `response_flags` 是 `NC`（no cluster）或 `UH`（no healthy upstream）**。

```bash
# 驗證 subset 有沒有對應的 endpoint
istioctl proxy-config endpoint deploy/istio-ingressgateway -n istio-system \
  | grep pmc-epmmformquerygui
```

### 參考來源

- kubernetes.io — pod-lifecycle：https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- kubernetes.io — deployment：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- kubernetes.io — topology-spread-constraints：https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- kubernetes.io — taint-and-toleration：https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- kubernetes.io — pod-priority-preemption：https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
- kubernetes.io — container-lifecycle-hooks：https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- github.com — kep.yaml：https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/3960-pod-lifecycle-sleep-action/kep.yaml
- kubernetes.io — probes：https://kubernetes.io/docs/concepts/workloads/pods/probes/
- kubernetes.io — pod-qos：https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- istio.io — protocol-selection：https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/
- kubernetes.io — service-v1：https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/
- istio.io — application-requirements：https://istio.io/latest/docs/ops/deployment/application-requirements/
- istio.io — destination-rule：https://istio.io/latest/docs/reference/config/networking/destination-rule/
- kubernetes.io — endpoint-slices：https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- kubernetes.io — secret：https://kubernetes.io/docs/concepts/configuration/secret/
- kubernetes.io — configure-pod-configmap：https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- kubernetes.io — volume：https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume/
- kubernetes.io — object-meta：https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/object-meta/
- kubernetes.io — configmap：https://kubernetes.io/docs/concepts/configuration/configmap/
- kubernetes.io — job：https://kubernetes.io/docs/concepts/workloads/controllers/job/
- istio.io — annotations：https://istio.io/latest/docs/reference/config/annotations/
- kubernetes.io — cron-jobs：https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- raw.githubusercontent.com — utils.go：https://raw.githubusercontent.com/kubernetes/kubernetes/master/pkg/controller/cronjob/utils.go
- pubs.opengroup.org — V3_chap02.html：https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
- istio.io — change-notes：https://istio.io/latest/news/releases/1.27.x/announcing-1.27/change-notes/
- istio.io — istioctl-analyze：https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/
- istio.io — gateway：https://istio.io/latest/docs/reference/config/networking/gateway/
- istio.io — secure-ingress：https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/
- istio.io — network-issues：https://istio.io/latest/docs/ops/common-problems/network-issues/
- istio.io — gateway：https://istio.io/latest/docs/setup/additional-setup/gateway/
- istio.io — ist0161：https://istio.io/latest/docs/reference/config/analysis/ist0161/
- istio.io — virtual-service：https://istio.io/latest/docs/reference/config/networking/virtual-service/
- envoyproxy.io — router_filter：https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter
- istio.io — traffic-management：https://istio.io/latest/docs/concepts/traffic-management/

---

## Part 7：Canary 發布與自動擴縮容

### 7.1 為什麼 K8s 原生做不到真正的 canary

K8s 的 Deployment 滾動更新期間，新舊版本其實會並存（官方：新的 ReplicaSet 可以在滾動更新開始時立刻擴大；以 `maxSurge` 設為 30% 為例，「the total number of old and new Pods does not exceed 130% of desired Pods」。`maxSurge` 預設為 25%）。問題在於比例只能用 Pod 數量表達，而且 rollout 會自動一路推進到 100%：你無法讓它停在某個比例上，也無法讓特定使用者（例如只有內部測試者）才分到新版。

想用 replica 數量硬湊比例（例如 v1 開 9 個、v2 開 1 個 = 10%）有三個問題：

1. **比例受限於 Pod 數量**。要做 1% 就得開 100 個 Pod
2. **改比例要動 Pod 數量**，很慢而且浪費資源
3. **無法針對特定使用者**（例如只讓內部測試者看到新版）

Istio 把「流量比例」和「Pod 數量」**解耦**：2 個 v1 Pod + 2 個 v2 Pod，一樣可以做 99:1 的分流。

### 7.2 完整實作：DestinationRule subset + VirtualService weight

#### 步驟 1：兩個版本的 Deployment 帶不同的 `version` label

```yaml
# v1（現有版本）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pmc-epmmformquerygui-v1
  namespace: ea-pmc
spec:
  selector:
    matchLabels:
      app: pmc-epmmformquerygui
      version: v1
  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui    # Service 靠這個選中「兩個版本的所有 Pod」
        version: v1                  # DestinationRule 靠這個分 subset
    spec:
      serviceAccountName: pmc-epmmformquerygui
      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.2.3
          resources:
            requests: { memory: "512Mi", cpu: "250m" }   # 7.5 的 HPA 靠它算 CPU utilization；沒設的話 HPA 不會動
---
# v2（新版本）—— 只有 version label 和 image 不同
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pmc-epmmformquerygui-v2
  namespace: ea-pmc
spec:
  replicas: 1                        # canary 初期不需要跟 v1 一樣多
  selector:
    matchLabels:
      app: pmc-epmmformquerygui
      version: v2
  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui
        version: v2
    spec:
      serviceAccountName: pmc-epmmformquerygui
      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.3.0
          resources:
            requests: { memory: "512Mi", cpu: "250m" }   # 同上：每一版都要設，7.5 的 HPA 才算得出來
```

#### 步驟 2：Service 不變（同時選中兩個版本）

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pmc-epmmformquerygui-svc
  namespace: ea-pmc
spec:
  selector:
    app: pmc-epmmformquerygui        # 【關鍵】不要加 version，才能同時涵蓋 v1 v2
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      appProtocol: http
```

#### 步驟 3：DestinationRule 定義 subset

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: pmc-epmmformquerygui-dr
  namespace: ea-pmc
spec:
  host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local

  trafficPolicy:                     # 套用到所有 subset 的預設策略
    loadBalancer:
      consistentHash:                # subset 內的軟黏著（見 7.4），不解決 canary 跨版本的問題
        httpCookie:
          # 不要用 JSESSIONID：設了 ttl 之後，請求沒帶這個 cookie 時 Envoy 會自己產生一個同名 cookie，
          # 與 Spring 的 session cookie 撞名（詳見 6.2 的說明）。改用專屬名稱，交給 Envoy 管理。
          name: istio-session-affinity
          ttl: 10800s
    connectionPool:
      tcp:  { maxConnections: 100, connectTimeout: 3s }
      http: { http1MaxPendingRequests: 100, maxRequestsPerConnection: 0 }
    outlierDetection:                # 熔斷：連續出錯的 Pod 自動踢出負載平衡
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50         # 最多踢掉一半，避免全部被踢光

  subsets:
    - name: v1
      labels: { version: v1 }        # 對應 Pod 的 label
    - name: v2
      labels: { version: v2 }
```

#### 步驟 4：VirtualService 控制比例

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app-routing
  namespace: ea-pmc
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  gateways:
    - istio-system/my-gateway
    - mesh                           # 【必加】否則內部呼叫吃不到權重

  http:
    # 階段 1：先讓內部測試者用 header 指定走 v2（0% 正式流量）
    - name: canary-testers
      match:
        - headers:
            x-canary: { exact: "true" }
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: v2
            port: { number: 8080 }

    # 階段 2+：正式流量按權重分配
    - name: main
      match:
        - uri: { prefix: /gui_epmmFormQuery/ }
        - uri: { exact: /gui_epmmFormQuery }
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: v1
            port: { number: 8080 }
          weight: 100                # <- 灰度主要靠調這兩個數字；v2 的 Pod 數也要跟著擴（見下方說明）
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: v2
            port: { number: 8080 }
          weight: 0
      timeout: 15s
      retries:
        attempts: 3
        perTryTimeout: 4s
        retryOn: "5xx,reset,connect-failure"
```

**推進權重時，v2 的容量也要跟上。** 步驟 1 的 v2 寫死 `replicas: 1` 而且沒有 HPA；權重拉到 50% 或 100% 時，一個 Pod 會被打爆。推進權重的同時要擴大 v2 的 replicas，或替 v2 也配一個 HPA（見 7.5）。

#### 步驟 5：灰度推進流程

```bash
# 階段 1：只有帶 header 的內部測試者能看到 v2（0% 正式流量）
curl -H "x-canary: true" https://myapp.example.com/gui_epmmFormQuery/

# 階段 2：切 5%
kubectl patch virtualservice app-routing -n ea-pmc --type=json -p='[
  {"op":"replace","path":"/spec/http/1/route/0/weight","value":95},
  {"op":"replace","path":"/spec/http/1/route/1/weight","value":5}
]'

# 觀察 5~15 分鐘：v2 的錯誤率與延遲
# 階段 3: 20% → 階段 4: 50% → 階段 5: 100%

# 出事立刻回滾（秒級，不需要重新部署）
kubectl patch virtualservice app-routing -n ea-pmc --type=json -p='[
  {"op":"replace","path":"/spec/http/1/route/0/weight","value":100},
  {"op":"replace","path":"/spec/http/1/route/1/weight","value":0}
]'
```

**每個階段要看的指標：**

```bash
# v2 的錯誤率（跟 v1 比）
sum(rate(istio_requests_total{destination_workload="pmc-epmmformquerygui-v2",response_code=~"5.."}[5m]))
/ sum(rate(istio_requests_total{destination_workload="pmc-epmmformquerygui-v2"}[5m]))

# v2 的 P99 延遲
histogram_quantile(0.99,
  sum(rate(istio_request_duration_milliseconds_bucket{destination_workload="pmc-epmmformquerygui-v2"}[5m]))
  by (le))
```

### 7.3 進階：鏡射（最安全的驗證方式）

在切任何真實流量之前，先把正式流量**複製一份**給 v2，但把回應丟掉。使用者完全無感，你卻能看到 v2 在真實流量下的表現。

```yaml
    - name: main
      route:
        - destination: { host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local, subset: v1 }
      mirror:
        host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
        subset: v2
      mirrorPercentage: { value: 100.0 }
```

> **⚠ 有副作用的請求不能鏡射。** 鏡射的 `POST /api/orders` 會**真的**在 v2 那邊建立訂單。只鏡射唯讀流量，或讓 v2 連到獨立的測試資料庫。

### 7.4 Canary 與 session 黏著的衝突（你的架構要特別注意）

**問題**：你的 Spring Boot 用 **in-memory `HttpSession`** + Keycloak OIDC。使用者登入後，session 存在某個 Pod 的記憶體裡。

canary 分流是**逐請求（per-request）**決定的，所以一個已登入的使用者，下一個請求有 10% 機率被送到 v2 —— **而 v2 沒有他的 session，會直接把他踢回 Keycloak 登入頁**。

**三種解法，由治標到治本：**

| 解法 | 做法 | 優缺點 |
|---|---|---|
| **A. consistentHash by cookie** | DestinationRule 用 `httpCookie`（專屬名稱如 `istio-session-affinity`，不要用 `JSESSIONID`） | 快，但是軟黏著，**只在 subset 內生效**——weight 分流仍在 subset 之間，同一個 cookie 還是可能被分到不同 subset |
| **B. 用 header/cookie 決定版本** | 不用 weight，改用 `match` 比對 cookie 值決定走 v1 或 v2 | 黏著保證，但比例控制變粗糙 |
| **C. session 外部化** | Spring Session + Redis | **根本解**，canary、擴縮容、Pod 重啟全都不再是問題 |

**解法 B 的寫法（不用 Redis 也能安全灰度）：**

```yaml
  http:
    # 已經被分到 v2 的使用者，之後永遠走 v2
    - match:
        - headers:
            cookie: { regex: ".*canary-group=v2.*" }
      route:
        - destination: { host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local, subset: v2 }

    # 其餘走 v1，並由 v1 決定要不要發 canary-group cookie
    - route:
        - destination: { host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local, subset: v1 }
```

> **建議**：**解法 A 無法避免使用者被登出，只能降低影響。** Istio 官方只把 consistent hash 稱為「soft session affinity」（"Consistent Hash-based load balancing can be used to provide soft session affinity"），而 weight 分流發生在 subset 之間，A 擋不住同一位使用者被送到另一個 subset；只在離峰時段灰度，也只是減少受影響的人數，不是消除。要**保證**不被登出，用**解法 B**（用 cookie 決定版本）或**解法 C**（session 外部化）。你架構上遲早要做**解法 C**——因為 `sessionAffinity: ClientIP` 在 Istio 下本來就沒生效（Part 6.2），你現在其實已經在承受「使用者偶爾被登出」的風險了。

### 7.5 HorizontalPodAutoscaler

#### 解決什麼問題

尖峰時段人工擴容太慢，離峰時多開的 Pod 純浪費。HPA 依指標自動調整 replica 數。

#### 全註解 YAML

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: pmc-epmmformquerygui-v1-hpa   # 每一版 Deployment 各一個 HPA（v2 另複製一份，name 與 scaleTargetRef 換成 -v2）
  namespace: ea-pmc
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: pmc-epmmformquerygui-v1   # 要縮放誰：7.2 的 Deployment 叫 -v1／-v2，沒有叫 pmc-epmmformquerygui 的，寫錯名字 HPA 找不到目標

  minReplicas: 2                    # 【建議至少 2】只有 1 個時，節點故障、drain 或 PDB 擋住自願中斷時就沒有備援
  maxReplicas: 10                   # 上限，避免失控擴容把 cluster 吃光

  metrics:
    # ---------- 型別 1：Resource（最常用）----------
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70    # 目標：平均 CPU 用量 = requests 的 70%
                                    # 【關鍵】分母是 requests，沒設 requests 這個 HPA 不會動
    # 【預設不啟用 memory】HPA 有多個指標時，每個指標各算一個期望 replica 數，然後取「最大值」；
    # JVM 的 memory 降不下來，這一項會讓 HPA 永遠縮不回去（見踩雷）
    # - type: Resource
    #   resource:
    #     name: memory
    #     target:
    #       type: Utilization
    #       averageUtilization: 80

    # ---------- 型別 2：Pods（每個 Pod 的自訂指標平均值）----------
    - type: Pods
      pods:
        metric:
          name: istio_requests_per_second     # 名稱由 adapter 的規則自訂（Istio 標準指標是 istio_requests_total counter，要在規則裡用 rate 定義），並需要提供 custom.metrics API 的實作
        target:
          type: AverageValue
          averageValue: "100"                 # 每個 Pod 平均 100 RPS

    # ---------- 型別 3：Object（某個 K8s 物件的指標）----------
    # - type: Object
    #   object:
    #     metric: { name: requests_per_second }
    #     describedObject: { apiVersion: networking.istio.io/v1, kind: VirtualService, name: app-routing }
    #     target: { type: Value, value: "10k" }

    # ---------- 型別 4：External（外部系統指標，如 queue 長度）----------
    # - type: External
    #   external:
    #     metric: { name: queue_messages_ready, selector: {matchLabels: {queue: "forms"}} }
    #     target: { type: AverageValue, averageValue: "30" }

  # ---------- 擴縮容行為（v2 才有，非常重要）----------
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0     # 擴容不等待，立刻反應（預設 0）
      policies:
        - type: Percent
          value: 100                    # 每 15 秒最多「翻倍」
          periodSeconds: 15
        - type: Pods
          value: 4                      # 或每 15 秒最多加 4 個
          periodSeconds: 15
      selectPolicy: Max                 # 兩個 policy 取「較寬鬆」的（擴得快）

    scaleDown:
      stabilizationWindowSeconds: 300   # 【重要】縮容前先觀察 5 分鐘，避免流量抖動造成反覆擴縮
      policies:
        - type: Percent
          value: 50                     # 每分鐘最多縮掉一半
          periodSeconds: 60
      selectPolicy: Min                 # 取「較保守」的（縮得慢）
```

#### 搭配 PodDisruptionBudget

HPA 管「自動擴縮」，PDB 管「維護時不要一次砍太多」。兩個要一起用：

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pmc-epmmformquerygui-pdb
  namespace: ea-pmc
spec:
  minAvailable: 1                   # 自願中斷（drain node、cluster 升級）時至少留 1 個
  # maxUnavailable: 1               # 或者反過來表達，兩者只能擇一
  selector:
    matchLabels:
      app: pmc-epmmformquerygui
```

> **PDB 的陷阱**：`minAvailable` 設成等於 `replicas`（例如 2 個 Pod 設 `minAvailable: 2`）會讓 **node drain 永遠卡住**，因為一個都不能動。規則：`minAvailable` 必須小於 `minReplicas`。

#### 常用 key 對照

| Key | 說明 | 踩雷 |
|---|---|---|
| `minReplicas` | 下限 | 建議 >= 2 |
| `maxReplicas` | 上限 | 要算得出 node 資源撐不撐得住 |
| `averageUtilization` | 目標使用率 | **分母是 `requests` 不是 `limits`** |
| `behavior.scaleDown.stabilizationWindowSeconds` | 縮容觀察期 | **預設 300 秒**，太短會震盪 |
| `behavior.scaleUp.stabilizationWindowSeconds` | 擴容觀察期 | 預設 0（立刻擴） |
| `selectPolicy` | `Max` / `Min` / `Disabled` | `Disabled` 可以「只擴不縮」 |

#### 踩雷

- **Deployment 裡還留著 `replicas: 2`**：每次 `kubectl apply` 都會把 HPA 調好的數字打回 2，然後 HPA 再調回來，來回震盪。**用 HPA 就把 `replicas` 從 manifest 刪掉。**
- **沒設 `resources.requests`**：CPU utilization 型的 HPA 完全不會動作。`kubectl describe hpa` 會顯示 `<unknown>`。
- **沒裝 metrics-server**：`kubectl top pod` 沒輸出就代表沒裝，HPA 拿不到指標。
- **用 memory 當指標對 Java 很危險**：JVM 的 heap 拿了就不太還，memory 用量會一路往上不下來，HPA 會一直擴容到 `maxReplicas` 卡住。**Java 應用優先用 CPU 或 RPS 當指標。**
- **HPA 反應比流量慢**：預設 15 秒同步一次，加上 Pod 啟動時間（你的 Spring Boot 可能要 60 秒），突發流量還是會打到現有 Pod。真正的尖峰要靠**預先擴容**（排程 HPA / KEDA cron scaler）。

### 7.6 什麼時候該升級到 Argo Rollouts / Flagger / KEDA

前面的做法（VirtualService weight + HPA）**零額外安裝**，但每次灰度都要手動改權重、手動看指標、手動決定要不要繼續。以下三個工具各自解決不同的痛點。

#### Argo Rollouts

**做什麼**：用 `Rollout` CRD 取代 `Deployment`，把灰度步驟寫成宣告式的階梯，自動推進。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
spec:
  replicas: 4
  # 此處已省略 selector 和 template（實際的 Rollout 需要寫出它們，或改用 workloadRef 引用既有 Deployment，見表下說明）
  strategy:
    canary:
      # 用 subset-level 的做法：沿用 7.2 的 DestinationRule 和 app-routing VS（兩個 destination 同一個 host、靠 subset 區分）。
      # 不要在這裡加 canaryService / stableService —— 那是 host-level 的做法，
      # 官方要求 VS route 裡有兩個 host 分別對應這兩個 Service，跟 7.2 的 VS 結構不合
      trafficRouting:
        istio:
          virtualService:
            name: app-routing               # 它會自動改這個 VS 的 weight
            routes: [main]
          destinationRule:
            name: pmc-epmmformquerygui-dr   # 7.2 步驟 3 的 DestinationRule
            canarySubsetName: v2
            stableSubsetName: v1
      analysis:                             # 背景分析：整個灰度推進期間持續跑，失敗就中止並回滾
        templates:
          - templateName: success-rate
      steps:
        - setWeight: 5
        - pause: { duration: 5m }           # 自動等 5 分鐘
        - setWeight: 20
        - pause: { duration: 10m }
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 100
```

背景分析要引用的 AnalysisTemplate 也要一起建立，否則上面的 `success-rate` 找不到。`failureLimit` 是中止條件之一：失敗次數超過容許值，這次發布就中止（確切計數語意見官方 analysis 文件）。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: ea-pmc
spec:
  metrics:
    - name: success-rate
      interval: 1m
      failureLimit: 3                       # 容許的失敗次數；超過就判定分析失敗，Rollout 中止（確切計數語意見 Argo 官方 analysis 文件）
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090   # 依你的環境調整
          query: "<你的 PromQL：查 canary 的成功率，依你的指標名稱撰寫>"   # 必須替換成真正的查詢，否則 successCondition 永遠拿不到資料
      successCondition: result[0] >= 0.99
```

| | |
|---|---|
| **解決** | 手動改權重、手動決定推進、出事要人在場才能回滾 |
| **代價** | **要把 Deployment 改寫成 Rollout CRD**（GitOps / Helm chart 都要調整）；也可以改用 `workloadRef` 引用既有 Deployment，見表下說明；多一套 controller 和 CLI 要維運 |
| **什麼時候值得** | 一週發布 2 次以上、或有夜間發布需求（自動回滾比叫人起床可靠）；已經在用 Argo CD 的話幾乎是免費加購 |

**不一定要改寫 Deployment**：Rollout 可以用 `workloadRef` 引用既有的 Deployment（官方遷移文件：「Reference an existing Deployment using `workloadRef` field.」），再把原 Deployment scale down 到 0（官方：「Instead of removing Deployment you can scale it down to zero and reference it from the Rollout resource」），`scaleDown` 可選 `never`／`onsuccess`／`progressively`，決定原 Deployment 何時縮減。

**兩個 Service 要自己建**：這個範例沒有 `canaryService` / `stableService`；若你改用 host-level 做法，官方寫「Finally, a canary and stable Service should be deployed.」—— 這兩個 Service 由你建立，Argo 只在發布期間改它們的 selector。

#### Flagger

**做什麼**：跟 Argo Rollouts 目標一樣，但**不用改寫你的 Deployment YAML**——它用一個 `Canary` CRD 引用既有的 Deployment，自動幫你產生和修改 VirtualService / DestinationRule。但它會**接管這個 Deployment 的副本數**：Flagger 另外建 `<name>-primary` Deployment 承接正式流量，再把原本的 Deployment 縮到 0 當成 canary 用（官方：「the target deployment is scaled to zero」）；同時建立 `<name>`、`<name>-primary`、`<name>-canary` 三個 Service。

```yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
spec:
  targetRef: { apiVersion: apps/v1, kind: Deployment, name: pmc-epmmformquerygui }
  service:
    port: 8080
    gateways: ["istio-system/my-gateway"]
    hosts: ["myapp.example.com"]
  analysis:
    interval: 1m
    threshold: 5              # 整次分析累計 5 次指標檢查失敗就回滾（官方：「max number of failed metric checks before rollback」；不要求連續）
    maxWeight: 50
    stepWeight: 10            # 每次 +10%
    metrics:
      - name: request-success-rate
        thresholdRange: { min: 99 }     # 成功率低於 99% 就回滾
        interval: 1m
      - name: request-duration
        thresholdRange: { max: 500 }    # P99 超過 500ms 就回滾
        interval: 1m
    webhooks:                            # 灰度過程中自動跑負載測試
      - name: load-test
        url: http://flagger-loadtester.test/
        metadata: { cmd: "hey -z 1m -q 10 http://pmc-epmmformquerygui-canary.ea-pmc:8080/" }   # 直接打 canary Service（官方範例也是 podinfo-canary），打公開網域只有 stepWeight% 會到 canary，低流量時分析樣本不夠
```

| | |
|---|---|
| **解決** | 同 Argo Rollouts，但**不用改寫 Deployment YAML**（副本數會被 Flagger 接管，見上） |
| **代價** | 它會**接管**你的 VirtualService / DestinationRule（自己產生自己改），你不能再手動維護那些檔案，跟 GitOps 的「宣告即真相」有摩擦 |
| **什麼時候值得** | 想要自動灰度但**不想改現有 Deployment 結構**；已經有 Prometheus 可以提供指標 |

**Argo Rollouts vs Flagger 一句話**：Argo 要你**改 workload 定義**、換來對灰度步驟的完全掌控；Flagger 不改 workload、但要你**交出流量設定的所有權**。已經在用 Argo CD 就選 Argo Rollouts，否則 Flagger 導入成本較低。

#### KEDA

**做什麼**：原生 HPA 也支援 Object / External 指標（見 7.5 的範例），KEDA 的價值在於**內建大量 scaler**（佇列長度、Kafka lag、資料庫查詢結果、cron 排程），不用自己架 metrics adapter，而且從 0 喚醒更成熟。原生 HPA 從 Kubernetes v1.37 起（`HPAScaleToZero` 進入 beta、預設開啟）也能縮到 0，但官方限制：「Setting `minReplicas: 0` requires at least one object or external metric to be configured」，純 CPU / memory 不行。

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: pmc-form-processor
  namespace: ea-pmc
spec:
  scaleTargetRef: { name: pmc-form-processor }
  minReplicaCount: 0          # 沒事的時候縮到 0，完全不佔資源（原生 HPA 從 v1.37 起也可以，但只限 Object/External 指標；KEDA 內建 scaler、從 0 喚醒更成熟）
  maxReplicaCount: 20
  cooldownPeriod: 300
  triggers:
    # 依 Kafka lag 擴縮
    - type: kafka
      metadata:
        bootstrapServers: kafka:9092
        consumerGroup: form-processor
        topic: form-events
        lagThreshold: "100"

    # 依 cron 預先擴容（尖峰前先把 Pod 開好，解決「HPA 反應太慢」）
    - type: cron
      metadata:
        timezone: Asia/Taipei
        start: "45 8 * * 1-5"     # 平日 08:45 先擴
        end: "0 18 * * 1-5"
        desiredReplicas: "6"
```

| | |
|---|---|
| **解決** | 依外部事件擴縮、縮到 0、排程式預先擴容 |
| **代價** | 多一個 operator；跟 HPA 不能同時管同一個 Deployment（KEDA 自己會產生 HPA） |
| **什麼時候值得** | 有**訊息佇列 / 批次處理**的 workload；或有明確的尖峰時段想預先擴容。**純 HTTP 服務用原生 HPA 就夠了** |

#### 決策表

| 你的狀況 | 建議 |
|---|---|
| 一個月發布 1~2 次，有人在場盯 | **VirtualService weight + HPA**（本文主線），不要多裝東西 |
| 發布頻繁 / 要夜間自動發布 | Argo Rollouts（已有 Argo CD）或 Flagger |
| 已經在用 Argo CD | **Argo Rollouts** |
| 不想動現有 Deployment 結構 | **Flagger** |
| 有 Kafka / RabbitMQ / 批次任務 | **KEDA** |
| 尖峰時段固定且 HPA 反應太慢 | **KEDA cron trigger** |
| 純 HTTP 服務、流量平穩 | **原生 HPA 就夠**，不要過度工程 |

> **給你的建議**：以目前的規模，**先把 HPA + PDB + `mesh` 加進 VirtualService 做好**，手動灰度就足夠。等到「發布頻率高到手動改權重變成負擔」再考慮 Argo Rollouts。**先解 session 外部化的問題，那個比自動灰度重要得多。**

---

> **延伸閱讀**：想讓 canary 不用等人做 pilot run，見 [Part 12](#part-12用-argo-rollouts-取代人工-pilot-run) —— 含 `setHeaderRoute` 精準指定哪些請求走 v2，以及從人工過渡到全自動的四階段路徑。

### 參考來源

- argo-rollouts — analysis：https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- argo-rollouts — specification：https://argo-rollouts.readthedocs.io/en/stable/features/specification/
- argo-rollouts — Istio traffic management：https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/
- argo-rollouts — migrating：https://argo-rollouts.readthedocs.io/en/stable/migrating/
- flagger — Istio progressive delivery：https://docs.flagger.app/tutorials/istio-progressive-delivery
- flagger — deployment strategies：https://docs.flagger.app/usage/deployment-strategies
- flagger — how it works：https://docs.flagger.app/usage/how-it-works
- istio.io — 0.1 canary：https://istio.io/latest/blog/2017/0.1-canary/
- istio.io — metrics：https://istio.io/latest/docs/reference/config/metrics/
- istio.io — destination-rule：https://istio.io/latest/docs/reference/config/networking/destination-rule/
- kubernetes.io — deployment：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- kubernetes.io — horizontal-pod-autoscale：https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

---

## Part 8：除錯速查表

### 8.1 istioctl 常用指令

```bash
# ---------- 總體健康檢查（出事先跑這個）----------
istioctl analyze -A                         # 掃描全 cluster 的設定問題
istioctl proxy-status                       # 所有 sidecar 的設定同步狀態
# STALE = istiod 已下發設定、但 Envoy 還沒回 ACK，可能有問題（官方：「has not received an acknowledgement」）
# NOT SENT = istiod 沒東西可送，通常是正常狀態（例如 ingressgateway 的 RDS 常顯示 NOT SENT），不用當成故障

# ---------- 單一 Pod 的完整診斷 ----------
istioctl x describe pod <pod> -n ea-pmc     # 這個 pod 適用哪些 VS/DR/policy，一次看完

# ---------- 設定下發檢查（由外而內）----------
istioctl proxy-config listener deploy/istio-ingressgateway -n istio-system   # Gateway 有沒有生效
istioctl proxy-config route   deploy/istio-ingressgateway -n istio-system    # VirtualService 路由
istioctl proxy-config cluster deploy/pmc-epmmformquerygui -n ea-pmc          # 看得到哪些服務（Sidecar 收斂結果）
istioctl proxy-config endpoint deploy/pmc-epmmformquerygui -n ea-pmc         # 後端 Pod 清單
istioctl proxy-config secret  deploy/pmc-epmmformquerygui -n ea-pmc          # mTLS 憑證與身分

# ---------- 授權除錯 ----------
istioctl x authz check deploy/epmm-api -n ea-epmm         # 這個 workload 被哪些 policy 管

# ---------- 動態調 log level（查完記得調回來）----------
istioctl proxy-config log deploy/epmm-api -n ea-epmm --level rbac:debug
istioctl proxy-config log deploy/epmm-api -n ea-epmm --level router:debug,connection:debug
istioctl proxy-config log deploy/epmm-api -n ea-epmm -r                      # 復原：-r 把所有 logger 重設回預設 level（warning）
# 也可用 --level warning（不指定 logger 名稱 = 套用到全部 logger）；default:warning 不是有效的 logger 名稱，istioctl 會回「unrecognized logger name」
```

### 8.2 Envoy access log 判讀

```bash
kubectl logs -n ea-pmc deploy/pmc-epmmformquerygui -c istio-proxy --tail=50
```

> **前提：access log 預設是關的。** 沒打開的話上面這行不會有任何請求紀錄（官方：「Istio offers a few ways to enable access logs.」）。要用 Telemetry API 打開，或在安裝時設 `meshConfig.accessLogFile=/dev/stdout`；只有 `demo` configuration profile 會預設啟用。

預設格式的欄位順序（實際輸出在 `upstream_host` 後還有更多欄位）：

```
[時間] "METHOD PATH PROTOCOL" 狀態碼 response_flags ... "upstream_host" ...
```

**`response_flags` 是最重要的欄位**——它直接告訴你是哪一層擋的：

| flag | 意義 | 往哪查 |
|---|---|---|
| `-` | 正常 | — |
| **`NR`** | **No Route** — 沒有路由規則匹配 | VirtualService 的 `match` / `hosts` / `gateways` |
| **`NC`** | **No Cluster** — 路由到的目的地不存在 | DestinationRule 的 subset 名稱打錯 |
| **`UH`** | **No healthy Upstream** — 沒有健康的後端 | Pod 全部 not ready，或 subset label 對不到 Pod |
| **`UF`** | **Upstream Failure** — 連不上後端 | **mTLS 不匹配**（最常見）、NetworkPolicy、Pod 掛了 |
| `UO` | Upstream Overflow | 熔斷觸發（`connectionPool` 上限） |
| `URX` | 重試次數用完 | 後端持續失敗 |
| `UT` | Upstream Timeout | 後端太慢，或 `timeout` 設太短 |
| `UAEX` | 外部授權拒絕 | `CUSTOM` action 的 ext_authz |
| `DC` | Downstream Connection termination | client 主動斷線 |

> **RBAC 拒絕沒有專屬 flag**：Envoy 的 response flag 清單裡沒有 RBAC，所以 AuthorizationPolicy 擋下時 flag 是 `-`，要靠 403 加上 `RESPONSE_CODE_DETAILS` 的 `rbac_access_denied_matched_policy[...]` 判讀，見 **Part 3**。

**症狀 → 原因 對照：**

| 你看到 | 最可能的原因 |
|---|---|
| 404 且 log 有 `NR` | 沒有路由匹配：HTTP 的 `Host` 沒對上 Gateway／VirtualService 的 `hosts`，或 VirtualService 的 `match`／`gateways` 沒對上（HTTPS 的 SNI 不符是 TLS 握手失敗，不會回 404） |
| gateway 完全沒 log | 通常是 access log 沒開，或流量根本沒到 gateway（DNS、LB、防火牆） |
| 503 且 `UH` / `NC` | subset 找不到 Pod，或 Service selector 錯 |
| 503 且 `UF` | mTLS 不匹配、NetworkPolicy 擋、或後端真的掛了 |
| 403 + `RBAC: access denied` | AuthorizationPolicy（Part 3） |
| 偶發 502／503 且集中在部署期間 | 缺 `preStop` sleep（Part 6.1；見表下說明） |
| 內部呼叫不吃 VS 規則 | `gateways` 缺 `mesh`（Part 6.6） |

> **502 還是 503？** 在 Envoy 底下多半看到 503 加 `UC`／`UF`／`URX`；502 較常是外層 F5／nginx 回的。

### 8.3 一分鐘分流診斷

```bash
# 1. 設定有沒有下發？
# 只看標題列與含 STALE 的列。不要用 grep -v SYNCED：一列只要任一欄是 SYNCED 就整列被濾掉，
# 「CDS 是 SYNCED、RDS 是 STALE」的 pod 會被藏起來，而標題列又一定會印出來，「有輸出」不代表有問題。
# 除了標題列之外還有輸出 = 有 pod 設定不同步（NOT SENT 通常只是 istiod 沒東西可送，不一定有問題）
istioctl proxy-status | awk 'NR==1 || /STALE/'

# 2. 全域設定有沒有錯？
istioctl analyze -A

# 3. 這個 pod 到底適用哪些規則？
istioctl x describe pod -n ea-pmc $(kubectl get pod -n ea-pmc -l app=pmc-epmmformquerygui -o name | head -1 | cut -d/ -f2)

# 4. endpoint 是空的嗎？
# Endpoints API 自 Kubernetes v1.33 起 deprecated，官方建議 client 改用 EndpointSlice API
kubectl get endpointslices -n ea-pmc -l kubernetes.io/service-name=pmc-epmmformquerygui-svc

# 5. 從 gateway 內部直接打，排除外部網路因素
# 前提：gateway pod 沒有 iptables 攔截，這個 curl 送出的是明文。ea-pmc 的 PeerAuthentication 若是 STRICT
# （官方：「Connection is an mTLS tunnel (TLS with client cert must be presented)」），這一步一定失敗，
# 但不代表服務壞了。STRICT 時改從有 sidecar 的 pod 測試（例如步驟 6 的 app pod 內 curl，但把 localhost 換成 Service 名稱）
kubectl exec -n istio-system deploy/istio-ingressgateway -- \
  curl -sS -o /dev/null -w "%{http_code}\n" \
  http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health

# 6. 從 app 容器打自己（排除 sidecar 因素）
kubectl exec -n ea-pmc deploy/pmc-epmmformquerygui -c app -- \
  curl -sS localhost:8080/gui_epmmFormQuery/actuator/health
```

> **除錯順序永遠是「由外而內」**：先確認 gateway 收得到 → 再確認路由對得上 → 再確認 endpoint 有東西 → 最後才查授權。反過來查會浪費很多時間。

### 參考來源

- istio.io — proxy-cmd：https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/
- istio.io — istioctl 指令參考：https://istio.io/latest/docs/reference/commands/istioctl/
- istio 原始碼 — proxyconfig.go：https://raw.githubusercontent.com/istio/istio/master/istioctl/pkg/proxyconfig/proxyconfig.go
- istio.io — access-log：https://istio.io/latest/docs/tasks/observability/logs/access-log/
- envoyproxy.io — substitution_formatter：https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter
- istio.io — gateway：https://istio.io/latest/docs/reference/config/networking/gateway/
- kubernetes.io — service：https://kubernetes.io/docs/concepts/services-networking/service/
- istio.io — peer_authentication：https://istio.io/latest/docs/reference/config/security/peer_authentication/

---

## Part 9：你目前環境的具體發現

以下是對照 `spring_full_v4.md` §24 的實際 manifest 找到的問題，按影響程度排序。

### 發現 1：Deployment 沒有 `serviceAccountName`（阻擋所有細粒度授權）

**現狀**：`spring_full_v4.md` 裡 `pmc-epmmformquerygui` 的 Pod spec 沒有 `serviceAccountName`，所有 Pod 都使用 `default` SA。（repo 的 `canary-manual/track-a/` 已修：Deployment 設了 `serviceAccountName: pmc-epmmformquerygui` 與 `automountServiceAccountToken: false`，SA 定義在 `base/00-serviceaccount.yaml`。下面是還沒修的環境該怎麼改。）

**為什麼是問題**：Istio 的 workload 身分完全來自 ServiceAccount。現在 `ea-pmc` 裡的三個 GUI 服務（FormEdit / FormRender / FormQuery）**身分完全一樣**，都是 `cluster.local/ns/ea-pmc/sa/default`。

這代表：

- 你**無法**寫出「只有 FormQuery 能呼叫 epmm-api」這種規則
- 任何一個服務被入侵，攻擊者就取得了整個 namespace 的所有權限
- Part 4 的跨 namespace 授權做不出粒度

**怎麼改**（每個 Deployment 各一份 SA）：

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
---
# 在 Deployment 的 spec.template.spec 加：
      serviceAccountName: pmc-epmmformquerygui
      automountServiceAccountToken: false
```

**影響**：低風險。`serviceAccountName` 在 `spec.template.spec` 底下，改它就是改 pod template，`kubectl apply` 之後會自動滾動更新、新 Pod 才拿到新身分，不需要另外 `rollout restart`（Kubernetes 官方：「A Deployment's rollout is triggered if and only if the Deployment's Pod template (that is, .spec.template) is changed」）。

---

### 發現 2：`sessionAffinity: ClientIP` 在 Istio 下不生效（但架構依賴它）

**現狀**：`spring_full_v4.md` 的 Service 設了 `sessionAffinity: ClientIP` + 3 小時 timeout，Deployment 跑 2 個 replica，Spring Boot 用 in-memory `HttpSession`。（repo 的 `canary-manual/track-a/base/01-service.yaml` 已拿掉 `sessionAffinity: ClientIP`，改由 `base/02-destinationrule.yaml` 的 `consistentHash` 做黏著。）

**為什麼是問題**：`sessionAffinity` 是 kube-proxy 的功能，而 mesh 內的流量由 sidecar 直接送到 Pod IP，**繞過了 kube-proxy 的負載平衡**（Part 1 關鍵觀念一）。所以這個設定實際上沒有提供你以為的保護。

從外部經 ingressgateway 進來的流量尤其明顯——gateway 的 Envoy 用自己的負載平衡演算法（Istio 官方：預設是「least requests model」，即 least request，不是 round-robin）挑 Pod，**同一個使用者的連續請求會在兩個 Pod 之間跳**，session 找不到就會被踢回 Keycloak 重新登入。

**症狀**：使用者偶發性地被登出、或操作到一半跳回登入頁——而且很難重現，因為只在特定的請求分配下才會發生。

**短期修法**：

> 注意：如果 repo 的 `track-a/base/02-destinationrule.yaml`（`pmc-epmmformquerygui-dr`）已套用，它的 host 跟下面這份相同；同一個 host 的兩份 DestinationRule 同時套用會衝突，不要另外再建一份 `pmc-query-affinity`，直接改既有那份。

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: pmc-query-affinity
  namespace: ea-pmc
spec:
  host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          # 不要用 JSESSIONID：Istio 官方說 ttl「If specified, a cookie with the TTL will be generated if the cookie is not present」，
          # 設了 ttl，請求沒帶 cookie 時 Envoy 會自己產生同名 cookie，跟 Spring 的 session cookie 打架，
          # Spring 換 session id 時雜湊值也跟著變。所以用專用名稱。
          name: istio-affinity
          ttl: 10800s
```

**根本修法**：Spring Session + Redis，把 session 外部化。**這也是做 canary 發布的前提條件**（Part 7.4）。

---

### 發現 3：VirtualService 沒有 `mesh`，內部流量繞過所有路由規則

**現狀**（`spring_full_v4.md` 的 VirtualService；repo 的 `canary-manual/track-a/base/03-virtualservice.yaml` 已修：hosts 加了內部 FQDN、gateways 加了 `mesh`，下面「怎麼改」就是那個寫法）：

```yaml
spec:
  hosts: [myapp.example.com]
  gateways: [istio-system/my-gateway]
```

**為什麼是問題**：這條 VirtualService **只管從 my-gateway 進來的流量**。`ea-pmc` 裡任何 Pod 直接呼叫 `pmc-epmmformquerygui-svc:8080` 時，完全不會套用這些規則。

後果：

- **canary 權重對內部呼叫完全無效**（Part 7 的做法會在這裡失效）
- 逾時、重試、header 改寫，內部呼叫都吃不到
- 三個 GUI 服務彼此呼叫時沒有任何流量治理

**怎麼改**：

```yaml
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   # 加入內部 FQDN
  gateways:
    - istio-system/my-gateway
    - mesh                                                 # 加這個
```

**注意**：加 `mesh` 之後內部流量會開始套用這些規則，**要先確認 `match` 條件涵蓋得完整**，否則內部呼叫可能撞到 `NR`（no route）而 404。建議先在測試環境驗證。

**完整機制與驗證方式**見 [Part 14](#part-14保留人工-pilot-run-的-canary-發布) 的 14.6 —— 那裡用具體數字算過，以你目前 2 個 stable pod 的規模，加上 1 個 canary pod 之後會有約三分之一的內部流量打到未驗證的版本。

---

### 發現 4：Service port 沒有命名，Istio 協定判定靠自動偵測

**現狀**（`spring_full_v4.md` 的 Service；repo 的 `canary-manual/track-a/base/01-service.yaml` 已修：port 設了 `name: http` 與 `appProtocol: http`）：

```yaml
  ports:
    - port: 8080
      targetPort: 8080
```

**為什麼是問題**：沒有 `name` 也沒有 `appProtocol`，Istio 只能靠自動協定偵測。Istio 官方說「Istio can automatically detect HTTP and HTTP/2 traffic.」，所以對 HTTP 服務（Spring Boot 這個）自動偵測本來就有效；明確宣告的價值是消除不確定性，而不是「不宣告 L7 功能就會失效」：

- 偵測需要檢查第一個封包，多一點延遲
- 偵測結果不是你宣告出來的，除錯時要多一步確認 Envoy 到底用 L7 還是 L4 處理
- 真正**必須**明確宣告的是 server-first 協定：官方說「Server First protocols, such as MySQL, are incompatible with automatic protocol selection.」；HTTP 服務不屬於這類

**怎麼改**：

```yaml
  ports:
    - name: http                # 加這個
      port: 8080
      targetPort: 8080
      appProtocol: http         # 或這個（更明確，優先）
```

**影響**：零風險，改完立即生效。

---

### 發現 5：沒有 PDB，也沒有 HPA

**現狀**：`replicas: 2` 寫死，沒有 PodDisruptionBudget。

**為什麼是問題**：

- **node drain / cluster 升級時，兩個 Pod 可能同時被驅逐**，造成完全停機。K8s 沒有 PDB 就不知道要保留幾個
- 尖峰時段只能人工擴容
- 滾動更新的 `maxUnavailable` / `maxSurge` 沒有明確寫出來，容量全靠預設值。官方說 `maxUnavailable` 的百分比換算成絕對數字時「rounding down」、`maxSurge`「rounding up」，預設都是 25%：2 個 replica 時 `maxUnavailable` 是 0、`maxSurge` 是 1，所以預設並不會讓容量減半；但寫死的值不會因為 replica 數改變而悄悄換算出別的結果，也才看得出設計意圖

**怎麼改**：

`spec.selector` 只用 `app` 選的話，canary pod 也會被算進去：canary 在線時，兩個 stable pod 仍可能同時被驅逐，而正式流量 100% 走 stable。所以 selector 要再加 `version: stable`（做法見 `canary-manual/CANARY-COMPLETE.md` 3.9；repo 的 `track-a/base/` 目前還沒有這份 PDB 檔案）：

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pmc-epmmformquerygui-pdb
  namespace: ea-pmc
spec:
  minAvailable: 1                # 注意：要小於 HPA 的 minReplicas
  selector:
    matchLabels:
      app: pmc-epmmformquerygui
      version: stable            # 只保護 stable；少了它，canary pod 也會被算進 minAvailable，canary 在線時兩個 stable 可能同時被驅逐
```

同時建議在 Deployment 明確寫出（repo 的 `canary-manual/track-a/release/` 兩份 Deployment 已經加了這三項，下面是還沒修的環境該補的）：

```yaml
  strategy:
    rollingUpdate:
      maxUnavailable: 0          # 更新期間不減少可用數
      maxSurge: 1
  minReadySeconds: 15
```

---

### 發現 6：缺少 `preStop` hook（滾動更新期間的零星 502／503）

**現狀**：`spring_full_v4.md` 的 Deployment 沒有 `lifecycle.preStop`，`terminationGracePeriodSeconds` 用預設值 30。（repo 的 `canary-manual/track-a/release/` 兩份 Deployment 已修：`preStop` 睡 10 秒、`terminationGracePeriodSeconds: 60`。下面是還沒修的環境該怎麼改。）

**為什麼是問題**：Pod 被刪除時，「從 endpoint 移除」和「收到 SIGTERM」是**並行**發生的。在 endpoint 變更傳播到所有 node 的 kube-proxy 和所有 sidecar 之前（通常幾百毫秒到幾秒），還會有流量繼續打到這個正在關閉的 Pod → 在 mesh 內通常是 **503**（Envoy access log 的 response flag 為 `UC`／`UF`，官方說明這些 flag 都是「in addition to 503 response code」）；502 比較常是外層 F5／nginx 回的。

再加上你有 in-memory session，30 秒的 grace period 對於「等現有請求做完」可能不夠。

**怎麼改**：

<!-- validate:skip-yaml 從 Deployment 截出的片段：lifecycle 在 containers[] 底下、terminationGracePeriodSeconds 在 Pod spec 底下，保留原縮排才看得出兩者層級不同，單獨拿出來不是合法 YAML -->
```yaml
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]
      terminationGracePeriodSeconds: 60      # 要大於 preStop sleep + 最長請求時間
```

K8s 1.34 以上可以改用不需要 shell 的 `preStop.sleep`（`preStop: { sleep: { seconds: 10 } }`），細節見 Part 6.1。

---

### 建議的處理順序

| 優先 | 項目 | 風險 | 效益 |
|---|---|---|---|
| 1 | 發現 4：Service port 命名 | 極低 | 立即；消除協定判定的不確定性（見發現 4 說明） |
| 2 | 發現 6：加 `preStop` | 極低 | 消除部署期間的零星 502／503 |
| 3 | 發現 5：加 PDB + `maxUnavailable: 0` | 低 | 避免維護時全面停機 |
| 4 | 發現 1：獨立 ServiceAccount | 低（需重啟） | **所有授權工作的前提** |
| 5 | 發現 2：consistentHash（短期） | 低 | 減少偶發登出 |
| 6 | 發現 3：加 `mesh` | **中**（要先驗證 match 完整性） | canary 的前提 |
| 7 | 發現 2：session 外部化（根本解） | 高（要改 code） | 解決 canary、擴縮容、重啟三個問題 |

### 參考來源

- istio.io — security 概念：https://istio.io/latest/docs/concepts/security/
- kubernetes.io — virtual-ips：https://kubernetes.io/docs/reference/networking/virtual-ips/
- istio.io — traffic-management 概念：https://istio.io/latest/docs/concepts/traffic-management/
- istio.io — destination-rule：https://istio.io/latest/docs/reference/config/networking/destination-rule/
- istio.io — virtual-service：https://istio.io/latest/docs/reference/config/networking/virtual-service/
- istio.io — protocol-selection：https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/
- envoyproxy.io — substitution_formatter：https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter
- kubernetes.io — Deployment：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- kubernetes.io — disruptions：https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- kubernetes.io — pod-lifecycle：https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/

---

---

## Part 10：istio-ingressgateway 與一般 Service 的差別（含雙 VIP 架構）

### 10.1 這是在解決什麼問題

先破除一個常見誤解：

> **`istio-ingressgateway` 本身就是一個 Service + 一個 Deployment，它不是「另一種資源類型」。**

你去看它的定義會發現，它就是：

```bash
kubectl get deploy,svc -n istio-system -l istio=ingressgateway
# deployment.apps/istio-ingressgateway   2/2
# service/istio-ingressgateway           LoadBalancer   10.20.30.40   15021:30721/TCP,80:31380/TCP,443:31390/TCP
#
# （示意輸出：nodePort 是叢集隨機分配的，你的數字會不一樣。
#   現行 Istio 預設的 Service 開 15021（狀態埠）、80、443 三個 port；
#   舊版 chart 才會把 80／443 固定成 31380／31390，且沒有 15021。）
```

一個 `type: LoadBalancer` 的 Service，加上背後幾個 Pod。**跟你的 `pmc-epmmformquerygui-svc` 結構上完全一樣。**

那差別在哪？差在三件事：

1. **背後的 Pod 跑的是 Envoy，不是你的業務程式**——它不處理業務邏輯，只轉發
2. **它的轉發規則不是來自 Service 的 selector，而是來自 Gateway + VirtualService 這兩個 CRD**
3. **它是「共用」的**——一個 VIP 後面可以掛幾十個服務，靠 Host header 和 path 分流

所以真正的問題不是「它跟 Service 有什麼不同」，而是：**「我該給每個服務各開一個 LoadBalancer VIP，還是共用一個入口？」**

### 10.2 三種對外方式的對照

| | **每個 app 一個 LoadBalancer Service** | **K8s Ingress** | **istio-ingressgateway** |
|---|---|---|---|
| 需要幾個 VIP | **每個服務一個**（VIP 是稀缺資源） | 共用一個 | 共用一個 |
| 工作層級 | L4（TCP/UDP） | L7（HTTP） | **L7 + L4 都可以** |
| 路由依據 | Service 的 `selector` | host + path | **host + path + header + method + query + 權重** |
| TLS 終止 | 在 LB 或你的 app | 在 Ingress controller | 在 gateway（Gateway CRD 定義） |
| 憑證放哪 | LB 設備 / app | Ingress 的 secret | Gateway 的 `credentialName` |
| 能做百分比分流嗎 | 不行（只能靠 Pod 數量硬湊） | 部分 controller 支援 | **可以**（VirtualService `weight`） |
| 能依 header 路由嗎 | 不行 | 大多不行 | **可以** |
| 逾時 / 重試 / 熔斷 | 不行 | 有限（annotation） | **可以** |
| 到後端是否加密 | 看 app 自己 | 通常明文 | **自動 mTLS** |
| 可觀測性 | 只有 LB 的統計 | controller 的 log | **完整 L7 metrics + trace** |
| 設定方式 | Service YAML | Ingress + annotation | **Gateway + VirtualService CRD** |

**一句話**：LoadBalancer Service 是「每個服務各自開一個門」，ingressgateway 是「**開一個大門，門內用規則分流**」。企業內網 VIP 通常要跟網路組申請、數量有限，這是很多公司選 ingressgateway 的現實原因。

### 10.3 封包走法對照

```
【方式 A】每個 app 各自一個 LoadBalancer Service

  Client ──▶ VIP-1 (10.20.30.41) ──▶ node ──[kube-proxy DNAT]──▶ pmc-query Pod
  Client ──▶ VIP-2 (10.20.30.42) ──▶ node ──[kube-proxy DNAT]──▶ pmc-edit  Pod
  Client ──▶ VIP-3 (10.20.30.43) ──▶ node ──[kube-proxy DNAT]──▶ pmc-render Pod
                  ↑
          三個服務 = 三個 VIP，而且完全沒有 L7 能力


【方式 B】共用 istio-ingressgateway

  Client ──▶ VIP (10.20.30.40) ──▶ node ──▶ ingressgateway Pod (Envoy)
                                                    │
                                    ┌───────────────┼───────────────┐
                        Gateway 決定：port/host/TLS 收不收
                        VirtualService 決定：path 送去哪、切幾成
                                    │               │               │
                          /gui_epmmFormQuery  /gui_epmmFormEdit  /gui_epmmFormRender
                                    ▼               ▼               ▼
                              pmc-query Pod    pmc-edit Pod   pmc-render Pod
                                    ↑
                    一個 VIP，而且沿路都有 L7 能力（分流/重試/metrics）
```

你目前的 `app-routing` VirtualService 就是方式 B——三個 GUI 服務共用 `myapp.example.com` 這一個入口，靠 path prefix 分流。

### 10.4 雙 VIP 架構：routable 與 non-routable

#### 兩個網段代表什麼

| 網段 | RFC | 企業裡的典型意義 |
|---|---|---|
| `10.0.0.0/8` | RFC 1918（私有位址） | **公司內網可路由**——其他機房、其他系統、使用者的 PC 都連得到 |
| `100.64.0.0/10` | RFC 6598（Shared Address Space，原本給 CGNAT 用） | **不可路由**——通常只在這座 cluster 或這個機房內有效，公司骨幹網路不會轉發 |

> **為什麼企業愛用 `100.64.0.0/10` 當內部網段**：它不是 RFC 1918，所以**不會跟公司既有的 10.x / 172.16.x / 192.168.x 網段撞號**。（RFC 6598 第 4 節也警告：不是 CGN 用途的使用者「are likely to experience problems」，所以挪作他用前要先確認不會跟 ISP／上游的 CGN 位址衝突。）
>
> **要注意**：`100.64.0.0/10` 是否「不可路由」是**公司網路政策決定的，不是協定規定的**。務必跟網路組確認你們的實際規則。

#### 為什麼要分兩個 VIP

這是**入口分層**：不是所有服務都該讓全公司連得到。

| | **routable VIP（10.x）** | **non-routable VIP（100.x）** |
|---|---|---|
| 誰連得到 | 公司內網任何地方 | 只有本 cluster / 本機房 |
| 適合放什麼 | 給真人使用者用的 GUI、要給其他部門呼叫的 API | 內部服務之間、跨 cluster 的東西向流量、管理介面 |
| 安全要求 | **高**——一定要 IP 白名單 + 認證 | 中——網路層已經是一道防線 |
| VIP 取得難度 | 通常要申請、數量有限 | 較容易 |

#### 做法：兩組獨立的 ingressgateway

**關鍵觀念：一組 ingressgateway = 一個 Deployment + 一個 Service + 一組專屬 label。** 要兩個 VIP，就裝兩組。

```yaml
# ===== 第一組：對外（routable，10.x）=====
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway              # 標準安裝的那一組
  namespace: istio-system
  annotations:
    # ⚠ 指定 VIP 的方式「依你們的 LB 實作而異」，見下方說明
    # MetalLB 0.14.9 起新前綴是 metallb.io；舊的 metallb.universe.tf 已 deprecated
    metallb.io/address-pool: corp-routable
spec:
  type: LoadBalancer
  selector:
    istio: ingressgateway                 # 選中第一組的 Pod
  loadBalancerSourceRanges:               # LB 層白名單（比 Istio 更前面）；是否生效取決於 LB 實作（F5 CIS／MetalLB），不支援時會被靜默忽略
    - 10.0.0.0/8
  ports:
    - name: http2
      port: 80
      targetPort: 8080
    - name: https
      port: 443
      targetPort: 8443
---
# ===== 第二組：對內（non-routable，100.x）=====
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway-internal
  namespace: istio-system             # 為了簡化沿用 istio-system；官方建議 gateway 跟 control plane 分開 namespace，見下方「踩雷 2」
  annotations:
    metallb.io/address-pool: internal-nonroutable
spec:
  type: LoadBalancer
  selector:
    istio: ingressgateway-internal        # ⚠ 不同的 label，選中第二組的 Pod
  ports:
    - name: http2
      port: 80
      targetPort: 8080
    - name: https
      port: 443
      targetPort: 8443
```

第二組的 Deployment（用 `istio/gateway` helm chart 裝最省事，這裡列出關鍵欄位讓你看清楚差別）：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway-internal
  namespace: istio-system             # 同上：建議改放獨立 namespace（例如 istio-ingress），見「踩雷 2」
spec:
  selector:
    matchLabels:
      istio: ingressgateway-internal
  template:
    metadata:
      labels:
        istio: ingressgateway-internal    # ⚠ 這個 label 就是 Gateway CRD 要 selector 的目標
        sidecar.istio.io/inject: "true"   # 官方 gateway 範例的註解是「Enable gateway injection.」。設成 "false" 就不注入，下面 image: auto 不會被換成真的 image，Pod 拉不到 image
      annotations:
        inject.istio.io/templates: gateway
    spec:
      # 見 Part 13：gateway 通常要排到特定網段的 node。這一組是對內（non-routable，100.x）的，
      # 所以要排到 non-routable 那群 node —— 不是照抄 13.4 那個 routable 的範例。
      # ⚠ label／taint 的 key、value 都是環境特定的 placeholder（key 沿用 Part 13 的 network，
      #   value non-routable 是這裡假設的），用 13.5 的指令查你們 cluster 裡 non-routable node 實際掛的是什麼。
      #   如果 non-routable node 根本沒有 label（只是一般 node），nodeSelector 也要整段拿掉，
      #   否則沒有任何 node 符合、Pod 永遠 Pending；不寫 toleration 時，routable node 的 taint
      #   本來就會把這組擋在外面（13.2 表格右下那格）
      nodeSelector:
        network: non-routable
      tolerations:                        # 只有 non-routable node 也打了 taint 時才需要；沒有 taint 就整段拿掉
        - key: "network"
          operator: "Equal"
          value: "non-routable"
          effect: "NoSchedule"
      containers:
        - name: istio-proxy
          image: auto                     # istiod 的 injection webhook 會自動填入正確 image
```

#### Gateway 用 `selector` 決定綁到哪一組（整個機制的關鍵）

```yaml
# 對外服務：綁 routable 那組
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway                 # ← 綁第一組（10.x VIP）
  servers:
    - port: { number: 443, name: https, protocol: HTTPS }
      tls: { mode: SIMPLE, credentialName: myapp-tls-cert }
      hosts: ["myapp.example.com"]
---
# 內部服務：綁 non-routable 那組
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: internal-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway-internal        # ← 綁第二組（100.x VIP）
  servers:
    - port: { number: 443, name: https, protocol: HTTPS }
      tls: { mode: SIMPLE, credentialName: internal-tls-cert }
      hosts: ["internal-api.example.com"]
```

然後 VirtualService 用 `gateways` 指定綁哪一個 Gateway：

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app-routing
  namespace: ea-pmc
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  gateways:
    - istio-system/my-gateway             # 只從 routable 那個入口進來
    - mesh                                # 加上內部流量（見 Part 9 發現 3）
  http:
    - match:
        - uri: { prefix: /gui_epmmFormQuery/ }
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            port: { number: 8080 }
```

#### 完整的綁定鏈

```
  Service (VIP)              Pod label                 Gateway.selector          VirtualService.gateways
  ─────────────────────────  ────────────────────────  ────────────────────────  ───────────────────────
  istio-ingressgateway   ──▶ istio: ingressgateway  ◀── my-gateway            ◀── istio-system/my-gateway
  (10.20.30.40 routable)

  istio-ingressgateway-      istio:                    internal-gateway          istio-system/
  internal               ──▶ ingressgateway-internal◀──                       ◀── internal-gateway
  (100.64.5.10 內部)
```

**要換入口，改的是 VirtualService，不只 `gateways` 那一行：`hosts` 也要對得上新 Gateway 的 hosts。** Istio 官方的 Gateway 參考說「A VirtualService must be bound to the gateway and must have one or more hosts that match the hosts specified in a server.」——上面的 `app-routing` 若只把 `gateways` 改成 `istio-system/internal-gateway`，`hosts` 裡沒有 `internal-api.example.com`，請求進得了 internal 那組 gateway 卻對不到任何路由，回 404（access log 的 response flag 是 `NR`）。服務本身（Deployment／Service）完全不用動。

#### VIP 怎麼指定：這一段必須跟網路組確認

指定「這個 Service 要拿哪個 VIP」的語法**完全取決於你們用哪套 LoadBalancer 實作**，沒有通用答案。三種常見寫法：

```yaml
# 寫法 1：直接指定 IP（最直觀，但 K8s 1.24 起 spec.loadBalancerIP 已標記為 deprecated，
#         很多 LB 實作仍支援，也有不少改用 annotation）
spec:
  type: LoadBalancer
  loadBalancerIP: 10.20.30.40
---
# 寫法 2：MetalLB 的 address pool
metadata:
  annotations:
    metallb.io/address-pool: corp-routable    # MetalLB 0.14.9 起新前綴是 metallb.io；舊的 metallb.universe.tf 已 deprecated
---
# 寫法 3：F5 Container Ingress Services（企業內網常見）
metadata:
  annotations:
    cis.f5.com/ipamLabel: routable        # IPAM label 對應到 F5 上設定好的位址池
```

**怎麼查你們現在用哪一種：**

```bash
# 看現有的 ingressgateway Service 上有什麼 annotation，照抄那個模式最保險
kubectl get svc -n istio-system istio-ingressgateway -o yaml | sed -n '/annotations/,/^spec/p'

# 看實際拿到的 external IP 落在哪個網段
kubectl get svc -n istio-system -o wide

# 看 cluster 裡有沒有 MetalLB / F5 CIS
kubectl get pods -A | grep -Ei "metallb|f5|cis|ipam"
```

> **建議**：不要自己猜。先跑上面第一條指令，看現有的那組怎麼寫，新的那組照同樣格式寫，再跟網路組確認位址池名稱。

### 10.5 兩個 VIP 的安全設定不一樣

routable 那組暴露在整個公司網路，防護要更嚴：

```yaml
# routable gateway：IP 白名單（Part 2.2 的 remoteIpBlocks）
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: routable-gw-allowlist
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway               # ⚠ 只保護 routable 那組
  action: ALLOW
  rules:
    - from:
        - source:
            remoteIpBlocks:               # 真實 client IP，需先設 numTrustedProxies
              - "10.100.0.0/16"           # 只有這幾個部門網段能進
              - "10.200.0.0/16"
---
# non-routable gateway：網路層已經隔離，但仍要擋掉明顯不該來的
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: internal-gw-baseline
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway-internal
  action: DENY
  rules:
    - to:
        - operation:
            # 管理端點不對外，即使是內部入口。
            # 本專案的 actuator 在 /gui_epmmFormQuery/actuator/...（前面有 context path），
            # 寫成 "/actuator/*" 是前綴比對，只打得中 /actuator 開頭的路徑 —— 這條 DENY
            # 會完全沒作用，而且不會有任何錯誤訊息。
            # {*} 比對單一路徑段（不跨 /），{**} 比對零或多段、而且必須是最後一個 operator。
            # 用 path template 時，同一段裡不能再有 * 或其他字元。
            # path template 從哪一版 Istio 開始支援，官方頁沒寫，舊版叢集要先自己確認。
            paths:
              - "/{*}/actuator/{**}"      # /<context-path>/actuator/...
              - "/actuator/{**}"          # 沒有 context path 的服務
```

**兩組的 `numTrustedProxies` 可能不一樣**——routable 那組前面有 F5（1 層），內部那組可能直連（0 層）。這個值設錯會導致 `remoteIpBlocks` 比對到錯的 IP（Part 1 關鍵觀念二）。

### 10.6 踩雷

#### 踩雷 1：Gateway 的 selector 綁到兩組（最嚴重）

如果第二組 gateway 的 Pod **也帶了 `istio: ingressgateway` 這個 label**（例如複製既有 manifest 時忘了改），那麼：

```yaml
spec:
  selector:
    istio: ingressgateway     # 同時命中兩組 Pod！
```

這條 Gateway 會**同時下發到兩組 gateway**，結果就是：**本來只想給內部用的服務，意外出現在 routable VIP 上**。而且這不會有任何錯誤訊息。

**驗證方式（部署新 gateway 後一定要跑）：**

```bash
# 1. 確認兩組 Pod 的 label 是分開的
kubectl get pods -n istio-system -L istio | grep -i gateway

# 2. 確認某個 Gateway 實際下發到哪些 Pod
#    listener 綁在 Pod 的 targetPort，不是 Service 的 port：標準安裝的 ingress gateway
#    Service 是 443 → 8443（80 → 8080），所以 listener 叫 0.0.0.0_8443，
#    用 --port 443 可能什麼都篩不出來。不確定 targetPort 時就不加 --port，直接 grep host。
istioctl proxy-config listener deploy/istio-ingressgateway -n istio-system --port 8443
istioctl proxy-config listener deploy/istio-ingressgateway-internal -n istio-system --port 8443
# 內部服務的 host 不該出現在第一條的輸出裡

# 3. 最直接的驗證：從公司網路 curl routable VIP，確認內部服務打不到
curl -sS -o /dev/null -w "%{http_code}\n" \
  --resolve internal-api.example.com:443:10.20.30.40 \
  https://internal-api.example.com/
# 000 或 404 都算正常，只有 200 才代表內部服務漏到 routable VIP 上：
#   000 —— HTTPS 的 SNI 對不到任何 filter chain，TLS 握手就失敗（curl exit 35），
#          根本沒有 HTTP 回應，-w 印出來就是 000。這是最常見的「正常」結果。
#   404 —— TLS 過了（例如有萬用憑證）但沒有 route 符合這個 host。
# 兩種在 gateway 的 access log 裡都記成 NR（no route／no matching filter chain）。
```

#### 踩雷 2：憑證放在錯的 namespace

`credentialName` 指向的 secret 必須在 **gateway Pod 所在的 namespace**（通常 `istio-system`）。兩組 gateway 如果在同一個 namespace，兩份憑證都放那裡；如果你把第二組裝到別的 namespace，憑證也要跟著搬。

> **gateway 該放哪個 namespace**：Istio 官方建議「As a security best practice, it is recommended to deploy the gateway in a different namespace from the control plane」，也就是把 gateway 放到獨立的 namespace，例如官方 Helm 範例的 `istio-ingress`。上面第二組的 manifest 為了簡化仍寫 `istio-system`；改放別處時，Service、Deployment、相關指令的 namespace 與上面說的憑證要一起搬。

#### 踩雷 3：只改了 Service 沒改 Deployment 的 label

新增第二組時，Service 的 `selector`、Deployment 的 `matchLabels`、Pod template 的 `labels`、Gateway 的 `selector` **四個地方都要對上**。少改一個就會出現「Service 有 VIP 但沒有 endpoint」或「Gateway 設定沒生效」。

```bash
# 一次檢查四者是否對齊
kubectl get svc -n istio-system istio-ingressgateway-internal -o jsonpath='{.spec.selector}{"\n"}'
# 看 Service 實際選到哪些 Pod：用 EndpointSlice（Endpoints API 自 v1.33 起 deprecated）
kubectl get endpointslices -n istio-system -l kubernetes.io/service-name=istio-ingressgateway-internal
```

#### 踩雷 4：gateway Pod 排不到對的 node

routable VIP 通常要求 gateway Pod 跑在特定網段的 node 上。這就是 `nodeSelector` / `tolerations` 的用途——見 **Part 13**。

> **延伸閱讀**：入口鏈的完整逐跳說明見 [Part 1](#part-1流量入口鏈-vip-到-pod)；gateway Pod 的 node 排程見 [Part 13](#part-13node-排程與-routable-網段)。

### 參考來源

- istio.io — IST0162（ingress gateway 的預設 port）：https://istio.io/latest/docs/reference/config/analysis/ist0162/
- rfc-editor.org — RFC 6598（Shared Address Space）：https://www.rfc-editor.org/rfc/rfc6598
- metallb.io — release notes（annotation prefix）：https://metallb.io/release-notes/
- kubernetes.io — Service API（loadBalancerSourceRanges）：https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/
- istio.io — 安裝 gateway：https://istio.io/latest/docs/setup/additional-setup/gateway/
- istio.io — Gateway：https://istio.io/latest/docs/reference/config/networking/gateway/
- istio.io — AuthorizationPolicy：https://istio.io/latest/docs/reference/config/security/authorization-policy/
- envoyproxy.io — substitution_formatter（response flags）：https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter
- kubernetes.io — Service（Endpoints deprecated）：https://kubernetes.io/docs/concepts/services-networking/service/

---

## Part 11：FZ1 與 FZ2 雙 cluster 的入口設計（DNS record 放哪）

### 11.1 這是在解決什麼問題

當公司的 CD 工具幫你建 istio ingressgateway，跳出「**DNS record 要建在 FZ1 嗎？**」這個問題時，它表面上在問 DNS，實際上是在替你決定一個架構問題：

> **這個服務要「單一入口」還是「兩座 cluster 都能收流量」？**

這個選擇會連動四件事：**故障域、憑證份數、設定同步成本、以及 session 會不會斷**。按下確認之前，先搞清楚你選的是哪一種。

### 11.2 模式 A：單一 DNS 指向 FZ1

這是 CD 預設會做的事——`myapp.example.com` 這筆 A record 只指向 FZ1 的 VIP。

```
                    DNS: myapp.example.com ──▶ 10.20.30.40（只有 FZ1 的 VIP）
                                                     │
                    ┌────────────────────────────────┘
                    ▼
        ┌───────────────────────────┐         ┌───────────────────────────┐
        │  FZ1                      │         │  FZ2                      │
        │  ┌─────────────────────┐  │         │                           │
        │  │ istio-ingressgateway│  │         │  （沒有對外入口，         │
        │  └──────────┬──────────┘  │         │    或有 VIP 但沒有        │
        │             │             │         │    DNS 指向它）           │
        │      ┌──────▼──────┐      │         │  ┌─────────────────────┐  │
        │      │ ea-pmc pods │      │         │  │ ea-pmc pods         │  │
        │      └─────────────┘      │         │  │ （跑著，但收不到     │  │
        │                           │         │  │   外部流量）        │  │
        └───────────────────────────┘         │  └─────────────────────┘  │
                                              └───────────────────────────┘
```

**那 FZ2 的服務怎麼被打到？** 只有兩種可能：

1. **FZ1 轉發過去**——你在 FZ1 的 VirtualService 裡把某些 path 導向 FZ2 的位址。這**就退化成 Part 5 的跨 cluster 情境**，而且會完整繼承那裡講的所有問題：身分在 gateway 斷掉、`principals` 失效、要改用 JWT
2. **FZ2 根本沒有對外入口**——它只跑內部批次、或當純 DR 待命

**後果：**

| 面向 | 影響 |
|---|---|
| 故障域 | **FZ1 是單點**。FZ1 的 ingressgateway 掛了，即使 FZ2 的 Pod 全都健康，使用者一樣連不進來 |
| 延遲 | 若流量需要轉到 FZ2，多一次跨機房往返 |
| 身分 | 轉到 FZ2 的流量，身分鏈在 FZ1 的 gateway 就斷了（Part 5） |
| 憑證 | 只需要一份，放在 FZ1 的 `istio-system` |
| 設定同步 | **簡單**——Gateway / VirtualService 只有 FZ1 要維護 |
| session | 沒有**跨 cluster** 的 session 問題（流量不會在兩座 cluster 間跳）；FZ1 內跨 pod 的問題仍在（見表下說明） |

> **「沒有跨 cluster 的 session 問題」不等於「session 沒問題」。** FZ1 內的 stable 本身就有 2 個 replica（`canary-manual/CANARY-COMPLETE.md` 3.6 的 `replicas: 2`），pilot 期間再加上 canary pod；而 `HttpSession`、in-flight 的 OAuth2 `state`、authorized-client token 全部在 pod 記憶體裡（同一份文件 3.7），請求跳到另一個 pod 一樣會被登出。把使用者黏在同一個 pod 上靠的是 DestinationRule 的 `consistentHash`（目標設定的 cookie 是 `epmm-affinity`，同一份文件 3.3），而那只是**軟性黏著**——pod 重啟或滾動更新時，黏著的那個 pod 不在了，session 照樣會掉。

**什麼時候模式 A 是正確選擇：**

- FZ2 是**災難備援（DR）**，平時不收流量
- FZ2 只跑**內部批次 / 資料同步**，沒有對外服務
- 服務本身可用性要求不高，能接受 FZ1 維護時的停機視窗
- **你的 app 還在用 in-memory session**——模式 A 至少不會再多一層跨 cluster 的跳轉（見 11.5）；FZ1 內跨 pod 的登出風險仍在，見上方表下說明

### 11.3 模式 B：兩座 cluster 各自建 ingressgateway

兩邊各有自己的 VIP，前面靠 GSLB 或 F5 的健康檢查決定把使用者導向哪一邊。

```
              DNS: myapp.example.com
                       │
              ┌────────▼─────────┐
              │  GSLB / F5       │  ← 對兩個 VIP 做健康檢查，
              │  健康檢查 + 導流  │    哪邊活著就回哪邊的 IP
              └───┬──────────┬───┘
                  │          │
        10.20.30.40          10.20.31.40
                  │          │
        ┌─────────▼───┐  ┌───▼─────────┐
        │  FZ1        │  │  FZ2        │
        │ ingressgw   │  │ ingressgw   │
        │     │       │  │     │       │
        │  ea-pmc     │  │  ea-pmc     │  ← 兩邊都要部署、都要有
        │  pods       │  │  pods       │    Gateway + VirtualService
        └─────────────┘  └─────────────┘
```

**需要準備什麼（缺一不可）：**

1. **GSLB 或健康檢查型 DNS**——單純的 DNS round-robin **不夠**，因為它不知道某一邊掛了。必須要有主動健康檢查，且要檢查到「真的能提供服務」的深度（打 `/gui_epmmFormQuery/actuator/health`，不是只 ping VIP）——但後端補上 permitAll 之前，這條路徑回 302 而不是 200，在那之前不能拿它當深度檢查（見 11.4「GSLB 的健康檢查要打對地方」）
2. **憑證要放兩份**——同一個 host 的憑證，兩個 cluster 的 `istio-system` 各放一份 secret（可以是同一張憑證的兩份副本）
3. **Gateway + VirtualService 兩邊都要有**——而且內容必須一致，否則會出現「同一個網址，看到的行為不一樣」
4. **image registry 兩邊都拉得到**
5. **ConfigMap / Secret 兩邊都要同步**

**後果：**

| 面向 | 影響 |
|---|---|
| 故障域 | **隔離**。FZ1 整座掛掉，GSLB 判定不健康後把流量切到 FZ2；使用者實際感受到的切換時間 ≈ 健康檢查判定時間 ＋ DNS TTL ＋ 用戶端快取（TTL 設太長時可以拖到一小時，見 11.10 踩雷 4） |
| 延遲 | 沒有跨 cluster hop，使用者打到哪邊就在那邊處理完 |
| 身分 | 沒有跨 cluster 身分問題（各自 cluster 內部完整） |
| 憑證 | **兩份**，且要一起輪替（過期時間要對齊） |
| 設定同步 | **這是主要成本**。兩邊設定漂移是最常見的故障來源，實務上需要 GitOps |
| session | **⚠ 這是最大的坑，見 11.4** |

### 11.4 模式 B 實際要準備的 manifest（哪些一樣、哪些必須不一樣）

「兩邊各自建 ingressgateway」到底要多做什麼？具體就是這幾份：

#### 兩座 cluster 完全相同的部分

```yaml
# ===== FZ1 與 FZ2 內容一字不差：Gateway 兩邊都要 apply；VirtualService 是簡化範例，不要 apply（見下方註解）=====
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
    - port: { number: 443, name: https, protocol: HTTPS }
      tls:
        mode: SIMPLE
        credentialName: myapp-tls-cert     # secret 名稱一樣，但兩邊各自要有一份
      hosts:
        - "myapp.example.com"              # ⚠ 同一個 host，兩邊都收
---
# ⚠ 下面這份 VirtualService 是【簡化範例】，只示意「兩邊相同」的骨架：
#   沒有 subset，也沒有 pilot-run（cookie → canary）規則。
#   它的 namespace／name（ea-pmc/app-routing）跟 track-a 的
#   canary-manual/track-a/base/03-virtualservice.yaml 一樣，照抄 apply 會整份蓋掉那一份：
#   canary 路由消失；而且 destination 沒有 subset 時，Service（selector 只比對 app）
#   背後的 stable 與 canary pod 都會分到正式流量。
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app-routing
  namespace: ea-pmc
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  gateways:
    - istio-system/my-gateway
    - mesh
  http:
    - name: primary
      match:
        - uri: { prefix: /gui_epmmFormQuery/ }
        - uri: { exact: /gui_epmmFormQuery }
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            port: { number: 8080 }
      timeout: 15s
```

**兩座 cluster 上的這兩份必須逐字相同**——Gateway 是上面那份，VirtualService 則是兩邊都 apply track-a 的 `canary-manual/track-a/base/03-virtualservice.yaml`（`pilot-run`、`primary`、`default` 三條規則，destination 都帶 subset），不是上面的簡化版。只要有一邊漏了某條 `match`，使用者就會遇到「同一個網址，重整一次行為就不一樣」——而且極難重現，因為要看 GSLB 那次把你導去哪邊。

> **這就是為什麼模式 B 幾乎一定要搭 GitOps**：同一份 Git 來源產生兩邊的設定，人工 `kubectl apply` 兩次遲早會漂移。

#### 兩座 cluster 必須不一樣的部分

```yaml
# ===== FZ1 =====
# ⚠ 這份只示意「兩邊哪裡不同」，不是可以直接 apply 的完整 Service：
#   安裝工具（istioctl／`istio/gateway` Helm chart）產生的 Service 還有 status-port 15021、
#   http2 等 port；直接 apply 這份可能把那些 port 蓋掉。位址池應透過安裝工具的
#   values（Service annotations）設定，而不是另外 apply 一份 Service。
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
  annotations:
    # 是否用 MetalLB、位址池叫什麼，都屬環境特定（依你們的 LB 實作而異）。
    # MetalLB 0.14.9 起新前綴是 metallb.io；舊的 metallb.universe.tf 已 deprecated
    metallb.io/address-pool: fz1-routable    # ← 不同
spec:
  type: LoadBalancer
  selector: { istio: ingressgateway }
  ports:
    # targetPort 依安裝方式而異：istioctl 安裝的是 8443，`istio/gateway` Helm chart 是 443。
    # 要填 gateway pod 實際在聽的那個 port，照你們實際的安裝方式確認。
    - { name: https, port: 443, targetPort: 8443 }
```

```yaml
# ===== FZ2 =====
# ⚠ 同 FZ1：只示意差異，不是完整 Service，位址池應透過安裝工具的 values 設定。
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
  annotations:
    # 前綴、環境特定的說明同 FZ1
    metallb.io/address-pool: fz2-routable    # ← 不同的位址池 → 不同 VIP
spec:
  type: LoadBalancer
  selector: { istio: ingressgateway }
  ports:
    # targetPort 的說明同 FZ1
    - { name: https, port: 443, targetPort: 8443 }
```

#### 憑證：兩邊各一份

```bash
# 同一張憑證，建到兩座 cluster 的 istio-system
for CTX in fz1 fz2; do
  kubectl --context=$CTX -n istio-system create secret tls myapp-tls-cert \
    --cert=myapp.crt --key=myapp.key --dry-run=client -o yaml | \
    kubectl --context=$CTX apply -f -
done

# 輪替時兩邊都要更新，而且要確認到期日一致
for CTX in fz1 fz2; do
  echo "=== $CTX ==="
  kubectl --context=$CTX -n istio-system get secret myapp-tls-cert \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
done
```

**這段腳本建議直接排進行事曆或 CI**——憑證只在其中一邊更新，是模式 B 最常見的故障原因之一，而且症狀是「一半的使用者說網站憑證過期」，非常難聯想。

#### GSLB 的健康檢查要打對地方

```
❌ 只檢查 VIP 通不通（ping 或 TCP 443）
   → ingressgateway 活著但後端 Pod 全掛，GSLB 仍然把流量導過去

✅ 檢查到「真的能提供服務」的深度
   → GET https://<VIP>/gui_epmmFormQuery/actuator/health
      SNI:  myapp.example.com          ← 必須帶 SNI，否則 TLS 握手就失敗，走不到 Host 比對
      Host: myapp.example.com          ← 握手成功之後，Host 不符 Gateway 的 hosts 才會回 404
      期望：200（⚠ 後端補上 permitAll 之前實際回 302，見下方說明）
```

> **⚠ 這條路徑目前回 302，不是 200。** 後端 `SecurityConfig` 的 permitAll 清單裡只有**沒有前綴**的 `/actuator/health`、`/actuator/health/**`，但 ConfigMap 的 `management.endpoints.web.base-path` 把 actuator 搬到了 `/gui_epmmFormQuery/actuator`，前綴路徑落在 `anyRequest().authenticated()` → 回 302（`canary-manual/CANARY-COMPLETE.md` 3.6）。所以 GSLB 若期望 200，兩邊都會被判定不健康；若 GSLB 把 3xx 也算成功，就成了不管後端死活都亮綠燈的假檢查。**在後端補上前綴路徑的 permitAll（Spring 後端那一側的修正，PRD 階段 1）之前，不要拿這條路徑當 GSLB 的深度檢查。**

> **⚠ SNI 和 Host header 都很容易漏掉。** 你的 Gateway 是 HTTPS 而且設了 `hosts: ["myapp.example.com"]`，官方說明這種 Gateway 會對進來的請求做 SNI 比對（「An HTTPS Gateway that specifies the hosts field will perform an SNI match on incoming requests.」）。GSLB 直接對 `https://<VIP>` 發健康檢查時，用 IP 連線不會送出 SNI（「…no SNI will be set, causing the request to fail.」），請求會先在 TLS 握手就失敗，根本走不到 Host 比對；Host 不符回 404 這一點，只在 TLS 握手成功之後才成立。所以健康檢查要**同時**設 SNI＝`myapp.example.com` 和 Host header，否則 GSLB 會以為這邊掛了——結果兩邊都被判定不健康。手動驗證時可以用 curl 的 `--resolve` 讓 SNI 與 Host 都帶上主機名，同時連到指定的 VIP：
>
> ```bash
> curl -sS -o /dev/null -w '%{http_code}\n' \
>   --resolve myapp.example.com:443:<VIP> \
>   https://myapp.example.com/gui_epmmFormQuery/actuator/health
> ```

### 11.5 session 的致命細節（直接關係到你的架構）

**Part 9 發現 2 提過：你的 Spring Boot 用 in-memory `HttpSession`。在模式 B 之下這會直接爆炸。**

原因：GSLB 是 **DNS 層級**的導流，它的粒度是「一次 DNS 查詢」，不是「一個使用者的一整段連線」。實務上會發生：

- 使用者的 DNS 快取過期 → 重新查詢 → GSLB 這次回 FZ2 的 IP → **使用者的 session 在 FZ1，FZ2 不認得他 → 被要求重新認證**。Keycloak 的 SSO session 還在時，這是不用輸入帳密的重新認證，但正在送出的表單或 POST 會遺失；登入流程進行到一半就被切到另一邊，還會出現 `authorization_request_not_found`。只有 SSO session 也過期時，才真的看到登入頁
- 使用者換網路（有線換 Wi-Fi、VPN 重連）→ 重新解析 → 可能落到另一邊
- 使用者換用不同的瀏覽器或不同的裝置 → 各自解析、各有各的 DNS 快取 → 有機會分散到兩邊

**四種處理方式：**

| 方式 | 做法 | 評價 |
|---|---|---|
| GSLB source-IP affinity | 讓 GSLB 記住「這個來源 IP 上次給了哪邊」 | **脆弱**。使用者換網路就失效；公司 NAT 後大量使用者共用同一個出口 IP，反而會全部擠到同一邊 |
| 兩邊 session 互相複寫 | Redis 跨 cluster replication | 跨機房延遲高，且複寫延遲期間仍可能讀不到 |
| GSLB／LB 前端的 cookie persistence | 前面若是 L7 的 F5 LTM（在 F5 終結 TLS、兩個 VIP 都是 pool member），用 HTTP cookie 把使用者黏在同一個 cluster（F5 文件：「Cookie persistence directs session requests to the same server based on HTTP cookies…」） | 比 source-IP 可靠；**但需要在 F5 終結 TLS**才讀得到 cookie |
| **session 外部化 + 固定一邊** | Spring Session + Redis，Redis 只放一邊（或用主從） | **實務上最可行**。但要接受「Redis 那邊掛了兩座 cluster 都受影響」 |

> **結論**：**在解決 session 之前，不要開 active-active。** 你會用「偶爾被登出」換到「故障時自動切換」，而前者天天發生、後者一年一次。
>
> 順序應該是：先做 session 外部化（Part 9 發現 2 的根本解）→ 再開模式 B。

### 11.6 兩種模式對照表

| 面向 | **模式 A：單一 DNS 指 FZ1** | **模式 B：兩邊各自入口 + GSLB** |
|---|---|---|
| VIP 數量 | 1 | 2 |
| DNS 設定 | 一筆 A record | GSLB 或健康檢查型 DNS |
| FZ1 整座掛掉 | **服務中斷**，要人工改 DNS | 自動切到 FZ2（秒~分鐘級，看 TTL 與檢查間隔） |
| FZ1 的 gateway 掛掉 | **服務中斷** | 自動切換 |
| 正常時的延遲 | 若需轉發到 FZ2 則多一跳 | 無額外跳數 |
| 憑證 | 1 份 | **2 份，要一起輪替** |
| Gateway / VirtualService | 只有 FZ1 | **兩邊都要，且必須一致** |
| 設定漂移風險 | 低 | **高**（主要維運成本） |
| 需要 GitOps | 不一定 | **幾乎必要** |
| in-memory session | 沒有跨 cluster 的問題（FZ1 內跨 pod 仍只靠 DestinationRule 軟性黏著，見 11.2） | **會被登出** |
| 跨 cluster 身分問題 | 轉發時會遇到（Part 5） | 不會 |
| 適合 | FZ2 是 DR / 只跑批次 | 真正需要高可用，且 session 已外部化 |

### 11.7 怎麼選

| 你的情況 | 選 |
|---|---|
| FZ2 是 DR，平時不收流量 | **模式 A**，接受 CD 預設把 DNS 建在 FZ1 |
| FZ2 只跑內部批次 / 資料同步 | **模式 A** |
| 還在用 in-memory session | **模式 A**（先解 session 再談；模式 A 只是沒有跨 cluster 的跳轉，FZ1 內跨 pod 的登出風險見 11.2） |
| 服務可以接受幾十分鐘的停機視窗 | **模式 A** |
| 有明確的 SLA 要求（例如 99.9% 以上） | **模式 B**，但要先備齊 GitOps 與 session 外部化 |
| 兩座 cluster 分屬不同機房且都有使用者 | **模式 B**（就近服務可省延遲） |

> **給你的具體建議**：以目前的狀態（in-memory session、沒有 PDB/HPA、設定還是手動 apply），**先選模式 A，讓 CD 把 DNS 建在 FZ1**。這不是妥協，而是因為模式 B 的前置條件你還沒備齊，硬上會得到一個「看起來高可用、實際上天天有人被登出」的系統。

### 11.8 按確認之前，要跟 CD 團隊問清楚的四件事

CD 工具實際做了什麼，決定了後續你要自己補什麼。**這四題我無法從你的環境推斷，必須問人：**

1. **它是裝一組全新的 ingressgateway，還是共用既有的那組？**
   - 裝新的 → 要確認新 Pod 的 label 跟既有那組**不同**（否則會踩到 Part 10.6 踩雷 1）
   - 共用既有 → 你的 Gateway `selector` 要對到既有的 label
2. **VIP 是從哪個位址池分配的？是 routable（10.x）還是 non-routable（100.x）？**
   - 這決定誰連得到，也決定要不要做 IP 白名單
3. **它會不會一起建 Gateway 和 VirtualService，還是只建 gateway 基礎設施？**
   - 只建基礎設施的話，Gateway / VirtualService 要你自己寫
4. **憑證由誰管？CD 會自動放 secret 嗎？輪替時會自動更新嗎？**
   - 這是模式 B 最容易漏掉的維運項目

### 11.9 如果之後要從模式 A 遷移到模式 B

按這個順序做，每一步都可以獨立驗證、獨立回退：

1. **先解 session 外部化**（Spring Session + Redis），在 FZ1 單邊驗證通過
2. **把設定納入 GitOps**——Gateway / VirtualService / ConfigMap 都從同一份 repo 產生，兩座 cluster 套用同一份來源
3. **FZ2 建 ingressgateway + 申請第二個 VIP**，先**不要**掛進 DNS
4. **用 hosts 檔或 `curl --resolve` 直接測 FZ2 的 VIP**，確認功能完全一致
5. **設定 GSLB，但先把 FZ2 的權重設 0**（或設成 backup），確認健康檢查正確反映兩邊狀態
6. **把 FZ2 權重慢慢調上來**，觀察有沒有 session 問題
7. **做一次真實的 FZ1 停機演練**，確認切換時間符合預期

### 11.10 踩雷

#### 踩雷 1：設定漂移（模式 B 最主要的故障來源）

兩邊的 VirtualService 內容不一致，使用者會遇到「重整一次行為就變了」。**而且這種問題不會有錯誤訊息**，因為兩邊的設定各自都是合法的。

**定期比對兩邊（建議排進 CI）：**

```bash
# Gateway 要寫全名：Gateway API 的 gateway.networking.k8s.io 也有 Gateway，kubectl 分不出來
for R in gateways.networking.istio.io virtualservices.networking.istio.io destinationrules.networking.istio.io authorizationpolicies.security.istio.io; do
  echo "=== $R ==="
  diff \
    <(kubectl --context=fz1 get $R -A -o yaml | grep -v 'resourceVersion\|uid:\|creationTimestamp\|generation:') \
    <(kubectl --context=fz2 get $R -A -o yaml | grep -v 'resourceVersion\|uid:\|creationTimestamp\|generation:') \
    && echo "  一致"
done
```

#### 踩雷 2：憑證只更新了一邊

症狀：**一半的使用者說憑證過期，另一半說正常**——因為 GSLB 把他們導到不同的 cluster。用 11.4 的到期日檢查腳本定期跑。

#### 踩雷 3：GSLB 健康檢查沒帶 Host header

Gateway 的 `hosts` 比對不到就回 404，GSLB 會把健康的 cluster 誤判為掛掉。見 11.4。

#### 踩雷 4：DNS TTL 設太長

模式 B 的自動切換速度上限就是 DNS TTL。實際切換時間 ≈ 健康檢查判定時間 ＋ DNS TTL ＋ 用戶端自己的快取（例如 JVM、瀏覽器），TTL 只是其中一項。TTL 設太長（例如 3600 秒）時，這個時間可以拖到一小時以上——**這樣就失去了做模式 B 的意義**。

TTL 要設多短請依你的 GSLB 與健康檢查間隔決定；實際切換時間要**實測**（含用戶端快取），不能只看設定值。

#### 踩雷 5：以為 active-active 就等於高可用

模式 B 只解決了「**入口層**」的高可用。如果兩座 cluster 共用同一個資料庫，而資料庫掛了，兩邊一起死。做模式 B 之前先想清楚：

| 元件 | 兩邊獨立嗎？ |
|---|---|
| ingressgateway | 是（模式 B 解決的部分） |
| 應用 Pod | 是 |
| 資料庫 | **通常不是** ← 真正的單點往往在這裡 |
| Keycloak | **通常不是** |
| Redis（如果做了 session 外部化） | 要另外設計 |

**先找出真正的單點在哪，再決定要不要投資在入口層的高可用。**

> **延伸閱讀**：跨 cluster 呼叫時的身分斷裂與補救見 [Part 5](#part-5獨立-cluster-互打走對方-vip-與-virtualservice)；session 問題的根源見 [Part 9](#part-9你目前環境的具體發現) 發現 2；DNS 是 active/standby（只回 active zone）時「FZ2 部好了卻 404」見 [Part 16](#part-16active-zone-dns-下-request-落在哪fz2-部好卻-404用-mesh-送到-fz2)。

### 參考來源

- istio.io — 常見網路問題（HTTPS Gateway 的 SNI 比對）：https://istio.io/latest/docs/ops/common-problems/network-issues/
- github.com/istio — gateway chart 的 values.yaml（targetPort）：https://github.com/istio/istio/blob/master/manifests/charts/gateway/values.yaml
- metallb.io — release notes（annotation prefix）：https://metallb.io/release-notes/
- F5 techdocs — Cookie persistence（廠商文件）：https://techdocs.f5.com/kb/en-us/products/big-ip_ltm/manuals/product/big-ip-local-traffic-manager-implementations-14-0-0/12.html
- Alibaba Cloud ASM — Istio Gateway 與 Gateway API Gateway 同名（廠商文件）：https://www.alibabacloud.com/help/en/asm/support/why-are-no-gateways-or-non-istio-gateways-returned-when-i-run-the-kubectl-command-to-query-gateways

---

## Part 12：用 Argo Rollouts 取代人工 pilot run

### 12.1 這是在解決什麼問題

你們現在的流程是：部署新版 → **請使用者 pilot run** → 使用者回報沒問題 → 全量上線。

這個流程的價值很明確：**真人驗證過的東西，大家才敢簽名**。但它有三個成本：

| 成本 | 具體表現 |
|---|---|
| **要等人** | 使用者有自己的工作，回報可能要等半天到隔天 |
| **時間受限** | 非上班時間不能發布，緊急修補只能等到隔天早上 |
| **範圍不一致** | 每次驗證點了哪些功能靠記憶，這次驗了 A 功能、下次驗了 B 功能，沒有紀錄 |

**自動化的目標不是「取消人工驗證」，而是「把人工驗證的內容變成每次都會跑、而且跑得比人更快更完整的程式」。**

這一節分兩部分：先回答你問的「**怎麼指定哪些 request 去 v2**」（這是技術前提），再回答「**怎麼不靠人**」。

### 12.2 先回答：怎麼指定哪些 request 去 v2

Argo Rollouts 搭配 Istio 時，除了 `setWeight`（百分比），還有一個關鍵能力：**`setHeaderRoute`**——依 header 精準指定哪些請求走 canary。

**這就是取代人工 pilot run 的技術前提**：有了它，自動化測試才能「保證打到 v2」。否則你的測試打過去，有 90% 機率落在 v1，測了等於沒測。

#### 完整的 Rollout 骨架

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
spec:
  replicas: 4
  selector:
    matchLabels:
      app: pmc-epmmformquerygui

  template:                              # 跟 Deployment 的 pod template 完全一樣
    metadata:
      labels:
        app: pmc-epmmformquerygui
    spec:
      serviceAccountName: pmc-epmmformquerygui
      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.3.0
          ports: [{ name: http, containerPort: 8080 }]

  strategy:
    canary:
      canaryService: pmc-query-canary    # Argo 自動維護這兩個 Service 的 selector
      stableService: pmc-query-stable
      trafficRouting:
        istio:
          virtualService:
            name: app-routing            # 它會自動改這個 VirtualService
            routes:
              - primary                  # ⚠ VirtualService 裡的 http route 必須有 name: primary
        # 【必要】steps 用了 setHeaderRoute，就必須在這裡宣告它的名字。沒寫 managedRoutes，
        # Rollout 驗證直接失敗（"Rollout has missing field 'spec.strategy.canary.trafficRouting.managedRoutes'"）；
        # 寫了但漏列某個 route，也會失敗（Steps define a route that does not exist，指的就是 managedRoutes 裡沒有這個名字）。
        # 這份骨架的步驟 1 用 canary-test，下面 cookie 版本用 canary-testers，所以兩個都列（canary-testers 只有改用 cookie 版本時才用到）；列的順序就是優先序。
        managedRoutes:
          - name: canary-test
          - name: canary-testers

      steps:
        # ===== 步驟 1：開一條 header 專用路由，正式流量仍 100% 在 v1 =====
        - setCanaryScale:
            replicas: 1                  # 先只開 1 個 canary Pod
        - setHeaderRoute:
            name: canary-test            # 這條 header route 的名字（之後要用同名關閉）
            match:
              - headerName: x-canary
                headerValue:
                  exact: "true"          # 帶這個 header 的請求 → 100% 進 v2

        # ===== 步驟 2：自動化 smoke test（取代人工 pilot run）=====
        - analysis:
            templates:
              - templateName: smoke-test
            args:
              - name: canary-host
                value: myapp.example.com

        # ===== 步驟 3：關掉 header route，開始放真實流量 =====
        - setHeaderRoute:
            name: canary-test            # 同名 + 沒有 match = 移除這條路由
        - setWeight: 5
        - pause: { duration: 5m }

        # ===== 步驟 4：用指標檢查真實流量下的表現 =====
        - analysis:
            templates:
              - templateName: success-rate

        - setWeight: 20
        - pause: { duration: 10m }
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 100
```

> **版本與宣告**：`setHeaderRoute`／`setMirrorRoute` 需要 Argo Rollouts v1.3 以上（release-1.2 的文件沒有這兩個功能，release-1.3 才有）。另外，後面 12.5～12.7 只貼了 `steps:` 片段，它們用到的 route 名稱（`mirror-to-canary`、`mirror`、`canary-test`）一樣都要列進 `trafficRouting.managedRoutes`，否則整個 Rollout 驗證失敗。

#### 三種「指定誰走 v2」的方式

| 方式 | 寫法 | 適合誰 |
|---|---|---|
| **header** | `setHeaderRoute` + `headerName: x-canary` | **自動化測試**（測試程式自己加 header） |
| **cookie** | `setHeaderRoute` 比對 `cookie` header 的 regex | **真人測試者**（種一次 cookie，在 header route 存在的那幾個 step 內都走 v2；見下方說明） |
| **權重** | `setWeight: 5` | **正式流量**的漸進放量 |

**給真人測試者用的 cookie 版本**（如果你們短期內還想保留人工驗證，這個很好用）：

```yaml
        - setHeaderRoute:
            name: canary-testers
            match:
              - headerName: cookie
                headerValue:
                  regex: ".*canary-user=true.*"
```

測試者在瀏覽器 console 執行一次 `document.cookie="canary-user=true;path=/"`，**在 header route 存在的那幾個 step 裡，他的操作都固定走 v2**——Argo 會在 rollout 結束或 abort 時移除 managedRoutes 裡的所有 route（要提早關掉，就像步驟 3 對 `canary-test` 做的那樣，用同名、不帶 match 的 `setHeaderRoute` 關閉它），所以它不是永久黏住。這比你們現在「使用者 pilot run 但不確定他打到哪個 Pod」還要可靠。

> **⚠ 前置條件（Part 9 發現 3）**：你現在的 `app-routing` 沒有 `mesh`，而且 route 沒有 `name`。要用 Argo Rollouts 必須先補：
> ```yaml
> spec:
>   gateways: [istio-system/my-gateway, mesh]
>   http:
>     - name: primary          # ← Argo 靠這個名字找到要改的 route
>       route:
>         - destination: { host: pmc-query-stable, ... }
>           weight: 100
>         - destination: { host: pmc-query-canary, ... }
>           weight: 0
> ```

### 12.3 路線一：Job-based smoke test（沒有 Prometheus 也能做）

**這條路線最直接對應你們現在的人工 pilot run**：把使用者實際會點的流程寫成測試腳本，讓 Argo 每次發布自動跑一次。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: smoke-test
  namespace: ea-pmc
spec:
  args:
    - name: canary-host
  metrics:
    - name: smoke-test
      # 只跑一次，不重複
      count: 1
      # Job 成功（exit 0）= 通過；失敗 = 整個 Rollout 自動 abort 並回滾
      failureLimit: 0
      provider:
        job:
          spec:
            backoffLimit: 0              # 不重試，失敗就是失敗
            activeDeadlineSeconds: 600   # 10 分鐘跑不完就當失敗
            template:
              metadata:
                labels:
                  # Part 6.4 踩雷 2：Job 不要注入 sidecar。Istio 官方已棄用同名 annotation，
                  # 改用 label；放 annotations 在新版可能不被認，sidecar 照注入。
                  sidecar.istio.io/inject: "false"
              spec:
                restartPolicy: Never
                containers:
                  - name: smoke
                    image: curlimages/curl:8.5.0
                    env:
                      - name: HOST
                        value: "{{args.canary-host}}"
                    command: ["/bin/sh", "-c"]
                    args:
                      - |
                        set -e
                        # ⚠ 關鍵：帶 x-canary header，保證打到 v2
                        H="-H x-canary:true -sS -o /dev/null -w %{http_code}"

                        echo "1. 健康檢查"
                        code=$(curl $H https://$HOST/gui_epmmFormQuery/actuator/health)
                        [ "$code" = "200" ] || { echo "health failed: $code"; exit 1; }

                        echo "2. 首頁載得起來"
                        code=$(curl $H https://$HOST/gui_epmmFormQuery/)
                        [ "$code" = "200" ] || { echo "index failed: $code"; exit 1; }

                        echo "3. 未登入時應該被導向 Keycloak"
                        code=$(curl $H https://$HOST/gui_epmmFormQuery/rs/gui/forms)
                        [ "$code" = "302" ] || [ "$code" = "401" ] || \
                          { echo "auth redirect failed: $code"; exit 1; }

                        echo "4. 靜態資源還在"
                        code=$(curl $H https://$HOST/gui_epmmFormQuery/web/main.dart.js)
                        [ "$code" = "200" ] || { echo "static asset failed: $code"; exit 1; }

                        echo "ALL SMOKE TESTS PASSED"
```

#### 怎麼把人工 pilot run 變成這份腳本

**實務上最有效的做法：下次做人工 pilot run 時，請使用者開著瀏覽器的 F12 Network 分頁，把整段操作錄下來。** 那份 HAR 檔就是你的第一版測試清單——它精確記錄了「真人驗證時實際打了哪些 API」。

轉換順序（不要一次做完，分三批）：

| 批次 | 內容 | 難度 |
|---|---|---|
| 第一批 | 健康檢查、首頁、靜態資源、認證導向 | 低，用 curl 就夠 |
| 第二批 | 需要登入的 API（用 Keycloak client credentials 拿 token） | 中 |
| 第三批 | 完整的表單查詢/送出流程 | 高，可能要 Playwright / newman |

第二批之後建議換成更適合的工具：

```yaml
                  - name: smoke
                    image: postman/newman:alpine       # 直接跑 Postman collection
                    args: ["run", "/tests/pmc-query.postman_collection.json",
                           "--env-var", "host=$(HOST)",
                           "--env-var", "canary_header=true"]
```

> **好處**：這份 collection 你們可能已經有了（測試 API 時用的），只要加上 `x-canary` header 就能重用。

### 12.4 路線二：Prometheus 指標分析

如果環境有 Prometheus（Istio 預設會產生這些指標），可以再加一層「真實流量下的表現」檢查。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
  namespace: ea-pmc
spec:
  args:
    # 要量哪個 Service。沒有 default，所以 Rollout 的 analysis step 一定要傳，否則這個 template 跑不起來：
    #   - analysis: { templates: [{ templateName: success-rate }], args: [{ name: service-name, value: pmc-epmmformquerygui-canary }] }
    # 不要寫死 destination_workload="pmc-epmmformquerygui"：Istio 對 Rollout 的 stable 與 canary
    # 兩組 ReplicaSet 回報的是同一個 workload 名，那樣量到的是兩者的合計，不是 canary。
    - name: service-name
  metrics:
    # ===== 指標 1：成功率（內含最低樣本數檢查）=====
    - name: success-rate
      interval: 1m                       # 每分鐘測一次
      count: 5                           # 共測 5 次
      # 成功與失敗各寫一個條件，中間留一段空隙（0.95 ~ 0.99）：
      # 落在空隙、或沒有資料時，結果是 Inconclusive（暫停等人），而不是 Failed。
      # 只寫 successCondition 的話，「不符合」一律算 Failed。
      successCondition: len(result) > 0 && result[0] >= 0.99
      failureCondition: len(result) > 0 && result[0] < 0.95
      failureLimit: 1                    # 允許失敗 1 次；第 2 次失敗就 abort（預設是 0）
      inconclusiveLimit: 2               # 允許 2 次 Inconclusive 量測，再多就把整個指標判 Inconclusive
      provider:
        prometheus:
          address: http://prometheus.istio-system.svc.cluster.local:9090
          # reporter="destination"：只算 server 端 sidecar 回報的那一份。
          # 沒有這條，經過 gateway 的請求會被 gateway 與 server 各報一次，計數變兩倍。
          query: |
            (
              sum(rate(istio_requests_total{
                reporter="destination",
                destination_service_name="{{args.service-name}}",
                destination_service_namespace="ea-pmc",
                response_code!~"5.."
              }[2m]))
              /
              sum(rate(istio_requests_total{
                reporter="destination",
                destination_service_name="{{args.service-name}}",
                destination_service_namespace="ea-pmc"
              }[2m]))
            )
            # 最低樣本數：近 2 分鐘不到 20 個請求就整條回傳空向量（-> len(result) == 0 -> Inconclusive）。
            # 不要另開一個 enough-traffic 指標：failureLimit 預設是 0，樣本不足會讓那個指標 Failed，
            # 而整個 AnalysisRun 取各指標中最糟的結果，Rollout 就 abort 了——跟「不下結論」正好相反。
            and on() (
              sum(increase(istio_requests_total{
                reporter="destination",
                destination_service_name="{{args.service-name}}",
                destination_service_namespace="ea-pmc"
              }[2m])) >= 20
            )

    # ===== 指標 2：P99 延遲 =====
    - name: latency-p99
      interval: 1m
      count: 5
      successCondition: len(result) > 0 && result[0] <= 1000    # 毫秒
      failureCondition: len(result) > 0 && result[0] > 1500     # 1000~1500 ms 之間 = Inconclusive
      failureLimit: 1
      inconclusiveLimit: 2
      provider:
        prometheus:
          address: http://prometheus.istio-system.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(istio_request_duration_milliseconds_bucket{
                reporter="destination",
                destination_service_name="{{args.service-name}}",
                destination_service_namespace="ea-pmc"
              }[2m])) by (le))
```

#### ⚠ 最重要的警告：小流量時指標會騙你

canary 初期只有 5% 流量。如果那段時間總共只進來 3 個請求，其中 1 個是使用者自己按了取消造成的 5xx，**成功率就變成 66%，Rollout 會誤判失敗直接回滾**。

三個防護：

1. **把最低樣本數檢查併進同一條 query**（上面 `success-rate` 裡的 `and on() (... >= 20)`），流量不夠時 query 回傳空結果，落到 Inconclusive，而不是 Failed。為什麼不拆成獨立的 `enough-traffic` 指標，見上面 query 裡的註解
2. **`failureLimit` 不要設 0**——給它一次容錯機會
3. **query 裡的 range（`[2m]`）拉長**（例如 `[5m]`），讓每次取樣涵蓋足夠的請求。`interval` 只決定多久測一次，不決定每次涵蓋多少請求

#### `successCondition` / `failureCondition` 與三種結果

| 結果 | 意義 | Rollout 行為 |
|---|---|---|
| **Successful** | 條件滿足 | 繼續下一個 step |
| **Failed** | 失敗次數超過 `failureLimit` | **自動 abort 並回滾到 stable** |
| **Inconclusive** | 成功與失敗兩個條件都寫了，但量到的值兩邊都不符合 | **暫停等人**（不會自動繼續，也不會回滾） |

「沒有資料」不會自動等於 Inconclusive，要看你怎麼寫條件：

- **只寫 `successCondition`**：條件不符合就是 Failed。例如 `0/0` 得到 NaN，`NaN >= 0.99` 為 false，直接 Failed。
- **query 回傳空陣列**：`result[0]` 取不到值，這次量測算 Error，連續錯誤超過 `consecutiveErrorLimit`（預設 4）整個指標就變 Error。Argo 把 Error 和 Failed 一樣當成 abort。要處理空陣列，條件裡要用 `len(result)`（如上面的 `len(result) > 0 && ...`）。
- **要「停下來等人」**：同時寫 `successCondition` 和 `failureCondition`，讓兩者之間留一段空隙，並視需要設 `inconclusiveLimit`。上面的範例就是這樣設計的。

`Inconclusive` 是刻意設計的安全網：**寧可停下來等人看，也不要在沒有資料的情況下自動放行。**但它要靠上面的條件寫法才會觸發，不是「沒資料」的預設結果。

### 12.5 路線三：mirror 影子流量（零風險預熱）

在切任何真實流量之前，先把正式流量**複製一份**給 v2：

```yaml
      steps:
        - setCanaryScale: { replicas: 2 }
        - setMirrorRoute:
            name: mirror-to-canary
            percentage: 100              # 100% 的流量都複製一份給 v2
            match:
              - method: { exact: GET }   # ⚠ 只鏡射 GET，避免重複寫入
        - pause: { duration: 10m }
        - analysis:
            templates: [{ templateName: success-rate }]
        - setMirrorRoute: { name: mirror-to-canary }   # 同名無 match = 關閉鏡射
        - setWeight: 5
```

**價值**：v2 承受了 100% 的真實流量（包含真實的資料形狀、真實的併發），但使用者完全不受影響——因為回應被丟棄。**這能抓到「用測試資料測不出來」的問題**，例如某個特殊表單資料會讓新版噴 exception。

**限制**：只能驗讀取路徑。`POST` / `PUT` 鏡射過去會**真的執行**，所以上面用 `method: { exact: GET }` 過濾。

### 12.6 把三條路線組合起來

```yaml
      steps:
        # 【階段 1】影子流量：零風險，先看會不會爆
        - setCanaryScale: { replicas: 2 }
        - setMirrorRoute:
            name: mirror
            percentage: 100
            match: [{ method: { exact: GET } }]
        - pause: { duration: 10m }
        - analysis: { templates: [{ templateName: success-rate }] }
        - setMirrorRoute: { name: mirror }

        # 【階段 2】精準測試：header 指定，跑完整 smoke test
        - setHeaderRoute:
            name: canary-test
            match: [{ headerName: x-canary, headerValue: { exact: "true" } }]
        - analysis: { templates: [{ templateName: smoke-test }] }
        - setHeaderRoute: { name: canary-test }

        # 【階段 3】小流量 + 指標驗證
        - setWeight: 5
        - pause: { duration: 10m }
        - analysis: { templates: [{ templateName: success-rate }] }

        # 【階段 4】漸進放量
        - setWeight: 25
        - pause: { duration: 10m }
        - analysis: { templates: [{ templateName: success-rate }] }
        - setWeight: 50
        - pause: { duration: 15m }
        - setWeight: 100
```

**這條流程涵蓋的驗證面，比人工 pilot run 更廣**：人工只能驗「功能對不對」，這裡還驗了真實流量下的成功率與延遲，而且每次發布都跑一模一樣的內容。

### 12.7 怎麼從人工過渡到全自動（最重要的一節）

**不要一步到位。** 直接把人工 gate 拿掉，沒有人敢簽名——因為還沒有人相信那些自動檢查抓得到問題。用四個階段換取信任：

#### 階段 1：人照按，但機器先驗一輪

```yaml
      steps:
        - setHeaderRoute:
            name: canary-test
            match: [{ headerName: x-canary, headerValue: { exact: "true" } }]
        - analysis: { templates: [{ templateName: smoke-test }] }   # 機器先跑
        - setWeight: 5
        - pause: {}                      # ⚠ 無 duration = 無限期等待人工 promote
                                         # 放在關閉 header route 之前：人工 pilot run 期間
                                         # header 規則還開著，pilot 使用者才能穩定打到 v2；
                                         # 若先關掉，只剩 5% 隨機權重，正是 12.2 批評的情況（測試有 90% 機率落在 v1）
        - setHeaderRoute: { name: canary-test }   # 只帶 name、不帶 match = 關閉這條 header route
```

`pause: {}` 會一直等，直到有人執行：

```bash
kubectl argo rollouts promote pmc-epmmformquerygui -n ea-pmc
```

**這個階段什麼都沒改變你們的流程**——使用者一樣做 pilot run、一樣要人按確認。差別只在於**機器已經先跑了一輪，而且留下紀錄**。

#### 階段 2：累積比對數據（跑 5 到 10 次發布）

每次發布記錄兩件事：

| 發布 | 自動檢查結果 | 人工 pilot run 結果 | 一致？ |
|---|---|---|---|
| v1.3.0 | PASS | OK | 是 |
| v1.3.1 | **FAIL**（靜態資源 404） | OK（使用者沒點到那頁） | **機器抓到人沒抓到的** |
| v1.3.2 | PASS | **NG**（某表單欄位跑版） | **人抓到機器沒抓到的** ← 把這個補進測試 |

**每一次「人抓到但機器沒抓到」，就把那個檢查加進 smoke test。** 幾輪之後測試覆蓋率會超過人工。

這張表也是你之後說服主管「可以拿掉人工 gate」的證據。

#### 階段 3：機器判斷，只在失敗時找人

```yaml
      steps:
        # smoke-test 要打 x-canary header：沒有 setHeaderRoute 的話，header 不會被路由到 canary
        # （此時 canary 權重是 0），測到的會是 v1，所以開啟和關閉兩步都要保留
        - setHeaderRoute:
            name: canary-test
            match: [{ headerName: x-canary, headerValue: { exact: "true" } }]
        - analysis: { templates: [{ templateName: smoke-test }] }
        - setHeaderRoute: { name: canary-test }
        - setWeight: 5
        - pause: { duration: 10m }       # ← 改成有時限，時間到自動繼續
        - analysis: { templates: [{ templateName: success-rate }] }
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 100
```

失敗時 Argo 會自動 abort 回滾；要「發通知」還得先設好 `argo-rollouts-notification-configmap`（官方：「Both triggers and templates are configured in the `argo-rollouts-notification-configmap` ConfigMap.」），並在 Rollout 上加訂閱 annotation（見 12.8）。**人從「每次都要看」變成「只有出事才要看」。**

#### 階段 4：全自動 + 保留緊急煞車

保留這些人工介入手段，隨時可以插手：

```bash
kubectl argo rollouts get rollout pmc-epmmformquerygui -n ea-pmc --watch   # 即時看進度
kubectl argo rollouts pause    pmc-epmmformquerygui -n ea-pmc              # 手動暫停
kubectl argo rollouts abort    pmc-epmmformquerygui -n ea-pmc              # 立刻回滾
kubectl argo rollouts promote  pmc-epmmformquerygui -n ea-pmc --full       # 跳過剩餘步驟直接全量
```

### 12.8 安全網設定

```yaml
spec:
  progressDeadlineSeconds: 1800          # 連續 1800 秒沒有進展 = 判定失敗（pause 期間不計）
  progressDeadlineAbort: true            # 逾時就自動 abort（預設 false：不設的話 controller 照常繼續處理，只是 status 標上 ProgressDeadlineExceeded）

  strategy:
    canary:
      abortScaleDownDelaySeconds: 30     # abort 後多久縮掉 canary Pod
      analysis:                          # 【背景分析】在 rollout 期間持續監控，
        templates:                       # 不只在特定 step 檢查
          # ⚠ 本 Part 前面那份 success-rate 有 count: 5，跑完 5 次就結束，不會持續整個 rollout。
          #   背景分析要另寫一份拿掉 count 的 AnalysisTemplate（官方：「The `count` can have 0 as
          #   value which means that it will run until the end of the Rollout execution」）：
          #   複製 12.4 那份 success-rate、刪掉 count: 5、改名為 success-rate-bg 即可
          - templateName: success-rate-bg
        startingStep: 2                  # 從 0 起算：2 = 第 3 個 step，延到該 step 才開始分析
```

**失敗通知**（Argo Rollouts 的 notification）：

```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-rollout-aborted.slack: deploy-alerts
    notifications.argoproj.io/subscribe.on-rollout-completed.slack: deploy-alerts
```

### 12.9 你的環境要先解決的三個前置條件

**這三項不解決，Argo Rollouts 裝了也發揮不了作用**，全部都指回 Part 9：

| 前置條件 | 為什麼是前置 | 對應 |
|---|---|---|
| **session 外部化** | canary 期間使用者會在 v1/v2 之間跳，in-memory session 會讓他被登出。**測試也會因此不穩定**（測到一半 session 掉了） | Part 9 發現 2 |
| **VirtualService 加 `mesh` 且 route 要有 `name`** | Argo 靠 route 名稱找到要改的路由；沒有 `mesh` 的話 header route 對內部呼叫無效 | Part 9 發現 3 |
| **Service port 命名** | 沒有 `name: http` / `appProtocol: http`，Istio 可能用 L4 處理，**header 路由會直接失效** | Part 9 發現 4 |

> **建議順序**：先修 Part 9 的發現 3 和 4（零風險、當天可完成）→ 再做 session 外部化 → 最後才導入 Argo Rollouts。

### 12.10 先確認環境有什麼

```bash
# 1. 有沒有 Prometheus？（決定走路線一還是路線二）
kubectl get svc -A | grep -i prometheus
kubectl get pods -n istio-system | grep -i prometheus

# 2. Istio 的指標有沒有在產生？
# Track B 是 Rollout、沒有 Deployment，所以 deploy/<名稱> 不存在；改用 label 挑一個 pod
POD=$(kubectl get pod -n ea-pmc -l app=pmc-epmmformquerygui -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ea-pmc "$POD" -c istio-proxy -- \
  curl -s localhost:15020/stats/prometheus | grep istio_requests_total | head -5

# 3. 有沒有裝 Argo Rollouts？
kubectl get crd rollouts.argoproj.io
kubectl get pods -n argo-rollouts

# 4. 有沒有 Argo CD？（有的話 Argo Rollouts 幾乎是免費加購）
kubectl get pods -n argocd
```

| 查到的結果 | 建議走哪條路線 |
|---|---|
| 有 Prometheus + 有 Istio 指標 | **路線二為主 + 路線一為輔**（12.6 的組合） |
| 沒有 Prometheus | **路線一**（Job-based smoke test），這條路線完全不依賴監控系統 |
| 有 Argo CD | 直接上 Argo Rollouts |
| 都沒有，也不想裝 | 用 Part 7.2 的手動 VirtualService weight，**但至少把 smoke test 腳本寫出來**，在 CI 裡跑 |

> **延伸閱讀**：手動 canary 的做法見 [Part 7](#part-7canary-發布與自動擴縮容)；Argo Rollouts 與 Flagger / KEDA 的取捨見 Part 7.6。
---

### 12.11 完整 manifest

Part 14.4 給了 Track A（兩個 Deployment）的完整 manifest，這裡是 Track B（Argo Rollouts）的。
**⚠ 這份是教學用的示意版，不是可以直接 apply 的完整版，也不是 `canary-manual/track-b/` 的逐字副本。**
repo 裡實際的檔案是 `track-b/base/00-serviceaccount.yaml`～`04-analysistemplate.yaml` 與 `track-b/release/10-configmap-1.2.3.yaml`、`release/20-rollout.yaml`，跟下面這份有這些差異：

- repo 的 Rollout 步驟 3 是人工閘門 `pause: {}`，這裡寫的是 `analysis`（自動版）。
- repo 的 image 與 ConfigMap 都是 `1.2.3`，沒有 `1.3.0`。
- repo 的 `user-name-attribute` 是 `sub`，也沒有下面已刪掉的 `app.cors`／`app.sso` 區塊。
- repo 多一個 `pmc-epmmformquerygui-svc` Service 和一個 ServiceAccount。
- 下面 Rollout 的 `SPRING_CONFIG_ADDITIONAL_LOCATION` 是未完成的寫法：image 本身的 `SPRING_CONFIG_LOCATION=file:/config/application.yaml` 還在，路徑不存在時 pod 會 CrashLoopBackOff（Spring Boot 2.4+ 對非 `optional:` 且找不到的 `spring.config.location` 會丟 `ConfigDataLocationNotFoundException`）。要等 track-b 的 ConfigMap 依 `CANARY-COMPLETE.md` 附錄 C 補齊後，才能改成 `SPRING_CONFIG_LOCATION`；在那之前請當成示意，不要直接 apply。

前面 12.2 的 Rollout 是精簡版（省略了 probe / resources / securityContext），下面這份補上了這些欄位，但照上面所說，仍不能直接 apply。

#### 資源的關係（含 ServiceAccount 與 `-svc` Service 共八份）

```
  ① ConfigMap（版本化，兩份）
     pmc-epmmformquery-config-1.2.3   ← 舊 ReplicaSet（stable）引用
     pmc-epmmformquery-config-1.3.0   ← 新 ReplicaSet（canary）引用
                    │
  ② Rollout（一份 template，Argo 產生兩組 ReplicaSet）
                    │
        ┌───────────┴───────────┐
     舊 ReplicaSet          新 ReplicaSet
     （stable）              （canary）
        │                       │
  ③ Service ×2（Argo 動態填 rollouts-pod-template-hash 到 selector）
     pmc-epmmformquerygui-stable   pmc-epmmformquerygui-canary
     （repo 另有第三個 pmc-epmmformquerygui-svc，是 VirtualService 的 mesh host，見下方 5.）
        │                       │
  ④ DestinationRule ×2（各綁一個 Service，只放 trafficPolicy，不用 subset）
        │                       │
  ⑤ VirtualService（route: primary，Argo 動態改 weight）
        └───────────┬───────────┘
                    │
  ⑥ AnalysisTemplate（指標判斷，失敗自動 abort）

  ⑦ ServiceAccount pmc-epmmformquerygui（Rollout 用 serviceAccountName 引用，下方未重印；內容見 repo）
  ⑧ Service pmc-epmmformquerygui-svc（第三個 Service，見 3.）
```

**跟 Track A 最大的結構差異**：Track A 用「一個 Service + DestinationRule subset」分兩軌；Track B 用「兩個 Service」分兩軌，**不需要 subset**。完整差異見 Part 15。

---

#### 1. ConfigMap（版本化命名）

**Track B 的 ConfigMap 只能用版本化命名**，這不是選擇題。原因：

Argo Rollouts 只有**一份** `spec.template`。stable 和 canary 不是兩份設定，而是「同一份 template 的兩個版本」——Argo 用 ReplicaSet 保留舊版：

```
   改 Rollout 的 template
        ↓
   Argo 建立【新 ReplicaSet】= canary（用 template 的新內容）
   Argo 保留【舊 ReplicaSet】= stable（用 template 的舊內容）
```

所以要讓兩軌用不同設定，唯一辦法就是**改 template 裡的 ConfigMap 名稱**——新 ReplicaSet 引用新名稱，舊 ReplicaSet 仍引用舊名稱。如果你固定寫 `name: pmc-epmmformquery-config-canary`，template 沒變，兩個 ReplicaSet 會引用同一份 ConfigMap，等於沒分開。

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-config-1.2.3     # 舊 ReplicaSet（stable）引用
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
    config-version: "1.2.3"
immutable: true                             # 建立後不可修改，防誤改也減少 API server 負擔
data:
  application.yml: |
    server:
      port: 8080
      forward-headers-strategy: framework

    spring:
      application:
        name: pmc-epmmformquerygui
      security:
        oauth2:
          client:
            registration:
              keycloak:
                client-id: ${KEYCLOAK_CLIENT_ID}
                client-secret: ${KEYCLOAK_CLIENT_SECRET}
                authorization-grant-type: authorization_code
                scope: [openid, profile, email]
                client-name: Keycloak Login
            provider:
              keycloak:
                issuer-uri: ${KEYCLOAK_ISSUER_URI}
                # 必須是 sub：寫成 preferred_username 是已知的錯誤（CANARY-COMPLETE.md 附錄 C）
                user-name-attribute: sub

    app:
      context-prefix: /gui_epmmFormQuery
      # app.cors.*、app.sso.* 已刪除：沒有任何程式讀它們（附錄 C、§10 #13），寫了只會讓人以為設定生效。
      # CORS 靠 CORS_ALLOWED_ORIGINS 環境變數；登出後導回的 key 是 app.post-logout-redirect-uri（§3.5），
      # 沒有預設值，少了它啟動時會 Could not resolve placeholder。
      post-logout-redirect-uri: ${POST_LOGOUT_REDIRECT_URI}
      privilege:
        enabled: ${PRIVILEGE_CHECK_ENABLED:false}
      frontend:
        url-prefix: /gui_epmmFormQuery/web
        resource-location: classpath:/gui_epmmFormQuery/web/
        index-path: /gui_epmmFormQuery/web/index.html
        classpath-base: gui_epmmFormQuery/web

    logging:
      level:
        com.example: INFO

    management:
      endpoints:
        web:
          base-path: /gui_epmmFormQuery/actuator
          exposure:
            include: health,info,mappings
      endpoint:
        health:
          show-details: when-authorized
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-config-1.3.0     # 新 ReplicaSet（canary）引用
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
    config-version: "1.3.0"
immutable: true
data:
  application.yml: |
    # ...（前面與 1.2.3 相同，此處省略）...

    app:
      context-prefix: /gui_epmmFormQuery

      # >>> 1.3.0 新增的設定，舊版沒有也不需要 <<<
      # 這就是「為什麼 ConfigMap 要分開」的實際例子：
      # 共用一份的話，你為了新版加的設定會立刻套到 stable 上。
      export:
        enabled: ${EXPORT_ENABLED:true}
        max-rows: ${EXPORT_MAX_ROWS:50000}
        timeout-seconds: ${EXPORT_TIMEOUT:120}

    logging:
      level:
        com.example: INFO
        com.example.export: DEBUG          # canary 期間把新功能的 log 開細一點
```

> 實際檔案見 `canary-manual/track-b/release/10-configmap-1.2.3.yaml`（內容與上面不同，差異見 12.11 開頭）。

---

#### 2. Rollout（完整版）

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
spec:
  replicas: 2
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 1800      # 連續 1800 秒沒有進展就判定失敗（pause 期間不計）
  progressDeadlineAbort: true        # 逾時自動 abort（預設 false：不設的話 controller 照常繼續處理，只是 status 標上 ProgressDeadlineExceeded）

  selector:
    matchLabels:
      app: pmc-epmmformquerygui      # 【注意】不要寫 version，Argo 自己用
                                     # rollouts-pod-template-hash 區分兩軌

  # ---------------------------------------------------------------------------
  # Pod template —— 跟 Track A 的 Deployment 內容完全一樣，可直接複製
  # ---------------------------------------------------------------------------
  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui
      annotations:
        config-version: "1.3.0"      # 改這個 + image → 產生新 ReplicaSet
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      serviceAccountName: pmc-epmmformquerygui
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 60

      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.3.0    # 發布時改這裡
          imagePullPolicy: IfNotPresent

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

          envFrom:
            - secretRef:
                name: pmc-epmmformquery-secret
          env:
            # ⚠ 未完成：image 內建的 SPRING_CONFIG_LOCATION 還在，這個寫法依賴 track-b ConfigMap 已補齊（見 12.11 開頭）
            - name: SPRING_CONFIG_ADDITIONAL_LOCATION
              value: "file:/app/config/application.yml"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name

          resources:
            requests: { memory: "512Mi", cpu: "250m" }
            limits:   { memory: "1Gi",   cpu: "1000m" }

          startupProbe:
            httpGet: { path: /gui_epmmFormQuery/actuator/health, port: 8080 }
            failureThreshold: 30
            periodSeconds: 10

          readinessProbe:
            httpGet: { path: /gui_epmmFormQuery/actuator/health, port: 8080 }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3

          livenessProbe:
            httpGet: { path: /gui_epmmFormQuery/actuator/health, port: 8080 }
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3

          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
            - name: tmp
              mountPath: /tmp

      volumes:
        - name: config
          configMap:
            name: pmc-epmmformquery-config-1.3.0    # 版本化，見上一份
        - name: tmp
          emptyDir: {}

  # ---------------------------------------------------------------------------
  # 發布策略
  # ---------------------------------------------------------------------------
  strategy:
    canary:
      stableService: pmc-epmmformquerygui-stable    # Argo 動態改這兩個 Service 的 selector
      canaryService: pmc-epmmformquerygui-canary
      abortScaleDownDelaySeconds: 30

      trafficRouting:
        managedRoutes:
          # 【必要】steps 用了 setHeaderRoute，就必須宣告它的名字。沒宣告並不是默默略過這個 step，
          # 而是整個 Rollout 驗證失敗（InvalidSpec），根本不會往下推進。
          - name: pilot-run
        istio:
          virtualService:
            name: app-routing
            routes:
              - primary           # 【必要】VirtualService 裡要有這個名字的 route

      steps:
        # 步驟 1：只開 1 個 canary pod，正式流量仍 100% 在 stable
        - setCanaryScale:
            replicas: 1

        # 步驟 2：開 cookie 專用路由，讓 pilot 使用者（或自動化測試）進 canary
        - setHeaderRoute:
            name: pilot-run
            match:
              - headerName: cookie
                headerValue:
                  regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"

        # 步驟 3：閘門 —— 這裡有兩種選擇，見 12.12
        #   人工版： - pause: {}
        #   自動版： - analysis: { templates: [{ templateName: success-rate-safe }] }
        - analysis:
            templates:
              - templateName: success-rate-safe

        # 步驟 4：移除 cookie 路由（同名無 match = 移除）
        - setHeaderRoute:
            name: pilot-run

        # 步驟 5：讓 canary 依流量比例擴容
        #   【不能省】否則 canary 一直卡在 1 個 pod，切 100% 流量會把它打爆
        - setCanaryScale:
            matchTrafficWeight: true

        # 步驟 6：全量
        - setWeight: 100
```

---

#### 3. Service ×2（repo 實際有 ×3）

repo 的 `track-b/base/01-services.yaml` 另有第三個 `pmc-epmmformquerygui-svc`：下面 VirtualService 的 `hosts` 列了 `pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local`（mesh 內部流量），這個 host 要有對應的 Service；這裡省略沒印，請看 repo 的檔案。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pmc-epmmformquerygui-stable
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
spec:
  type: ClusterIP
  selector:
    app: pmc-epmmformquerygui     # Argo 會再自動加上 rollouts-pod-template-hash
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
      appProtocol: http           # 必要：cookie 比對是 L7 功能
---
apiVersion: v1
kind: Service
metadata:
  name: pmc-epmmformquerygui-canary
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
spec:
  type: ClusterIP
  selector:
    app: pmc-epmmformquerygui
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
      appProtocol: http
```

> **不要自己在 selector 寫 `version`**。Argo 會動態把 `rollouts-pod-template-hash` 寫進這兩個 Service 的 selector，讓 stable Service 只指到舊 ReplicaSet、canary Service 只指到新 ReplicaSet。你先寫死反而會打架。

---

#### 4. DestinationRule ×2

Track B 不用 subset，這兩份只剩 `trafficPolicy` 的作用（session 黏著、連線池、熔斷）。因為 DestinationRule 是綁 host 的，兩個 Service 要各套一份。

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: pmc-epmmformquerygui-stable-dr
  namespace: ea-pmc
spec:
  host: pmc-epmmformquerygui-stable
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          # 不要用 JSESSIONID：設了 ttl 之後，請求沒帶這個 cookie 時 Envoy 會自己產生一個同名 cookie
          # （Envoy 文件："a cookie with the TTL will be generated if the cookie is not present"），
          # 和 Spring 的 session cookie 同名會互相覆寫，黏著反而被破壞，所以改用專屬名稱。
          name: epmm-affinity
          ttl: 10800s
    connectionPool:
      tcp:  { maxConnections: 100, connectTimeout: 3s }
      http: { http1MaxPendingRequests: 100 }
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: pmc-epmmformquerygui-canary-dr
  namespace: ea-pmc
spec:
  host: pmc-epmmformquerygui-canary
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          # 不要用 JSESSIONID，理由同上一份 stable-dr。
          name: epmm-affinity
          ttl: 10800s
    connectionPool:
      tcp:  { maxConnections: 100, connectTimeout: 3s }
      http: { http1MaxPendingRequests: 100 }
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

---

#### 5. VirtualService

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app-routing
  namespace: ea-pmc
spec:
  hosts:
    - myapp.example.com
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
  gateways:
    - istio-system/my-gateway
    - mesh                                   # 理由見 14.6

  http:
    # Argo 會在這個位置之前「動態插入」名為 pilot-run 的 route（步驟 2 時），
    # 並在步驟 4 移除。你不需要自己寫那條。

    - name: primary                          # 【必要】要跟 Rollout 的 routes 對上
      match:
        - uri: { prefix: /gui_epmmFormQuery/ }
        - uri: { exact: /gui_epmmFormQuery }
      route:
        - destination:
            host: pmc-epmmformquerygui-stable    # 【必要】對應 stableService
            port: { number: 8080 }
          weight: 100                            # Argo 動態改這個數字
        - destination:
            host: pmc-epmmformquerygui-canary    # 【必要】對應 canaryService
            port: { number: 8080 }
          weight: 0                              # Argo 動態改這個數字
      timeout: 15s
      retries:
        attempts: 3
        perTryTimeout: 4s
        # 不放 5xx：Istio 的 retry 不分 HTTP method，5xx 會讓一個失敗的 POST 表單最多重送 3 次
        retryOn: "reset,connect-failure,refused-stream"

    - name: default                          # catch-all 安全網
      route:
        - destination:
            host: pmc-epmmformquerygui-stable
            port: { number: 8080 }
```

> **⚠ 發布期間不要手動 `kubectl apply` 這個檔案**，會跟 Argo 打架。
> 用 Argo CD 的話，要設定忽略 `weight` 欄位的差異，否則 Argo CD 會一直想把權重改回 100/0。

---

#### 套用順序

```bash
NS=ea-pmc

# 先驗語法（server-side dry-run）：整個目錄一次驗完，任何一份有錯就在這裡停下，還沒動到叢集
kubectl -n $NS apply --dry-run=server -f base/ -f release/

# ⚠ 如果原本是 Track A：不要先刪 Deployment。Argo 文件說 Rollout 不會去管理既有 Deployment 的 Pod，
# 且「a Rollout should run next to the Deployment before deleting the Deployment」，
# 不照這個順序可能停機。所以先建 Rollout、確認健康，最後才刪舊 Deployment。
# 也可以改用 workloadRef 搭配 scaleDown: onsuccess，讓 Rollout 健康後才縮掉舊 Deployment。
kubectl -n $NS apply -f base/00-serviceaccount.yaml    # 缺了它 Rollout 的 pod 建不起來（serviceAccountName）
kubectl -n $NS apply -f release/10-configmap-1.2.3.yaml
kubectl -n $NS apply -f base/01-services.yaml
kubectl -n $NS apply -f base/02-destinationrule.yaml
kubectl -n $NS apply -f base/03-virtualservice.yaml
kubectl -n $NS apply -f base/04-analysistemplate.yaml
kubectl -n $NS apply -f release/20-rollout.yaml        # Rollout 最後套，前面的都要先就位

# status 回報 Healthy（指令 exit 0）才會往下刪；失敗就停在這裡，舊 Deployment 繼續服務
kubectl argo rollouts status pmc-epmmformquerygui -n $NS && \
  kubectl -n $NS delete deploy pmc-epmmformquerygui-stable pmc-epmmformquerygui-canary
```

---

### 12.12 用 metric 判斷：最小可用的例子

你要最簡單的版本，那就**只看一個指標：成功率**。

#### 最小可用的 AnalysisTemplate

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate-minimal
  namespace: ea-pmc
spec:
  metrics:
    - name: success-rate
      interval: 1m                          # 每隔多久量一次
      count: 5                              # 總共量幾次 → 1m x 5 = 跑 5 分鐘
      successCondition: result[0] >= 0.99   # 通過條件：成功率 >= 99%
      failureLimit: 1                       # 容許失敗 1 次，第 2 次才 abort
      provider:
        prometheus:
          address: http://prometheus.istio-system.svc.cluster.local:9090
          query: |
            sum(rate(istio_requests_total{
              destination_workload="pmc-epmmformquerygui",
              destination_workload_namespace="ea-pmc",
              response_code!~"5.."
            }[2m]))
            /
            sum(rate(istio_requests_total{
              destination_workload="pmc-epmmformquerygui",
              destination_workload_namespace="ea-pmc"
            }[2m]))
```

在 Rollout 裡這樣用：

```yaml
      steps:
        - setCanaryScale: { replicas: 1 }
        - setWeight: 5
        - analysis:                          # ← 就這三行
            templates:
              - templateName: success-rate-minimal
        - setWeight: 100
```

#### 每個欄位在做什麼

| 欄位 | 意思 | 怎麼調 |
|---|---|---|
| `interval` | 多久量一次 | 太短會抓到瞬間抖動，建議 1~2 分鐘 |
| `count` | 總共量幾次 | `interval x count` = 這個 analysis 跑多久 |
| `successCondition` | 通過的條件 | `result[0]` 是 Prometheus 回傳的第一個數值 |
| `failureLimit` | 容許失敗幾次 | **不要設 0**，給一次容錯避免瞬間抖動誤判 |
| `provider.prometheus.address` | Prometheus 位址 | Istio addon 預設是這個，自己裝的要改 |

**`result[0]` 是什麼**：Prometheus 回傳的是一個陣列（可能有多筆時間序列）。上面的 query 用了 `sum()` 聚合，所以只會回傳一個值，取 `result[0]` 就是那個成功率（0.0 ~ 1.0 之間的小數）。

#### 判斷結果有三種

| 結果 | 意思 | Rollout 的行為 |
|---|---|---|
| **Successful** | 條件滿足 | 繼續下一個 step |
| **Failed** | 失敗次數超過 `failureLimit` | **自動 abort：流量切回 stable、canary 縮掉** |
| **Inconclusive** | 查詢沒有資料 / 無法判斷 | **暫停等人**（不繼續也不回滾） |

`Inconclusive` 是刻意的安全網：**寧可停下來等人看，也不要在沒有資料的情況下自動放行。**

#### ⚠ 最重要的陷阱：小流量時指標會騙你

canary 初期只有 5% 流量。如果那 2 分鐘總共只進來 **3 個請求**，其中 1 個是使用者自己按取消造成的 5xx —— 成功率就變成 **66%**，Rollout 會誤判失敗直接回滾，但其實根本沒問題。

**解法：把「請求數要夠多才算數」併進同一條 query，並讓成功與失敗兩個條件之間留一段空隙。** 流量不夠時 query 回傳空結果，落到 Inconclusive（暫停等人），而不是 Failed。

```yaml
    # 取代上面的 success-rate 指標（同一個指標內含最低樣本數檢查）
    - name: success-rate
      interval: 1m
      count: 5
      # 成功與失敗各寫一個條件，中間留空隙（0.95 ~ 0.99）；沒有資料時也是 Inconclusive。
      successCondition: len(result) > 0 && result[0] >= 0.99
      failureCondition: len(result) > 0 && result[0] < 0.95
      failureLimit: 1
      inconclusiveLimit: 2                  # 允許 2 次 Inconclusive 量測，再多就把整個指標判 Inconclusive
      provider:
        prometheus:
          address: http://prometheus.istio-system.svc.cluster.local:9090
          query: |
            (
              sum(rate(istio_requests_total{
                destination_workload="pmc-epmmformquerygui",
                destination_workload_namespace="ea-pmc",
                response_code!~"5.."
              }[2m]))
              /
              sum(rate(istio_requests_total{
                destination_workload="pmc-epmmformquerygui",
                destination_workload_namespace="ea-pmc"
              }[2m]))
            )
            # 最低樣本數：近 2 分鐘不到 20 個請求就整條回傳空向量（-> len(result) == 0 -> Inconclusive）。
            and on() (
              sum(increase(istio_requests_total{
                destination_workload="pmc-epmmformquerygui",
                destination_workload_namespace="ea-pmc"
              }[2m])) >= 20
            )
```

**為什麼不另開一個 `enough-traffic` 指標**：一個指標的 `failureLimit` 是「這個指標容許自己失敗幾次」，超過才把該指標判 Failed；而整個 AnalysisRun 取各指標中最糟的結果。`count: 5` 搭配 `failureLimit: 5` 的指標最多只會失敗 5 次，永遠不會超過上限，等於形同虛設；它也擋不住 `success-rate` 自己失敗。若改設 `failureLimit: 0`（預設），樣本不足又會讓它 Failed、整個 Rollout abort，跟「不下結論」正好相反。指標之間沒有依附關係，所以樣本數檢查要併進同一條 query。

> `canary-manual/track-b/base/04-analysistemplate.yaml` 裡的 `success-rate-safe` 目前仍是另開 `enough-traffic` 指標的寫法，有上述同樣的問題，尚未修正，不要當成正式環境的範本照抄。

#### 想再加 P99 延遲的話

```yaml
    - name: latency-p99
      interval: 1m
      count: 5
      successCondition: result[0] <= 1000    # 毫秒
      failureLimit: 1
      provider:
        prometheus:
          address: http://prometheus.istio-system.svc.cluster.local:9090
          query: |
            histogram_quantile(0.99,
              sum(rate(istio_request_duration_milliseconds_bucket{
                destination_workload="pmc-epmmformquerygui",
                destination_workload_namespace="ea-pmc"
              }[2m])) by (le))
```

#### 失敗時會發生什麼（你選的「自動回滾」）

這是 **Argo 的預設行為，不用額外設定**：

```
  analysis 失敗（超過 failureLimit）
        ↓
  Rollout 進入 Degraded 狀態
        ↓
  VirtualService 的 weight 立刻改回 stable 100 / canary 0
        ↓
  等 abortScaleDownDelaySeconds（30 秒）後縮掉 canary pod
        ↓
  發通知（如果有設 notification）
```

**使用者端幾乎無感**，因為 canary 本來就只有 5% 流量，切回去是秒級的。

analysis 一失敗，Rollout 就整個 abort，根本走不到後面的 step，所以在 `analysis` 後面接 `pause: {}` 並不能做到「失敗時停下來等人」。要停下來等人，應把指標設計成 Inconclusive（`successCondition` 與 `failureCondition` 之間留空隙，見上面的範例）；或用 `dryRun` 只收集數據、不讓結果影響 Rollout。

#### 先確認環境有沒有 Prometheus

```bash
# 1. 有沒有 Prometheus？
kubectl get svc -A | grep -i prometheus

# 2. Istio 的指標有沒有在產生？
# Track B 是 Rollout、沒有 -stable Deployment（deploy/...-stable 只存在於 Track A）；用 label 挑一個 pod
POD=$(kubectl get pod -n ea-pmc -l app=pmc-epmmformquerygui -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ea-pmc "$POD" -c istio-proxy -- \
  curl -s localhost:15020/stats/prometheus | grep istio_requests_total | head -3

# 3. 手動跑一次 query，確認拿得到數字（把 Prometheus port-forward 出來）
kubectl -n istio-system port-forward svc/prometheus 9090:9090
# 然後瀏覽器開 http://localhost:9090 貼上上面的 query
```

**第 3 步很重要**：先手動確認 query 拿得到合理的數字，再放進 AnalysisTemplate。不然你會在發布時才發現 query 寫錯，而那時候 Rollout 已經卡住了。

如果環境**沒有 Prometheus**，改走 12.3 的 Job-based smoke test —— 那條路線完全不依賴監控系統。

### 參考來源

- Argo Rollouts — Analysis & Progressive Delivery：https://argo-rollouts.readthedocs.io/en/stable/features/analysis/
- Argo Rollouts — Prometheus provider：https://argo-rollouts.readthedocs.io/en/stable/analysis/prometheus/
- Argo Rollouts — Notifications：https://argo-rollouts.readthedocs.io/en/stable/features/notifications/
- Argo Rollouts — Rollout Specification：https://argo-rollouts.readthedocs.io/en/stable/features/specification/
- Argo Rollouts — Traffic Management：https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/
- Argo Rollouts — Migrating to Rollouts：https://argo-rollouts.readthedocs.io/en/stable/migrating/
- github.com/argoproj — analysis.go：https://github.com/argoproj/argo-rollouts/blob/master/analysis/analysis.go
- github.com/argoproj — analysis_types.go（failureLimit）：https://github.com/argoproj/argo-rollouts/blob/master/pkg/apis/rollouts/v1alpha1/analysis_types.go
- github.com/argoproj — validation.go：https://github.com/argoproj/argo-rollouts/blob/master/pkg/apis/rollouts/validation/validation.go
- github.com/istio — pkg/kube/util.go：https://github.com/istio/istio/blob/master/pkg/kube/util.go
- istio.io — Annotations 參考：https://istio.io/latest/docs/reference/config/annotations/
- istio.io — Standard Metrics：https://istio.io/latest/docs/reference/config/metrics/
- Prometheus — Querying basics：https://prometheus.io/docs/prometheus/latest/querying/basics/
- Envoy — route_components.proto：https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto

---

## Part 13：node 排程與 routable 網段

### 13.1 這是在解決什麼問題

企業內網的 K8s cluster，node 通常不是同質的。最常見的分法就是**依網段**：

- 一部分 node 的 IP 落在 **公司可路由的網段**（例如 `10.x.x.x`）——這些 node 上的 Pod 能被公司其他系統直接連到，也連得出去
- 其他 node 只有 **不可路由的網段**（例如 `100.64.x.x`）——只在 cluster 內部有效

**可路由的 node 是稀缺資源**（IP 要跟網路組申請、有數量限制、成本較高），所以管理員會用 label + taint 把它保護起來：**只有真正需要的 workload 才排得上去。**

`nodeSelector: routable` 和對應的 `toleration` 就是在做這件事。

> **⚠ 重要：`routable` 不是 Kubernetes 的標準欄位或標準 label。** 它是你們公司自訂的慣例。實際的 label key、value、taint 內容**必須用 13.5 的指令查你們自己的 cluster**——本節所有範例都是 placeholder。

### 13.2 核心觀念：label 和 taint 是兩個獨立的機制

這是最多人搞錯的地方。它們**方向相反、缺一不可**：

| 機制 | 設在哪 | Pod 這邊寫什麼 | 語意 |
|---|---|---|---|
| **label** | node 上 | `nodeSelector` / `nodeAffinity` | 「**我想去那裡**」（吸引） |
| **taint** | node 上 | `tolerations` | 「**我被允許去那裡**」（排除） |

```
   node 有 label: network=routable        ← 用來「找得到」這台
   node 有 taint: network=routable:NoSchedule  ← 用來「擋住」沒授權的 Pod

   Pod 要成功排上去，兩件事都要做：
   ┌────────────────────────────────────────────────┐
   │  nodeSelector: { network: routable }           │  ← 我指定要去
   │  tolerations:  [ network=routable:NoSchedule ] │  ← 我有通行證
   └────────────────────────────────────────────────┘
```

#### 四象限：少了哪一個會怎樣

| | **有 toleration** | **沒有 toleration** |
|---|---|---|
| **有 nodeSelector** | ✅ **正確**——指定去 routable node，且有通行證 | ❌ **一直 Pending**——指定了要去，但被 taint 擋在門外 |
| **沒有 nodeSelector** | ⚠ **危險**——有通行證但沒指定，**可能排到 routable，也可能排到一般 node**，結果不可預期 | ✅ 正常排到一般 node（大多數服務就是這樣） |

**右上角那格是最常見的錯誤**：「我加了 `nodeSelector: routable` 為什麼 Pod 一直 Pending？」——因為忘了加 toleration。

**左下角那格是最陰的錯誤**：有些人為了保險把 toleration 加好加滿，但沒寫 nodeSelector。結果 Pod 這次排到一般 node、下次滾動更新排到 routable node，行為不一致而且浪費稀缺資源。

### 13.3 誰需要 routable、誰不需要

| Workload | 需要 routable？ | 原因 |
|---|:---:|---|
| **istio-ingressgateway** | **通常要（看環境）** | 它要綁公司可路由的 VIP；是否一定要排到那個網段的 node，取決於 Service 的 `externalTrafficPolicy` 與你們 LB／CNI 的限制（見表下說明與 Part 10） |
| 需要被公司**其他系統直接連**的服務 | 要 | 例如提供 API 給別的部門的系統呼叫 |
| 需要**主動連外部系統**的服務 | 看情況 | 取決於出向是否經過 SNAT——要問網路組 |
| `pmc-epmmformquerygui` 這類 GUI | **看情況** | 入口流量從 ingressgateway 進來，不需要可路由 IP；但它是 BFF，啟動時與登入時都會主動連 Keycloak（discovery、token、JWKS），屬於上一類「主動連外部系統」——看 Keycloak 的位置與出向是否經過 SNAT，要問網路組 |
| 一般後端 API（`epmm-api`） | **不用** | 只被 mesh 內部呼叫 |
| CronJob / 批次任務 | **不用** | 除非要打公司內其他系統 |

> **原則：需要「被外面直接找到」或「自己主動出去」的才需要 routable。** 躲在 ingressgateway 後面、而且自己不主動連外部系統的服務，不需要——這也是用 ingressgateway 共用入口的另一個好處：**入口這一側只有 gateway 要佔用稀缺的 routable node。**
>
> **ingressgateway 是否「一定要」排到 routable node，不是 K8s 的通則，要看條件：**
>
> - `externalTrafficPolicy: Cluster`（預設）時，K8s 官方說明："Set the field to `Cluster` to route external traffic to all ready endpoints"——VIP 落到任何一台 node，都會轉發到其他 node 上的 Pod，Pod 不一定要在 routable node。
> - `externalTrafficPolicy: Local` 時，官方說明是 "If the traffic policy is `Local` and there are no node-local endpoints, the kube-proxy does not forward any traffic for the relevant Service."——VIP 所在的 node 上沒有 gateway Pod 就不轉發，此時 Pod 必須在 VIP 實際對外宣告的那些 node 上。
> - 貴司 LB／CNI 若限制只能把流量送到特定網段的 node，也會讓 Pod 必須排到該網段（環境特定）。
> - 檢查指令：`kubectl get svc -n istio-system istio-ingressgateway -o jsonpath='{.spec.externalTrafficPolicy}'`

### 13.4 完整寫法

#### 基本版：nodeSelector + toleration

> **注意：下面是片段，不是能直接 apply 的完整 Deployment。** 它省略了 `spec.selector`（apps/v1 的必填欄位，官方：".spec.selector is a required field that specifies a label selector"），直接 `kubectl apply` 會被拒絕。另外 ingressgateway 的 Deployment 通常由安裝工具管理，`nodeSelector` / `tolerations` 應該寫在 IstioOperator 或 Helm values 裡；直接改 Deployment，下次安裝工具重新套用時可能被蓋回去。這裡只是用 Deployment 的形狀示範這兩個欄位放在哪一層。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  template:
    spec:
      # ---------- 「我要去 routable node」----------
      nodeSelector:
        network: routable            # ⚠ placeholder，用 13.5 的指令查你們的實際 key/value

      # ---------- 「我有通行證」----------
      tolerations:
        - key: "network"             # ⚠ 要跟 node 上 taint 的 key 完全一致
          operator: "Equal"          # Equal = 要比對 value；Exists = 只要 key 存在就容忍
          value: "routable"
          effect: "NoSchedule"       # 要跟 taint 的 effect 一致

      containers:
        - name: istio-proxy
          image: auto
```

#### 進階版：nodeAffinity（更有彈性）

`nodeSelector` 只能做「完全相等」的比對。要表達「這幾個網段其中之一」或「優先但不強制」，就要用 `nodeAffinity`：

```yaml
    spec:
      affinity:
        nodeAffinity:
          # 硬性條件：不滿足就不排（等同 nodeSelector，但支援更多運算子）
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: network
                    operator: In
                    values: ["routable", "routable-dmz"]   # 兩個網段都可以

          # 軟性偏好：盡量排到這裡，排不上也接受
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: topology.kubernetes.io/zone
                    operator: In
                    values: ["zone-a"]

      tolerations:
        - key: "network"
          operator: "Equal"
          value: "routable"
          effect: "NoSchedule"
```

#### taint 的三種 effect

| effect | 對「沒有 toleration 的 Pod」的行為 |
|---|---|
| `NoSchedule` | **不排新的**上來，但已經在跑的不動 |
| `PreferNoSchedule` | 盡量不排，但真的沒地方時還是會排（軟性） |
| `NoExecute` | **不排新的，而且把已經在跑的驅逐掉** |

搭配 `NoExecute` 時可以加 `tolerationSeconds`，但**它只適合 not-ready 這類暫時性的 taint**。官方說明："Pods that tolerate the taint without specifying `tolerationSeconds` in their toleration specification remain bound forever"；有指定時則 "remain bound for the specified amount of time. After that time elapses, the node lifecycle controller evicts the Pods from the node."

```yaml
        # 暫時性 taint 的例子（not-ready）：node 異常時容忍 300 秒，之後才驅逐
        - key: "node.kubernetes.io/not-ready"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 300
```

`network=routable` 是永久的專用 taint，toleration **不要**加 `tolerationSeconds`：加了等於 gateway Pod 每 300 秒就被驅逐一次。

#### 管理員那一側的指令（了解即可，通常不是你做）

```bash
# 加 label（讓 Pod 找得到）
kubectl label node <node-name> network=routable

# 加 taint（擋住沒授權的 Pod）
kubectl taint node <node-name> network=routable:NoSchedule

# 移除 taint（注意最後那個減號）
kubectl taint node <node-name> network=routable:NoSchedule-
```

### 13.5 查出你們實際的 label 與 taint

**因為 `routable` 是公司自訂慣例，這一步不能省。** 四條指令：

```bash
# 1. 看每台 node 的 IP 落在哪個網段（最直接的判斷依據）
kubectl get nodes -o wide
#    INTERNAL-IP 是 10.x.x.x  → 可能是 routable
#    INTERNAL-IP 是 100.64.x.x → 可能是 non-routable

# 2. 看所有 node 的 label，找出跟網段有關的那個 key
kubectl get nodes --show-labels
#    常見的 key 名稱：network / node-role / zone / topology / nodepool / net-type

# 3. 看 taint（label 和 taint 的 key 通常一樣但不保證）
kubectl describe node <node-name> | grep -A5 "Taints:"

# 4. 一行同時看 node 名稱、IP、taint —— 最快的全景檢查
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,TAINTS:.spec.taints[*].key'
```

**最可靠的做法：直接抄現有的。** 找一個已經跑在 routable node 上的 workload（通常就是 ingressgateway），看它怎麼寫：

```bash
kubectl get deploy -n istio-system istio-ingressgateway \
  -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}{.spec.template.spec.tolerations}{"\n"}'
```

這一行的輸出就是你該照抄的格式。

### 13.6 這跟 Part 10 的關係

Part 10 講的雙 VIP 架構，**能不能成立就取決於這一節**：

```
  Service (type: LoadBalancer, VIP 10.20.30.40 routable)
        │  selector: istio=ingressgateway
        ▼
  ingressgateway Pod
        │  ⚠ 在 Local／LB 有網段限制的環境，這個 Pod 必須跑在
        │    routable 網段的 node 上，VIP 的流量才到得了它
        ▼
  nodeSelector: network=routable  +  toleration
        ▼
  routable node（IP 10.x.x.x）
```

如果 gateway Pod 被排到 non-routable 的 node 上，**在 `externalTrafficPolicy: Local`（或貴司 LB／CNI 有網段限制）的環境下，Service 拿得到 VIP，但流量進不來**（`Cluster` 時 VIP 會把流量轉發到其他 node 上的 Pod，不會有這個症狀）——症狀是 external IP 有值、endpoint 也有值，但從外面 curl 就是 timeout。這種問題非常難查，因為所有 K8s 物件看起來都正常。

**驗證 gateway Pod 排在對的地方：**

```bash
# 看 gateway Pod 實際跑在哪台 node
kubectl get pods -n istio-system -l istio=ingressgateway -o wide

# 對照那台 node 的 IP 網段
kubectl get node <那台 node> -o wide
```

### 13.7 踩雷

#### 踩雷 1：只加 nodeSelector，忘記 toleration（最常見）

**症狀**：Pod 永遠 `Pending`。

```bash
kubectl describe pod <pod> -n <ns> | tail -20
# Events:
#   Warning  FailedScheduling  0/12 nodes are available:
#     3 node(s) had untolerated taint(s),
#     9 node(s) didn't match Pod's node affinity/selector.
```

> **版本差異**：K8s v1.34 起，這則事件只印「node(s) had untolerated taint(s)」，**不再印出 taint 的 key／value**；v1.33 以前才會印成 `node(s) had untolerated taint {network: routable}`。看到新格式時，要再跑 `kubectl describe node <node>` 看 `Taints:`，才知道缺的是哪一個 toleration。

**這行訊息就是答案**：`untolerated taint` = 缺 toleration；`didn't match node affinity/selector` = 那些 node 沒有你要的 label。

#### 踩雷 2：`operator: Exists` 太寬鬆

```yaml
        - key: "network"
          operator: "Exists"       # 容忍「所有 key 是 network 的 taint」
          effect: "NoSchedule"     # 包括 network=dmz、network=restricted...
```

這會讓 Pod 有資格排到**所有帶 `network` taint 的 node**，包含你不希望它去的。**除非真的要「容忍一切」，否則一律用 `Equal` 明確指定 value。**

最寬鬆的寫法（幾乎不該用在業務 Pod 上）：

```yaml
        - operator: "Exists"       # 沒有 key 沒有 effect = 容忍所有 taint
```

這是 DaemonSet（如監控 agent）才會用的寫法。

#### 踩雷 3：routable node 太少，跟分散策略打架

routable node 通常只有 2~3 台。如果同時設了：

```yaml
      nodeSelector: { network: routable }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule      # ⚠ 硬性
          labelSelector:                        # 少了它就不會計入任何 Pod，這條約束等於沒有作用
            matchLabels: { app: my-app }
```

`DoNotSchedule` 擋的是**不均勻**，不是「一台最多放一個」：`maxSkew: 1` 允許任兩台 node 的 Pod 數相差 1。3 台 routable node 放第 4 個 Pod，結果是 2/1/1，skew 是 1，仍然符合 `maxSkew`，**排得上去**。所以 replica 數超過 routable node 數量，本身不會讓 Pod 卡住。

真正會讓多出來的 Pod 排不上去的，是以 `kubernetes.io/hostname` 為 topologyKey 的 **required `podAntiAffinity`**（一台 node 只准放一個）；或是 routable node 的 CPU／memory 不夠。`topologySpreadConstraints` 要有 `labelSelector`，官方說明是「Pods that match this label selector are counted」。

**修法**：如果你的目的是在 node 稀缺時還能盡量分散，改用軟性約束：

```yaml
          whenUnsatisfiable: ScheduleAnyway     # 盡量分散，但排不下就擠在一起
```

#### 踩雷 4：HPA 擴容時 routable 資源不足

HPA 把 replica 從 2 拉到 10，但 routable node 只夠放 4 個 → **6 個 Pod 卡在 Pending，而 HPA 不會因此回退**。

`kubectl get hpa` 沒有 `CURRENT`／`DESIRED` 欄位（欄位是 `NAME REFERENCE TARGETS MINPODS MAXPODS REPLICAS AGE`），而且 `REPLICAS` 會把 Pending 的 Pod 也算進去，所以會顯示 10，看不出卡住。要看 `kubectl get deploy` 的 `READY`（例如 `4/10`），或 `kubectl describe hpa` 裡的「Deployment pods: X current / Y desired」。

**修法**：
- 給需要 routable 的服務設一個**符合實際容量的 `maxReplicas`**
- 或重新檢視「這個服務真的需要 routable 嗎」——多數情況下答案是不需要（見 13.3）

#### 踩雷 5：`nodeSelector` 和 `nodeAffinity` 同時存在

兩個都寫的話是 **AND**（必須同時滿足），不是覆蓋。很容易寫出永遠無解的條件：

```yaml
      nodeSelector:
        network: routable
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: network
                    operator: In
                    values: ["internal"]     # ⚠ 跟上面矛盾，永遠 Pending
```

**建議：擇一使用。** 需要彈性就只用 `nodeAffinity`，簡單情況就只用 `nodeSelector`。

> **延伸閱讀**：Deployment 其他排程相關設定（`podAntiAffinity`、`topologySpreadConstraints`、`priorityClassName`）見 [Part 6](#part-6六種常用-kind-詳解) 的 6.1；為什麼 ingressgateway 一定要 routable 見 [Part 10](#part-10istio-ingressgateway-與一般-service-的差別含雙-vip-架構)。

### 參考來源

- Kubernetes — Virtual IPs and Service Proxies：https://kubernetes.io/docs/reference/networking/virtual-ips/
- Kubernetes — Deployments：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes — Taints and Tolerations：https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes — Pod Topology Spread Constraints：https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — HPA Walkthrough：https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/
- github.com/kubernetes — taint_toleration.go（release-1.34）：https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/scheduler/framework/plugins/tainttoleration/taint_toleration.go

---

## Part 14：保留人工 pilot run 的 Canary 發布

> **可直接 apply 的完整 manifest 在 `canary-manual/` 目錄**，本節說明設計原理與取捨。
> 給驗證人員的操作說明在 `canary-manual/pilot-run-guide.md`。

### 14.1 這是在解決什麼問題

Part 7 的權重分流 canary 有一個對「人工簽核流程」致命的缺陷：

> **權重分流無法保證 pilot 使用者看到新版本。**

設 5% 權重的意思是「每個請求有 5% 機率進 canary」。所以請使用者做 pilot run 時：

- 他登入時可能進 stable、下一個請求進 canary、再下一個又回 stable
- 因為 in-memory session 的關係，他會**不斷被踢回 Keycloak 重新登入**
- 就算他順利操作完，你**也無法確定他到底驗證了哪一版**

**這正是「權重分流」與「人工驗證」在設計上互相衝突的地方**：權重分流是為了「降低出錯時的影響範圍」而設計的（機率性、逐請求），人工驗證需要的是「確定性」（這個人從頭到尾都在新版）。

### 14.2 解法：用 cookie 指定，而不是用權重

```
   正式使用者 ─────────────────────▶ stable（舊版，權重 100）
                                       ▲
   pilot 使用者                        │  簽核通過後
   （帶 canary=always cookie）         │  才把 canary 的 image 升為 stable
        └─────────────────────────▶ canary（新版，權重 0）
```

**關鍵性質：canary 的正式流量權重永遠是 0。**

這帶來三個好處：

| | 權重分流 canary | **cookie 指定** |
|---|---|---|
| pilot 使用者保證看到新版 | **不能** | **能，100% 確定** |
| 驗證期間對正式使用者的風險 | 有（5% 真的進新版） | **零** |
| 使用者驗到一半被切回舊版 | 會 | 不會 |
| canary 掛掉的影響 | 5% 使用者受影響 | **完全沒有影響** |
| 適合人工簽核 | 不適合 | **適合** |

### 14.3 命名採「固定 stable / canary」而不是版本號

Part 7.2 用的是 `v1` / `v2` 命名。那個模式的問題是**每次發布都要改四個地方**：新增 Deployment、改 DestinationRule 的 subset、改 VirtualService 的 subset 名稱、清掉舊的 Deployment。

固定命名的模式改成：

| | 版本號累加（Part 7.2） | **固定 stable/canary（本節）** |
|---|---|---|
| Deployment 名稱 | `...-v1`、`...-v2`、`...-v3`… | 永遠是 `...-stable`、`...-canary` |
| 每次發布要改 | Deployment + DR + VS | **只改 canary 的 image tag** |
| DestinationRule | 每次要加 subset | **永遠不動** |
| VirtualService | 每次要改 subset 名稱 | **永遠不動** |
| 舊資源清理 | 要記得刪 | 不會累積 |
| 適合寫成 SOP | 不適合（每次不一樣） | **適合（每次一模一樣）** |

pod label 用 `version: stable` / `version: canary`：這是 Istio 的標準 label，會成為 metrics 的 `destination_version`，所以 Prometheus 查詢可以直接用它區分兩軌。

**promote 的動作 = 把 stable 的 image 改成 canary 現在跑的那一版**，然後 canary 縮到 0。下次發布時 canary 再被拉起來裝更新的版本。

### 14.4 完整 manifest

以下五份就是這套機制的全部，用 `ea-pmc` 的真實名稱寫成，可以直接複製修改。
**內容與 `canary-manual/track-a/` 的檔案完全相同** —— 那邊是可直接 `kubectl apply` 的版本，這裡是方便閱讀的版本，改動時請兩邊一起改。

#### 四層 label 串接（先看懂這張圖，後面的 YAML 就都通了）

這是整套機制最容易接錯、也最難除錯的地方。接錯的症狀是 **503 且 access log 的 `response_flags` 是 `UH`**，沒有任何明確的錯誤訊息告訴你哪裡錯。

```
  ① Deployment 的 pod template label
     ┌──────────────────────────────┐        ┌──────────────────────────────┐
     │ app:     pmc-epmmformquerygui│        │ app:     pmc-epmmformquerygui│
     │ version: stable              │        │ version: canary              │
     └───────┬──────────────┬───────┘        └───────┬──────────────┬───────┘
             │              │                        │              │
             │              └────────┬───────────────┘              │
             │                       │                              │
  ② Service selector （只比對 app，所以兩軌的 pod 都被選中）          │
             │              ┌────────▼────────┐                     │
             │              │ selector:       │                     │
             │              │   app: pmc-...  │  ← 沒有 version！    │
             │              └─────────────────┘                     │
             │                                                      │
  ③ DestinationRule subset （用 version 把 Service 切成兩半）        │
     ┌───────▼───────────────┐                    ┌─────────────────▼──────┐
     │ - name: stable        │                    │ - name: canary         │
     │   labels:             │                    │   labels:              │
     │     version: stable   │                    │     version: canary    │
     └───────┬───────────────┘                    └─────────────────┬──────┘
             │                                                      │
  ④ VirtualService 用 subset 名稱決定流量去哪一軌                     │
     ┌───────▼───────────────┐                    ┌─────────────────▼──────┐
     │ subset: stable        │                    │ subset: canary         │
     │ weight: 100           │                    │ 只有帶 cookie 的人      │
     └───────────────────────┘                    └────────────────────────┘
```

**四個最常見的接錯方式：**

| 錯誤 | 症狀 |
|---|---|
| Service 的 selector 多寫了 `version` | 只選到一軌，另一個 subset 沒有 endpoint → **503 `UH`** |
| DestinationRule 的 `labels` 跟 pod label 不一致 | subset 選不到 pod → **503 `UH`** |
| VirtualService 的 `subset` 名稱打錯 | 找不到 cluster → **503 `NC`** |
| DestinationRule 的 `host` 跟 VirtualService 的 `destination.host` 不一致 | subset 定義形同不存在 → **503** |

驗證指令：

```bash
# subset 有沒有對應到 pod（兩個 subset 都要有 endpoint）
istioctl proxy-config endpoint deploy/pmc-epmmformquerygui-stable -n ea-pmc \
  --cluster "outbound|8080|canary|pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local"
```

---

#### 1. ServiceAccount + Deployment（stable）

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pmc-epmmformquerygui
  namespace: ea-pmc
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pmc-epmmformquerygui-stable      # 名稱固定，永遠不帶版本號
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
    version: stable
spec:
  replicas: 2
  revisionHistoryLimit: 5
  progressDeadlineSeconds: 600
  minReadySeconds: 15

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0                  # 更新期間不減少可用數

  selector:
    matchLabels:
      app: pmc-epmmformquerygui
      version: stable                    # 建立後不可修改

  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui        # ← Service 用這個選中
        version: stable                  # ← DestinationRule 用這個分 subset
      annotations:
        checksum/config: "REPLACE_WITH_SHA256_OF_CONFIGMAP"
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      serviceAccountName: pmc-epmmformquerygui
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 60

      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: pmc-epmmformquerygui
              version: stable

      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.2.3     # promote 時改這一行
          imagePullPolicy: IfNotPresent

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

          envFrom:
            - secretRef:
                name: pmc-epmmformquery-secret
          env:
            - name: SPRING_CONFIG_ADDITIONAL_LOCATION
              value: "file:/app/config/application.yml"
            - name: APP_TRACK
              value: "stable"                                 # log 裡可分辨自己是哪一軌
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name

          resources:
            requests: { memory: "512Mi", cpu: "250m" }
            limits:   { memory: "1Gi",   cpu: "1000m" }

          startupProbe:                                       # 給 Spring Boot 慢啟動用
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            failureThreshold: 30
            periodSeconds: 10                                 # 最多給 300 秒

          readinessProbe:                                     # 失敗 = 移出 endpoint
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3

          livenessProbe:                                      # 失敗 = 重啟，要比 readiness 遲鈍
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3

          lifecycle:
            preStop:
              exec:
                # 等 endpoint 從所有 sidecar 移除，消除滾動更新期間的零星 502
                command: ["/bin/sh", "-c", "sleep 10"]

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
            - name: tmp                                       # readOnlyRootFilesystem 的配套
              mountPath: /tmp

      volumes:
        - name: config
          configMap:
            name: pmc-epmmformquery-config
        - name: tmp
          emptyDir: {}
```

---

#### 2. Deployment（canary）

**跟 stable 只差三處**：`name`、`version` label、`replicas`。其餘完全一樣。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pmc-epmmformquerygui-canary     # 差異 1
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
    version: canary                     # 差異 2
spec:
  replicas: 1                           # 差異 3 —— 必須是 1，理由見 14.5 前提 1
  revisionHistoryLimit: 3
  progressDeadlineSeconds: 600
  minReadySeconds: 15

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

  selector:
    matchLabels:
      app: pmc-epmmformquerygui
      version: canary

  template:
    metadata:
      labels:
        app: pmc-epmmformquerygui
        version: canary
      annotations:
        checksum/config: "REPLACE_WITH_SHA256_OF_CONFIGMAP"
        proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'
    spec:
      serviceAccountName: pmc-epmmformquerygui
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 60

      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: your-registry/pmc-epmmformquerygui:1.3.0     # 每次要測的新版改這裡
          imagePullPolicy: IfNotPresent

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

          envFrom:
            - secretRef:
                name: pmc-epmmformquery-secret
          env:
            - name: SPRING_CONFIG_ADDITIONAL_LOCATION
              value: "file:/app/config/application.yml"
            - name: APP_TRACK
              value: "canary"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name

          resources:
            requests: { memory: "512Mi", cpu: "250m" }
            limits:   { memory: "1Gi",   cpu: "1000m" }

          startupProbe:
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            failureThreshold: 30
            periodSeconds: 10

          readinessProbe:
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /gui_epmmFormQuery/actuator/health
              port: 8080
            periodSeconds: 30
            timeoutSeconds: 5
            failureThreshold: 3

          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 10"]

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]

          volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
            - name: tmp
              mountPath: /tmp

      volumes:
        - name: config
          configMap:
            name: pmc-epmmformquery-config
        - name: tmp
          emptyDir: {}
```

---

#### 3. Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pmc-epmmformquerygui-svc
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
spec:
  type: ClusterIP
  selector:
    app: pmc-epmmformquerygui     # 【關鍵】只寫 app，不要寫 version
                                  # 寫了 version 就只會選到一軌，另一個 subset
                                  # 會沒有 endpoint → 503（response_flags: UH）
  ports:
    - name: http                  # 【關鍵】cookie 比對是 L7 功能，
      port: 8080                  #         沒命名 Istio 可能用 L4 處理而靜默失效
      targetPort: 8080
      protocol: TCP
      appProtocol: http           # 比 port 命名更明確，兩個都寫最保險

  # 【不要加 sessionAffinity: ClientIP】
  # 它在 mesh 內不生效（sidecar 直送 pod IP，繞過 kube-proxy），見 Part 6.2。
  # 要黏著請用下面 DestinationRule 的 consistentHash。
```

---

#### 4. DestinationRule

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: pmc-epmmformquerygui-dr
  namespace: ea-pmc
spec:
  # 【關鍵】要跟 VirtualService 的 destination.host 完全一致
  host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local

  trafficPolicy:                  # 兩個 subset 共用的預設策略
    loadBalancer:
      consistentHash:             # 取代失效的 Service.sessionAffinity
        httpCookie:
          name: JSESSIONID        # Spring Boot 的 session cookie
          ttl: 10800s

    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 3s
      http:
        http1MaxPendingRequests: 100
        maxRequestsPerConnection: 0

    outlierDetection:             # 熔斷：連續出錯的 pod 自動踢出負載平衡
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50      # 最多踢一半，避免全部被踢光

  subsets:
    - name: stable                # ← VirtualService 用這個名字
      labels:
        version: stable           # ← 要跟 Deployment 的 pod label 一致

    - name: canary
      labels:
        version: canary

      # canary 若要開超過 1 個 replica，解開這段，
      # 否則 pilot 使用者會在多個 canary pod 之間跳而被登出
      # trafficPolicy:
      #   loadBalancer:
      #     consistentHash:
      #       httpCookie: { name: JSESSIONID, ttl: 10800s }
```

---

#### 5. VirtualService（整套機制的核心）

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: app-routing
  namespace: ea-pmc
spec:
  hosts:
    - myapp.example.com                                     # 外部進來的 host
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local     # 【關鍵】內部呼叫的 host
  gateways:
    - istio-system/my-gateway
    - mesh                                                  # 【關鍵】理由見 14.6

  http:
    # =========================================================================
    # 規則 1：PILOT RUN —— 帶 cookie 的人走 canary
    # 【順序至關重要】match 是 first-match-wins，這條一定要在最前面
    # =========================================================================
    - name: pilot-run
      match:
        - headers:
            cookie:
              # 精準比對，避免誤中 xcanary=always 之類的名稱，理由見 14.8
              regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: canary
            port:
              number: 8080
      headers:
        response:
          set:
            x-app-track: "canary"      # pilot 使用者在 F12 看得到，見 14.7
      timeout: 15s
      retries:
        attempts: 3
        perTryTimeout: 4s
        retryOn: "5xx,reset,connect-failure"

    # =========================================================================
    # 規則 2：正式流量 —— 全部走 stable
    # =========================================================================
    - name: primary
      match:
        - uri: { prefix: /gui_epmmFormQuery/ }
        - uri: { exact: /gui_epmmFormQuery }
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: stable
            port:
              number: 8080
          weight: 100                  # pilot run 期間永遠 100
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: canary
            port:
              number: 8080
          weight: 0                    # 永遠 0，這就是「零風險」的來源
      headers:
        response:
          set:
            x-app-track: "stable"
      timeout: 15s
      retries:
        attempts: 3
        perTryTimeout: 4s
        retryOn: "5xx,reset,connect-failure"

    # =========================================================================
    # 規則 3：catch-all —— 沒有 match，全部命中，一定放最後
    # 【不能省略】加了 mesh 之後，內部呼叫若打到 match 沒涵蓋的路徑
    #             會因為找不到 route 而 404（response_flags: NR），見 14.6
    # =========================================================================
    - name: default
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: stable
            port:
              number: 8080
```

---

#### 套用順序

```bash
NS=ea-pmc

# 先建身分與網路設定，再建 workload
kubectl -n $NS apply -f serviceaccount.yaml
kubectl -n $NS apply -f service.yaml
kubectl -n $NS apply -f destinationrule.yaml
kubectl -n $NS apply -f virtualservice.yaml
kubectl -n $NS apply -f deployment-stable.yaml
kubectl -n $NS apply -f deployment-canary.yaml

# 平時 canary 不用跑，縮到 0
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0

# 套用前先驗語法（不會真的建立資源）
kubectl -n $NS apply --dry-run=server -f ./
```

### 14.5 三個必須注意的前提

#### 前提 1：canary 必須只有 1 個 replica

你的 app 用 in-memory `HttpSession`，而 `sessionAffinity: ClientIP` 在 Istio 下不生效（Part 6.2）。canary 若開 2 個 pod，**pilot 使用者的請求會在兩個 canary pod 之間跳，一樣會被登出**——cookie 只保證他進 canary 這一軌，不保證進哪一個 pod。

開 1 個 pod 是最簡單可靠的解法。真的需要多個 canary pod 時，必須在 canary subset 上加 `consistentHash`。

#### 前提 2：Service 的 port 一定要命名

cookie 比對是 **L7 功能**。Service 的 port 沒有 `name: http` / `appProtocol: http` 時，Istio 可能用 L4 處理這個 port，**cookie 路由會直接失效而且沒有錯誤訊息**——症狀是「帶了 cookie 還是進 stable」。

這就是 Part 9 發現 4 為什麼要修。

#### 前提 3：VirtualService 必須含 `mesh`，且 `hosts` 要包含內部 FQDN

沒有 `mesh` 的話，cluster 內部呼叫會繞過整條 VirtualService，在 stable 和 canary 的 pod 之間**隨機分配**——以 stable 2 個 pod、canary 1 個 pod 計算，**約三分之一的內部流量會打到未經驗證的 canary**，而且這個比例不會出現在任何權重設定裡。

**機制與完整說明見下一節 14.6**（這是本章最容易被忽略、後果也最嚴重的一項），對應 Part 9 發現 3。

### 14.6 為什麼 VirtualService 一定要加 mesh

這句話在本文件出現過好幾次，但一直只講「不加會出事」。這一節解釋**機制**——為什麼會出事、出什麼事、以及加了之後要注意什麼。

#### 一、`gateways` 欄位的三種狀態

| 你怎麼寫 | 這條 VirtualService 套用到誰 |
|---|---|
| **完全不寫 `gateways`** | 預設值是 `["mesh"]` —— **只**套用到 sidecar（= 內部流量） |
| `gateways: [istio-system/my-gateway]` | **只**套用到那個 gateway。**sidecar 完全不包含** |
| `gateways: [istio-system/my-gateway, mesh]` | 兩者都套用 |

`mesh` 是 Istio 的**保留字**，意思是「mesh 內的所有 sidecar」。

最反直覺的是中間那一列：**一旦你列了任何一個 gateway，預設的 `mesh` 就消失了**，必須自己加回去。很多人以為 `gateways` 是「額外再加上 gateway」，其實是「整個換掉」。

你原本的設定正是這一種：

```yaml
spec:
  hosts: [myapp.example.com]
  gateways: [istio-system/my-gateway]     # ← 沒有 mesh，內部流量完全不受管
```

#### 二、沒有 `mesh` 時，內部呼叫實際走什麼路

假設 `ea-pmc` 裡另一個服務打 `pmc-epmmformquerygui-svc:8080`：

```
  ① 呼叫方 pod 發出請求
        ↓
  ② 被自己的 sidecar 攔截（iptables 導向 port 15001）
        ↓
  ③ sidecar 找「適用於 mesh、而且 hosts 包含這個目的地」的 VirtualService
        ↓
     找不到（因為 gateways 只寫了 my-gateway）
        ↓
  ④ 退回該 Service 的「預設路由」
        ↓
  ⑤ 對這個 Service 的【所有 endpoint】做 round-robin
        ↓
     而 Service 的 selector 是 app: pmc-epmmformquerygui
     ——它同時選中了 stable 和 canary 的 pod
        ↓
  ⑥ 內部流量隨機打到 canary
```

關鍵在第 ⑤ 步：**沒有 VirtualService 告訴 sidecar 要選哪個 subset，它就把整個 Service 的 endpoint 當成一個池子平均分配。** DestinationRule 定義了 subset，但「要用哪個 subset」是 VirtualService 的職責——沒有 VirtualService，subset 等於不存在。

#### 三、對這套 canary 設計是致命的

整章的核心保證是：**canary 的正式流量權重是 0，所以 pilot run 期間零風險。**

沒有 `mesh`，這個保證**只對走 gateway 的流量成立**。內部呼叫完全繞過那個 `weight: 0`。

用你的實際配置算一次：

| | pod 數 | 內部流量分配 |
|---|---:|---:|
| stable | 2 | 約 67% |
| **canary** | **1** | **約 33%** |

**內部流量有三分之一會打到未經驗證的 canary。** 這比你刻意設 5% 權重還糟糕，而且：

- 它**不會出現在任何權重設定裡**——你看 VirtualService 只會看到 `weight: 0`
- 它**完全在你的控制之外**——比例是由 pod 數量決定的，你調 canary 到 2 個 pod 就變 50%
- 它**沒有任何警告**

#### 四、`hosts` 是配對的另一半，光加 `mesh` 沒用

這是第二個容易漏的地方。sidecar 是用「**目的地 host**」去比對 VirtualService 的 `hosts` 清單。

內部呼叫的目的地是 `pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local`（短名 `pmc-epmmformquerygui-svc` 也會被 sidecar 正規化成這個 FQDN）。如果 `hosts` 只有 `myapp.example.com`：

```yaml
spec:
  hosts:
    - myapp.example.com          # ← 內部呼叫的 host 不是這個
  gateways:
    - istio-system/my-gateway
    - mesh                       # ← 加了也沒用，因為 hosts 比對不到
```

**兩者必須成對出現：**

```yaml
spec:
  hosts:
    - myapp.example.com                                   # 給 gateway 流量
    - pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   # 給 mesh 內部流量
  gateways:
    - istio-system/my-gateway
    - mesh
```

#### 五、一起失效的不只是 canary

沒有 `mesh` 時，這條 VirtualService 上的**所有** L7 設定對內部呼叫都不生效：

| 設定 | 內部呼叫吃得到嗎 |
|---|:---:|
| `route` 的 subset 選擇與 `weight` | 不行 |
| `timeout` | 不行（退回 Istio 預設：不逾時） |
| `retries` | 不行 |
| `headers`（請求/回應改寫） | 不行 |
| `rewrite` / `redirect` | 不行 |
| `fault`（故障注入） | 不行 |
| `mirror`（流量鏡射） | 不行 |
| `corsPolicy` | 不行 |

所以如果你發現「明明設了 15 秒逾時，內部呼叫卻掛了好幾分鐘」，第一個要檢查的就是 `gateways` 有沒有 `mesh`。

#### 六、哪些「不」受影響（避免過度恐慌）

這也是常見誤解——不是所有 Istio 功能都需要 VirtualService：

| 項目 | 沒有 `mesh` 時 | 為什麼 |
|---|:---:|---|
| **DestinationRule 的 `trafficPolicy`** | **照樣生效** | DR 綁的是 host，不需要 VirtualService。所以 `consistentHash`、`connectionPool`、`outlierDetection` 對內部呼叫仍然有效 |
| **DestinationRule 的 `subsets` 定義** | 定義存在，但沒人用 | subset 的「選擇」是 VirtualService 的職責 |
| **PeerAuthentication（mTLS）** | **照樣生效** | 那是連線層的事，跟路由無關 |
| **AuthorizationPolicy** | **照樣生效** | 同上 |
| **kubelet 的 liveness / readiness probe** | **不受影響** | probe 是直接打 pod，不經過 mesh 路由 |

換句話說：**安全管控不受影響，流量治理全部失效。**

#### 七、誰算「內部呼叫方」

對照你的環境，這些都會受影響：

- `ea-pmc` 裡的另外兩個 GUI 服務（FormEdit / FormRender），如果它們會互相呼叫
- **Prometheus 抓 metrics**（如果 Prometheus 有 sidecar）
- CronJob / 批次任務
- `ea-epmm` 或其他 namespace 打過來的服務
- 你自己 `kubectl exec` 進某個有 sidecar 的 pod 做的測試 ← **這一點很重要**：你在 cluster 內部 curl 測試 canary，測到的結果可能跟真實外部流量完全不同

#### 八、加上 `mesh` 之後要注意的副作用

加了之後，內部流量**開始套用 `match` 規則**——這是好事，但也帶來一個新風險：

如果你的 `match` 只涵蓋 `/gui_epmmFormQuery/`，而某個內部呼叫打的是別的路徑（例如直接打 `/actuator/health` 而沒有 context path），它會**找不到任何 route 而 404**，access log 的 `response_flags` 是 `NR`（No Route）。

**這就是 14.4 的 VirtualService 裡那條 `default` route 存在的理由：**

```yaml
    - name: default
      route:                          # 沒有 match = 全部命中
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: stable
```

它是安全網，**不能省略**。而且因為 match 是 first-match-wins，它一定要放在最後（見 Part 6.6 踩雷 2）。

> **導入建議**：如果你現在的 VirtualService 還沒有 `mesh`，加上去之前**先確認 `match` 涵蓋得夠完整、而且有 catch-all**，否則內部呼叫可能從「隨機但會通」變成「404」。建議先在測試環境驗一輪。

#### 九、怎麼驗證 `mesh` 真的生效

```bash
# 【方法 1】看某個 mesh 內的 pod 有沒有拿到這條 route
istioctl proxy-config route deploy/pmc-epmmformquerygui-stable -n ea-pmc --name 8080 -o json \
  | grep -A5 pmc-epmmformquerygui-svc
# 看得到 pilot-run / primary / default 三條 = mesh 生效
# 只看到一條預設的 = 沒生效

# 【方法 2】最直接：從 mesh 內部 curl，看 x-app-track 回什麼
kubectl -n ea-pmc run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -sS -o /dev/null -D - \
  http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health \
  | grep -i x-app-track
# 有 x-app-track: stable = mesh 生效（因為那個 header 是 VirtualService 加的）
# 完全沒有這個 header  = 沒生效，內部流量繞過了 VirtualService

# 【方法 3】看這個 pod 適用哪些 VirtualService
istioctl x describe pod -n ea-pmc <pod-name>
```

> **方法 2 是最快的自我檢查**：那個 `x-app-track` header 只有 VirtualService 會加。內部 curl 拿不到它，就代表內部流量根本沒經過這條 VirtualService。

#### 十、一句話總結

> **`gateways` 列了 gateway 就會踢掉預設的 `mesh`；沒有 `mesh`，內部流量會繞過所有路由規則，直接對 Service 的全部 endpoint 做 round-robin —— 包含你正在測試的 canary。**
>
> 而且 `hosts` 必須同時包含內部的 FQDN，兩者缺一不可。

### 14.7 讓 pilot 使用者能「自證」在新版上

光是切過去不夠，**使用者要能確認自己真的在 canary 上**，否則可能白測一輪。

用 VirtualService 的 response header 做，**不需要改任何程式碼**：

```yaml
    - name: pilot-run
      match:
        - headers:
            cookie:
              regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"
      route:
        - destination:
            host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
            subset: canary
      headers:
        response:
          set:
            x-app-track: "canary"      # ← 使用者在 F12 Network 分頁看得到
```

stable 那條路由也設 `x-app-track: "stable"`，這樣兩種狀態都有明確訊號，而不是「有 header = canary、沒 header = 不確定」。

### 14.8 cookie 的比對要精準

```yaml
# ❌ 太寬鬆：xcanary=always 或 mycanary=always2 都會誤中
              regex: ".*canary=always.*"
```

```yaml
# ✅ 用完整的分隔符比對
              regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"
```

cookie header 的格式是 `a=1; b=2; c=3`，所以要比對「字串開頭或前面有 `; `」以及「字串結尾或後面接 `;`」。

### 14.9 兩種實作方式

> **完整的逐欄位差異對照、兩份可照做的 SOP、以及兩種 track 之間怎麼切換**，見 [Part 15](#part-15兩種上版方式的完整對照與-sop)。

| | **Track A：兩個 Deployment** | **Track B：Argo Rollouts** |
|---|---|---|
| 需要安裝 | **不用** | Argo Rollouts controller + CLI |
| 人工閘門 | **天生就是**（沒人執行 promote 就不會前進） | `pause: {}` + `promote` 指令 |
| 流量切換 | 你自己 `kubectl` | Argo 自動改 VirtualService |
| promote | 把 stable 的 image 改成 canary 的 | `kubectl argo rollouts promote` |
| 之後要加自動化 | 要重寫 | **直接加 `analysis` step 即可** |

**建議先用 Track A。** 它零安裝，而且「人工閘門」是天然的——沒有人做事，就永遠不會有正式使用者看到新版本。這比任何機制都可靠。

**⚠ 兩軌互斥**：Rollout 會自己管理 ReplicaSet，同時存在 Deployment 的話兩個 controller 會互搶 pod。切換前必須先刪掉 Track A 的兩個 Deployment。

#### Track B 的兩個容易漏掉的設定

```yaml
      trafficRouting:
        managedRoutes:
          - name: pilot-run          # 【必要】沒宣告的話 setHeaderRoute 不會生效
        istio:
          virtualService:
            name: app-routing
            routes:
              - primary              # 【必要】VirtualService 裡要有這個名字的 route
```

還有一個：`setCanaryScale: { replicas: 1 }` 之後，**必須在放量前加上 `setCanaryScale: { matchTrafficWeight: true }`**，否則 canary 會一直卡在 1 個 pod，等一下切 100% 流量過去會把單一 pod 打爆。

### 14.10 完整流程速查

```bash
NS=ea-pmc

# 【1】新版部署到 canary（正式流量完全不受影響）
kubectl -n $NS set image deploy/pmc-epmmformquerygui-canary \
  app=your-registry/pmc-epmmformquerygui:1.3.0
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=1
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-canary

# 【2】驗證 cookie 路由有效（別跳過）
kubectl -n $NS run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -sS -o /dev/null -D - -H "Cookie: canary=always" \
  http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
# 期望看到 x-app-track: canary

# 【3】把 pilot-run-guide.md 發給驗證人員，等簽核

# 【4-a】通過 → promote
kubectl -n $NS set image deploy/pmc-epmmformquerygui-stable \
  app=your-registry/pmc-epmmformquerygui:1.3.0
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-stable
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0

# 【4-b】不通過 → 關掉 canary（使用者完全無感）
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0

# 【5】promote 後才發現問題 → 回退
kubectl -n $NS rollout undo deploy/pmc-epmmformquerygui-stable
```

`canary-manual/scripts/canary.sh` 把這些包成 `deploy` / `verify` / `status` / `promote` / `rollback` / `undo` 六個指令。

### 14.11 這套流程未來怎麼演進

本節保留了人工閘門，Part 12 講的是完全自動化。**兩者不是對立的，是同一條路上的兩個位置**：

```
  現在（Part 14）          下一步                    最終（Part 12）
  ─────────────────       ─────────────────         ─────────────────
  cookie 指定 canary  →   cookie 指定 canary    →   cookie 指定 canary
  人工 pilot run          人工 pilot run             自動 smoke test
                          + 自動 smoke test          + 指標分析
                            （兩者比對）              失敗自動回滾
  人工 promote            人工 promote               自動 promote
```

**中間那一步是關鍵**：讓機器跟人同時驗，累積「機器判斷 vs 人工判斷」的比對紀錄。每次「人抓到但機器沒抓到」就把那個檢查補進測試。跑個 5~10 次發布之後，那張比對表就是你說服主管拿掉人工閘門的證據。

而 `pilot-run-guide.md` 裡要求驗證人員**具體寫下第 6 項測了什麼**，就是在為這一步收集素材——那些答案就是第一版自動化測試的內容。

> **延伸閱讀**：權重分流的做法見 [Part 7](#part-7canary-發布與自動擴縮容)；完全自動化的做法見 [Part 12](#part-12用-argo-rollouts-取代人工-pilot-run)；本節依賴的三個前提見 [Part 9](#part-9你目前環境的具體發現) 的發現 2、3、4。
---

## Part 15：兩種上版方式的完整對照與 SOP

> Part 14 是 **Track A**（兩個 Deployment，人工 pilot run）
> Part 12 是 **Track B**（Argo Rollouts，可人工也可自動）
> 這一章把兩者攤開比較，並給兩份可以直接照做的 SOP。
>
> **如果你的 CD 只能 `kubectl apply`（不能下 scale / patch / rollout undo），直接看 15.8 起。**
> 15.4 / 15.5 是有完整 kubectl 權限時的版本；15.8–15.13 是純 apply 也能運作的版本。

### 15.1 先講一個現實限制

你說想「同時保有兩套，看情況選」。這個目標是對的，但有一個必須先講清楚的限制：

> **同一個服務，不能這次發布用 Track A、下次發布用 Track B。**

原因是兩者的資源型別不同、而且互斥：

| | Track A | Track B |
|---|---|---|
| 誰管理 pod | 兩個 **Deployment** controller | 一個 **Rollout** controller |
| 同時存在會怎樣 | **兩個 controller 互相搶 pod** —— Deployment 想維持自己的 ReplicaSet，Rollout 也想，結果 pod 反覆被建立和刪除 | |

切換 track 要「刪掉 Deployment、建立 Rollout」（或反過來），這中間有**服務中斷的風險**，不是可以每週來一次的操作。

**所以「看情況選」要換個方式達成 —— 見下一節。**

---

### 15.2 兩種可行的「同時保有兩套」

#### 做法一：不同服務用不同 track

最單純。例如：

| 服務 | 用哪個 track | 理由 |
|---|---|---|
| `pmc-epmmformquerygui`（使用者天天用的 GUI） | **Track A** | 改動影響大，堅持人工 pilot run |
| `epmm-api`（內部 API，沒有 UI） | **Track B** | 沒有畫面要看，指標判斷就夠 |
| 批次 / CronJob | 都不用 | 不是常駐服務 |

各自獨立，互不影響。缺點是團隊要維護兩套 SOP。

#### 做法二：同一個服務用 Track B，靠 steps 設計出兩種節奏（推薦）

**這是唯一能對同一個服務「看情況選」的做法。**

關鍵洞察：Argo Rollouts 的閘門是寫在 `steps` 裡的，而**同一個 Rollout 可以同時具備人工閘門和自動判斷**——差別只在「你怎麼推進它」：

```yaml
      steps:
        - setCanaryScale: { replicas: 1 }
        - setHeaderRoute:                      # 開 cookie 路由給 pilot 使用者
            name: pilot-run
            match:
              - headerName: cookie
                headerValue:
                  regex: "^(.*;\\s*)?canary=always(\\s*;.*)?$"
        - analysis:                            # 機器先驗一輪
            templates: [{ templateName: success-rate-safe }]
        - pause: {}                            # ← 人工閘門，無限期等
        - setHeaderRoute: { name: pilot-run }
        - setCanaryScale: { matchTrafficWeight: true }
        - setWeight: 100
```

有了這一份 Rollout，**兩種節奏都能跑，而且不用改任何 YAML**：

| 情境 | 你怎麼做 | 實際發生什麼 |
|---|---|---|
| **平常（要 pilot run）** | 等 pilot 使用者簽核 → `promote` | 機器先驗指標，人再驗功能，兩關都過才上 |
| **緊急修補（沒時間等人）** | 直接 `promote --full` | 跳過所有剩餘 step，指標仍然跑過了 |
| **夜間 / 週末（沒人在）** | 把 `pause: {}` 那行拿掉再 apply | 全自動，失敗自動回滾 |

**`promote --full` 是關鍵**：它跳過所有剩餘的 step 直接全量，但**前面已經跑完的 analysis 仍然生效**——所以你不是「完全沒驗證」，只是「跳過人工那一關」。

> **建議**：如果你確定未來要走自動化（Part 12.7 的四階段），**直接上 Track B 並保留 `pause: {}`**。這樣基礎設施一次到位，之後要放寬只是拿掉一行，不用再做一次 track 切換。

---

### 15.3 YAML 逐項差異對照

這是你問的「兩邊 YAML 差在哪」。

#### 資源清單對照

| 資源 | Track A | Track B |
|---|---|---|
| **ConfigMap** | 2 份（版本化） | 2 份（版本化） |
| **workload** | **Deployment ×2**（`-stable` / `-canary`） | **Rollout ×1** |
| **Service** | **1 個**（`-svc`） | **2 個**（`-stable` / `-canary`）+ 可選的 `-svc` |
| **DestinationRule** | **1 份**（含 `subsets`） | **2 份**（無 `subsets`，只有 `trafficPolicy`） |
| **VirtualService** | 1 份（你自己維護 3 條 route） | 1 份（**Argo 會改它**，你只寫 2 條 route） |
| **AnalysisTemplate** | 不需要 | 需要（用指標判斷時） |
| 檔案總數 | 5 | 6 |

#### 逐欄位差異

| 項目 | Track A | Track B | 為什麼不同 |
|---|---|---|---|
| **workload kind** | `Deployment` ×2 | `Rollout` ×1 | Argo 用一份 template 產生兩組 ReplicaSet |
| **pod label `version`** | **要寫**（`stable` / `canary`） | **不要寫** | Argo 自己用 `rollouts-pod-template-hash` 區分 |
| **`replicas` 怎麼控制 canary** | canary Deployment 寫 `replicas: 1` | Rollout 的 `setCanaryScale: {replicas: 1}` | Track B 由 steps 控制，不是靜態欄位 |
| **ConfigMap 命名** | 版本化（也可用 `-stable`/`-canary`） | **只能版本化** | Argo 單一 template 的架構限制（見 12.11） |
| **Service selector** | 只寫 `app`（兩軌都選中） | 只寫 `app`（Argo 動態補 hash） | Track A 靠 DR subset 分軌；Track B 靠 Service 分軌 |
| **DR 有沒有 `subsets`** | **有**（`stable` / `canary`） | **沒有** | Track B 用兩個 Service 就分開了，不需要 subset |
| **DR 份數** | 1（綁 `-svc`） | 2（各綁一個 Service） | DR 是綁 host 的 |
| **VS 的 `destination.host`** | 都指 `-svc`，用 `subset` 區分 | 分別指 `-stable` / `-canary` 兩個 Service | 同上 |
| **VS route 數量** | **3 條**（`pilot-run` / `primary` / `default`） | **2 條**（`primary` / `default`） | `pilot-run` 由 Argo 動態插入 |
| **cookie 路由誰建** | **你自己寫在 VS 裡**（常駐） | **Argo 動態建立/移除**（`setHeaderRoute`） | Track B 只在 canary 期間存在 |
| **VS route 要不要 `name`** | 不強制（但建議） | **`primary` 是必要的** | Argo 靠名字找到要改的 route |
| **`managedRoutes`** | 不存在 | **必須宣告** | 沒宣告 `setHeaderRoute` 不生效 |
| **權重誰改** | 你手動 `kubectl patch` | **Argo 自動改** | |
| **promote 機制** | 改 stable Deployment 的 image + ConfigMap 引用 | `kubectl argo rollouts promote` | |
| **回滾機制** | `kubectl rollout undo` / 縮 canary 到 0 | `kubectl argo rollouts abort` / `undo` | |
| **失敗自動回滾** | **沒有**（要人發現) | **有**（analysis 失敗自動 abort） | |

#### 同樣的部分（可以直接沿用，不用改）

- **ConfigMap 的內容**：完全一樣
- **pod template 的內容**：probe、resources、securityContext、preStop、volumes 完全一樣，可以整段複製
- **ServiceAccount**：同一個
- **Secret**：同一個
- **cookie 的名稱與 regex**：`canary=always` 與 `^(.*;\\s*)?canary=always(\\s*;.*)?$`
- **VirtualService 的 `hosts` 與 `gateways`**（含 `mesh`）
- **`canary` 只開 1 個 replica 的理由**：in-memory session（見 14.5 前提 1）

---

### 15.4 Track A 的 SOP（人工 pilot run）

> **⚠ 這一版用了 `kubectl scale` / `patch` / `rollout undo`。如果你的 CD 只能 `kubectl apply`（例如公司管控的 Azure release pipeline），直接跳到 15.10。**

> 可列印版在 `canary-manual/SOP.md`。

#### 【前置檢查】只在第一次、或改過網路設定後做

```bash
NS=ea-pmc
```

| # | 檢查 | 指令 | 通過的樣子 |
|---|---|---|---|
| 1 | Service port 有命名 | `kubectl -n $NS get svc pmc-epmmformquerygui-svc -o jsonpath='{.spec.ports}'` | 看得到 `"name":"http"` 與 `"appProtocol":"http"` |
| 2 | VS 有 `mesh` | `kubectl -n $NS get vs app-routing -o jsonpath='{.spec.gateways}'` | 陣列裡有 `mesh` |
| 3 | 兩個 subset 都有 endpoint | `kubectl -n $NS get endpoints pmc-epmmformquerygui-svc` | 有 IP 清單 |
| 4 | sidecar 有注入 | `kubectl -n $NS get pods -l app=pmc-epmmformquerygui -o jsonpath='{.items[0].spec.containers[*].name}'` | 看得到 `istio-proxy` |

---

#### 【步驟 1】建立新版本的 ConfigMap

```bash
VER=1.3.0
# 從上一版複製後修改，或直接寫新的
kubectl -n $NS apply -f configmap-$VER.yaml
kubectl -n $NS get cm pmc-epmmformquery-config-$VER
```

**確認成功**：`kubectl get cm` 看得到 `pmc-epmmformquery-config-1.3.0`。

> ⚠ ConfigMap 設了 `immutable: true`，如果內容要改**必須換版本號**，不能改既有的。

---

#### 【步驟 2】把新版部署到 canary

```bash
kubectl -n $NS patch deploy pmc-epmmformquerygui-canary --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
   \"value\":\"your-registry/pmc-epmmformquerygui:$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
   \"value\":\"pmc-epmmformquery-config-$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
   \"value\":\"$VER\"}
]"
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=1
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-canary --timeout=10m
```

或用腳本：`./canary.sh deploy 1.3.0`（它會一次處理 image + ConfigMap + annotation 三處）

**確認成功**：`rollout status` 顯示 `successfully rolled out`，且

```bash
kubectl -n $NS get pods -l app=pmc-epmmformquerygui -L version
# canary 那個 pod 是 Running 2/2（app + istio-proxy）
```

**此時的狀態**：正式流量 100% 在 stable，**canary 完全沒有正式流量**。

---

#### 【步驟 3】驗證 cookie 路由真的有效（不要跳過）

```bash
kubectl -n $NS run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- sh -c '
  echo "--- 不帶 cookie ---"
  curl -sS -o /dev/null -D - \
    http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
  echo "--- 帶 cookie ---"
  curl -sS -o /dev/null -D - -H "Cookie: canary=always" \
    http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
'
```

**確認成功**：第一次回 `x-app-track: stable`，第二次回 `x-app-track: canary`。

**沒過的話**：見 14.6 與 `canary-manual/README.md` 的排查表。**這一步沒過就不要往下走**，否則 pilot 使用者驗的其實是舊版。

---

#### 【步驟 4】請使用者做 pilot run

1. 把 `canary-manual/pilot-run-guide.md` 發給驗證人員
2. 請他們**先做步驟 2 的自證**（F12 看 `x-app-track: canary`）再開始驗
3. 等他們回填驗證清單

**期間你可以看**：

```bash
kubectl -n $NS logs -l version=canary -c app --tail=100 -f
kubectl -n $NS top pod -l version=canary
```

---

#### 【步驟 5a】簽核通過 → promote

```bash
kubectl -n $NS patch deploy pmc-epmmformquerygui-stable --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
   \"value\":\"your-registry/pmc-epmmformquerygui:$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
   \"value\":\"pmc-epmmformquery-config-$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
   \"value\":\"$VER\"}
]"
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-stable --timeout=15m
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0
```

或：`./canary.sh promote`

> **⚠ 這裡是「分開 ConfigMap」最容易出錯的地方**：promote 要同時換 **image 和 ConfigMap 引用**。只換 image 的話，新版程式會配到舊版設定 —— 如果新版需要 `app.export.*` 那些新設定，啟動就會失敗或行為異常。腳本會一起處理，手動做的話**兩個都不能漏**。

**確認成功**：

```bash
kubectl -n $NS get deploy -l app=pmc-epmmformquerygui \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
# stable 的 IMAGE 和 CONFIG 都要是新版
```

---

#### 【步驟 5b】簽核不通過 → 關掉 canary

```bash
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0
```

**使用者完全無感** —— 因為正式流量本來就沒有進 canary。

---

#### 【步驟 6】promote 之後才發現問題 → 回退

```bash
kubectl -n $NS rollout undo deploy/pmc-epmmformquerygui-stable
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-stable
```

> `rollout undo` 會把 image **和** ConfigMap 引用一起還原（因為它還原的是整個 pod template），這是版本化 ConfigMap 的另一個好處。

---

#### 【步驟 7】清理舊 ConfigMap（每月一次即可）

```bash
# 列出所有版本，保留最近 3 個
kubectl -n $NS get cm -l app=pmc-epmmformquerygui \
  --sort-by=.metadata.creationTimestamp -o name
```

或：`./canary.sh cleanup`

---

### 15.5 Track B 的 SOP（Argo Rollouts）

> **⚠ 這一版用了 `kubectl argo rollouts` 指令。只能 apply 的環境請看 15.12 —— 那裡說明為什麼 `promote` 碰不到，以及可行的替代方案。**

#### 【前置檢查】

```bash
NS=ea-pmc
RO=pmc-epmmformquerygui
```

| # | 檢查 | 指令 | 通過的樣子 |
|---|---|---|---|
| 1 | Argo Rollouts 有裝 | `kubectl get crd rollouts.argoproj.io` | 找得到 |
| 2 | CLI 外掛有裝 | `kubectl argo rollouts version` | 印出版本 |
| 3 | Prometheus 可達 | `kubectl -n $NS run t --rm -i --restart=Never --image=curlimages/curl -- curl -s http://prometheus.istio-system:9090/-/healthy` | 回 `Prometheus is Healthy` |
| 4 | VS 有名為 `primary` 的 route | `kubectl -n $NS get vs app-routing -o jsonpath='{.spec.http[*].name}'` | 看得到 `primary` |
| 5 | 前置檢查 1、2、4 同 Track A | | |

---

#### 【步驟 1】建立新版本的 ConfigMap

同 Track A 步驟 1。

---

#### 【步驟 2】改 Rollout 觸發發布

```bash
VER=1.3.0
kubectl -n $NS patch rollout $RO --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
   \"value\":\"your-registry/pmc-epmmformquerygui:$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
   \"value\":\"pmc-epmmformquery-config-$VER\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
   \"value\":\"$VER\"}
]"
```

**確認成功**：

```bash
kubectl -n $NS argo rollouts get rollout $RO --watch
```

會看到它自動走 step：`setCanaryScale` → `setHeaderRoute` → 停在 `analysis` 或 `pause`。

---

#### 【步驟 3】觀察 analysis 結果

```bash
# 看 analysis 跑得怎麼樣
kubectl -n $NS get analysisrun --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n $NS describe analysisrun <名稱>
```

| Phase | 意思 | 接下來 |
|---|---|---|
| `Running` | 還在量 | 等（預設跑 5 分鐘） |
| `Successful` | 指標通過 | 自動進到下一個 step |
| `Failed` | 指標不通過 | **已經自動回滾了**，去看 log 查原因 |
| `Inconclusive` | 沒有資料 | **卡住等人**，多半是流量太少或 query 寫錯 |

---

#### 【步驟 4】pilot run（如果 steps 裡有 `pause: {}`）

同 Track A 步驟 3、4：先驗 cookie 路由，再請使用者驗。

**Track B 的 cookie 路由是 Argo 動態插入的**，所以驗證前先確認它真的插進去了：

```bash
kubectl -n $NS get vs app-routing -o jsonpath='{.spec.http[*].name}'
# 應該看得到 pilot-run（canary 期間才有）
```

---

#### 【步驟 5a】簽核通過 → promote

```bash
kubectl -n $NS argo rollouts promote $RO           # 前進一步（跳過當前 pause）
kubectl -n $NS argo rollouts get rollout $RO --watch
```

**緊急情況跳過所有剩餘步驟**：

```bash
kubectl -n $NS argo rollouts promote $RO --full
```

**確認成功**：`kubectl argo rollouts get rollout $RO` 顯示 `Status: ✔ Healthy`，且 canary 與 stable 的 revision 相同。

---

#### 【步驟 5b】簽核不通過 → abort

```bash
kubectl -n $NS argo rollouts abort $RO
```

流量立刻切回 stable，canary pod 在 `abortScaleDownDelaySeconds`（30 秒）後縮掉。

---

#### 【步驟 6】promote 之後才發現問題 → undo

```bash
kubectl -n $NS argo rollouts undo $RO
kubectl -n $NS argo rollouts get rollout $RO --watch
```

---

#### 【隨時可用的緊急煞車】

```bash
kubectl -n $NS argo rollouts pause   $RO    # 暫停在當前 step
kubectl -n $NS argo rollouts abort   $RO    # 立刻回滾
kubectl -n $NS argo rollouts status  $RO    # 目前狀態
kubectl -n $NS argo rollouts get rollout $RO --watch   # 即時看進度
```

---

### 15.6 什麼情況用哪一套

| 情況 | 建議 | 理由 |
|---|---|---|
| 改了使用者看得到的畫面 / 流程 | **人工 pilot run** | 指標看不出「按鈕跑版」「欄位順序錯了」 |
| 只改後端邏輯，介面沒動 | 指標判斷就夠 | 成功率和延遲抓得到 |
| 改了資料庫 schema | **人工 + 額外準備回滾腳本** | 兩者都救不了資料問題 |
| 緊急修補（線上正在出事） | Track B 的 `promote --full` | 指標仍會跑，只跳過人工那關 |
| 夜間 / 週末發布 | Track B 全自動 | 沒人待命時自動回滾比叫人起床可靠 |
| 改動很小（改個文字、調個參數） | 指標判斷 | 人工驗證的邊際效益太低 |
| 第一次用新的發布機制 | **人工，而且要有人盯著** | 先建立對機制本身的信任 |
| 有人待命 | 兩者皆可 | |
| 沒人待命 | **只能自動**（或不要發） | 人工閘門沒人按，canary 會一直掛著 |
| **CD 只能 `kubectl apply`** | **Track A**（見 15.8–15.13） | 權重與 replicas 都在你自己的 YAML 裡，沒有 controller 跟你搶 |

> **一個實用的判斷法**：問「如果這次改壞了，指標抓得到嗎？」
> - 抓得到（5xx 變多、變慢）→ 自動判斷就夠
> - 抓不到（畫面跑版、算錯數字但 HTTP 200）→ **必須人工驗**

---

### 15.7 兩種 track 之間的切換

#### Track A 遷移到 Track B

**前置**：Argo Rollouts 已安裝，且 Track B 的所有 manifest 都準備好了。

```bash
NS=ea-pmc

# 【1】先記錄現在跑的是什麼版本（切換出問題時要用）
kubectl -n $NS get deploy pmc-epmmformquerygui-stable \
  -o custom-columns='IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'

# 【2】先建立 Track B 需要的新資源（此時還不影響任何流量）
kubectl -n $NS apply -f track-b/00-configmap.yaml
kubectl -n $NS apply -f track-b/02-services.yaml
kubectl -n $NS apply -f track-b/04-destinationrule.yaml
kubectl -n $NS apply -f track-b/05-analysistemplate.yaml

# 【3】把 VirtualService 換成 Track B 版本
#     此時 destination 指向 -stable Service，但那個 Service 還沒有 endpoint
#     ⚠ 這一步會造成短暫的 503，所以要在低流量時段做
kubectl -n $NS apply -f track-b/03-virtualservice.yaml

# 【4】立刻建立 Rollout（越快越好，讓 -stable Service 有 endpoint）
kubectl -n $NS apply -f track-b/01-rollout.yaml
kubectl -n $NS argo rollouts get rollout pmc-epmmformquerygui --watch

# 【5】確認 Rollout 的 pod 起來、Service 有 endpoint 了
kubectl -n $NS get endpoints pmc-epmmformquerygui-stable

# 【6】最後才刪掉舊的 Deployment
kubectl -n $NS delete deploy pmc-epmmformquerygui-stable pmc-epmmformquerygui-canary
```

> **⚠ 步驟 3~5 之間會有服務中斷**（VirtualService 已經指向新 Service，但 Rollout 的 pod 還沒起來）。
>
> **想避免中斷的做法**：把步驟 4 提前到步驟 3 之前 —— 先讓 Rollout 把 pod 跑起來（此時新舊 pod 並存，但 VirtualService 還指著舊的），確認 `-stable` Service 有 endpoint 之後，再切 VirtualService。代價是短時間內 pod 數量翻倍，要確認資源夠。

**切換後的驗證清單：**

```bash
# 1. Rollout 是 Healthy
kubectl -n $NS argo rollouts status pmc-epmmformquerygui

# 2. 兩個 Service 都有 endpoint（canary 在非發布期間可以是空的）
kubectl -n $NS get endpoints pmc-epmmformquerygui-stable pmc-epmmformquerygui-canary

# 3. 從外部打得通
curl -sS -o /dev/null -w "%{http_code}\n" https://myapp.example.com/gui_epmmFormQuery/

# 4. 舊的 Deployment 真的沒了
kubectl -n $NS get deploy -l app=pmc-epmmformquerygui
```

#### Track B 退回 Track A

如果 Argo Rollouts 用不順手要退回去，把上面的順序反過來：

```bash
# 【1】先建 Deployment（用 Rollout 目前跑的 image 和 ConfigMap）
kubectl -n $NS apply -f track-a/01-deployment-stable.yaml
kubectl -n $NS apply -f track-a/02-deployment-canary.yaml
kubectl -n $NS scale deploy/pmc-epmmformquerygui-canary --replicas=0

# 【2】等 stable Deployment 的 pod 就緒
kubectl -n $NS rollout status deploy/pmc-epmmformquerygui-stable

# 【3】建 Track A 的 Service 與 DestinationRule
kubectl -n $NS apply -f track-a/03-service.yaml
kubectl -n $NS apply -f track-a/04-destinationrule.yaml

# 【4】切 VirtualService
kubectl -n $NS apply -f track-a/05-virtualservice.yaml

# 【5】最後刪 Rollout
kubectl -n $NS delete rollout pmc-epmmformquerygui
```

> **這個方向比較安全**，因為步驟 1~2 先讓新 pod 就緒，切 VirtualService 時後端已經備妥。

#### 切換時最容易出錯的三件事

| 錯誤 | 症狀 | 預防 |
|---|---|---|
| 兩個 controller 並存 | pod 反覆被建立刪除 | **一定要刪乾淨再建**，用 `kubectl get deploy,rollout -l app=...` 確認 |
| VirtualService 指向還沒有 endpoint 的 Service | 503 `UH` | 先讓 pod 就緒，再切 VS |
| ConfigMap 引用漏改 | 新版程式配舊版設定 | 切換前先確認 `configMap.name` 對得上 |

> **延伸閱讀**：Track A 的完整 manifest 見 [Part 14](#part-14保留人工-pilot-run-的-canary-發布) 的 14.4；Track B 的見 [Part 12](#part-12用-argo-rollouts-取代人工-pilot-run) 的 12.11；`mesh` 為什麼必要見 14.6。
---

### 15.8 CD 只能 apply 時的限制對照

前面 15.4 / 15.5 的 SOP 假設你可以下 `kubectl scale`、`patch`、`rollout undo`、`argo rollouts promote`。**如果你的 CD 綁在只能 `kubectl apply` 的 pipeline（例如公司管控的 Azure release pipeline），那些指令一個都用不了。**

這一節之後（15.8–15.13）是**完全不依賴那些指令**的版本。

#### 先分清楚兩件事

| | pipeline（CD） | 你本人 |
|---|---|---|
| 能做什麼 | **只有 `kubectl apply`** | `get` / `describe` / `logs`（唯讀） |
| 用途 | **改變狀態** | **驗證狀態** |

所以後面的 SOP 分成兩種區塊：

- **【改動】** = 編輯 YAML → commit → pipeline apply
- **【驗證】** = 你自己下唯讀指令確認（pipeline 不需要這些）

#### 四件做不到的事與對應做法

| 做不到 | 影響 | apply-only 的做法 |
|---|---|---|
| `kubectl scale` | 開關 canary 沒辦法用指令 | **`replicas` 寫死在 YAML**，改 replicas = 改檔案 + apply |
| `kubectl rollout undo` | 沒有一鍵回滾 | **回滾 = 把 YAML 改回上一版**，**Git 歷史就是你的回滾機制**（15.11） |
| `kubectl delete` | 舊 ConfigMap 清不掉 | 接受累積 + 定期請有權限的人清（15.11） |
| `kubectl argo rollouts promote` | Track B 的人工閘門推不動 | `promote` 改的是 **`status`**，apply 只能改 **`spec`** → 改用 `spec.paused`（15.12） |

#### 一個容易忽略的連鎖影響：replicas 與 HPA 會打架

`replicas` 寫在 YAML 裡，每次 apply 就會把 HPA 調好的數字打回去。所以兩個 Deployment 要分開處理：

| | 寫不寫 `replicas` | 能不能接 HPA |
|---|---|---|
| **canary** | **一定要寫**（靠它開關 0 / 1） | **不能** |
| **stable** | 要接 HPA 的話**省略這個欄位** | 可以 |

省略 `replicas` 的話，`kubectl apply` 不會管這個欄位，HPA 設定的值就保留得住。這跟 Part 7.5 的建議一致，只是這裡多一層：**canary 因為要當開關，注定不能接 HPA**。

---

### 15.9 檔案分層：base 與 release

apply-only 的第一個工程決定是：**把「每次發布都要改的檔」跟「幾乎不動的檔」分開**。

```
canary-manual/
├── track-a/
│   ├── base/                        建置時 apply 一次，之後只有網路/身分設定變更才動
│   │   ├── 00-serviceaccount.yaml
│   │   ├── 01-service.yaml
│   │   ├── 02-destinationrule.yaml
│   │   └── 03-virtualservice.yaml
│   └── release/                     每次發布都要改、都要 apply
│       ├── 10-configmap-1.2.3.yaml      ← 舊版，保留（回滾要用）
│       ├── 10-configmap-1.3.0.yaml      ← 每次發布「新增」一個檔
│       ├── 20-deployment-stable.yaml
│       └── 21-deployment-canary.yaml
└── track-b/
    ├── base/
    │   ├── 00-serviceaccount.yaml
    │   ├── 01-services.yaml
    │   ├── 02-destinationrule.yaml
    │   ├── 03-virtualservice.yaml       ← ⚠ Argo 會改它，絕不能進 release 流程
    │   └── 04-analysistemplate.yaml
    └── release/
        ├── 10-configmap-1.2.3.yaml
        └── 20-rollout.yaml
```

#### 為什麼一定要分

| 理由 | 說明 |
|---|---|
| **避免誤觸網路設定** | 每次發布都 apply VirtualService，一個手滑就改到路由規則，影響所有使用者 |
| **pipeline 設定更單純** | release stage 的檔案清單固定就是 `release/`，不用維護一長串路徑 |
| **Track B 是硬性要求** | Argo 會動態改 VirtualService 的 weight 並插入 `pilot-run` route。**發布途中 apply 它會把權重打回 100/0，直接中斷 canary** |

#### 檔名編號的意義

| 編號 | 意義 |
|---|---|
| `00-` ~ `09-` | base：身分、網路 |
| `10-` | release：ConfigMap（每版一個檔） |
| `20-` ~ `29-` | release：workload（Deployment / Rollout） |

`kubectl apply -f release/` 會按檔名排序套用，所以 **ConfigMap（10-）一定在 workload（20-）之前**建立 —— 這個順序是必要的，否則 Pod 會因為找不到 ConfigMap 而卡在 `ContainerCreating`。

---

### 15.10 Track A 的 apply-only SOP

**這是 apply-only 環境的主線流程。** 假設目前線上跑的是 `1.2.3`，要發布 `1.3.0`。

> 【改動】= 編輯 YAML → commit → pipeline apply
> 【驗證】= 你自己下唯讀指令

#### 起始狀態（repo 裡的樣子）

```yaml
# release/20-deployment-stable.yaml
  image: your-registry/pmc-epmmformquerygui:1.2.3
  configMap.name: pmc-epmmformquery-config-1.2.3
  config-version: "1.2.3"
  replicas: 2
```

```yaml
# release/21-deployment-canary.yaml
  image: your-registry/pmc-epmmformquerygui:1.2.3
  configMap.name: pmc-epmmformquery-config-1.2.3
  config-version: "1.2.3"
  replicas: 0          ← canary 平時是關的
```

---

#### 步驟 1【改動】新增 1.3.0 的 ConfigMap

**新增檔案** `release/10-configmap-1.3.0.yaml`（不要改 1.2.3 那份，它設了 `immutable: true`，而且回滾要用）：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pmc-epmmformquery-config-1.3.0
  namespace: ea-pmc
  labels:
    app: pmc-epmmformquerygui
    config-version: "1.3.0"
immutable: true
data:
  application.yml: |
    # ...（從 1.2.3 複製後修改）...
    app:
      context-prefix: /gui_epmmFormQuery

      # 1.3.0 新增的設定
      export:
        enabled: ${EXPORT_ENABLED:true}
        max-rows: ${EXPORT_MAX_ROWS:50000}
```

---

#### 步驟 2【改動】把 canary 指向新版並打開

編輯 `release/21-deployment-canary.yaml`，**三處版本號 + replicas 共四個地方**：

```diff
 spec:
-  replicas: 0
+  replicas: 1                      # ← 打開 canary
   template:
     metadata:
       annotations:
-        config-version: "1.2.3"
+        config-version: "1.3.0"    # ← 三處之一
     spec:
       containers:
         - name: app
-          image: your-registry/pmc-epmmformquerygui:1.2.3
+          image: your-registry/pmc-epmmformquerygui:1.3.0    # ← 三處之二
       volumes:
         - name: config
           configMap:
-            name: pmc-epmmformquery-config-1.2.3
+            name: pmc-epmmformquery-config-1.3.0             # ← 三處之三
```

> **⚠ 最常見的失誤：只改了 image，忘了 ConfigMap。**
> 新版程式會配到舊版設定 —— 如果新版需要 `app.export.*` 那些新設定，啟動就會失敗或行為異常。
> **commit 前用 `grep` 自己檢查一次**：
> ```bash
> grep -n '1\.3\.0\|1\.2\.3' release/21-deployment-canary.yaml
> ```
> 應該看到三個 `1.3.0`，沒有殘留的 `1.2.3`。

**commit 並讓 pipeline apply `release/`。**

**【驗證】**

```bash
NS=ea-pmc
# canary pod 起來了，而且三處都是新版
kubectl -n $NS get deploy -l app=pmc-epmmformquerygui -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
```

**此時狀態**：正式流量 100% 在 stable，**canary 沒有任何正式流量**。

---

#### 步驟 3【驗證】確認 cookie 路由有效

```bash
kubectl -n $NS run t --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- sh -c '
  echo "--- 不帶 cookie ---"
  curl -sS -o /dev/null -D - \
    http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
  echo "--- 帶 cookie ---"
  curl -sS -o /dev/null -D - -H "Cookie: canary=always" \
    http://pmc-epmmformquerygui-svc.ea-pmc:8080/gui_epmmFormQuery/actuator/health | grep -i x-app-track
'
```

期望：第一次 `stable`，第二次 `canary`。

> `kubectl run` 需要建立 Pod 的權限。如果你只有純唯讀權限，改用瀏覽器驗證：
> 開 `https://myapp.example.com/gui_epmmFormQuery/`，F12 → Network → 看 `x-app-track`；
> 再照 `pilot-run-guide.md` 種 cookie，重整，確認變成 `canary`。

---

#### 步驟 4 請使用者做 pilot run

把 `canary-manual/pilot-run-guide.md` 發給驗證人員，等回填的驗證清單。

**【驗證】**期間觀察：

```bash
kubectl -n $NS logs -l version=canary -c app --tail=100 -f
```

---

#### 步驟 5a【改動】簽核通過 → promote

編輯**兩個**檔案：

**(1) `release/20-deployment-stable.yaml`** —— 改同樣的三處：

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

**(2) `release/21-deployment-canary.yaml`** —— 關掉 canary：

```diff
 spec:
-  replicas: 1
+  replicas: 0
```

> **canary 的三處版本號留在 1.3.0 不用改回去** —— 它已經關了，下次發布時再一起改成 1.4.0。

**commit 並 apply `release/`。**

**【驗證】**

```bash
kubectl -n $NS get deploy -l app=pmc-epmmformquerygui -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
# stable 的 IMAGE 和 CONFIG 都要是 1.3.0，READY 要等於 replicas

kubectl -n $NS get pods -l app=pmc-epmmformquerygui -L version
# 應該只剩 stable 的 pod
```

> **stable 的滾動更新是 K8s 自動做的**（`maxUnavailable: 0` + `maxSurge: 1`），
> 不需要也不能下 `kubectl rollout status`。要看進度就用 `kubectl get pods -w`。

---

#### 步驟 5b【改動】簽核不通過 → 關掉 canary

只改一個地方：

```diff
 # release/21-deployment-canary.yaml
 spec:
-  replicas: 1
+  replicas: 0
```

commit + apply。**使用者完全無感** —— 正式流量本來就沒進 canary。

---

#### 操作對照總表

| 操作 | 改哪個檔 | 改什麼 | apply |
|---|---|---|---|
| **部署到 canary** | 新增 `10-configmap-<新版>.yaml`<br>改 `21-deployment-canary.yaml` | 三處版本號 + `replicas: 0` → `1` | `release/` |
| **promote** | 改 `20-deployment-stable.yaml`<br>改 `21-deployment-canary.yaml` | 三處版本號<br>`replicas: 1` → `0` | `release/` |
| **canary 不通過** | 改 `21-deployment-canary.yaml` | `replicas: 1` → `0` | `release/` |
| **promote 後回滾** | `git revert` | 見 15.11 | `release/` |
| **改網路設定** | `base/` 底下的檔 | 依需求 | **`base/`**（單獨的 stage） |

---

### 15.11 回滾完全靠 Git

apply-only 沒有 `kubectl rollout undo`，所以**回滾就是「把 YAML 改回上一版再 apply」**。要讓這件事可靠，發布流程必須綁在 Git 上。

#### 發布 = 一個 commit

建議每次發布開一個 PR，commit message 帶版本號：

```
release: pmc-epmmformquerygui 1.3.0 to canary
release: promote pmc-epmmformquerygui 1.3.0 to stable
```

這樣 `git log --oneline release/` 就是你的發布歷史。

#### 回滾 = revert 那個 commit

```bash
# 找出 promote 的 commit
git log --oneline -- release/20-deployment-stable.yaml

# revert 它（會把三處版本號改回 1.2.3）
git revert <commit-sha>
git push
```

然後重跑 pipeline apply `release/`。

**revert 的好處**：它把 image 和 ConfigMap 引用**一起**改回去，不會發生「只回滾了 image、設定還是新版」的半吊子狀態。

#### ⚠ 最重要的警告：舊 ConfigMap 絕對不能刪

revert 之後 `20-deployment-stable.yaml` 會引用回 `pmc-epmmformquery-config-1.2.3`。
**如果那份 ConfigMap 已經從 cluster 刪掉了，Pod 會卡在 `ContainerCreating`，而你回不去了。**

```
   刪掉舊 ConfigMap  ==  毀掉回滾能力
```

**保留數量必須 ≥ 你可能回滾的深度。** 建議至少保留 3 個版本。

#### 那 ConfigMap 累積怎麼辦

apply-only 沒有 `kubectl delete`，三個選項：

| 做法 | 評價 |
|---|---|
| **接受累積**（推薦） | ConfigMap 很小（幾 KB），一年幾十個對 etcd 完全無感。**這是最安全的選項** |
| 定期請有權限的人清 | 每季一次，保留最近 5 個版本。要有明確的「不能刪最近 3 個」規則 |
| `kubectl apply --prune -l app=...` | **不建議**。prune 會刪掉「不在這次 apply 檔案裡、但帶有該 label」的所有資源 —— label 寫錯或檔案漏帶就會誤刪正在用的東西 |

> **建議直接選第一個。** 為了省幾 KB 而讓自己失去回滾能力，是很糟的交易。

---

### 15.12 Track B 在 apply-only 下的限制與解法

#### 限制一：`promote` 碰不到（這是硬限制）

```
  kubectl argo rollouts promote  →  改的是 Rollout 的 status.pauseConditions
  kubectl apply                  →  只能改 spec
```

**`status` 是 subresource，`apply` 送不進去。** 所以 `steps` 裡的 `pause: {}` 在 apply-only 環境下**推不動** —— rollout 會永遠卡在那一步。

#### 可行解法：改用 `spec.paused`

`spec.paused` 是 **spec 欄位**，apply 改得到：

```diff
 spec:
   replicas: 2
-  paused: false
+  paused: true          # 暫停，等人驗證
```

流程變成：

| 階段 | 改什麼 | apply 後的效果 |
|---|---|---|
| 1. 發布 | image + ConfigMap 三處，`paused: true` | Rollout 起 canary 但暫停 |
| 2. 驗證 | 不改任何東西 | pilot run |
| 3. 推進 | `paused: true` → `false` | 繼續走完剩下的 steps |
| 4. 中止 | 把三處版本號 revert 回舊版 | Argo 視為新的一次 rollout，回到舊版 |

而且 `steps` 裡**不要**放 `pause: {}`（那個推不動），改成只有 `analysis` 與 `setWeight`。

> **⚠ 這一段必須先在你們環境驗證。**
> `spec.paused` 與 canary `steps` 的互動細節（暫停時機、跟 `setCanaryScale` 的先後、resume 之後從哪一步繼續）我無法替你保證。
> **驗證方式**：在測試環境跑一次完整流程，用 `kubectl -n ea-pmc get rollout pmc-epmmformquerygui -o yaml` 觀察 `status.currentStepIndex` 的變化，確認暫停與繼續的行為符合預期，再用到正式環境。

#### 限制二：VirtualService 不能進 release 流程

Argo 會動態改 VirtualService：改 `primary` route 的 weight、插入與移除 `pilot-run` route。

**發布途中 apply 它，會把權重打回 `100/0`，直接中斷正在進行的 canary。**

所以：
- VirtualService **必須**放在 `base/`
- release stage 的檔案清單**絕不能**包含它
- 用 Argo CD 的話，要設定忽略該資源 weight 欄位的差異

#### 結論：apply-only 環境下 Track A 明顯更適合

| | Track A | Track B |
|---|---|---|
| 權重誰控制 | **你的 YAML** | Argo（會跟 apply 打架） |
| replicas 誰控制 | **你的 YAML** | Argo 的 `setCanaryScale` |
| 人工閘門怎麼推 | **改 `replicas` 就好** | 只能靠 `spec.paused`（需驗證） |
| 回滾 | **git revert** | git revert（但要小心 Argo 的狀態機） |
| 有沒有 controller 跟你搶 | **沒有** | 有 |

**在只能 apply 的環境，Track A 的每一個控制點都在你自己的 YAML 裡，沒有第二個 controller 跟你搶控制權。** 這是決定性的優勢。

**建議**：apply-only 就用 Track A。等到 pipeline 能跑指令了（或導入 Argo CD 的 UI promote）再考慮 Track B。

---

### 15.13 Azure Pipeline 的設定建議

> 我不知道你們 pipeline 的實際設定，這一節是「建議的形狀」與「該去問什麼」。

#### 建議切成三個 stage

| Stage | 何時跑 | apply 什麼 | 誰核准 |
|---|---|---|---|
| **validate** | 每次 PR | `--dry-run=server -f release/` | 自動 |
| **deploy-release** | 每次發布 | `release/` | 發布負責人 |
| **deploy-base** | **手動觸發**，很少跑 | `base/` | 需要多一層核准 |

`deploy-base` 一定要跟 `deploy-release` 分開，而且加上額外核准 —— 它會動到 VirtualService 這種「改錯就全體使用者受影響」的資源。

#### validate stage 很值得加

`--dry-run=server` 也是 apply 指令的一部分，通常 pipeline 都做得到：

```bash
kubectl apply --dry-run=server -f release/
```

它會把 YAML 送到 API server 做完整驗證（含 admission webhook），但**不真的建立資源**。可以在 PR 階段就抓出：

- YAML 語法錯誤
- 欄位名稱打錯
- `ports` 寫成數字而不是字串這類型別錯誤
- CRD 沒安裝

#### 該去問平台團隊的三件事

1. **pipeline 用的是哪個 task？**
   - 如果是 `KubernetesManifest@1`，它其實支援 `deploy` / `promote` / `reject` / `scale` / `patch` / `delete` 等 action —— 你可能不只有 apply
   - 如果是 `Kubernetes@1`，可以跑任意 kubectl 指令
   - 問清楚才知道能不能簡化流程

2. **能不能加一個 `--dry-run=server` 的 validate stage？**

3. **能不能把 `base/` 跟 `release/` 拆成兩個 stage，並給 `base/` 額外的核准關卡？**

> **如果問完發現其實可以跑指令**，就回頭用 15.4 / 15.5 那兩份 SOP，操作會簡單很多。
> 這一節（15.8–15.13）是「最壞情況下也能運作」的版本。

---

## Part 16：active zone DNS 下 request 落在哪（FZ2 部好卻 404、用 mesh 送到 FZ2）

### 16.1 這是在解決什麼問題

公司的 DNS 是 **active/standby**：同一個 host（例如 `myapp.example.com`）**永遠只回 active zone 那座 cluster 的 VIP**，要切 zone 時才改回另一邊。

典型的困惑長這樣：

> 我在 FZ2 部好了一整套 —— VirtualService、Service、DestinationRule、Pod 全都有。FZ1 什麼都沒部。打 `https://myapp.example.com/gui_epmmFormQuery/` 卻拿到 **404**。FZ2 明明是好的啊？

答案一句話：**「去哪座 cluster」在 DNS 那一步就決定了，之後 Istio 不會幫你換 cluster。** request 根本沒有到 FZ2，它到的是 FZ1，而 FZ1 的 ingressgateway 不認識這個 host 的路由。

要真的看懂這件事，得先分清楚兩條完全不同的線：

- **資料路徑**（16.2）：封包實際經過哪些東西
- **控制面**（16.3）：每一站的「路由表」是誰、從哪裡讀來填的

### 16.2 資料路徑：封包真正經過什麼

最常見的誤解是把 Gateway / VirtualService / DestinationRule / Service 想成四個依序穿過的「站」。**實際上真正經過的只有 VIP、ingressgateway、目標 Pod 三種東西**，其他都是查表。

```
 [0] 瀏覽器 https://myapp.example.com/gui_epmmFormQuery/
  │
 [1] DNS ── 公司 DNS 只回 active zone 的 VIP
  │         ← 去哪座 cluster 在這一步就定了，之後不會再換
  ▼
 [2] VIP（F5 / LB）
  ▼
 [3] Service: istio-ingressgateway  (ns istio-system, type LoadBalancer)
  │   ← 整條路上「唯一真的經過」的 K8s Service；它是 gateway 的，不是你 AP 的
  ▼
 [4] Pod: istio-ingressgateway（純 Envoy）
  │   在「同一個 Envoy 裡」依序查四張表 —— 不是四個網路跳點：
  │     4a Gateway            這個 port / host / TLS 收不收？
  │     4b VirtualService     host + path → 要送去哪個 destination.host（+ subset）
  │     4c DestinationRule    subset 對到哪些 label 的 Pod、LB 策略、連線池
  │     4d AP 的 Service + Endpoints   destination.host → Pod IP 清單（通訊錄）
  ▼
 [5] 直接連目標 Pod IP（不經過 AP Service 的 ClusterIP，也不經過 kube-proxy）
  ▼
 [6] AP Pod 的 istio-proxy（inbound）：PeerAuthentication(mTLS) → AuthorizationPolicy
  ▼
 [7] Spring Boot :8080（Spring Security / PrivilegeCheckFilter）
```

所以「先到 Service 還是先到 VirtualService」的答案是：

1. **先到 ingressgateway 的 Service**（`istio-system` 那個，不是你的）
2. **再到 ingressgateway 的 Envoy**，在裡面依序套 Gateway → VirtualService → DestinationRule
3. **你 AP 的 Service 從頭到尾不是一跳** —— Envoy 只是拿它當通訊錄，查出 Pod IP 後直接連（Part 1 關鍵觀念一）

**但通訊錄不能沒有。** `canary-manual/track-a/base/03-virtualservice.yaml` 裡寫的 `destination.host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local`，必須在**同一座 cluster** 的 service registry 查得到；查不到，Envoy 就不知道要連去哪（16.4 的 `NC`）。

#### 具體例子：VS 指向 Service 的「名字」，但封包不送到 Service 的 IP

**VS 確實指向你 AP 的 Service** —— `destination.host` 寫的就是 Service 的全名。它沒做的是「把封包送到 Service 的 ClusterIP」。用 repo 的真實物件、配上假設的 IP：

```
03-virtualservice.yaml
  destination.host: pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   ← 你 AP 的 Service 名字
  subset: stable

01-service.yaml  →  pmc-epmmformquerygui-svc
  ClusterIP: 10.96.12.34          ← Service 自己的 IP（總機）
  selector:  app=pmc-epmmformquerygui

K8s 依 selector 自動產生的 Endpoints（通訊錄）：
  172.16.3.21:8080   label version=stable
  172.16.5.8:8080    label version=stable
  172.16.7.40:8080   label version=canary

02-destinationrule.yaml
  subset stable → label version=stable
```

request 到了 ingressgateway 的 Envoy，Envoy 在內部做三步：

```
① 查 VS：/gui_epmmFormQuery/ → 「pmc-epmmformquerygui-svc 的 stable subset」
   對應到 Envoy 內部的 cluster：outbound|8080|stable|pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
② 這個 cluster 的成員 = Service 的 Endpoints ∩ DR subset label（version=stable）
     172.16.3.21 ✔   172.16.5.8 ✔   172.16.7.40 ✗（canary）
③ 依 DR 的 LB 策略挑一個，例如 172.16.5.8，直接建立連線

封包的目的地是 172.16.5.8:8080
10.96.12.34（ClusterIP）從頭到尾沒有出現在封包上
```

**打電話的比喻**：Service 名字是「公司名」，ClusterIP 是「總機」，Pod IP 是「分機」。

- **沒有 Istio**：你撥總機 `10.96.12.34`，kube-proxy（總機小姐）用 iptables DNAT 幫你轉到某一支分機
- **有 Istio**：Envoy 自己翻通訊錄查到分機號碼，**直接撥分機**，從來不撥總機（Part 1 關鍵觀念一）
- **但公司一定要在通訊錄上**：Service 不存在 → Envoy 查不到任何分機 → 503 `NC`

自己驗證（在能連 cluster 的機器上）：

```bash
# 通訊錄：一排 Pod IP
kubectl -n ea-pmc get endpoints pmc-epmmformquerygui-svc

# Envoy 手上有哪些 cluster（一個 Service 會展開成「不分 subset」＋ 每個 subset 各一個）
istioctl proxy-config cluster deploy/istio-ingressgateway -n istio-system \
  --fqdn pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
#   SERVICE FQDN                                        PORT  SUBSET  DIRECTION  TYPE
#   pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   8080  -       outbound   EDS
#   pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   8080  stable  outbound   EDS
#   pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local   8080  canary  outbound   EDS

# stable subset 裡實際有誰 —— 只有 stable，而且都是 Pod IP
istioctl proxy-config endpoint deploy/istio-ingressgateway -n istio-system \
  --cluster "outbound|8080|stable|pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local"
#   ENDPOINT          STATUS
#   172.16.3.21:8080  HEALTHY
#   172.16.5.8:8080   HEALTHY
```

gateway access log 的 `upstream_host` 欄位印出來的也會是 `172.16.5.8:8080`，不是 `10.96.12.34`。VS / DR / Service 三者是用哪些 key 連起來的，見 [Part 0「物件之間怎麼互相找到」](#物件之間怎麼互相找到label名字host-三種連結)。

### 16.3 控制面：表是誰填的 —— 404 的根本原因

16.2 裡 Envoy 查的那四張表，不是 Envoy 自己知道的。是 **istiod 去 watch 本 cluster 的 API server**，把讀到的 Gateway / VS / DR / Service / Endpoints 翻成 Envoy 設定（xDS）推下去。

關鍵在「**本 cluster**」三個字：

```
          FZ1（active）                            FZ2
 ┌───────────────────────────────┐      ┌───────────────────────────────┐
 │ API server                    │      │ API server                    │
 │   Gateway ✔（CD 建的共用 *）  │      │   Gateway ✔                   │
 │   VS ✗  Service ✗  DR ✗       │      │   VS ✔  Service ✔  DR ✔       │
 │   Pod ✗                       │      │   Pod ✔                       │
 │        │ watch                │      │        │ watch                │
 │     istiod（FZ1）             │      │     istiod（FZ2）             │
 │        │ push xDS             │      │        │ push xDS             │
 │   ingressgateway Envoy（FZ1） │      │   ingressgateway Envoy（FZ2） │
 └───────────▲───────────────────┘      └───────────────────────────────┘
             │                                   request 根本沒有來這裡
   DNS: myapp.example.com → FZ1 VIP
```

**兩座 cluster 的 istiod 互不相通**（除非平台組做了 Istio multi-cluster，見 16.6 路線二）。FZ2 的 VirtualService 寫得再完整，FZ1 的 istiod 也看不到它，FZ1 的 Envoy 裡就沒有這個 host 的 route。

所以那個 404 的完整因果是：

```
DNS 回 FZ1 VIP → FZ1 ingressgateway → 共用 wildcard Gateway 收下 host
→ 查 VirtualService：FZ1 沒有任何 VS 宣告 myapp.example.com → 沒有 route → 404（NR）
```

### 16.4 FZ1 缺什麼 → 什麼症狀

前提：**沒有** Istio multi-cluster。request 被 DNS 送進 FZ1。

| FZ1 的狀態 | 使用者看到 | access log `response_flags` |
|---|---|---|
| Gateway 不收這個 host（HTTPS，SNI 對不到任何 server） | TLS handshake 失敗 / 連線被 reset | 通常沒有 log |
| 共用 wildcard Gateway 收了，但**沒有 VS** | **404** ← 你遇到的就是這個 | `NR`（no route） |
| 有 VS，但**沒有 AP Service**，或 VS 指的 subset 在 DR 裡沒定義 | 503 | `NC`（no cluster） |
| VS + Service + DR 都有，但**沒有 Pod**、或 Pod label 跟 subset 對不上 | 503 | `UH`（no healthy upstream） |
| 整套都有 | 200 | `-` |

**結論：在 FZ1 只補一個 VS 是不夠的** —— 404 只會變成 503。FZ1 要嘛有整套（Gateway 收 host + VS + DR + Service + Pod），要嘛靠 16.6 的方式把流量送去 FZ2。

### 16.5 驗證：確認 request 真的落在哪一邊

下面這些要在能連 cluster 的機器上跑：

```bash
# 1. DNS 現在回哪個 IP？
nslookup myapp.example.com

# 2. 跟兩邊 ingressgateway 的 EXTERNAL-IP 對照
kubectl --context=fz1 -n istio-system get svc istio-ingressgateway
kubectl --context=fz2 -n istio-system get svc istio-ingressgateway

# 3. 繞過 DNS，直接打 FZ2 的 VIP
#    成功 = FZ2 本身沒問題，404 是「DNS 把你送進 FZ1」造成的
curl -vk --resolve myapp.example.com:443:<FZ2_VIP> \
  https://myapp.example.com/gui_epmmFormQuery/rs/gui/ping

# 4. FZ1 gateway 的 access log：看到 404 + NR = FZ1 沒有這個 host 的 VS
kubectl --context=fz1 -n istio-system logs deploy/istio-ingressgateway --tail=200 \
  | grep myapp.example.com

# 5. FZ1 的 Envoy 到底有沒有這個 host 的 route（空的 = 沒有）
istioctl --context=fz1 proxy-config route deploy/istio-ingressgateway -n istio-system \
  | grep myapp.example.com
```

> **`curl --resolve` 是測 standby zone 的標準做法。** 想在 FZ2 驗證新部署、又不想動 DNS，就用它。不需要為了「測一下 FZ2」去搭 16.6 的跨 cluster 接力。

### 16.6 用 service mesh 把 FZ1 收到的 request 送到 FZ2 的 Pod

如果真的需要「request 進 FZ1、由 FZ2 的 Pod 處理」，mesh 有兩條路。**兩條的本質完全不同**：路線一是「FZ1 當成一般 client 去打 FZ2 的大門」，路線二是「兩座 cluster 併成同一個 mesh，FZ1 直接看得到 FZ2 的 Pod」。

#### 路線一：VIP 接力（不需要 multi-cluster，就是 Part 5 的模式）

```
 Client
   │ DNS → FZ1 VIP
   ▼
 FZ1 ingressgateway
   │ 共用 Gateway 收 host
   │ FZ1 VS：route 到 ServiceEntry 的 host
   │ FZ1 DR：TLS origination，SNI = myapp.example.com
   ▼
 （出 FZ1，走公司網路）── FZ2 VIP
   ▼
 FZ2 ingressgateway
   │ Gateway → VS → DR（跟外部使用者直接打進 FZ2 是同一條路）
   ▼
 FZ2 Pod
```

FZ1 這邊要放的三份：

```yaml
# FZ1 / ea-pmc
# 1. ServiceEntry：把 FZ2 的大門註冊進 FZ1 的 mesh
#    ⚠ 一定要 STATIC + 寫死 FZ2 VIP。用 resolution: DNS 去解 myapp.example.com
#      的話，公司 DNS 回的是 active zone —— 也就是 FZ1 自己 —— request 會在 FZ1
#      的 ingressgateway 無限繞圈，最後以 timeout 或 503 收場，log 裡看起來像
#      「FZ2 很慢」，完全不會指向 DNS。
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: myapp-fz2-relay
  namespace: ea-pmc
spec:
  hosts:
    - myapp-fz2-relay.internal      # 只在 mesh 內有意義的名字，不需要真的有 DNS record
  location: MESH_EXTERNAL
  resolution: STATIC
  endpoints:
    - address: 10.20.31.40          # FZ2 ingressgateway 的 VIP
  ports:
    - { number: 443, name: https, protocol: HTTPS }
  exportTo: ["."]
---
# 2. DestinationRule：ingressgateway 打 FZ2 時升級成 TLS
#    sni 要填 myapp.example.com —— FZ2 的 Gateway 是靠 SNI 選憑證、選 server 的，
#    填成 relay 的名字會在 FZ2 那邊 handshake 失敗。
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: myapp-fz2-relay
  namespace: ea-pmc
spec:
  host: myapp-fz2-relay.internal
  trafficPolicy:
    tls:
      mode: SIMPLE
      sni: myapp.example.com
---
# 3. VirtualService：FZ1 的 gateway 收到 myapp.example.com 就轉去 FZ2
#    Host header 預設原樣帶過去（仍是 myapp.example.com），所以 FZ2 的
#    Gateway / VS 對得上。不要加 rewrite.authority —— 改掉 Host 之後
#    FZ2 的 VS 會比對不到，又是一個 404。
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: myapp-fz2-relay
  namespace: ea-pmc
spec:
  hosts: ["myapp.example.com"]
  gateways: ["istio-system/<FZ1 共用 Gateway 的名字>"]
  http:
    - route:
        - destination:
            host: myapp-fz2-relay.internal
            port: { number: 443 }
```

**代價**（全部繼承自 Part 5）：

- **身分在 FZ2 的 ingressgateway 斷掉** —— FZ2 Pod 的 sidecar 看到的來源永遠是 FZ2 的 `sa/istio-ingressgateway`，寫 `principals` 的 AuthorizationPolicy 全部要改（Part 5 核心結論）
- **FZ1 仍是單點** —— FZ1 的 ingressgateway 掛了，FZ2 再健康也進不去
- **DNS 切到 FZ2 之後這條就沒作用了** —— 流量直接進 FZ2，FZ1 的 relay VS 沒人打
- 多一次跨機房往返、兩次 TLS
- 如果 Gateway 是 `istio-system` 的共用物件，你的 VS 和 CD 團隊管的其他 VS 會共用同一個 host 空間 —— **同一個 host 被兩份 VS 宣告時，Istio 的合併行為不保證你要的那份贏**

#### 路線二：Istio multi-cluster（multi-primary + multi-network，平台層級）

把 FZ1、FZ2 併成**同一個 mesh**。這時 FZ1 的 istiod 讀得到 FZ2 的 Service / Endpoints，FZ1 的 Envoy 就可以直接把 FZ2 的 Pod 當成自己的 endpoint。

```
 控制面：
   FZ1 istiod ──(remote secret: FZ2 的 kubeconfig)──▶ watch FZ2 API server
   同名、同 namespace 的 Service 視為「同一個服務」，endpoint 合併
     pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
       = FZ1 的 Pod（如果有） + FZ2 的 Pod（經由 FZ2 east-west gateway）

 資料路徑：
   Client → FZ1 VIP → FZ1 ingressgateway（Gateway → VS → DR）
     │ endpoint 是「FZ2 east-west gateway:15443」（因為 FZ2 的 Pod IP 在另一個網路，FZ1 連不到）
     │ mTLS，SNI = outbound_.8080_._.pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local
     ▼
   FZ2 east-west gateway（tls.mode: AUTO_PASSTHROUGH —— 只看 SNI 轉發，不解密）
     ▼
   FZ2 Pod 的 sidecar（mTLS 從 FZ1 ingressgateway 一路到這裡才終止）→ app
```

**前提（缺一不可，全部是平台組的事）：**

1. **共用 root CA** —— 兩邊 istiod 用同一張 root 簽發（`cacerts` secret），否則 FZ2 的 sidecar 不信任 FZ1 送來的憑證
2. **istiod 讀得到對方 API server** —— `istioctl create-remote-secret` 產生的 secret，且網路上 FZ1 → FZ2 API server 要通
3. **east-west gateway** —— 跟 ingressgateway 分開的另一組 gateway，專收跨 cluster 流量（15443）
4. **network label** —— 每座 cluster 標 `topology.istio.io/network`，istiod 才知道「這個 Pod IP 我直接連不到，要走對方的 east-west gateway」
5. **兩邊 istiod 版本要一起升級**

**AP 團隊在 FZ1 要放什麼：**

| 物件 | 要不要 | 說明 |
|---|---|---|
| Gateway | 共用 wildcard 已收就不用 | |
| VirtualService | **要** | FZ1 的 Envoy 收到 host 要知道往哪送 |
| DestinationRule | **要** | subset 定義；要做 failover 就一定要（見下） |
| Service | **建議要**（沒有 Pod 也可以） | ingressgateway 靠 istiod 合併後的 registry，不需要 DNS；但 FZ1 內其他 Pod 呼叫時要靠 kube-dns 解得到這個名字（除非開了 Istio DNS proxying）。官方範例是每座 cluster 都建 Service，以平台實測為準 |
| Deployment / Pod | 不用 | endpoint 來自 FZ2 |

**附帶好處：**

- **身分端到端保留** —— FZ2 Pod 看到的來源是 FZ1 ingressgateway 的 SPIFFE ID（但兩座共用 trust domain 時，`principals` 分不出是哪一座的 ingressgateway）
- **locality failover** —— DR 加 `localityLbSetting` ＋ `outlierDetection`，平常走本 zone，本 zone 的 Pod 掛了才自動送去另一座。**沒有 `outlierDetection` 就不會 failover**，這是最常見的漏設

**這不是 AP 團隊能自己開的東西**，而且 Part 5 附錄講的「mesh 打通 = 信任邊界打通」在這裡一樣成立。先問平台組有沒有（列在文末「需向他人確認」）。

### 16.7 三種做法對照

| | **兩邊都部整套**（Part 11.4） | **路線一：VIP 接力** | **路線二：multi-cluster** |
|---|---|---|---|
| FZ1 要有 Pod 嗎 | 要 | 不用 | 不用 |
| DNS 切到 FZ2 後 | 照常運作 | relay 失去作用 | 照常運作 |
| FZ1 ingressgateway 掛了 | 要等 DNS 切 zone | 服務中斷 | 要等 DNS 切 zone |
| 誰能做 | AP 團隊 | AP 團隊 | **平台組** |
| 來源身分 | 完整 | **斷在 FZ2 gateway** | 完整 |
| in-memory session | 只在切 zone 那一刻被登出 | 同左 | **流量分散到兩邊 Pod 時會被登出**（Part 11.5） |
| 主要成本 | 兩邊設定漂移（11.10） | 多一跳、ServiceEntry 迴圈陷阱 | 憑證、跨 cluster 除錯、版本同步 |

**建議：**

- **在 active/standby DNS 下，正解是兩邊部署逐字相同的整套**。DNS 一切 zone，100% 的流量就換邊，standby 那座必須當下就接得住 —— 這跟「request 能不能繞到另一邊」無關，是「另一邊有沒有準備好」
- **只是想測 FZ2**：用 16.5 的 `curl --resolve`，不要為了測試去搭路線一
- **路線一**只適合短期過渡（例如 FZ1 暫時無法部署），而且要記得它在 DNS 切 zone 後就沒用了
- **路線二**等到真的需要「單一 zone 內 Pod 掛了自動跨 cluster 接手」時再跟平台組談

### 16.8 踩雷

#### 踩雷 1：只在 active zone 補 VS

404 變 503（`NC` 或 `UH`），看起來像「進步了」，其實只是換一種壞法。見 16.4。

#### 踩雷 2：ServiceEntry 用 DNS 解自己的正式 host

`resolution: DNS` ＋ `hosts: [myapp.example.com]` → 公司 DNS 回 active zone = FZ1 → 自己打自己。症狀是 timeout 或 503，**錯誤訊息完全不會提到 DNS**。路線一一律用 `STATIC` 寫死對方 VIP。

#### 踩雷 3：以為 FZ2 部好了就代表 standby 準備好了

standby zone 平常收不到流量，所以它壞掉也沒人發現 —— 直到 DNS 切過去那一刻。**定期用 `curl --resolve` 打一次 standby 的 VIP**，並用 Part 11.10 踩雷 1 的 diff 腳本比對兩邊設定。

#### 踩雷 4：健康檢查沒帶 Host header

不管是 DNS 切 zone 的判斷、還是你自己用 `curl` 打 VIP，沒帶 `Host: myapp.example.com`（或 `--resolve`）時 Gateway 的 hosts 比對不到，會回 404 —— 然後你會誤以為那一邊掛了。見 Part 11.4。

> **延伸閱讀**：入口鏈逐跳的錯誤碼見 [Part 1](#part-1流量入口鏈-vip-到-pod)；跨 cluster 身分斷裂與 JWT 補救見 [Part 5](#part-5獨立-cluster-互打走對方-vip-與-virtualservice)；兩座 cluster 的入口模式與 session 問題見 [Part 11](#part-11fz1-與-fz2-雙-cluster-的入口設計dns-record-放哪)。

---

## 附錄：這份文件之後怎麼轉成 skill

每個 Part 都是獨立可抽出的段落。之後要轉成 Claude Code skill 時，建議這樣拆：

```
.claude/skills/k8s-istio-ops/
├── SKILL.md                          # Part 0 名詞表 + 決策表 + 何時讀哪個 reference
└── references/
    ├── traffic-path.md               # Part 1  流量入口鏈
    ├── namespace-policies.md         # Part 2  四層管控
    ├── rbac-denied-debug.md          # Part 3（最常用，獨立一份）
    ├── cross-namespace.md            # Part 4  同 cluster 跨 ns
    ├── cross-cluster.md              # Part 5 + Part 11（跨 cluster 呼叫 + 雙 cluster 入口設計）
    ├── kind-reference.md             # Part 6  六種 kind
    ├── canary-and-hpa.md             # Part 7  手動 canary + HPA
    ├── progressive-delivery.md       # Part 12 Argo Rollouts 自動化發布
    ├── ingress-and-vip.md            # Part 10 ingressgateway 與雙 VIP
    ├── node-scheduling.md            # Part 13 node 排程與 routable 網段
    └── troubleshooting.md            # Part 8  除錯速查
```

**拆解建議**：

- **Part 5 和 Part 11 合併成一份** —— 兩者都在講「兩座 cluster 之間怎麼辦」，Part 5 是「呼叫對方」、Part 11 是「入口該建幾個」，放一起讀比較完整
- **Part 10 和 Part 13 保持分開但互相引用** —— Part 10 是網路架構、Part 13 是排程機制，觸發情境不同
- **Part 9（環境發現）不要放進 skill** —— 那是這個時間點的稽核結果，會過期。改成一份 issue 清單或 backlog 追蹤
- **Part 3 一定要獨立** —— 這是最高頻的查詢情境，不該埋在大檔案裡

`SKILL.md` 的 description 建議涵蓋的觸發詞：`RBAC: access denied`、`AuthorizationPolicy`、`VirtualService 404`、`Istio 503`、`canary`、`Argo Rollouts`、`HPA`、`跨 namespace`、`跨 cluster`、`ingressgateway`、`routable`、`nodeSelector Pending`。

---

## 版本紀錄

| 版本 | 內容 |
|---|---|
| v1 | Part 0–9：名詞表、流量入口鏈、四層管控、RBAC 除錯、跨 ns、跨 cluster、六種 kind、canary + HPA、除錯速查、環境發現 |
| v2 | 新增 Part 10–13：ingressgateway 與雙 VIP、FZ1/FZ2 入口設計、Argo Rollouts 取代人工 pilot run、node 排程與 routable 網段 |
| v3 | 補記 Part 14–15（保留人工 pilot run 的 canary、兩種上版方式的對照與 SOP）；新增 Part 16：active zone DNS 下 request 落在哪、FZ2 部好卻 404 的成因、用 mesh 送到 FZ2 的兩條路線；Part 0 補「Istio 本身由什麼組成」與「物件之間怎麼互相找到（label / 名字 / host）」；16.2 補「VS 指向 Service 名字但封包直連 Pod IP」的具體例子 |

## 文件中標示為「需向他人確認」的項目

這些是文件無法從你的環境推斷、必須問人的事項，集中列在這裡方便追蹤：

| 項目 | 問誰 | 在哪一節 |
|---|---|---|
| VIP 位址池的指定語法（`loadBalancerIP` / MetalLB / F5 CIS annotation） | 網路組 / 平台組 | Part 10.4 |
| `100.64.0.0/10` 在公司網路政策下是否真的不可路由 | 網路組 | Part 10.4 |
| 各入口前面實際有幾層 proxy（決定 `numTrustedProxies`） | 網路組 | Part 1、Part 10.5 |
| CD 建 ingressgateway 時：裝新的還是共用、VIP 從哪個池來、會不會一併建 Gateway/VirtualService、憑證誰管 | CD 團隊 | Part 11.7 |
| node 的實際 label key / value 與 taint 內容 | 用 Part 13.5 的指令自己查 | Part 13.5 |
| 環境有沒有 Prometheus / Argo Rollouts | 用 Part 12.10 的指令自己查 | Part 12.10 |
| FZ1 / FZ2 有沒有做 Istio multi-cluster（共用 root CA、remote secret、east-west gateway） | 平台組 | Part 16.6 路線二 |
| active zone 怎麼切換（誰觸發、自動還是人工）、DNS TTL 多長 | 網路組 | Part 16.1 |
