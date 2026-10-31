# 查證帳本：k8s-ecosystem-guide.md

> 這份帳本是 `tasks/prd-k8s-guide-verification.md` 與 Ralph loop 的事實依據。
> 每一列是 guide 裡的一條可證偽說法，對照官方文件（kubernetes.io、istio.io、envoyproxy.io、
> argoproj）查證後的結果。**基準是查證當下的官方最新版文件**；版本相關的功能在「建議改法」
> 裡註明最低版本。
>
> - **判定**：正確／錯誤／過時／不精確／環境特定／無法驗證／改成指標
>   （「改成指標」只用在 Part 14／15 的完整 manifest 與 SOP 小節：那些內容的唯一真實來源是
>   `canary-manual/CANARY-COMPLETE.md`，loop 要把它們換成「兩三句摘要＋指向對應章節」，不逐行修正）
> - **使用者確認**：✓ 同意要改／✗ 不改（附理由）／待定
> - 只有「使用者確認 ✓」且判定不是「正確」的列，才會變成 loop 的修正故事。
> - 「環境特定」的列不上網查，改併入 guide 文末「需向他人確認」清單。
> - 行號是查證當下（commit `2c26688`）的行號，loop 改過之後會漂移 —— 以「原文摘錄」定位。
> - code-review 的 Spec 軸會 WebFetch 每一列的 URL，確認「來源引文」真的存在。

## 判定統計

| 批 | 範圍 | 說法總數 | 正確 | 錯誤 | 過時 | 不精確 | 環境特定 | 無法驗證 | 改成指標 |
|---|---|---|---|---|---|---|---|---|---|
| ① | Part 0 | 73 | 61 | 1 | 1 | 8 | 0 | 2 | 0 |
| ① | Part 1 | 41 | 25 | 2 | 0 | 9 | 4 | 1 | 0 |
| ② | Part 2.1–2.2 | 53 | 38 | 4 | 1 | 9 | 1 | 0 | 0 |
| ② | Part 2.3–2.5 | 49 | 28 | 4 | 0 | 15 | 0 | 2 | 0 |
| ② | Part 3 | 40 | 24 | 3 | 1 | 11 | 0 | 1 | 0 |
| ③ | Part 4 | 42 | 25 | 5 | 0 | 9 | 3 | 0 | 0 |
| ③ | Part 5（上半） | 38 | 27 | 2 | 1 | 7 | 0 | 1 | 0 |
| ③ | Part 5（下半） | 34 | 21 | 3 | 0 | 9 | 0 | 1 | 0 |
| ④ | Part 6.1–6.2 | 70 | 51 | 3 | 1 | 14 | 0 | 1 | 0 |
| ④ | Part 6.3–6.4 | 52 | 33 | 3 | 3 | 11 | 1 | 1 | 0 |
| ④ | Part 6.5–6.6 | 52 | 32 | 4 | 2 | 11 | 0 | 3 | 0 |
| ⑤ | Part 7 | 56 | 33 | 3 | 1 | 14 | 3 | 2 | 0 |
| ⑤ | Part 12 | 53 | 27 | 7 | 1 | 17 | 1 | 0 | 0 |
| ⑤ | Part 14 | 62 | 27 | 16 | 8 | 8 | 0 | 1 | 2 |
| ⑤ | Part 15 | 68 | 17 | 21 | 11 | 10 | 1 | 2 | 6 |
| ⑥ | Part 8 | 19 | 10 | 4 | 1 | 4 | 0 | 0 | 0 |
| ⑥ | Part 9 | 24 | 9 | 3 | 6 | 4 | 2 | 0 | 0 |
| ⑥ | Part 10 | 30 | 16 | 3 | 2 | 6 | 2 | 1 | 0 |
| ⑥ | Part 11 | 25 | 10 | 0 | 1 | 9 | 3 | 2 | 0 |
| ⑥ | Part 13 | 30 | 20 | 2 | 1 | 4 | 3 | 0 | 0 |
| ⑥ | Part 16 | 42 | 26 | 1 | 1 | 9 | 4 | 1 | 0 |

---

## Part 0：名詞速查表

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P00-001 | 37, 39 | K8s 原生只有「Service → Pod」這一層抽象；只能靠 replica 數量硬湊比例 | 不精確 | https://kubernetes.io/docs/concepts/workloads/management/ ; https://kubernetes.io/docs/concepts/services-networking/gateway/ | "You can tweak the number of replicas of the stable and canary releases to determine the ratio of each release that will receive live production traffic (in this case, 3:1)." / "Gateway API kinds support functionality for common traffic routing use cases such as header-based matching, traffic weighting, and others that were only possible in Ingress by using custom annotations." | 改成：只用核心的 Service 時，流量比例只能靠 replica 數量去湊（官方 canary 範例就是 3:1）。K8s 另有 Ingress，以及 Gateway API 這個 add-on（HTTPRoute 可以設權重）；但身分、mTLS、L7 授權仍然要靠 mesh | ✓ |
| P00-002 | 44, 53 | Istio 把這些抽出來，變成 sidecar（Envoy）＋一組 CRD；控制面 istiod＋資料面所有 Envoy | 不精確 | https://istio.io/latest/docs/ambient/overview/ | "The ztunnel proxy is written in Rust." / "Pods and workloads using sidecar mode can co-exist within the same mesh as pods that use ambient mode." | 加註：本文只講 sidecar 模式。Istio 另有 ambient 模式，資料面是每個節點一個 ztunnel（Rust 寫的，不是 Envoy）加上選用的 waypoint（Envoy），Pod 裡沒有 sidecar | ✓ |
| P00-011 | 80 | namespace 少了那個 label，Pod 會是 `1/1`、而且所有 Istio 設定對它都無效 | 不精確 | https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/ | "If either label (`istio-injection` or `sidecar.istio.io/inject` or `istio.io/rev`) is enabled, the pod is injected." / "the `istio-injection` label will take precedence." | 改成：namespace 沒 label、Pod 也沒標 `sidecar.istio.io/inject: "true"` 時通常不會注入（1/1）。這時它自己的 inbound 政策（AuthorizationPolicy、PeerAuthentication）沒有 Envoy 可以執行；但 mesh 裡其他 client 呼叫它時，client 端的 VS/DR 仍然套用。兩種 label 同時存在時 `istio-injection` 優先 | ✓ |
| P00-014 | 133 | istiod 只讀「自己這座 cluster」的 API server | 不精確 | https://istio.io/latest/docs/ops/deployment/deployment-models/ | "each control plane must observe endpoints from the API Server in every cluster." / "The `remote secret` contains credentials, granting access to the API server in the cluster." | 改成：istiod 只從自己這座 cluster（config cluster）讀 Istio 設定（VS/DR/Gateway…）；有設 multicluster（remote secret）時，還會讀其他 cluster 的 Service/Endpoints 做服務發現，但不讀它們的 VS | ✓ |
| P00-024 | 166, 223 | 比對 Pod 的 label，產生 Endpoints；不寫 selector 就不會自動產生 Endpoints | 過時 | https://kubernetes.io/docs/concepts/services-networking/service/ | "Feature state: Deprecated since Kubernetes v1.33" / "it is recommended that all clients use the EndpointSlice API rather than Endpoints." / "Because this Service has no selector, the corresponding EndpointSlice objects are not created automatically." | 「Endpoints」改成「EndpointSlice」，註明 Endpoints API 從 v1.33 起 deprecated；除錯指令改用 `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | ✓ |
| P00-025 | 167 | `ports[].targetPort: 8080` == container 的 containerPort | 不精確 | https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/ ; https://kubernetes.io/docs/concepts/services-networking/service/ | "Not specifying a port here DOES NOT prevent that port from being exposed." / "By default and for convenience, the `targetPort` is set to the same value as the `port` field." | 改成：targetPort 必須等於程式實際 listen 的 port；containerPort 主要是宣告用（用 named port 時才必要）；targetPort 省略時預設等於 port | ✓ |
| P00-034 | 196 | ⑥ ⑨ port 對不上 → 503 或連線被拒 | 無法驗證 | — | — | 寫細並標成經驗值：⑥ VS 的 port 不是 Service port → 對應 cluster 不存在，503 `NC`；⑨ targetPort 不是 app listen 的 port → Envoy 連上游失敗，503 `UF`/`URX`（upstream connect error…connection refused） | ✓ |
| P00-045 | 227 | AuthorizationPolicy selector **省略 = 整個 namespace**；放在 `istio-system` 且省略 = 整個 mesh | 不精確 | https://istio.io/latest/docs/concepts/security/ ; https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "The value of the root namespace is configurable, and the default is `istio-system`." / "The targetRefs specifies a list of resources the policy should be applied to." | 改成：省略 selector（且沒寫 targetRefs）＝整個 namespace；放在 **root namespace**（`meshConfig.rootNamespace`，預設 istio-system）且省略＝整個 mesh；也可以改用 `targetRefs` 指定 Gateway/Service | ✓ |
| P00-058 | 247 | DestinationRule…mTLS 模式；沒有 subset 就無法做版本分流 | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "DestinationRule defines policies that apply to traffic intended for a service after routing has occurred." / "SSL/TLS related settings for upstream connections." | 改成：DR 的 `tls` 是 client 端對上游連線的 TLS 設定（如 ISTIO_MUTUAL），server 端要不要強制 mTLS 由 PeerAuthentication 決定。不用 subset 也能分流（VS 用 weight 分到兩個不同的 Service）；同一個 Service 底下分版本時才需要 subset | ✓ |
| P00-059 | 248 | ServiceEntry…沒有它：嚴格模式下打不出去 | 不精確 | https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/ | "`ALLOW_ANY` is the default value" / "If the option is set to `REGISTRY_ONLY`, then the Istio proxy blocks any host without an HTTP service or service entry defined within the mesh." | 「嚴格模式」容易跟 mTLS STRICT 搞混。改成：`outboundTrafficPolicy.mode: REGISTRY_ONLY` 時打不出去；預設 ALLOW_ANY 會放行，但流量是 passthrough，拿不到 VS/DR 的功能 | ✓ |
| P00-061 | 250 | PeerAuthentication…沒有它：沒有身分，授權 policy 全部失效 | 錯誤 | https://istio.io/latest/docs/concepts/security/ | "Mesh-wide peer authentication policies with an unset mode use the `PERMISSIVE` mode by default." / "For peer authentication, Istio automatically upgrades all traffic between two PEPs to mutual TLS." / mutual TLS "must be enabled before using any of the following fields in the authorization policy:" | 改成：沒寫 PeerAuthentication 時預設是 PERMISSIVE，兩邊都有 sidecar 就會自動升級成 mTLS，身分照樣存在。真正的風險是 plaintext 也收（沒 sidecar 的 client 能繞過身分）。依賴 mTLS 的只有 `principals`/`notPrincipals`、`namespaces`/`notNamespaces`、`source.principal`、`source.namespace`，path、method 規則不受影響 | ✓ |
| P00-070 | 273 | ① NetworkPolicy 擋掉的：`connection refused` / timeout，**看不到任何 Istio log** | 無法驗證 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "The ability to log network security events (for example connections that are blocked or accepted)."（列在 NetworkPolicy API 做不到的事） | K8s 沒規定被擋時是 drop 還是 reject，取決於 CNI。改成：通常是 timeout（多數 CNI 直接丟封包），有沒有 RST 看 CNI；NetworkPolicy API 本身沒有 log，要用 CNI 自己的工具（Calico/Cilium） | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P00-003 | 52 | Envoy 是 C++ 寫的 proxy | https://www.envoyproxy.io/ |
| P00-004 | 54 | istiod 把設定翻成 Envoy 設定推送 | https://istio.io/latest/docs/ops/deployment/architecture/ |
| P00-005 | 54 | istiod 是控制面，不轉流量 | https://istio.io/latest/docs/ops/deployment/architecture/ |
| P00-006 | 55 | gateway 的 TLS secret 放 istio-system | https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/ |
| P00-007 | 68–74 | 注入後是 2/2、容器名 istio-proxy | https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/ |
| P00-008 | 77 | ingressgateway 前面是 LoadBalancer Service | https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/ |
| P00-009 | 78 | iptables 把流量導進 Envoy（15001/15006） | https://istio.io/latest/docs/ops/deployment/application-requirements/ |
| P00-010 | 80 | namespace label＋mutating webhook 在 Pod 建立時注入 | https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/ |
| P00-012 | 99 | gateway 直接連 Pod 端點 | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P00-013 | 126–127 | gateways 寫了 mesh 才會套到 sidecar | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-015 | 134 | proxy-status 的 SYNCED 代表已 ACK | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ |
| P00-016 | 144 | VS 跟 DR 靠 host＋subset 名對上 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-017 | 150 | Gateway.selector 用 label 選 Pod | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P00-018 | 153 | gateways 寫成 ns/name | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-019 | 154 | VS hosts 要對上 Gateway hosts | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P00-020 | 157 | destination.host 是 registry 裡的 Service | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P00-021 | 159 | subset 必須在 DR 裡定義 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-022 | 160 | port.number 是 host 上的 port | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-023 | 163 | subset labels 篩選端點 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P00-026 | 171/197/224 | selector 對不上 template 會被 API 拒絕 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P00-027 | 182 | cluster 名格式 `outbound\|port\|subset\|fqdn` | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ |
| P00-028 | 185 | 選不到 Pod 就是 503 UH | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P00-029 | 191 | Gateway 沒載入就連不上或 404 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P00-030 | 192 | gateways 或 host 對不上就 404（NR） | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P00-031 | 193 | host 拼錯就 503 NC（NC 的對應是推論，Envoy 只定義 NC＝cluster not found） | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-032 | 194 | subset 找不到就 503 NC（同上，推論） | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P00-033 | 195 | label 對不到 Pod 就 503 UH | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P00-035 | 199 | 短名依 VS 所在 ns 補全 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-036 | 204 | matchLabels 各條件是 AND | https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| P00-037 | 210 | In/NotIn/Exists/DoesNotExist | https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| P00-038 | 217 | 兩種寫法同時用是 AND | https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| P00-039 | 223 | Service selector 只能等值、直接寫 map | https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/ |
| P00-040 | 223 | 沒寫 selector 不自動建端點 | https://kubernetes.io/docs/concepts/services-networking/service/ |
| P00-041 | 224 | Deployment selector 建立後不可改 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P00-042 | 225 | DR subset labels 是 map | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P00-043 | 226 | Gateway selector 是 map | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P00-044 | 227 | 政策的 selector 只有 matchLabels | https://istio.io/latest/docs/reference/config/type/workload-selector/ |
| P00-046 | 228 | Sidecar 省略 selector 就是 ns 預設 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P00-047 | 229 | podSelector {} 選全部 Pod | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P00-048 | 230 | metadata.name label 可以選 ns | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P00-049 | 231 | PDB 用 label selector | https://kubernetes.io/docs/concepts/workloads/pods/disruptions/ |
| P00-050 | 232 | topologySpread 用 labelSelector | https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ |
| P00-051 | 233 | sourceLabels 需要 mesh 才生效 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P00-052 | 235 | 政策選錯 workload 會無聲不生效 | https://istio.io/latest/docs/ops/common-problems/security-issues/ |
| P00-053 | 241 | Deployment 管副本與 image | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P00-054 | 242 | Service 提供穩定入口 | https://kubernetes.io/docs/concepts/services-networking/service/ |
| P00-055 | 243 | ConfigMap 把設定跟 image 解耦 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P00-056 | 244 | CronJob 定時跑 Job | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P00-057 | 245 | Gateway 定義 port、host、TLS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P00-060 | 249 | 預設每個 sidecar 載入全 mesh 設定 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P00-062 | 251 | 沒有 AuthZ 政策就全部放行 | https://istio.io/latest/docs/concepts/security/ |
| P00-063 | 252 | RequestAuthentication 驗 JWT | https://istio.io/latest/docs/concepts/security/ |
| P00-064 | 253 | NetworkPolicy 是 L3/L4，需要 CNI | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P00-065 | 254 | HPA 自動調整副本數 | https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/ |
| P00-066 | 255 | PDB 限制自願中斷 | https://kubernetes.io/docs/concepts/workloads/pods/disruptions/ |
| P00-067 | 264–270 | 生效順序 NP→mTLS→AuthZ | https://istio.io/latest/docs/concepts/security/ |
| P00-068 | 266 | 身分是 ServiceAccount | https://istio.io/latest/docs/concepts/security/ |
| P00-069 | 268 | AuthZ 在 Envoy 執行 | https://istio.io/latest/docs/concepts/security/ |
| P00-071 | 274 | STRICT 拒絕 plaintext，沒有 403 | https://istio.io/latest/docs/tasks/security/authentication/authn-policy/ |
| P00-072 | 275 | 403＋"RBAC: access denied" | https://istio.io/latest/docs/tasks/security/authorization/authz-http/ |
| P00-073 | 278 | 這個訊息跟 K8s RBAC 無關 | https://istio.io/latest/docs/tasks/security/authorization/authz-http/ |

---

## Part 1：流量入口鏈 VIP 到 Pod

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P01-001 | 294–295 | `VIP (F5 / 硬體 LB / 雲端 LB)` 轉發到 NodePort 或 LB Service | 環境特定 | — | — | 不查證（公司環境的描述） | ✓ |
| P01-002 | 304 | 查 DestinationRule → 選 subset → 選負載平衡演算法 → 拿到目標 Pod IP 清單 | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "Labels apply a filter over the endpoints of a service in the service registry." | 改成：Pod IP 清單是 istiod 從 service registry（K8s Service／EndpointSlice）推給 Envoy 的。DestinationRule 不提供 IP，subset 的 `labels` 只是篩選這份清單，另外決定 LB 演算法和連線設定 | ✓ |
| P01-003 | 311–312 | `localhost:8080`、PrivilegeCheckFilter | 環境特定 | — | — | 不查證 | ✓ |
| P01-004 | 320 | ③ Service port 設錯 → `Connection refused` | 環境特定 | — | — | 症狀取決於外部 LB 怎麼處理（可能 RST，也可能 timeout）。改寫成「連不上（refused 或 timeout）」 | ✓ |
| P01-005 | 321 | ④a Gateway：**404 但沒有任何 access log** ← host 沒對上 | 錯誤 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | NR: "No route configured for a given request in addition to 404 response code" | Host 對不上 Gateway 時，回 404 的就是 Envoy 自己（route 表裡沒有符合的 virtual host），flag 一樣是 `NR`，log 有開就有紀錄，所以「有沒有 log」分不出 ④a 和 ④b。改成：HTTP host 不符 → 404＋`NR`，跟 VS 沒匹配長得一樣，要用 `proxy-config route` 看 virtual host 清單分辨；HTTPS SNI 不符 → TLS 握手就失敗，不會有 404；完全沒有 log 時，先查 access log 有沒有開、該 port 有沒有 listener | ✓ |
| P01-006 | 322 | ④b VS：404 且 access log 有紀錄、`response_flags` 為 `NR` | 不精確 | https://istio.io/latest/docs/tasks/observability/logs/access-log/ | "The egress gateway and access logging will be enabled if you install the `demo` configuration profile." | 補上前提：access log 預設不開（只有 demo profile 會開），要先用 Telemetry API 或 `meshConfig.accessLogFile=/dev/stdout` 打開；`NR` 不是 VS 專屬，Gateway host 不符時也會出現 | ✓ |
| P01-007 | 323 | ⑤ DR：**503 `UH/UF`** ← subset 選不到 Pod | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | UH: "No healthy upstream hosts in upstream cluster in addition to 503 response code." / UF: "Upstream connection failure in addition to 503 response code." / NC: "Upstream cluster not found." | 拆開：subset labels 選不到任何 Pod → 503 `UH`；VS 引用了 DR 沒定義的 subset → 503，通常是 `NC`；`UF` 是連線失敗（常見於 mTLS 衝突），跟 subset 選不到 Pod 不是同一件事 | ✓ |
| P01-008 | 332 | kube-proxy 的 iptables/IPVS 規則做 DNAT，隨機挑一個 Pod IP | 不精確 | https://kubernetes.io/docs/reference/networking/virtual-ips/ ; https://github.com/kubernetes/enhancements/blob/master/keps/sig-network/5495-deprecate-ipvs-mode-in-kube-proxy/README.md | "In Kubernetes 1.37, this is `iptables`, but a future version of Kubernetes will change the default to `nftables`." | 改成：kube-proxy 的 iptables（目前預設）或 nftables 規則做 DNAT；iptables 模式預設隨機挑 Pod，IPVS 依 scheduler。IPVS 模式 v1.35 起 deprecated、v1.40 預設停用、v1.43 移除（KEP-5495） | ✓ |
| P01-009 | 344 | `sessionAffinity: ClientIP` 在 mesh 內失效 | 無法驗證 | https://kubernetes.io/docs/reference/networking/virtual-ips/ | "A backend is chosen (either based on session affinity or randomly) and packets are redirected to the backend without rewriting the client IP address." | K8s 只說 affinity 是 kube-proxy 選 backend 時套用的；Istio 官方沒有逐字說「ClientIP 失效」，這是從機制推出來的。加一句「由機制推得，可用 `proxy-config endpoint` 與實測驗證」 | ✓ |
| P01-010 | 344 | 要在 Istio 下做黏著，必須用 DR 的 `consistentHash` | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "can be used to provide soft session affinity based on HTTP headers, cookies or other properties." / "With consistent hash, the guarantees are weaker." | 補上：consistentHash 只是「軟性」黏著，Pod 增減時會重新分配，不能取代共享 session；從 ingressgateway 進來的流量用 `useSourceIp` 會雜湊到 gateway 的 IP，應優先用 `httpCookie` 或 header | ✓ |
| P01-011 | 345 | Service port 名稱決定 L4/L7，沒命名好 VS 比對會默默失效 | 不精確 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ | "Istio can automatically detect HTTP and HTTP/2 traffic." / "If the protocol cannot automatically be determined, traffic will be treated as plain TCP traffic." | 改成：協定由 `appProtocol`（優先）或 port 名稱前綴決定；都沒寫時 sidecar 會自動偵測 HTTP/HTTP2，偵測不出來才當 TCP、L7 規則才失效。建議明確寫 `appProtocol: http` | ✓ |
| P01-012 | 354 | VIP 做 SNAT（多數 F5 預設） | 環境特定 | — | — | 不查證 | ✓ |
| P01-013 | 355 | `externalTrafficPolicy: Cluster` → 看到 node IP｜真實 client IP 在 `X-Forwarded-For` | 錯誤 | https://kubernetes.io/docs/tutorials/services/source-ip/ | "Packets sent to Services with `Type=NodePort` are source NAT'd by default." / "`node2` replaces the source IP address (SNAT) in the packet with its own IP address" | SNAT 在 L4 就把真實 IP 換掉了，kube-proxy 不會加 XFF，Envoy append 進 XFF 的是 node IP。改成：ingressgateway 看到 node IP，真實 client IP 只有在更前面的 L7 proxy 先寫進 XFF 時才拿得到，否則**完全遺失**。另外這一欄標題應是「ingressgateway 看到的 source IP」—— 目標 Pod 看到的永遠是 gateway Pod IP | ✓ |
| P01-014 | 358 | 必須先在 MeshConfig 設 `numTrustedProxies` | 不精確 | https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/ | "If you previously installed an Istio ingress gateway, restart all ingress gateway pods after step 1." | 改成：可以設在全域 MeshConfig，或在 gateway Pod 加 `proxy.istio.io/config` annotation 個別設；改完已在跑的 ingressgateway Pod 要重啟才生效 | ✓ |
| P01-015 | 361 | 註解 `MeshConfig（istio ConfigMap 或 IstioOperator）`＋頂層 `meshConfig:` | 不精確 | https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/ | gatewayTopology "is applied to all the gateways in the cluster unless overridden via annotations of the gateway workloads." | 註解改成：IstioOperator 的 `spec.meshConfig`（Helm 是 `meshConfig:` values）；直接改 `istio` ConfigMap 時 key 是 `mesh`、內容從 `defaultConfig:` 開始，**沒有** `meshConfig:` 這一層。此設定只對 gateway 生效 | ✓ |
| P01-016 | 369 | 從 XFF 最右邊往左數第 N+1 個是真實 client | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers | "the trusted client address is the Nth address from the right end of XFF." | 改成：以 gateway **收到**的 XFF 看是從右數第 N 個；gateway 會再 append 一個下游 IP，所以 app 端看到的 XFF 裡變成第 N+1 個。結果寫進 `X-Envoy-External-Address`；XFF 項數少於 N 時退回用直接連線的來源 IP | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P01-017 | 297 | ingressgateway Svc 在 istio-system，LB/NodePort | https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-control/ |
| P01-018 | 300 | gateway Pod 是獨立 Envoy | https://istio.io/latest/docs/concepts/traffic-management/ |
| P01-019 | 301 | Gateway 管 port/host/TLS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P01-020 | 302 | VS 管路由與分流比例 | https://istio.io/latest/docs/concepts/traffic-management/ |
| P01-021 | 305 | 直連 Pod IP、不經 ClusterIP | https://istio.io/latest/docs/ops/configuration/traffic-management/dns/ |
| P01-022 | 308 | PeerAuthentication 管 mTLS | https://istio.io/latest/docs/concepts/security/ |
| P01-023 | 309 | 授權由 Envoy 執行 | https://istio.io/latest/docs/concepts/security/ |
| P01-024 | 321 | `proxy-config listener` | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P01-025 | 322 | `proxy-config route` | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P01-026 | 323 | `proxy-config endpoint` | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P01-027 | 324 | 拒絕時回 `RBAC: access denied` | https://istio.io/latest/docs/tasks/security/authorization/authz-http/ |
| P01-028 | 325 | mTLS 衝突 → 503 UF | https://istio.io/latest/docs/ops/common-problems/network-issues/ |
| P01-029 | 325 | `proxy-config secret` | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P01-030 | 332 | 無 mesh 時 affinity 在 kube-proxy | https://kubernetes.io/docs/reference/networking/virtual-ips/ |
| P01-031 | 334 | iptables 導向 15001 | https://istio.io/latest/docs/ops/deployment/application-requirements/ |
| P01-032 | 334 | sidecar 自己挑 endpoint | https://istio.io/latest/docs/concepts/traffic-management/ |
| P01-033 | 346 | headless 走原始目的地 | https://istio.io/latest/docs/ops/configuration/traffic-management/dns/ |
| P01-034 | 354/358 | ipBlocks＝封包來源 IP | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P01-035 | 355 | 預設 Cluster、會 SNAT | https://kubernetes.io/docs/reference/networking/virtual-ips/ |
| P01-036 | 356 | Local 保留 IP、gateway 會 append XFF | https://kubernetes.io/docs/tutorials/services/source-ip/ |
| P01-037 | 358 | remoteIpBlocks 要先設 numTrustedProxies | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P01-038 | 358 | 未設時不信任 XFF（預設 0） | https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/ |
| P01-039 | 362–365 | gatewayTopology 欄位路徑 | https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/ |
| P01-040 | 365 | N＝前方受信任 proxy 數 | https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/ |
| P01-041 | 366 | SANITIZE_SET 合法（gateway 預設值） | https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/ |

---

## Part 2.1–2.2：PeerAuthentication、AuthorizationPolicy

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P02-001 | 390 | **這是 AuthorizationPolicy 的前置條件。** 沒有 mTLS，`principals` / `namespaces` 這些欄位永遠比對不到東西 | 不精確 | https://istio.io/latest/docs/concepts/security/ | "For peer authentication, Istio automatically upgrades all traffic between two PEPs to mutual TLS." / "it is strongly recommended to always use these fields with **strict** mutual TLS mode." | 前置條件是「mTLS」不是「PeerAuthentication 物件」：兩端都有 sidecar 時沒有 PeerAuthentication 也會走 auto mTLS。真正的陷阱在 PERMISSIVE：明文請求沒有 principal，ALLOW 擋得掉明文，但 DENY 裡的 principals 規則會被明文繞過。改成：principals/namespaces 依賴 mTLS，官方強烈建議搭配 STRICT，PERMISSIVE 下明文可能繞過 DENY（與 P00-061 一致） | ✓ |
| P02-002 | 414, 433 | portLevelMtls 必須搭配 selector 才有效 | 不精確 | https://raw.githubusercontent.com/istio/istio/master/manifests/charts/base/files/crd-all.gen.yaml ; https://istio.io/latest/docs/reference/config/security/peer_authentication/ | "message: portLevelMtls requires selector" / "These only apply when a workload selector is specified." | 改成：沒有非空的 `selector.matchLabels` 時，Istio ≥1.23 會在 apply 時被 CRD 驗證直接拒絕；更舊版本才是靜默忽略 | ✓ |
| P02-003 | 441 | 放在 root namespace（預設 istio-system）且名為 `default` 的 PeerAuthentication 會套用到整個 mesh | 不精確 | https://istio.io/latest/docs/concepts/security/ | "Mesh-wide policy: A policy specified for the root namespace without or with an empty `selector` field." | 名稱跟範圍無關：放在 root namespace、沒有 selector（或空的）就是 mesh-wide，叫 `default` 只是慣例；換個名字照樣全 mesh 中招 | ✓ |
| P02-004 | 447 | 把 HTTP probe 改寫成走 sidecar 的 15021 port（`sidecar.istio.io/rewriteAppHTTPProbe`，預設開啟） | 錯誤 | https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/ | "You can annotate the pod with `sidecar.istio.io/rewriteAppHTTPProbers: "false"` to disable the probe rewrite option."；改寫後範例輸出是 `"port": 15020,` | 改寫目標是 pilot-agent 的 **15020**（路徑 `/app-health/<container>/livez` 或 `readyz`）；15021 是 sidecar 自己的 `/healthz/ready`。Pod annotation 正確拼法是 `sidecar.istio.io/rewriteAppHTTPProbers`（結尾 Probers），加在 pod template 上；`rewriteAppHTTPProbe` 是全域 Helm 值，不是 annotation | ✓ |
| P02-005 | 447 | 或用了 TCP probe 打在 mTLS port 上，就會出問題 | 錯誤 | https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/ | "As stated previously, Istio uses probe rewrite to implement HTTP, TCP, and gRPC probes by default." / "so the probe will always succeed as long as the sidecar is running." | TCP、gRPC probe 預設也會改寫，STRICT 下不會壞。關掉改寫後：HTTP probe 在 STRICT 下會失敗（kubelet 沒有 mesh 憑證）；TCP probe 則因所有 port 都由 sidecar 接聽而**永遠成功**（假綠燈，偵測不到 app 掛掉） | ✓ |
| P02-006 | 491, 629 | `AUDIT`：只記 log 不擋，**上線前先跑這個**；上線前先用 `AUDIT` 跑一輪，看 log 確認沒誤傷再改 `ALLOW` | 錯誤 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ ; https://istio.io/latest/docs/tasks/security/authorization/authz-dry-run/ | "A separate plugin must be configured and enabled to actually fulfill the audit decision and complete the audit behavior." / "currently only supports ALLOW and DENY policies" | AUDIT 只把請求「標記」起來，沒另外設稽核 plugin 就不會有任何紀錄，也不能預演 ALLOW 會擋掉什麼。預演改用 `istio.io/dry-run: "true"` annotation（Alpha，只支援 ALLOW、DENY）：加在原本的 policy 上，看 Envoy log 與 metrics 的 shadow 結果，確認後拿掉 annotation | ✓ |
| P02-007 | 511, 589–591 | `ipBlocks`…在 mesh 內幾乎必錯——比到的是 ingressgateway 或 node 的 IP；1 層以上（經過 VIP / ingressgateway / CDN）→ 用 `remoteIpBlocks` | 不精確 | https://istio.io/latest/docs/tasks/security/authorization/authz-ingress/ | "If you are using `externalTrafficPolicy: Local`, then you should use `ipBlocks` in your `AuthorizationPolicy`." | 跟官方不一致，也跟寫法 A 註解「0 層→用 ipBlocks」矛盾。ipBlocks 比對封包來源位址，Pod 直連 Pod 時比到的就是對方 Pod IP。選擇準則改成：client IP 在 L3 就被保留（直連、或 `externalTrafficPolicy: Local`）→ ipBlocks；只存在 XFF 或 PROXY protocol 裡 → remoteIpBlocks＋numTrustedProxies | ✓ |
| P02-008 | 512, 552 | `remoteIpBlocks`：`X-Forwarded-For` 裡的原始 client IP；前置：MeshConfig 必須設 numTrustedProxies | 不精確 | https://istio.io/latest/docs/reference/config/security/conditions/ ; https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "Original client IP address as determined by X-Forwarded-For header or Proxy Protocol, supports single IP or CIDR" / "To make use of this field, you must configure the `numTrustedProxies` field of the `gatewayTopology`" | 來源除了 XFF 也可能是 PROXY protocol（LB 與 gateway 都要支援）；numTrustedProxies 可設在全域 `meshConfig.defaultConfig.gatewayTopology`，或用 gateway Pod 的 `proxy.istio.io/config` annotation 個別設；值等於 gateway 前面受信任的 proxy 層數（與 P01-014 一致） | ✓ |
| P02-009 | 526（另見 388、478、599） | Deployment 沒有設 `serviceAccountName`…身分是 `cluster.local/ns/ea-pmc/sa/default` | 環境特定 | — | — | 不查證。但跟同節其他內容矛盾：388 行 SAN 範例寫 `sa/pmc-epmmformquerygui`，478、599 行的 YAML 也用這個 principal，照 526 行的說法那兩份 YAML 在目前環境**永遠比對不到**。在 388、478、599 旁註明「前提：已依 Part 4 建立同名 SA；目前環境是 sa/default」 | ✓ |
| P02-010 | 572–587 | 寫法 C：DENY + notRemoteIpBlocks —— 黑名單式（更保險，因為 DENY 優先） | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers | "Otherwise, the trusted client address is the source IP address of the immediate downstream node's connection to Envoy." | 寫法 C 跟 B 一樣需要 numTrustedProxies（或 PROXY protocol），註解完全沒提。沒設時 remote IP 退回上一跳（LB 或 node IP，通常在 10.0.0.0/8 內），`notRemoteIpBlocks: ["10.0.0.0/8"]` 永遠不成立、DENY 不觸發，**所有外部流量靜默放行**。拿掉「更保險」、補前置條件；B 允許 10/8 與 172.16/12、C 只排除 10/8，語意要統一 | ✓ |
| P02-011 | 602 | sidecar 的 ALLOW 上寫 `hosts: ["epmm-api-svc.ea-epmm.svc.cluster.local"]` | 不精確 | https://istio.io/latest/docs/ops/best-practices/security/ | "exact match authorization policies only match the exact string given for the `hosts` or `notHosts` fields." / "the `host` and `notHosts` fields should generally only be used on gateway for external traffic" | hosts 對 Host header 精確比對：client 用短名、或 Host 帶 port（`...:8080`）都比對不到，ALLOW 不命中 → 403。在 sidecar 上拿掉 `hosts`（官方建議只在 gateway 用）；真要用就同時寫 `host` 與 `host:*` | ✓ |
| P02-012 | 616 | `request.headers[<name>]`：HTTP header，name 要小寫 | 不精確 | https://istio.io/latest/docs/reference/config/security/normalization/ | "Istio authorization policy will compare the header name with a case-insensitive approach." | 改成：name 放在 [] 內、不加引號、不分大小寫；只支援 HTTP | ✓ |
| P02-013 | 620 | `destination.port`：目標 port（數字） | 不精確 | https://istio.io/latest/docs/reference/config/security/conditions/ | "Destination workload instance port, must be in the range [0, 65535]. Note this is not the service port" | 改成：workload（容器）port，不是 Service port；`when.values` 是字串陣列，寫成 `values: ["8080"]` | ✓ |
| P02-014 | 625 | `/api/*/detail` 這種中間的萬用字元**不支援** | 過時 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ ; https://istio.io/latest/news/releases/1.22.x/announcing-1.22/change-notes/ | "`{*}` matches a single glob that cannot extend beyond a path segment." / "Added support for path templating in AuthorizationPolicy." | 單一 `*` 確實只能在開頭或結尾；但 Istio 1.22 起 paths 支援 URI template：`/api/{*}/detail` 比對中間單一段，`{**}` 比對零到多段且必須放最後；`/foo/{*}.txt` 這種同一段混字元的寫法不合法 | ✓ |
| P02-015 | 626 | `paths` 比對的是「未正規化」的路徑…務必在 MeshConfig 開啟 `pathNormalization` | 錯誤 | https://istio.io/latest/docs/reference/config/security/normalization/ ; https://istio.io/latest/docs/ops/best-practices/security/ | "Istio will resolve single dot `/./` and double dot `/../` according to RFC 3986." / "This is enabled by default with the normalization option `BASE`." | 預設 `BASE` 正規化已在授權前處理 `/../`（`/api/v1/../admin` 預設就被當成 `/api/admin`）。預設**沒有**的是合併 `//`（`MERGE_SLASHES`）與解碼 `%2F`/`%5C`（`DECODE_AND_MERGE_SLASHES`）。改成：預設 BASE 已處理 dot-segment；後端若把 `//` 或 `%2F` 視為等價，就把 `meshConfig.pathNormalization.normalization` 調成 MERGE_SLASHES 或 DECODE_AND_MERGE_SLASHES | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P02-016 | 388 | istiod 擔任 CA 簽發憑證 | https://istio.io/latest/docs/concepts/security/ |
| P02-017 | 388 | SAN 是 spiffe://td/ns/x/sa/y | https://istio.io/latest/docs/ops/integrations/spire/ |
| P02-018 | 390 | principals/namespaces 需要 mTLS | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-019 | 396/408/464 | apiVersion security.istio.io/v1（Istio ≥1.22） | https://istio.io/latest/news/releases/1.22.x/announcing-1.22/ |
| P02-020 | 399 | namespace 層級慣例名 default | https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/ |
| P02-021 | 403 | STRICT 拒收明文 | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P02-022 | 420 | portLevelMtls 用容器 port | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P02-023 | 429 | 實際預設為 PERMISSIVE | https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/ |
| P02-024 | 430 | DISABLE 不使用 mTLS | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P02-025 | 431 | UNSET 繼承上層（無上層視為 PERMISSIVE） | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P02-026 | 432 | 無 selector 套用整個 namespace | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P02-027 | 438 | workload > ns > mesh | https://istio.io/latest/docs/concepts/security/ |
| P02-028 | 441 | root ns 無 selector 套用全 mesh | https://istio.io/latest/docs/concepts/security/ |
| P02-029 | 445 | 先 PERMISSIVE，觀察後再 STRICT | https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/ |
| P02-030 | 445 | connection_security_policy="mutual_tls"（destination reporter） | https://istio.io/latest/docs/reference/config/metrics/ |
| P02-031 | 446 | 無 sidecar 的 client 在 STRICT 下失敗 | https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/ |
| P02-032 | 447 | HTTP probe 預設改寫 | https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/ |
| P02-033 | 448 | 填 Service port 不生效 | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P02-034 | 456 | 在 server 端 Envoy 判定 | https://istio.io/latest/docs/concepts/security/ |
| P02-035 | 468 | 放在被呼叫方的 namespace | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-036 | 489 | ALLOW 為白名單語意 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-037 | 490 | DENY 先於 ALLOW 判斷 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-038 | 492 | CUSTOM 交給外部授權 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-039 | 497 | 順序 CUSTOM→DENY→ALLOW | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-040 | 499 | 沒有 ALLOW policy 就全部放行 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-041 | 509 | principals 是 SA 身分 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-042 | 510 | namespaces 取自憑證、需要 mTLS | https://istio.io/latest/docs/concepts/security/ |
| P02-043 | 511/546 | ipBlocks 比對封包來源 IP | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-044 | 513 | requestPrincipals 需要 RequestAuthentication | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-045 | 518 | principal 格式 td/ns/x/sa/y | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-046 | 557 | 放在 gateway 所在 namespace | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-047 | 605/627 | ports 必須是字串（CRD items type: string） | https://raw.githubusercontent.com/istio/istio/master/manifests/charts/base/files/crd-all.gen.yaml |
| P02-048 | 606 | notPaths 是排除比對 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-049 | 610/617 | claims 比對需要 RequestAuthentication | https://istio.io/latest/docs/reference/config/security/conditions/ |
| P02-050 | 618 | request.auth.principal 為 iss/sub | https://istio.io/latest/docs/reference/config/security/conditions/ |
| P02-051 | 619 | source.namespace/principal 是來源身分 | https://istio.io/latest/docs/reference/config/security/conditions/ |
| P02-052 | 621 | connection.sni 是 TLS SNI | https://istio.io/latest/docs/reference/config/security/conditions/ |
| P02-053 | 628 | 放在 root ns 等於全 mesh 生效 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |

---

## Part 2.3–2.5：Sidecar、NetworkPolicy、四者對照表

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P02-201 | 637 | 每個 sidecar 都有 100 份 cluster/listener 設定；1000 個服務時…數百 MB…任何一個服務變動都會觸發全 mesh 的 config push | 無法驗證 | https://istio.io/latest/docs/ops/deployment/performance-and-scalability/ ; https://istio.io/latest/docs/ops/configuration/mesh/configuration-scoping/ | "The memory consumption of the proxy depends on the total configuration state the proxy holds." / "Each proxy instance will receive configuration for all namespaces as well." | 拿掉「數百 MB」「100 份 listener」等數字（官方沒有依服務數算的記憶體數據，outbound listener 多半依 port 合併）。改成：預設每個 proxy 都收到所有 namespace 的設定，記憶體跟著設定總量長，實際數字用 `proxy-config` 與 `kubectl top` 量；「每次變動推全 mesh」刪掉或標成經驗說法 | ✓ |
| P02-202 | 645, 663 | 要真正擋住，得靠 `REGISTRY_ONLY` + NetworkPolicy；改 REGISTRY_ONLY 才是嚴格模式 | 不精確 | https://istio.io/latest/docs/reference/config/networking/sidecar/ ; https://istio.io/latest/docs/ops/best-practices/security/ | "This option does not act as one, or as any form of an outbound firewall." / "When combined with a Network Policy, you can enforce all traffic, or some subset, goes through the egress gateway." | 改成：`REGISTRY_ONLY` 只是盡力而為的防呆（抓漏寫的 ServiceEntry），不是防火牆；官方建議的強制做法是 Egress Gateway＋NetworkPolicy（Pod 的 egress 只允許打到 egress gateway） | ✓ |
| P02-203 | 682 | 實務上會隨機挑一個生效），而且不會有明顯錯誤訊息 | 不精確 | https://istio.io/latest/docs/reference/config/analysis/ ; https://istio.io/latest/docs/reference/config/networking/sidecar/ | "More than one sidecar resource in a namespace has no workload selector" / "The behavior of the system is undefined if more than one selector-less `Sidecar` configurations exist in a given namespace." | 刪掉「隨機挑一個」（官方只說行為未定義）。補：`kubectl apply` 不會擋，但 `istioctl analyze -n ea-pmc` 會報 IST0111；多個 selector 命中同一 workload 會報 IST0110；建議把 analyze 放進 CI | ✓ |
| P02-204 | 741 | 忘了留 `istio-system/*`：telemetry、tracing 上報會失敗 | 不精確 | https://istio.io/latest/docs/ops/integrations/prometheus/ ; https://istio.io/latest/docs/reference/config/networking/sidecar/ | Prometheus "works by scraping these endpoints and collecting the results." | 指標是 Prometheus 主動拉的，跟 sidecar egress 無關。改成：官方範例都保留 `istio-system/*`；受影響的是 sidecar 要主動連過去的 istio-system 服務（例如裝在 istio-system 的 tracing collector、egress gateway），拿掉前先用 `proxy-config cluster` 確認；tracing 會壞這點官方沒寫，要寫就標成經驗 | ✓ |
| P02-205 | 742 | Sidecar 的 hosts 比對的是 FQDN，app 用 `http://epmm-api-svc/` 時 DNS 解析階段就失敗了 | 錯誤 | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ | "DNS queries that don't specify a namespace are limited to the Pod's namespace. Access Services in other namespaces by specifying it in the DNS query." | 因果寫錯：短名解析失敗是 K8s DNS 的 search domain 造成的，沒套 Sidecar 也一樣。改成：從 ea-pmc 呼叫 `epmm-api-svc` 會被展開成 `epmm-api-svc.ea-pmc.svc.cluster.local`，本來就查不到；跨 namespace 一定要寫 `epmm-api-svc.ea-epmm` 或完整 FQDN。Sidecar hosts 的 dnsName 官方要求寫 FQDN 是另一件事 | ✓ |
| P02-206 | 751 | 直接打其他 Pod 的 IP 和 port，繞過 mesh 的 L7 管控 | 不精確 | https://istio.io/latest/docs/ops/best-practices/security/ | "Instead, the security boundary is that a client may not bypass another pod's sidecar." / "Redirection only handles TCP based traffic. Any UDP or ICMP packets will not be captured or modified." | 改成：攻擊者能繞過自己 Pod 的 sidecar，但打到對方被攔截的 TCP port 時仍會經過對方的 sidecar 與 AuthorizationPolicy；真正的漏洞是 UDP/ICMP、port 22、sidecar 自己的 port、`excludeInboundPorts` 排除的 port，NetworkPolicy 補的是這幾塊 | ✓ |
| P02-207 | 753 | NetworkPolicy 保護的是「所有 IP 封包」 | 不精確 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "traffic to and from the node where a Pod is running is always allowed, regardless of the IP address of the Pod or the node" | 改成：NetworkPolicy 管 Pod 層級的 L3/L4 流量（CNI 有實作時），但 Pod 所在節點進出的流量永遠放行 | ✓ |
| P02-208 | 782 | 這個 label 是 K8s 1.22+ 自動加的 | 不精確 | https://kubernetes.io/docs/reference/labels-annotations-taints/ ; https://www.kubernetes.dev/resources/keps/2161/ | Milestones "Beta `v1.21`" and "Stable `v1.22`"; "this feature will be defaulted to on in its Beta phase." | 改成：1.21 起預設自動加（beta，feature gate `NamespaceDefaultLabelName`），1.22 GA 後不能關、值不能改 | ✓ |
| P02-209 | 809, 822 | 放行 ingressgateway 與控制平面，但只用 `kubernetes.io/metadata.name: istio-system` 比對 | 不精確 | https://istio.io/latest/docs/setup/additional-setup/gateway/ | "As a security best practice, it is recommended to deploy the gateway in a different namespace from the control plane." | 補註：官方建議 gateway 裝在另一個 namespace（範例是 `istio-ingress`），只放行 istio-system 時會被擋，要另加一個 namespaceSelector；先用 `kubectl get pod -A -l istio=ingressgateway` 確認 gateway 在哪 | ✓ |
| P02-210 | 830 | 工作負載 egress 裡寫 `- { protocol: TCP, port: 15017 }    # webhook` | 錯誤 | https://istio.io/latest/docs/ops/deployment/application-requirements/ ; https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/ | 15017: "Webhook container port, forwarded from 443" / "the API server sends an `admissionReview` request to webhook as specified in the `clientConfig`." | 15017 是 kube-apiserver 打進 istiod 的方向，工作負載不會往外連，從 ea-epmm 的 egress 刪掉；sidecar 連 istiod 只要 15012。若 istio-system 也套了 default-deny，要在 istio-system 那邊另外放行 API server 打進 15017 的 ingress | ✓ |
| P02-211 | 838 | `policyTypes`…沒列到的方向完全不受此 policy 管 | 不精確 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "…by default `Ingress` will always be set and `Egress` will be set if the NetworkPolicy has any egress rules." | 補上：有寫 policyTypes 才是這樣；省略時預設一定含 Ingress，有 `egress` 規則才加 Egress。所以只寫 egress 規則、沒寫 policyTypes 的 policy，也會讓 Pod 的 ingress 進入隔離狀態 | ✓ |
| P02-212 | 843 | `ipBlock.cidr` + `except`：IP 網段（用來放行 mesh 外部） | 不精確 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "These should be cluster-external IPs, since Pod IPs are ephemeral and unpredictable." | 「mesh 外部」改成「叢集外部」；叢集內但不在 mesh 裡的 Pod 一樣用 selector，不要寫 ipBlock | ✓ |
| P02-213 | 855–858 | OR：ea-pmc 的所有 Pod，或者 任何 ns 裡 label 是 app=xxx 的 Pod | 錯誤 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "allows connections from Pods in the local Namespace with the label `role=client`, _or_ from any Pod in any namespace with the label `user=alice`." | 單獨寫 `podSelector` 只選 policy 所在 namespace 的 Pod。改成：OR：ea-pmc 的所有 Pod，或者本 namespace（ea-epmm）裡 label 是 app=xxx 的 Pod（也跟第 839 行的表格一致） | ✓ |
| P02-214 | 862 | 先確認：`kubectl get pods -n kube-system` 再 grep calico/cilium/weave | 不精確 | https://github.com/flannel-io/flannel ; https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "has a `netpol.enabled` option that deploys the Kubernetes SIGs network policy controller alongside Flannel." / "Creating a NetworkPolicy resource without a controller that implements it will have no effect." | 改成：flanneld 本身不實作，但 Helm chart 可用 `netpol.enabled` 另裝控制器；grep 名字會漏掉其他實作（例如雲端供應商的 dataplane），可靠的做法是在測試 ns 套 deny-all 再實際 curl | ✓ |
| P02-215 | 877–879 | 擋掉的症狀：timeout / connection refused（無 Istio log） | 無法驗證 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "The ability to log network security events (for example connections that are blocked or accepted)."（列在 NetworkPolicy 做不到的事） | 丟棄（timeout）還是拒絕（refused）由 CNI 決定。改成：通常是 timeout，依 CNI 而定；NetworkPolicy 本身沒有阻擋紀錄（與 P00-070 一致） | ✓ |
| P02-216 | 882 | Sidecar 作用在「送得出去嗎」而不是「進得來嗎」 | 不精確 | https://istio.io/latest/docs/reference/config/networking/sidecar/ | "Ingress specifies the configuration of the sidecar for processing inbound traffic to the attached workload instance." | 補一句：Sidecar 也有 `ingress` 欄位可設 inbound listener；本節只用到 egress，而且它不是授權機制 | ✓ |
| P02-217 | 894, 906 | 擋得住繞過 sidecar 的直連：AuthzPolicy 不行；Istio policy 擋不住繞過 sidecar 的直連 | 不精確 | https://istio.io/latest/docs/ops/best-practices/security/ | "Instead, the security boundary is that a client may not bypass another pod's sidecar." | AuthzPolicy 改成「部分」：被攔截的 inbound TCP port 照樣執行；擋不住的是沒被攔截的協定與 port、被入侵 Pod 往外的 egress。第 906 行改成：Istio policy 管不到 UDP/ICMP、被排除的 port，也管不到被入侵 Pod 自己的出向流量 | ✓ |
| P02-218 | 902 | NetworkPolicy 只能比 IP，Pod 重建就失效 | 錯誤 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "**podSelector**: This selects particular Pods in the same namespace as the NetworkPolicy which should be allowed as ingress sources or egress destinations." | NetworkPolicy 用 label selector 選 Pod，重建不會失效（第 864 行自己也這樣說）。改成：NetworkPolicy 只認 label 和 IP，不認密碼學身分、看不到 L7；AuthorizationPolicy 的 `principals` 認的是 mTLS 憑證裡的 ServiceAccount 身分 | ✓ |
| P02-219 | 903 | AuthorizationPolicy `remoteIpBlocks`（放 ingressgateway 上） | 不精確 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ ; https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/ | "To make use of this field, you must configure the `numTrustedProxies` field of the `gatewayTopology`" / "all proxies in front of the Istio gateway proxy must parse HTTP traffic and append to the X-Forwarded-For header" | 補前提：要先設 `gatewayTopology.numTrustedProxies`（或 gateway annotation），前面的 LB 要追加 XFF；純 TCP LB 改用 PROXY protocol；沒設定時 remote.ip 拿不到真正的 client IP（與 P01-013、P01-014 一致） | ✓ |
| P02-220 | 907 | NetworkPolicy egress + Sidecar `REGISTRY_ONLY`：兩層一起才擋得住 | 不精確 | https://istio.io/latest/docs/ops/best-practices/security/ | "When combined with a Network Policy, you can enforce all traffic, or some subset, goes through the egress gateway." | NetworkPolicy 不能依主機名過濾，REGISTRY_ONLY 也不是安全邊界。改成：ServiceEntry＋Egress Gateway（在 gateway 上限制主機名）＋NetworkPolicy 只允許 Pod 的 egress 打到 egress gateway | ✓ |
| P02-221 | 908 | Sidecar：這是它唯一能解的問題 | 不精確 | https://istio.io/latest/docs/reference/config/networking/sidecar/ | "sets the default behavior of the sidecar for handling unknown outbound traffic" | 跟上一列與第 642 行互相矛盾。改成「主要用途」，並說明 Sidecar 也能設每個 workload 的 outboundTrafficPolicy 與 ingress listener | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P02-222 | 645 | ALLOW_ANY 是預設，不是安全邊界 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-223 | 651 | Sidecar 用 networking.istio.io/v1 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-224 | 659 | `./*` 代表自己 ns | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-225 | 660, 674 | `istio-system/*` 代表該 ns 全部服務 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-226 | 661, 673 | `ns/FQDN` 選單一服務 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-227 | 662 | Sidecar 有 outboundTrafficPolicy 欄位 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-228 | 671 | `*/*` 等於全 mesh | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-229 | 672 | `ea-epmm/*` 代表該 ns 全部服務 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-230 | 680–682 | 每個 ns 只能有一份無 selector，多份時行為未定義 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-231 | 684, 699, 705 | 有 selector 的優先，不會合併 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-232 | 707 | 多個 selector 命中同一 workload 行為未定義 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-233 | 723, 732 | proxy-config 接受 `[<type>/]<name>`（文件寫 `deployment/`，`deploy/` 縮寫沒有範例） | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P02-234 | 743 | REGISTRY_ONLY 需要 ServiceEntry | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P02-235 | 765–767 | `{}` 加兩種 policyTypes 等於全拒絕 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-236 | 769, 863 | deny egress 也會擋 DNS | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-237 | 782 | metadata.name label 由系統設定且不可改 | https://kubernetes.io/docs/reference/labels-annotations-taints/ |
| P02-238 | 803, 841, 850 | 寫在同一項是 AND | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-239 | 829 | 15012 是 istiod 的 XDS/CA | https://istio.io/latest/docs/ops/deployment/application-requirements/ |
| P02-240 | 839 | 單獨的 podSelector 只選同 ns | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-241 | 842 | 寫在不同項是 OR | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-242 | 861 | 多條 policy 是聯集，沒有 deny | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-243 | 862 | CNI 沒實作就無效；flanneld 本身不實作 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-244 | 864 | 用 selector，不要寫死 Pod IP | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P02-245 | 878 | STRICT 下明文請求被斷線、拿不到 HTTP 碼 | https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/ |
| P02-246 | 878 | Authz 拒絕時回 "RBAC: access denied" | https://istio.io/latest/docs/tasks/security/authorization/authz-http/ |
| P02-247 | 888 | Authz 的 ipBlocks 比對來源 IP | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-248 | 889 | principals 需要開 mTLS | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P02-249 | 895 | NetworkPolicy 不需要 Istio | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |

---

## Part 3：`RBAC: access denied` 除錯專章

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P03-001 | 930 | 403，body 就是那七個字 | 不精確 | https://raw.githubusercontent.com/envoyproxy/envoy/main/source/extensions/filters/http/rbac/rbac_filter.cc | `callbacks_->sendLocalReply(Http::Code::Forbidden, "RBAC: access denied", ...` | body 是 `RBAC: access denied`（3 個英文字、19 個字元），不是七個字。改成：403，body 只有 `RBAC: access denied` 這一行純文字 | ✓ |
| P03-002 | 948–950 | 有 `x-envoy-upstream-service-time` → 請求已經到過目標 → 目標 sidecar 擋的；沒有 → ingressgateway 就擋掉了 | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter ; https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter | "Contains the time in milliseconds spent by the upstream host processing the request" | header 只代表回應那一跳的 Envoy 有把請求轉給上游；服務直接打服務、沒經 gateway 時，「沒有 → gateway 擋的」不成立。改成：最可靠是看各 proxy 的 access log，response code details 出現 `rbac_access_denied_matched_policy[...]` 的那個就是擋下的 Envoy；header 只當輔助線索 | ✓ |
| P03-003 | 967 | Prometheus 抓 metrics、health check…全部被擋 | 不精確 | https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/ ; https://istio.io/latest/docs/ops/integrations/prometheus/ | "This option is enabled by default." / "The merged metrics will be scraped from `:15020/stats/prometheus`." | 預設 kubelet probe 被改寫到 15020、Prometheus 也從 15020 抓合併 metrics，都不經過 inbound RBAC filter，預設不會被擋。改成：關掉 probe rewrite 或 metrics merge、讓 kubelet 或 Prometheus 直接打 app port 時才會被擋；典型受害者是「其他沒列進名單的服務」 | ✓ |
| P03-004 | 1013–1014 | `istioctl proxy-config secret … -o json` 再 grep `spiffe://` | 錯誤 | https://istio.io/latest/docs/ops/common-problems/security-issues/ | 官方範例：`istioctl proxy-config secret … -o json` 經 jq 取 `.secret.tlsCertificate.certificateChain.inlineBytes`，再 `base64 -d` 與 `openssl x509 -noout -text`，確認 SAN 為 "URI:spiffe://cluster.local/ns/my-ns/sa/my-sa" | JSON 裡的憑證是 base64 的 `inlineBytes`，直接 grep 找不到 `spiffe://`。改用官方的 jq＋`base64 -d`＋`openssl x509 -noout -text` 寫法，看 Subject Alternative Name | ✓ |
| P03-005 | 1017 | `sa/default` 等於「這個 namespace 的任何 Pod」 | 不精確 | https://kubernetes.io/docs/concepts/security/service-accounts/ | "If you deploy a Pod in a namespace, and you don't manually assign a ServiceAccount to the Pod, Kubernetes assigns the `default` ServiceAccount for that namespace to the Pod." | 改成：等於「這個 namespace 裡所有沒指定 serviceAccountName 的 Pod」，有指定其他 SA 的不算 | ✓ |
| P03-006 | 1030–1032 | `-o jsonpath='{.items[0].spec.containers[*].name}'`＋應該要看到 istio-proxy | 過時 | https://istio.io/latest/news/releases/1.27.x/announcing-1.27/upgrade-notes/ | "Native sidecars are now enabled by default for eligible pods." / "This changes `istio-proxy` from a container to an init container." | Istio 1.27 起（符合條件的 Pod）`istio-proxy` 在 `initContainers`，只查 `containers` 會誤判成沒注入。改成兩處都查：`{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}` | ✓ |
| P03-007 | 1035–1036 | `kubectl exec … -c istio-proxy -- curl -s localhost:15000/stats` 再 grep ssl.handshake | 不精確 | https://istio.io/latest/docs/ops/configuration/security/harden-docker-images/ ; https://istio.io/latest/docs/ops/common-problems/security-issues/ | "Istio's default images are based on `ubuntu` with some extra tools added. An alternative image based on distroless images is also available." / "Distroless images are missing all debugging tools (including a shell!)."；官方範例：`kubectl exec … -c istio-proxy -- pilot-agent request GET config_dump` | **（batch ③ 更正）** 預設的 proxyv2 映像是 Ubuntu 為底、**有 curl**（https://raw.githubusercontent.com/istio/istio/master/docker/Dockerfile.base）；只有 opt-in 的 distroless variant（`values.global.variant=distroless`）才沒有 curl 與 shell。原文的 curl 指令在預設映像可以跑，但官方範例一律用 `pilot-agent request GET stats`，兩種映像都能用，所以仍建議改成這個寫法，並註明「distroless variant 沒有 curl」。另外 `ssl.handshake` 是 listener 層級的累計計數，判斷不了某個來源是否走 mTLS，加註「判斷個別來源用 XFCC（見 P03-015）」 | ✓ |
| P03-008 | 1039 | namespace 沒有 `istio-injection=enabled` label，就一定沒有身分 | 不精確 | https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/ | "If either label (`istio-injection` or `sidecar.istio.io/inject` or `istio.io/rev`) is enabled, the pod is injected." | 改成：namespace 的 `istio-injection=enabled` 或 `istio.io/rev=<rev>`、或 Pod 的 `sidecar.istio.io/inject="true"`，任一成立就注入；都沒有、或其中一個明確設成 disabled／"false" 才不注入（與 P00-011 一致） | ✓ |
| P03-009 | 1048 | `ports` 填 Service port，但 Envoy 看的是容器 port | 無法驗證 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | `ports`: "A list of ports as specified in the connection." | 官方沒明說 targetPort 還是 Service port，只寫「連線上的 port」；推論方向合理但不是原文。改成：`ports` 比對連線實際的目的 port，也就是 Pod 的 containerPort（Service 的 targetPort），不是 Service port；拿掉「Envoy 看的是」這種像在引用官方的語氣 | ✓ |
| P03-010 | 1052 | `paths` 看的是**原始 HTTP request path** | 不精確 | https://istio.io/latest/docs/ops/best-practices/security/ | "Path normalization (a.k.a., URI normalization) modifies and standardizes the incoming requests' paths"；BASE "is currently the option used in the default installation of Istio." | 改成：`paths` 比對的是正規化後（預設 BASE，依 RFC 3986，並把 `\` 轉成 `/`）的 path，一樣要寫完整的 `/gui_epmmFormQuery/...`（與 P02-015 一致） | ✓ |
| P03-011 | 1062 | `kubectl get authorizationpolicy -n istio-system -o yaml` 再 grep -A5 selector | 不精確 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "If the selector and the targetRef are not set, the selector will match all workloads." | grep 只列出「有」selector 的 policy，危險的「沒有 selector」反而看不到。改成逐條列出 name 與 selector／targetRefs：`-o custom-columns=NAME:.metadata.name,SELECTOR:.spec.selector,TARGETREFS:.spec.targetRefs`，兩欄都是 `<none>` 的就是作用到全 mesh | ✓ |
| P03-012 | 1065 | 放在 `istio-system` 的 policy **必須有 `selector`** | 不精確 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "If the selector and the targetRef are not set, the selector will match all workloads." | 改成：必須有 `selector` 或 `targetRefs`，兩者都沒有才會套用到全 mesh（與 P00-045 一致） | ✓ |
| P03-013 | 1084 | **policy 名稱和第幾條 rule 都會印出來** | 不精確 | https://raw.githubusercontent.com/envoyproxy/envoy/main/source/extensions/filters/http/rbac/rbac_filter.cc ; https://istio.io/latest/docs/ops/common-problems/security-issues/ | `ENVOY_LOG(debug, "enforced denied, matched policy {}", log_policy_id);` / 官方範例：`enforced denied, matched policy ns[foo]-policy[deny-path-headers]-rule[0]` | 只有被 DENY policy 命中時才印 policy 與 rule；最常見的成因 1（有 ALLOW 但沒命中任何 rule）會印 `enforced denied, matched policy none`。補一句：看到 `matched policy none` 就是 ALLOW 名單沒對上 | ✓ |
| P03-014 | 1089–1090 | `istioctl proxy-config listener deploy/epmm-api … --port 8080 -o json` 再 grep rbac filter | 錯誤 | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ ; https://istio.io/latest/docs/reference/commands/istioctl/ | "every sidecar has a listener bound to `0.0.0.0:15006` which is where IP tables routes all inbound pod traffic to." / `--port`: "Filter listeners by Port field" | sidecar 的 inbound 全部走 15006 listener，`--port 8080` 篩出來的頂多是 outbound listener，沒有 inbound RBAC filter。改成 `--port 15006 -o json` 再找 destination port 8080 那條 filter chain 的 `envoy.filters.http.rbac`；或官方寫法 `pilot-agent request GET config_dump` 再 grep | ✓ |
| P03-015 | 1096–1098 | 「看收到的 XFCC header」：`curl -s localhost:15000/config_dump` 再 grep forward_client_cert | 錯誤 | https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto ; https://istio.io/latest/docs/tasks/security/authentication/authn-policy/ | `forward_client_cert_details`: "How to handle the x-forwarded-client-cert (XFCC) HTTP header." / "That header's presence is evidence that mutual TLS is used." | config_dump 只看得到「怎麼處理 XFCC」的設定，看不到實際收到的 header。要看真的 XFCC：讓目標 app 回顯 request header（httpbin `/headers`、Spring 印出 `X-Forwarded-Client-Cert`），或把 `%REQ(X-FORWARDED-CLIENT-CERT)%` 加進 access log；header 裡 `URI=spiffe://…` 就是來源身分 | ✓ |
| P03-016 | 1116–1117 | `kubectl get rolebinding,clusterrolebinding -A -o json` 再 grep SA 名字 | 不精確 | https://kubernetes.io/docs/reference/access-authn-authz/rbac/ | "ServiceAccounts have names prefixed with `system:serviceaccount:`, and belong to groups that have names prefixed with `system:serviceaccounts:`." | 用 SA 名字 grep 會漏掉綁在 `system:serviceaccounts`、`system:serviceaccounts:ea-pmc`、`system:authenticated` 群組上的權限。補：最終以 `kubectl auth can-i --list --as=…` 為準，grep 只找得到直接綁定，並把這些群組名一起 grep | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P03-017 | 925 | 字串出自 Envoy RBAC filter | https://raw.githubusercontent.com/envoyproxy/envoy/main/source/extensions/filters/http/rbac/rbac_filter.cc |
| P03-018 | 925 | AuthZ 轉成 http.rbac filter | https://istio.io/latest/docs/ops/common-problems/security-issues/ |
| P03-019 | 929 | K8s forbidden 訊息格式 | https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/responsewriters/errors.go |
| P03-020 | 930–931 | apiserver 回 403 Status | https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/responsewriters/errors.go |
| P03-021 | 934/953/971 | x authz check 接受 type/name -n | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P03-022 | 955 | DENY 先於 ALLOW 評估 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-023 | 965 | 有 ALLOW 就預設拒絕 | https://istio.io/latest/docs/concepts/security/ |
| P03-024 | 976 | 多條 rules 為 OR | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-025 | 986 | 只寫 to＝任何來源 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-026 | 982/1002 | principal 格式 td/ns/sa | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-027 | 993/999 | 未指定 SA 用 default | https://kubernetes.io/docs/concepts/security/service-accounts/ |
| P03-028 | 1021 | principals 需 mTLS | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-029 | 1021 | 明文時 principal 比對失敗 | https://istio.io/latest/docs/concepts/security/ |
| P03-030 | 1047 | ports 型別是字串 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-031 | 1049 | `/api/*` 為前綴比對 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-032 | 1056 | root ns policy 全 mesh | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P03-033 | 1075 | log --level rbac:debug | https://istio.io/latest/docs/ops/common-problems/security-issues/ |
| P03-034 | 1081 | warning 是合法層級 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P03-035 | 1084 | log 格式 ns[]-policy[]-rule[] | https://istio.io/latest/docs/ops/common-problems/security-issues/ |
| P03-036 | 1105 | 訊息含 cannot…in API group | https://raw.githubusercontent.com/kubernetes/kubernetes/master/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/responsewriters/errors.go |
| P03-037 | 1109–1110 | can-i --as=SA -n | https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/ |
| P03-038 | 1112 | can-i --list 列出全部 | https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/ |
| P03-039 | 1123–1129 | rbac/v1、"" 為 core | https://kubernetes.io/docs/reference/access-authn-authz/rbac/ |
| P03-040 | 1143/1148 | ClusterRole+RoleBinding 限該 ns | https://kubernetes.io/docs/reference/access-authn-authz/rbac/ |

---

## Part 4：同 cluster 跨 namespace 互打

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P04-001 | 1179, 1182 vs 1185 | `"http://epmm-api-svc.ea-epmm/api/v1/forms"`（沒寫 port），1185 卻寫 `:8080` | 環境特定 | — | — | 三個範例的 port 要一致：Service port 若是 8080，1179、1182 也補 `:8080`，否則會打到 80 | ✓ |
| P04-002 | 1184 | 完整 FQDN（少一次 search domain 嘗試，也不會被 ndots 影響） | 錯誤 | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ ; https://www.man7.org/linux/man-pages/man5/resolv.conf.5.html | K8s 範例：`options ndots:5`。man7："Resolver queries having fewer than ndots dots (default is 1) in them will be attempted using each component of the search path in turn until a match is found." | `epmm-api-svc.ea-epmm.svc.cluster.local` 只有 4 個點、少於 5，照樣先跑 search list（先查 `…cluster.local.ea-pmc.svc.cluster.local` 等，全部失敗才查絕對名稱），查詢次數反而比 `epmm-api-svc.ea-epmm`（第 2 次就中）多。真正不受 ndots 影響要在尾端加點：`epmm-api-svc.ea-epmm.svc.cluster.local.`，或在 Pod `dnsConfig.options` 調低 ndots。改成：FQDN 可讀性最好；要省查詢請加結尾點或調 ndots | ✓ |
| P04-003 | 1196 | `ndots:5` 會讓每個少於 5 個點的名字都跑完整串 search domain | 不精確 | https://www.man7.org/linux/man-pages/man5/resolv.conf.5.html | "attempted using each component of the search path in turn until a match is found." | 改成：少於 5 個點的名字會**先**依序套 search domain、**命中就停**，全部 miss 才查原名；只有找不到的名字（例如外部網域）才會跑完整串 | ✓ |
| P04-004 | 1201–1202 | `kubectl exec … -c istio-proxy -- nslookup …` | 錯誤 | https://raw.githubusercontent.com/istio/istio/master/docker/Dockerfile.base | apt 套件："ca-certificates \ curl \ iptables \ nftables \ iproute2 \ iputils-ping \ knot-dnsutils \ netcat-openbsd \" | 預設 proxyv2 只裝 `knot-dnsutils`（提供 `kdig`/`khost`），沒有 `nslookup`；distroless variant 連 shell 都沒有。改用 `kubectl debug -n ea-pmc <pod> -it --image=busybox:1.36 --target=app -- nslookup epmm-api-svc.ea-epmm.svc.cluster.local`；確定是預設映像時也可用 `-- kdig …` | ✓ |
| P04-005 | 1207 | 你現在兩邊都是 `default` SA | 環境特定 | https://kubernetes.io/docs/concepts/security/service-accounts/ | "Kubernetes assigns the `default` ServiceAccount for that namespace to the Pod." | 機制正確；現況用 `kubectl get pod -o jsonpath='{.spec.serviceAccountName}'` 自己確認 | ✓ |
| P04-006 | 1240–1243 | 改完必須重啟才會拿到新身分：`kubectl rollout restart …` | 不精確 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/ ; https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | "You cannot update the `.spec.serviceAccountName` field of a Pod that already exists." / "Declare the new state of the Pods by updating the PodTemplateSpec of the Deployment. A new ReplicaSet is created…" | 改成：既有 Pod 的 SA 改不了，一定要換新 Pod；但改 `spec.template.spec.serviceAccountName` 本身就是改 pod template，`kubectl apply` 會自動滾動更新，不用另外 `rollout restart`（多跑只是再滾一輪） | ✓ |
| P04-007 | 1245 | `istioctl proxy-config secret … -o json` 再 grep `spiffe://` | 錯誤 | https://istio.io/latest/docs/ops/integrations/spire/ | "istioctl proxy-config secret "$CURL_POD" -o json \| jq -r \" "'.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \| base64 --decode > chain.pem" | 同 P03-004：憑證是 base64 的 `inlineBytes`，grep 幾乎一定是空的。改成 jq 取 `.dynamicActiveSecrets[] \| select(.name=="default") \| .secret.tlsCertificate.certificateChain.inlineBytes`，再 `base64 -d \| openssl x509 -noout -text` 看 Subject Alternative Name | ✓ |
| P04-008 | 1251 | 先確保 mTLS 開著，principals 才有值（接著設 `mode: STRICT`） | 不精確 | https://istio.io/latest/docs/reference/config/security/peer_authentication/ ; https://istio.io/latest/docs/concepts/security/ | "Otherwise treated as `PERMISSIVE`." / "Istio automatically upgrades all traffic between two PEPs to mutual TLS." | principals 需要的是「這條連線走 mTLS」，不需要 STRICT；沒有 PeerAuthentication 時是 PERMISSIVE＋auto-mTLS，principal 也有值。STRICT 的作用是拒收明文。註解改成「2a. STRICT：拒絕沒有 sidecar 的明文流量（principals 本身在 auto-mTLS 下就有值）」（與 P00-061、P02-001 一致） | ✓ |
| P04-009 | 1286–1287 | `"cluster.local/ns/istio-system/sa/istio-ingressgateway"` | 不精確 | https://istio.io/latest/docs/ops/configuration/security/security-policy-examples/ | "principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]" | istioctl/operator 預設 SA 是 `istio-ingressgateway-service-account`，Helm gateway chart 等於 release 名稱；寫錯時規則 2 永遠不命中、外部流量全被拒。先查實際名稱再填（與 P05-002 一致） | ✓ |
| P04-010 | 1289 | health / metrics 任何人都能打，不然 probe 和 Prometheus 會死 | 不精確 | https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/ ; https://istio.io/latest/docs/ops/integrations/prometheus/ | "The rewriting of problematic probes is enabled by default in all built-in Istio configuration profiles" / "This option is enabled by default but can be disabled by passing `--set meshConfig.enablePrometheusMerge=false`" | 預設 probe 改寫到 15020、metrics 合併從 15020 抓，都不經 inbound AuthZ，「不加規則 3 就會死」只在關掉改寫或合併時成立。規則 3 沒有 `from`，等於對所有來源開放這些 path。改成：只有關閉 probe 改寫／metrics merge 時才需要，範圍縮到最小（與 P03-003 一致） | ✓ |
| P04-011 | 1297–1300 | `action: AUDIT` 先設這個，跑幾天，確認 log 裡沒有該放行卻被記錄的來源 | 錯誤 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ ; https://istio.io/latest/docs/tasks/security/authorization/authz-dry-run/ | "AUDIT policies do not affect whether requests are allowed or denied to the workload." / "A separate plugin must be configured and enabled to actually fulfill the audit decision and complete the audit behavior." / "dry-run the policy without actually enforcing it." | AUDIT 記的是「規則命中」的請求，語意跟原文相反，而且沒有 plugin 什麼都不記。改成：保留 `action: ALLOW`，加 annotation `istio.io/dry-run: "true"`（Alpha），看 proxy debug log 的 `shadow denied` 或 `authz_dry_run_result` 指標，確認後拿掉 annotation（與 P02-006 一致） | ✓ |
| P04-012 | 1355–1359 | `# 必開：ingressgateway`，只寫 `namespaceSelector: istio-system` | 不精確 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "allows connections from Pods in the local Namespace with the label `role=client`, _or_ from any Pod in any namespace with the label `user=alice`." | 沒有 podSelector 也沒有 ports，放行的是 istio-system **所有 Pod** 到**所有 port**。收斂：同一個元素加 `podSelector: {matchLabels: {istio: ingressgateway}}`，再加 `ports: [{protocol: TCP, port: 8080}]` | ✓ |
| P04-013 | 1331, 1369 | Istio policy 管的是「經過 sidecar 的流量」；攻擊者在 pod 裡直接連 Pod IP 繞過 sidecar —— AuthorizationPolicy：不行 | 錯誤 | https://istio.io/latest/docs/ops/best-practices/security/ | "the security boundary is that a client may not bypass _another_ pod's sidecar." | 攻擊者繞過的是**自己**的 sidecar；epmm-api 的 inbound 仍被它自己的 sidecar 攔下，沒有 mTLS 憑證就沒有 principal，ALLOW 不命中，STRICT 下明文直接被拒。這一格改成「可以（被呼叫端的 sidecar 仍會執行）」；AuthZ 擋不到的是 non-TCP 與被排除在攔截之外的 port，NetworkPolicy 的價值在 L3/L4 縱深防禦與防 sidecar 被拿掉或設錯（與 P02-206、P02-217 一致） | ✓ |
| P04-014 | 1370 | 攻擊者偽造 `X-User-Id` header —— AuthorizationPolicy 可以（`when` 條件） | 不精確 | https://istio.io/latest/docs/reference/config/security/conditions/ | `request.headers`: "HTTP request headers." / `request.auth.claims`: "Raw claims of the authenticated JWT token." | `when: request.headers[...]` 只比對值，看不出是不是偽造。防偽造要用 RequestAuthentication 驗 JWT 再用 `request.auth.claims[...]` 或 `requestPrincipals` 授權，或在 ingress 端剝掉外部帶進來的 `X-User-Id` | ✓ |
| P04-015 | 1378 | `kubectl exec … -c app -- curl …` | 環境特定 | — | — | app 映像有沒有 curl 看 Dockerfile；沒有就改用 `kubectl debug --target=app --image=curlimages/curl …` | ✓ |
| P04-016 | 1382 | 000/timeout = NetworkPolicy 或 DNS | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | UF: "Upstream connection failure in addition to `503` response code." | 來源端有 sidecar 時 curl 連的是本機 Envoy，TCP 一定建得起來；NetworkPolicy 擋掉時 Envoy 連上游失敗回 **503**（`UF`，通常等到 connect timeout 之後）；mTLS 不一致也是 503。只有 DNS 失敗（curl exit 6）或沒有 sidecar 才會看到 000。改成：200 通；403 授權（`RBAC: access denied`）；503＋UF 多半是網路層或 mTLS；000 多半是 DNS | ✓ |
| P04-017 | 1384–1385 | 確認走的是 mTLS 而不是明文：`istioctl x describe pod …` | 不精確 | https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/ ; https://istio.io/latest/docs/reference/commands/istioctl/ | "Pilot reports that pod enforces mTLS and clients speak mTLS" / "Analyzes pod, its Services, DestinationRules, and VirtualServices and reports the configuration objects that affect that pod." | describe 回報的是**設定推論**（且是 experimental），不是實際流量。改成「確認設定上會走 mTLS」；確認實際流量看 `istio_requests_total{connection_security_policy="mutual_tls"}` 或 access log | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P04-018 | 1171 | Pod 預設不隔離 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P04-019 | 1178 | 跨 ns 短名解析不到 | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ |
| P04-020 | 1182 | `svc.ns` 可解析 | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ |
| P04-021 | 1190–1194 | resolv.conf 格式與 ndots:5 | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ |
| P04-022 | 1196 | 先補自己 ns，跨 ns 首查必敗 | https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ |
| P04-023 | 1209–1223 | SA YAML 合法 | https://kubernetes.io/docs/concepts/security/service-accounts/ |
| P04-024 | 1225–1231 | SA 設在 pod template spec | https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/ |
| P04-025 | 1232 | Pod spec 的 automount 優先 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/ |
| P04-026 | 1238 | 關 automount 不影響 Istio 身分 | https://raw.githubusercontent.com/istio/istio/master/manifests/charts/istio-control/istio-discovery/files/injection-template.yaml |
| P04-027 | 1238 | 憑證經 SDS 給 Envoy | https://istio.io/latest/docs/concepts/security/ |
| P04-028 | 1245, 1324 | istioctl 接受 deployment/ 形式 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P04-029 | 1252–1259 | PeerAuthentication v1、STRICT 語意 | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| P04-030 | 1262–1281 | AuthZ v1 欄位結構 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P04-031 | 1277 | principal 格式 `td/ns/x/sa/y` | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P04-032 | 1281, 1292 | `*` 結尾是前綴比對 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P04-033 | 1283, 1289 | 多條 rules 是 OR | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P04-034 | 1305 | 沒列入 egress 就沒有對方的設定 | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P04-035 | 1308–1318 | Sidecar v1、`ns/dnsName` 格式、名稱 default | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P04-036 | 1324–1325 | `pc cluster --fqdn` 用法 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P04-037 | 1346–1352 | ns+pod selector 同元素是 AND | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P04-038 | 1349 | metadata.name label 自動帶 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P04-039 | 1366–1368 | NP 只到 L4；AuthZ 管 L7 method | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P04-040 | 1372 | 兩者疊加做縱深防禦 | https://istio.io/latest/docs/ops/best-practices/security/ |
| P04-041 | 1382 | 403 是授權拒絕 | https://istio.io/latest/docs/tasks/security/authorization/authz-http/ |
| P04-042 | 1385 | `istioctl x describe pod` 存在 | https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/ |

---

## Part 5（上半）：獨立 cluster 互打 —— 封包路徑、身分斷點、三種補救方案

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P05-001 | 1430 | 若有收斂過，沒把對方 host 列進去就**出不去** | 不精確 | https://istio.io/latest/docs/reference/config/networking/sidecar/ | "If requests are sent to destinations not included in the scoping, the traffic will be treated as unmatched traffic" / "In REGISTRY_ONLY mode, unknown outbound traffic will be dropped." | 改成：沒列進 `egress.hosts` 的目的地被當成 unmatched traffic —— `REGISTRY_ONLY` 時丟棄；預設 `ALLOW_ANY` 時通常仍經 PassthroughCluster 放行，只是失去 ServiceEntry／DR 的設定（TLS origination、逾時等） | ✓ |
| P05-002 | 1448（1467 也有） | 看到的來源永遠是 `cluster.local/ns/istio-system/sa/istio-ingressgateway` | 不精確 | https://istio.io/latest/docs/ops/configuration/security/security-policy-examples/ | "notPrincipals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]" | 拿掉「永遠」：principal 是 `<trust-domain>/ns/<gateway ns>/sa/<gateway 的 SA>`；istioctl 預設裝法的 SA 是 `istio-ingressgateway-service-account`，Helm gateway chart 跟 release 名稱走；trust domain 也不一定是 `cluster.local`。先用 `kubectl get pod -n istio-system -l istio=ingressgateway -o jsonpath='{..serviceAccountName}'` 確認，1467 那條 policy 一起改 | ✓ |
| P05-003 | 1490–1491、1510 | `issuer: "https://keycloak.example.com/auth/realms/my-realm"` | 過時 | https://www.keycloak.org/migration/migrating-to-quarkus ; https://www.keycloak.org/securing-apps/oidc-layers | "By default, the new Quarkus distribution removes `/auth` from the context-path." / "/realms/{realm-name}/protocol/openid-connect/certs" | 改成 `https://<host>/realms/<realm>` 與 `.../realms/<realm>/protocol/openid-connect/certs`；只有設了 `http-relative-path=/auth` 或舊版 WildFly 才保留 `/auth`。issuer 必須跟 token 的 `iss` 逐字相同，否則所有 token 都 401 —— 以 `/.well-known/openid-configuration` 回傳的 `issuer` 為準；1510 的 requestPrincipals 前綴一起改 | ✓ |
| P05-004 | 1513 | `request.auth.claims[azp]` # authorized party = client_id | 無法驗證 | https://istio.io/latest/docs/reference/config/security/conditions/ | "The authorized presenter of the authenticated JWT token, constructed from the JWT claim `<azp>`," | 語法正確，但「Keycloak 的 azp 等於 client_id」在 keycloak.org 找不到明文。註明「以實際 decode 的 token 為準」，或改用 Istio 內建的 `request.auth.presenter`（就是 azp） | ✓ |
| P05-005 | 1521 | `RequestAuthentication` **本身不擋任何東西** | 不精確 | https://istio.io/latest/docs/reference/config/security/request_authentication/ | "It will reject a request if the request contains invalid authentication information" / "A request that does not contain any authentication credentials will be accepted but will not have any authenticated identity." | 改成：RequestAuthentication 不擋**沒帶** token 的請求，但會直接以 401 拒絕帶了**無效** token 的請求（簽章錯、過期、iss 不符） | ✓ |
| P05-006 | 1504–1518 對照 1542 | DENY 上寫 `notPaths: ["/actuator/health*"]  # health check 除外` | 不精確 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "If there are no ALLOW policies for the workload, allow the request." / "If any of the ALLOW policies match the request, allow the request." / "Deny the request." | 同一 workload 已有 `epmm-api-require-jwt` 這條 ALLOW（只放 `/api/*` 的 GET/POST），`/actuator/health` 躲過 DENY 後仍因沒有 ALLOW 命中而 403，註解說的「除外」不成立。改成：在 ALLOW 另加一條 rule 放行 health 路徑，或明講 kubelet 探針經 probe rewrite 走 pilot-agent、本來就不受影響；並說明這條 DENY 在有 requestPrincipals ALLOW 時是多餘的保險 | ✓ |
| P05-007 | 1550–1569 | 「只允許 A cluster 的出口網段進來」，ALLOW 掛在共用的 `istio: ingressgateway` 上 | 不精確 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "If there are no ALLOW policies for the workload, allow the request." / "Deny the request." | 共用 ingressgateway 上一出現 ALLOW，**其他所有 host 的流量**沒命中就 403，整個 cluster 對外服務一起中斷。改成 `action: DENY`＋`notRemoteIpBlocks: ["10.20.30.0/24"]`，`to.operation.hosts` 只寫 epmm-api，並加警告。**前提同 P05-008**：gateway 必須真的拿得到 client IP（L7 LB 附加 XFF＋numTrustedProxies，或 PROXY protocol），否則 remote IP 退回 LB／node IP，DENY 永遠不觸發、全部靜默放行（同 P02-010） | ✓ |
| P05-008 | 1577 | `numTrustedProxies: 1     # B 的 VIP/F5 算一層` | 不精確 | https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/ | "proxies in front of the Istio gateway proxy must parse HTTP traffic and append to the X-Forwarded-For header at each hop." / "Envoy falls back to using the immediate downstream address as the trusted client address." | 只有 F5 做 L7 終止並附加 XFF 時才算一層。本節圖上 TLS 在 ⓸ gateway 終止，代表 F5 是 L4 透傳、加不了 XFF，remoteIpBlocks 會退回比對 F5／node IP。補上：L4 LB 改用 PROXY protocol，或 `externalTrafficPolicy: Local`＋`ipBlocks` | ✓ |
| P05-009 | 1584–1585 | `kubectl logs ...` 再 grep x-forwarded-for | 錯誤 | https://istio.io/latest/docs/tasks/observability/logs/access-log/ | 預設格式含 `"%REQ(X-FORWARDED-FOR)%"`（佔位符會被換成 header 的值，範例輸出是 `"-"`） | 預設 TEXT 格式只印 XFF 的**值**、不印 header 名稱，grep 永遠是空的。改成直接看最近幾行 log 找引號內的 IP 串，或打 httpbin `/get` 看收到的 XFF；並註明 access log 預設沒開（`meshConfig.accessLogFile=/dev/stdout` 或 Telemetry API，與 P01-006 一致） | ✓ |
| P05-010 | 1590、1592 | TLS passthrough（保留原始憑證…）；由後端自己驗 client 憑證 | 不精確 | https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/ ; https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "This instructs the gateway to pass the ingress traffic “as is”, without terminating TLS" / "A list of peer identities derived from the peer certificate." | 保留的是 A 的 **app** 自己發起的 TLS，不是 A 的 Istio workload 身分：A 的 app 要自備 B 的 app 信任的 client cert，由**應用程式**（不是 B 的 sidecar）驗；B sidecar 的 `principals` 看到的仍是 gateway 那條 mTLS 的身分，而且只能做 L4 判斷。標題改成「端到端 TLS（由 app 自行做 mTLS）」 | ✓ |
| P05-011 | 1627 | 沒有 path 路由、沒有 header 比對、**沒有 canary weight** | 錯誤 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ | RouteDestination: "Weight specifies the relative proportion of traffic to be forwarded to the destination." | 刪掉「沒有 canary weight」：tls route 可以用 `weight` 做連線層級的比例分流，只是不能依 header 或 path | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P05-012 | 1396 | 同 istiod／CA 才互信憑證 | https://istio.io/latest/docs/concepts/security/ |
| P05-013 | 1429 | AuthzPolicy 只管 inbound | https://istio.io/latest/docs/concepts/security/ |
| P05-014 | 1431 | REGISTRY_ONLY 需 SE，預設 ALLOW_ANY | https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/ |
| P05-015 | 1432 | DR 做 TLS origination | https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/ |
| P05-016 | 1433 | egress 被隔離時要放行 VIP | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P05-017 | 1435 | Gateway 依 host／TLS 收流量 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P05-018 | 1436 | VS 是 gateway 的路由規則 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P05-019 | 1437 | gateway 上用 remoteIpBlocks | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-020 | 1439 | gateway→app 是 B 內 mTLS | https://istio.io/latest/docs/concepts/security/ |
| P05-021 | 1442 | NetPol 來源是 gateway pod | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P05-022 | 1450 | gateway 終止 TLS 後重發 mTLS | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-023 | 1474 | JWT 屬 HTTP 層可穿透 | https://istio.io/latest/docs/reference/config/security/request_authentication/ |
| P05-024 | 1476 | client 內建 SA 可取 token | https://www.keycloak.org/docs/latest/server_admin/index.html |
| P05-025 | 1480/1495/1526/1551 | security.istio.io/v1 | https://istio.io/latest/docs/reference/config/security/request_authentication/ |
| P05-026 | 1491 | JWKS 路徑 openid-connect/certs | https://www.keycloak.org/securing-apps/oidc-layers |
| P05-027 | 1492 | forwardOriginalToken 保留 token | https://istio.io/latest/docs/reference/config/security/request_authentication/ |
| P05-028 | 1508 | requestPrincipals 為 iss/sub | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-029 | 1510 | `iss/*` 前綴比對 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-030 | 1513 | `request.auth.claims[x]` 語法 | https://istio.io/latest/docs/reference/config/security/conditions/ |
| P05-031 | 1521 | 無 token 會通過，要 AuthZ 擋 | https://istio.io/latest/docs/reference/config/security/request_authentication/ |
| P05-032 | 1539 | notRequestPrincipals ["*"] 擋無 JWT | https://istio.io/latest/docs/tasks/security/authentication/authn-policy/ |
| P05-033 | 1571 | remoteIpBlocks 需 numTrustedProxies | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-034 | 1574–1576 | gatewayTopology 設定路徑 | https://istio.io/latest/docs/ops/configuration/traffic-management/network-topologies/ |
| P05-035 | 1595–1607 | Gateway v1 + TLS + PASSTHROUGH | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P05-036 | 1617–1620 | PASSTHROUGH 用 tls+sniHosts | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P05-037 | 1592 | 後端自行終止 TLS | https://istio.io/latest/docs/tasks/traffic-management/ingress/ingress-sni-passthrough/ |
| P05-038 | 1627 | 無 path／header 路由與 L7 指標 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |

---

## Part 5（下半）：A／B cluster 各自要準備什麼、真正的 multi-cluster

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P05-201 | 1643–1646, 1650, 1658–1661 | ServiceEntry `number: 443 / name: https / protocol: HTTPS`＋「TLS origination（app 打 http，sidecar 幫你升級成 https）」 | 錯誤 | https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/ ; https://istio.io/latest/docs/reference/config/networking/service-entry/ | "will perform TLS origination for HTTP requests on port 80 and the `ServiceEntry` will then redirect the requests on port 80 to target port 443." / "TLS implies the connection will be routed based on the SNI header to the destination." | YAML 做不到註解說的事：只宣告 443 為 HTTPS，sidecar 會當成不透明的 TLS 依 SNI 透傳；app 打明文到 :443 沒有 SNI、不會發起 TLS，app 打 https 則會被 host 層級的 `tls: SIMPLE` 再加密一次。改法：ServiceEntry 加一個 port `{number: 80, name: http, protocol: HTTP, targetPort: 443}`，DR 的 TLS 移進 `portLevelSettings: - port: {number: 80}` 並設 `tls: {mode: SIMPLE}`，app 改打 `http://epmm-api.b-cluster.example.com`（80）。`connectionPool.http` 也要 port 是 HTTP 才生效 | ✓ |
| P05-202 | 1660–1661 | `sni: … # 內網自簽憑證常常漏這個 → handshake 失敗` | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "SNI will be automatically set based on downstream HTTP host/authority header" / caCertificates: "If omitted, the proxy will verify the server's certificate using the OS CA certificates." / credentialName: "This secret must exist in the namespace of the proxy using the certificates." | port 改成 HTTP 後 SNI 會依 Host header 自動帶入，漏 `sni` 不是自簽憑證失敗的主因；真正的問題是這份 DR 沒有 `caCertificates` 也沒有 `credentialName`，sidecar 用 OS 信任庫驗 B 的憑證，自簽一定失敗。改成：給內部 CA —— 用 `credentialName`（secret 放 **ea-pmc**，且 DR 要有 `workloadSelector`）或 `caCertificates`（掛進 sidecar 的檔案路徑），並加 `subjectAltNames`。註解改成「自簽憑證要給 CA，否則用 OS 信任庫驗證會失敗」 | ✓ |
| P05-203 | 1683–1699 | `# 4. NetworkPolicy：放行出向`，`policyTypes: [Egress]`，只放行 10.99.88.0/24:443 | 不精確 | https://kubernetes.io/docs/concepts/services-networking/network-policies/ | "A default deny-all egress policy also blocks DNS traffic. If your workloads need DNS resolution, you must add a separate NetworkPolicy that allows egress to your cluster's DNS service." | 講清楚這份是疊加式的：單獨套用時 Pod 進入 egress 隔離，DNS（`resolution: DNS` 時 Envoy 自己要透過 kube-dns 解析）與 istiod 15012 全被擋。加註「需搭配既有允許 kube-dns 53/UDP+TCP 與 istiod 15012 的 egress policy」 | ✓ |
| P05-204 | 1750–1752 | B 的 gateway「IP 白名單」用 `remoteIpBlocks: ["10.20.30.0/24"]` | 不精確 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | remoteIpBlocks: "A list of IP blocks, populated from `X-Forwarded-For` header or proxy protocol." / "To make use of this field, you must configure the `numTrustedProxies` field of the `gatewayTopology`" | 補前提：前面有 L7 LB／PROXY protocol 且設了 numTrustedProxies 才用 `remoteIpBlocks`；A 直接打 B 的 gateway LB VIP 時改用 `ipBlocks`，且 LB Service 要 `externalTrafficPolicy: Local` 才保得住來源 IP。另外 gateway 看到的通常是 A 的 node／NAT 出口 IP，不是 A 的 Pod CIDR（與 P02-007 一致） | ✓ |
| P05-205 | 1793 | Multi-Primary：兩個 cluster 各有 istiod，互相同步 endpoint | 不精確 | https://istio.io/latest/docs/ops/deployment/deployment-models/ | "each control plane must observe endpoints from the API Server in every cluster." / "To enable endpoint discovery for a cluster, an administrator generates a `remote secret`" | 改成：每個 istiod 透過 remote secret 直接 watch 對方 cluster 的 API server 取得 endpoint（istiod 之間不互相同步） | ✓ |
| P05-206 | 1795 | 把 Multi-Network 列成跟 Multi-Primary／Primary-Remote 並列的第三種模式 | 不精確 | https://istio.io/latest/docs/ops/deployment/deployment-models/ ; https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/ | "the workload instances in different networks can only reach each other through one or more Istio gateways." | 網路模型跟控制面模型是兩個獨立的選擇。表格拆成兩個維度：控制面（Multi-Primary／Primary-Remote）× 網路（single／multi-network），官方指南可以自由組合（例如 Multi-Primary on different networks） | ✓ |
| P05-207 | 1799 | 兩邊的 istiod 用同一張 root cert 簽發（`cacerts` secret） | 不精確 | https://istio.io/latest/docs/setup/install/multicluster/before-you-begin/ | "A multicluster service mesh deployment requires that you establish trust between all clusters in the mesh." / "This guide will assume that you use a common root to generate intermediate certificates for each primary cluster." | 改成：共用同一個 root CA，替每個 cluster 簽一張各自的 intermediate CA 放進 `cacerts`，istiod 用 intermediate 簽 workload 憑證（istiod 不直接用 root 簽） | ✓ |
| P05-208 | 1800 | 互相有對方的 API server 存取權（缺一不可） | 不精確 | https://istio.io/latest/docs/setup/install/multicluster/primary-remote/ | "we give the control plane in `cluster1` access to the API Server in `cluster2`." | 「互相」只在 Multi-Primary 成立；Primary-Remote 是單向的（primary 的 istiod 讀 remote 的 API server）。改成：每個 primary 要有所有 cluster API server 的存取權（remote secret） | ✓ |
| P05-209 | 1801 | east-west gateway 缺一不可 | 錯誤 | https://istio.io/latest/docs/setup/install/multicluster/multi-primary/ | "Both clusters reside on the `network1` network, meaning there is direct connectivity between the pods in both clusters." / "Service workloads communicate directly (pod-to-pod) across cluster boundaries." | 改成：只有 multi-network（跨網路流量）時必要；Primary-Remote 即使同網路也常用它暴露 istiod 給 remote；同網路的 Multi-Primary 不需要 | ✓ |
| P05-210 | 1802 | `topology.istio.io/network` label 缺一不可 | 錯誤 | https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/ ; https://istio.io/latest/docs/setup/install/multicluster/multi-primary/ | "If the istio-system namespace is already created, we need to set the cluster's network there:"（單一網路的指南不設這個 label，只在安裝設定寫 "network: network1"） | 改成：multi-network 時須在 istio-system namespace 標 `topology.istio.io/network`。另補真正共通的前提：唯一的 `clusterName`、相同的 `meshID`、（單一網路時）Pod/Service CIDR 不重疊 | ✓ |
| P05-211 | 1812–1813 | 跨 cluster 的 locality failover…A cluster 的服務掛了自動導到 B cluster，app 完全無感 | 不精確 | https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/failover/ ; https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "This is required in order for failover to function properly."（指 outlierDetection）/ "Note: if no OutlierDetection specified, this will not take effect." | 補上：DR 必須設 `outlierDetection`（需要時再加 `localityLbSetting`／`failover`）；failover 要等錯誤累積到 ejection 才觸發，會有請求先失敗。「app 完全無感」改成「需靠 retry 才能讓 app 幾乎無感」；failover 依 locality（region/zone）決定，不是依 cluster | ✓ |
| P05-212 | 1822 | 網路不互通，只有幾個開放的 VIP → 不能換，multi-cluster 要求網路可達 | 不精確 | https://istio.io/latest/docs/ops/deployment/deployment-models/ ; https://istio.io/latest/docs/setup/install/multicluster/before-you-begin/ | "the workload instances in different networks can only reach each other through one or more Istio gateways." / "The API Server in each cluster must be accessible to the other clusters in the mesh." | multi-network 本來就是給 Pod 不能直連的網路用的，不需要 Pod 互通；需要的是 east-west gateway 與 API server（Primary-Remote 再加 istiod）可達。改成「若連 API server 與 east-west gateway 都無法開放，才不能換」 | ✓ |
| P05-213 | 1827 | istiod 版本必須同步升級 | 無法驗證 | https://istio.io/latest/docs/setup/install/multicluster/before-you-begin/ | （官方沒有「所有 cluster 必須同版本」的規定） | 改成：需遵守 control plane／data plane 版本差的支援規則，Primary-Remote 的 remote proxy 版本不可超過 primary istiod；或刪除 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P05-214 | 1633 等 | networking.istio.io/v1 有效 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P05-215 | 1641 | MESH_EXTERNAL＝mesh 外部 | https://istio.io/latest/docs/reference/config/networking/service-entry/ |
| P05-216 | 1642 | resolution DNS 非同步解析 | https://istio.io/latest/docs/reference/config/networking/service-entry/ |
| P05-217 | 1647–1648 | exportTo "." 僅本 ns | https://istio.io/latest/docs/reference/config/networking/service-entry/ |
| P05-218 | 1660 | SIMPLE＝單向 TLS 發起 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P05-219 | 1663–1664 | connectTimeout 等欄位有效 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P05-220 | 1665–1668 | outlierDetection 欄位有效（TCP 計連線失敗） | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P05-221 | 1678–1681 | egress hosts 用 ns/dnsName | https://istio.io/latest/docs/reference/config/networking/sidecar/ |
| P05-222 | 1718 | secret 放 istio-system（gateway workload ns） | https://istio.io/latest/docs/reference/config/analysis/ist0161/ |
| P05-223 | 1720 | Gateway hosts 無前綴＝*/ | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P05-224 | 1730 | 跨 ns 引用 ns/gateway | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P05-225 | 1738 | HTTPRoute timeout 欄位 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P05-226 | 1741–1748 | ALLOW：沒匹配就拒絕 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-227 | 1766–1768 | metadata.name 自動 label | https://kubernetes.io/docs/concepts/services-networking/network-policies/ |
| P05-228 | 1777 | gateway→app 走 B 內 mTLS | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-229 | 1778, 1783 | 來源變 gateway SA | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-230 | 1782 | A 的 AuthZ 管 inbound | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P05-231 | 1793 | Multi-Primary 要 API server 互通 | https://istio.io/latest/docs/setup/install/multicluster/before-you-begin/ |
| P05-232 | 1794 | Primary-Remote 依賴 primary（「完蛋」是原文誇飾） | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P05-233 | 1800 | create-remote-secret 產生 secret | https://istio.io/latest/docs/setup/install/multicluster/multi-primary/ |
| P05-234 | 1807–1810 | 跨 cluster 保留 workload 身分（前提：同一 trust domain） | https://istio.io/latest/docs/ops/deployment/deployment-models/ |

---

## Part 6.1–6.2：Deployment、Service

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P06-001 | 1845 | 每次改 `template` 就產生一個新的 ReplicaSet，然後逐步把流量從舊的挪到新的 | 不精確 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ | "If the readiness probe returns a failed state, the EndpointSlice controller removes the Pod's IP address from the EndpointSlices of all Services that match the Pod." | 改成「Deployment 只負責逐步調整新、舊 ReplicaSet 的 Pod 數量；流量會不會轉移，取決於 Service／EndpointSlice 依 Pod 的 ready 狀態更新後端清單（在 mesh 裡則是 Envoy）」。Deployment 本身不搬流量。 | ✓ |
| P06-002 | 1862 | minReadySeconds … 防止一 ready 就被塞流量 | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | "specifies the minimum number of seconds for which a newly created Pod should be ready without any of its containers crashing, for it to be considered available" | 改成「Pod ready 後要穩定多久，才被 Deployment 算進 available（會影響滾動更新的推進速度）」。Pod 一旦 ready 就會被放進 EndpointSlice 開始接流量，minReadySeconds 擋不住流量。 | ✓ |
| P06-003 | 1920 | 各 zone 之間 Pod 數量最多差 1 | 不精確 | https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ | "if you select whenUnsatisfiable: ScheduleAnyway, the scheduler gives higher precedence to topologies that would help reduce the skew." | 範例搭配的是 `ScheduleAnyway`，maxSkew 只是排程偏好，實際差距可能超過 1。改成「盡量讓各 zone 差距不超過 1；只有 DoNotSchedule 才是硬上限」。 | ✓ |
| P06-004 | 1932-1935 | not-ready … node 失聯後，撐 300 秒才被驅逐（預設 300） | 不精確 | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ | "node.kubernetes.io/unreachable: Node is unreachable from the node controller. This corresponds to the NodeCondition Ready being \"Unknown\"." / "Kubernetes automatically adds a toleration for node.kubernetes.io/not-ready and node.kubernetes.io/unreachable with tolerationSeconds=300" | 「失聯」對應的是 `node.kubernetes.io/unreachable`；`not-ready` 指的是 Ready=False。另外系統本來就會自動加上 300 秒的這兩條 toleration，範例這樣寫只是重複一次預設值。建議改註解並註明「只有要調整秒數時才需要寫」，或改成示範 unreachable。 | ✓ |
| P06-005 | 1937 | priorityClassName: high-priority # 資源不足時，優先保住高優先權的 Pod | 不精確 | https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/ | "If the priority class is not found, the Pod is rejected." | 補註「叢集裡必須先建好名為 high-priority 的 PriorityClass，否則 Pod 在 admission 階段就會被拒絕」。作用也要寫清楚：優先權決定排程佇列的順序，而且可以搶占（preempt）低優先權的 Pod。 | ✓ |
| P06-006 | 1940 | 收到 SIGTERM 後給多久優雅關閉（預設 30） | 不精確 | https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/ | "The Pod's termination grace period countdown begins before the PreStop hook is executed" | 預設 30 秒沒錯，但倒數是從 Pod 開始終止就起算，preStop 執行的時間也算在裡面。範例的 preStop 睡 10 秒，app 實際收到 SIGTERM 後只剩約 50 秒。改成「從開始終止起算的總預算，含 preStop 時間」。 | ✓ |
| P06-007 | 2016-2021 | exec: command: ["/bin/sh", "-c", "sleep 10"] # 收到 SIGTERM 前先睡幾秒 | 不精確 | https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/3960-pod-lifecycle-sleep-action/kep.yaml | "stage: stable" / "stable: \"v1.34\"" / "- name: PodLifecycleSleepAction" | 順序說得對（先跑 preStop，後送 SIGTERM）。但 exec 寫法要求 image 裡有 `/bin/sh`；distroless 之類的 image 沒有 sh，hook 會失敗，等於沒有 sleep，502 還是會出現。建議補一句：K8s v1.30 起是 beta、v1.34 起 GA，可以改寫成 `preStop: { sleep: { seconds: 10 } }`，由 kubelet 執行，不依賴 shell。 | ✓ |
| P06-008 | 2073 | liveness 和 readiness 用同一個 endpoint … failureThreshold 至少要是 readiness 的 3 倍 | 不精確 | https://kubernetes.io/docs/concepts/workloads/pods/probes/ | "A common pattern for liveness probes is to use the same low-cost HTTP endpoint as for readiness probes, but with a higher failureThreshold." | 官方說共用同一個 endpoint 是常見做法，問題出在門檻一樣，不在 endpoint 相同。「3 倍」找不到官方依據，請改成經驗值的寫法。另外上方 YAML 三種 probe 都打 `/actuator/health`，liveness 的 failureThreshold 也同樣是 3，跟這條建議自相矛盾。建議把 liveness 改成 `/actuator/health/liveness`、readiness 改成 `/actuator/health/readiness`，或提高 liveness 的 failureThreshold。 | ✓ |
| P06-009 | 2078 | 只設 limits 不設 requests：K8s 會把 requests 設成等於 limits，QoS 變 Guaranteed | 不精確 | https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/ | "Every Container in the Pod must have a CPU limit and a CPU request, both greater than zero." | 「requests 會從 limits 複製過來」是對的。但要成為 Guaranteed，Pod 裡每一個容器的 cpu 和 memory 都得設 limit，而且 request 等於 limit；只設 memory limit 的話是 Burstable。Istio 注入的 istio-proxy 也算一個容器，它的 requests/limits 不相等時，整個 Pod 就不會是 Guaranteed。請把這兩個條件補上。 | ✓ |
| P06-010 | 2081 | Pod 已經收到 SIGTERM 但 endpoint 還沒從所有 node 的 iptables 移除 | 不精確 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ | "Any endpoints that represent the terminating Pods are not immediately removed from EndpointSlices, and a status indicating terminating state is exposed from the EndpointSlice API." | 終止中的 endpoint 不會馬上被移除，而是標成 terminating、ready=false。在這個 mesh 裡，延遲主要來自 istiod 把 EDS 更新推到各個 Envoy，跟 iptables 關係不大。建議改成「endpoint 狀態要傳遞到所有 kube-proxy／Envoy 需要時間」。 | ✓ |
| P06-011 | 2115 | 【Istio 關鍵】名稱決定協定判定，一定要命名 | 不精確 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ | "appProtocol takes precedence over the port name." | 判定順序是 appProtocol 優先，其次才是 port 名稱前綴。已經設了 appProtocol 的話，名稱就不是判定依據。K8s 只在多個 port 時強制要命名。建議改成「appProtocol 或 port 名稱前綴擇一明確宣告（兩者都寫最好）」。 | ✓ |
| P06-012 | 2165 | 不命名 = 只能用 L4 功能 | 錯誤 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ | "If the protocol cannot automatically be determined, traffic will be treated as plain TCP traffic." | 沒命名時 Istio 會自動偵測 HTTP/HTTP2，偵測得到就能用 L7；有 appProtocol 也一樣可以用 L7。這也跟本節 2183、2185 行的說法互相矛盾。改成「沒命名也沒 appProtocol 時靠自動偵測，偵測失敗才當 TCP（L4）」。 | ✓ |
| P06-013 | 2169 | Local 時，沒有該 Pod 的 node 會拒絕連線 | 不精確 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ | "(Traffic mistakenly sent to a node with no endpoints will be dropped.)" | 封包是被丟棄（drop），不是拒絕（reject），client 端看到的是 timeout，不是 connection refused。另外補充：外部 LB 會用 healthCheckNodePort 把這種 node 排除掉。 | ✓ |
| P06-014 | 2185 | 對 server-first 協定（MySQL、Redis）會誤判並造成連線 hang | 錯誤 | https://istio.io/latest/docs/ops/deployment/application-requirements/ | "The following ports are known to commonly carry server first protocols, and are automatically assumed to be TCP:" （官方表格列的是 SMTP 25、DNS 53、MySQL 3306、MongoDB 27017） | Redis 是 client 先送命令，不屬於 server-first，請刪掉 Redis，改舉 MySQL、SMTP、MongoDB。官方也沒有描述「hang」這個症狀，建議改成「與自動偵測及 PERMISSIVE mTLS 不相容，必須明確宣告為 TCP；但標準 port（例如 3306）Istio 會自動當成 TCP」。 | ✓ |
| P06-015 | 2209-2211 | httpCookie: name: JSESSIONID … ttl: 10800s （方案 A 最推薦） | 錯誤 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "If specified, a cookie with the TTL will be generated if the cookie is not present." | 設了 ttl 之後，請求沒帶這個 cookie 時，Envoy 會自己產生一個同樣叫 JSESSIONID 的 cookie，跟 Spring 的 session cookie 撞名。Spring 收到不認得的 session id 會重發 JSESSIONID，雜湊值跟著變，黏著反而被破壞。建議改用專用名稱，例如 `name: istio-session-affinity` 加 `ttl: 10800s`，交給 Envoy 管理，不要跟 JSESSIONID 共用。如果一定要用 JSESSIONID 就拿掉 ttl，但第一個請求落在哪個 Pod，不保證就是之後雜湊對到的那個 Pod。 | ✓ |
| P06-016 | 2220 | consistentHash 用的是 ring hash 演算法 | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "The Maglev load balancer implements consistent hashing to backend hosts." | consistentHash 有 ringHash 和 maglev 兩種演算法可選，官方頁面沒有寫哪一種是預設。改成「一致性雜湊（ringHash 或 maglev）」。 | ✓ |
| P06-017 | 2227 | kubectl get endpoints <svc> 沒東西 | 過時 | https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/ | "a kubernetes.io/service-name label that enables simple lookups of all EndpointSlices belonging to a Service" （同頁註明 Endpoints API 自 v1.33 起 deprecated） | 改成 `kubectl get endpointslices -n ea-pmc -l kubernetes.io/service-name=<svc>`，順便說明 Endpoints API 從 v1.33 起已經 deprecated。 | ✓ |
| P06-018 | 2228 | targetPort 填了不存在的名稱：不會報錯，但 endpoint 永遠是空的 | 無法驗證 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ | "If this is a string, it will be looked up as a named port in the target Pod's container ports." | 官方文件沒寫「名稱查不到」時會怎樣。建議改成較保守的寫法：「名稱對不到 containerPort 時，該 port 不會產生可用的 endpoint，API 也不會報錯」，並附上實測方法（檢查 EndpointSlice 的 ports 欄位）。 | ✓ |
| P06-019 | 2229 | externalTrafficPolicy: Local + 節點沒有 Pod … 要搭配 topologySpreadConstraints 確保每個 node 都有 Pod | 不精確 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ | "External systems (e.g. load-balancers) can use this port to determine if a given node holds endpoints for this service or not." | topologySpreadConstraints 保證不了「每個 node 都有 Pod」（只有 2 個 replica 時根本不可能）。正規做法是讓 LB 透過 healthCheckNodePort 自動避開沒有 endpoint 的 node；真的要每台都有，就得用 DaemonSet。 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P06-020 | 1859 | 用 HPA 時不要寫 replicas | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-021 | 1860 | revisionHistoryLimit 預設 10、佔 etcd | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-022 | 1861 | progressDeadlineSeconds 預設 600 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-023 | 1865 | Recreate 先全殺再全起 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-024 | 1867-1868 | maxSurge/maxUnavailable 可填數字或百分比 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-025 | 1872 | selector 須符合 template，建立後不可改 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-026 | 1878 | version label 供 DR subset 分流 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P06-027 | 1880-1881 | 改 template 的 annotation 會觸發 rollout | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-028 | 1883 | holdApplicationUntilProxyStarts 延後 app 啟動 | https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/ |
| P06-029 | 1886 | SA 是 Istio principal 的來源 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P06-030 | 1887 | automountServiceAccountToken 可設 false | https://kubernetes.io/docs/concepts/security/service-accounts/ |
| P06-031 | 1890 | nodeSelector 是硬性條件 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/scheduling-eviction/assign-pod-node.md |
| P06-032 | 1894 | nodeAffinity 支援 In/NotIn/Exists | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/scheduling-eviction/assign-pod-node.md |
| P06-033 | 1902 | 偏好規則 weight 範圍 1~100 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/scheduling-eviction/assign-pod-node.md |
| P06-034 | 1922 | ScheduleAnyway 與 DoNotSchedule 的語意 | https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ |
| P06-035 | 1929 | Equal 比對 value，Exists 只看 key | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ |
| P06-036 | 1931 | taint 有三種 effect | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ |
| P06-037 | 1958 | 用明確 tag 時 IfNotPresent 少查一次 registry | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/containers/images.md |
| P06-038 | 1961 | 命名 port 可被 targetPort 引用 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| P06-039 | 1983 | requests 是排程依據 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/configuration/manage-resources-containers.md |
| P06-040 | 1986 | 超過 memory limit 被 OOM，超過 cpu limit 被 throttle | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/configuration/manage-resources-containers.md |
| P06-041 | 1995-1997 | startup 給 300 秒，成功前不跑另兩種 probe | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ |
| P06-042 | 1999 | readiness 失敗移出 endpoint、不重啟 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ |
| P06-043 | 2008-2014 | liveness 失敗重啟，約 90 秒 | https://kubernetes.io/docs/concepts/workloads/pods/probes/ |
| P06-044 | 2049-2055 | 表中各欄預設值（1/25%/25%/0/10/600/30） | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-045 | 2062 | serviceAccountName 預設為 default | https://kubernetes.io/docs/concepts/security/service-accounts/ |
| P06-046 | 2069 | startupProbe 失敗會重啟容器 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ |
| P06-047 | 2077 | selector 不能改，只能砍掉重建 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ |
| P06-048 | 2079 | memory limit 是硬上限 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/configuration/manage-resources-containers.md |
| P06-049 | 2080 | cpu limit 會造成 throttling | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/configuration/manage-resources-containers.md |
| P06-050 | 2096 | mesh 內負載平衡由 sidecar 負責 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/reference/networking/virtual-ips.md |
| P06-051 | 2109 | 預設型別是 ClusterIP | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/services-networking/service.md |
| P06-052 | 2112 | selector 比對的是 Pod label | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/services-networking/service.md |
| P06-053 | 2117 | targetPort 可以填名稱 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| P06-054 | 2119 | appProtocol 是明確的協定宣告 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ |
| P06-055 | 2125 | 10800 秒等於 3 小時（也是預設值） | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/reference/networking/virtual-ips.md |
| P06-056 | 2127 | internalTrafficPolicy Local 只走本機 Pod | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| P06-057 | 2133 | Headless 的 DNS 直接回傳 Pod IP | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/services-networking/service.md |
| P06-058 | 2145 | nodePort 預設範圍 30000-32767 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/services-networking/service.md |
| P06-059 | 2150 | Local 保留 client IP，Cluster 是預設 | https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/ |
| P06-060 | 2151 | loadBalancerSourceRanges 是 LB 層白名單 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| P06-061 | 2156 | ExternalName 是 DNS CNAME | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/services-networking/service.md |
| P06-062 | 2164 | Headless 靠 clusterIP: None，不是一種 type | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/concepts/services-networking/service.md |
| P06-063 | 2166 | appProtocol 優先於 port 名稱 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ |
| P06-064 | 2170 | 本機沒 Pod 就連不到 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| P06-065 | 2171 | 需要 LB 供應商支援 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ |
| P06-066 | 2179-2182 | port 名稱前綴對應的協定 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ |
| P06-067 | 2183 | 未命名時走自動偵測 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ |
| P06-068 | 2193 | sessionAffinity 是 kube-proxy 的功能 | https://raw.githubusercontent.com/kubernetes/website/main/content/en/docs/reference/networking/virtual-ips.md |
| P06-069 | 2198 | apiVersion 為 networking.istio.io/v1 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P06-070 | 2216 | consistentHash 可用 useSourceIp | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |

---

## Part 6.3–6.4：ConfigMap（與 Secret）、CronJob／Job

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P06-201 | 2239 | 有 `kubectl get secret` 權限的人就能看到內容 | 不精確 | https://kubernetes.io/docs/concepts/configuration/secret/ | "Anyone with API access can retrieve or modify a Secret, and so can anyone with access to etcd. Additionally, anyone who is authorized to create a Pod in a namespace can use that access to read any Secret in that namespace; this includes indirect access such as the ability to create a Deployment." | 補一句：「能存取 etcd 的人看得到；在該 namespace 能建 Pod 或 Deployment 的人，也能把任何 Secret 掛進 Pod 讀出來。所以只收 `get secret` 權限不夠。」再列官方建議的四步：encryption at rest、最小權限 RBAC、只讓特定容器存取、外部 secret store。 | ✓ |
| P06-202 | 2296, 2321 | subPath 是掛載當下複製的 | 不精確 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ | "A container using a ConfigMap as a subPath volume will not receive ConfigMap updates." | 結論（不會更新）是對的，機制寫錯。官方只陳述結果，沒說是「複製」。實際上 subPath 是把當下那個檔案 bind mount 進容器；ConfigMap 更新時 kubelet 換掉的是 `..data` symlink，bind mount 還指著舊檔。建議改成「subPath 綁定的是掛載當下那個檔案，看不到之後的更新」。 | ✓ |
| P06-203 | 2306, 2355 | `defaultMode: 0444`（八進位檔案權限） | 無法驗證 | https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/volume/ | （抓取的內容在 ConfigMapVolumeSource 段落之前就被截斷，沒取得原文） | 寫法本身沒有可疑之處。這次沒能拿到 `defaultMode` 的官方原文（包含預設值 0644），建議下一批人工再核對 API reference。 | ✓ |
| P06-204 | 2320 | 會（約 1 分鐘內） | 不精確 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ | "the total delay from the moment when the ConfigMap is updated to the moment when new keys are projected to the pod can be as long as kubelet sync period (1 minute by default) + TTL of ConfigMaps cache (1 minute by default) in kubelet." | 改成「會，但最長可能要 kubelet sync period（預設 1 分鐘）加上快取 TTL（預設 1 分鐘），也就是大約 2 分鐘；改一下 Pod 的 annotation 可以立刻觸發刷新」。 | ✓ |
| P06-205 | 2338 | `kubectl get configmap ... -o yaml` 再 sha256sum | 不精確 | https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/object-meta/ | "UID is the unique in time and space value for this object. It is typically generated by the server on successful creation of a resource" | 對整份 live 物件的 YAML 算雜湊，會把 server 填的 `uid`、`resourceVersion`、`creationTimestamp`、`managedFields` 一起算進去。結果是資料沒變但重建物件或改 metadata 時 hash 也會變；而且必須先 apply ConfigMap 才算得出來。改成只對資料算：`kubectl get cm pmc-epmmformquery-config -n ea-pmc -o jsonpath='{.data.application\.yml}'` 的輸出取 sha256 前 8 碼（跟本 repo 的 `sync-config-hash.sh`、第 6.3 節一致），或在 CI 直接對本地檔案解析後的 `data` 算。 | ✓ |
| P06-206 | 2361 | ConfigMap 不存在時 Pod 卡在 `ContainerCreating` | 不精確 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ | "If you reference a ConfigMap that doesn't exist and you don't mark the reference as optional, the Pod won't start." | 官方只說「Pod 起不來」，沒指定狀態名稱。改成「以 volume 掛載時通常停在 `ContainerCreating`（Events 會有 FailedMount）；以 `env`/`envFrom` 引用時通常是 `CreateContainerConfigError`（此細節官方文件未列出）」。兩種都要看 `kubectl describe pod` 的 Events。 | ✓ |
| P06-207 | 2363 | `VERSION: 1.10` 會變成 `1.1` | 不精確 | https://kubernetes.io/docs/concepts/configuration/configmap/ | "The data field is designed to contain UTF-8 strings while the binaryData field is designed to contain binary data as base64-encoded strings." | 在 ConfigMap 的 `data` 裡，沒加引號的 `1.10` 是 YAML 浮點數，跟 boolean 一樣會被 API 以型別錯誤拒絕，不會被靜默存成 `1.1`。變成 `1.1` 是值先經過 Helm 模板等工具重新序列化才會發生。改成「`VERSION: 1.10` 同樣會被拒絕；透過 Helm values 帶入時還可能先變成 1.1，所以一律加引號」。 | ✓ |
| P06-208 | 2411, 2425 | `podFailurePolicy:` 搭配 `restartPolicy: OnFailure` | 錯誤 | https://kubernetes.io/docs/concepts/workloads/controllers/job/ | "if you want to use a .spec.podFailurePolicy field for a Job, you must also define that Job's pod template with .spec.restartPolicy set to Never." | 這份範例 YAML 送出去會被 API 拒絕。二選一：要用 podFailurePolicy，就把 `restartPolicy` 改成 `Never`（重試改由 Job controller 重建 Pod）；要保留 `OnFailure`，就整段刪掉 podFailurePolicy。並在註解寫明「podFailurePolicy 需要 restartPolicy: Never」。 | ✓ |
| P06-209 | 2423, 2525 | annotations 底下的 `sidecar.istio.io/inject: "false"` | 過時 | https://istio.io/latest/docs/reference/config/annotations/ | "This annotation has been deprecated in favor of the sidecar.istio.io/inject label documented" | 把 `sidecar.istio.io/inject: "false"` 從 `template.metadata.annotations` 移到 `template.metadata.labels`，並註明「annotation 形式已 deprecated，官方建議用 label」。 | ✓ |
| P06-210 | 2454 | 否則 UTC 跟你想的差 8 小時 | 環境特定 | — | — | 依規定不研究。這句只在 controller 時區是 UTC、使用者在台灣時成立，建議加上「若 controller 跑在 UTC」的前提。 | ✓ |
| P06-211 | 2480 | `kubectl get jobs -n ea-pmc -l job-name` 看這個 CronJob 產生的所有 Job | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/job/ | "Job labels will have batch.kubernetes.io/ prefix for job-name and controller-uid." | 每個自動 selector 的 Job 都帶 job-name label，只寫 key 的 selector 會列出整個 namespace 所有 CronJob 和 Job 產生的 Job，不只這一個。改成在 `jobTemplate.metadata.labels` 加一個 label（例如 `app: pmc-form-daily-sync`），再用 `-l app=pmc-form-daily-sync`；或用 `kubectl get jobs -o custom-columns` 列出 ownerReferences 篩選。 | ✓ |
| P06-212 | 2482 | Job 的 Pod 跑完不會消失，除非設了 ttl | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ | "Setting this field to 0 will not keep any successful jobs." | CronJob 產生的 Job 也會被 `successfulJobsHistoryLimit`/`failedJobsHistoryLimit` 清掉（連同 Pod）。改成「除非被 ttl 或歷史上限清掉」。 | ✓ |
| P06-213 | 2495 | `Failed`：重試超過 backoffLimit，或超過 activeDeadlineSeconds | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/job/ | "A failed Pod matches a rule in .spec.podFailurePolicy that has the FailJob action." | 補上「命中 podFailurePolicy 的 FailJob 規則」（本節範例自己就用了這條），以及 Indexed Job 的 backoffLimitPerIndex / maxFailedIndexes。 | ✓ |
| P06-214 | 2502 | 錯過超過 100 次……這個 CronJob 就永遠不再排程了；訊息為 `Cannot determine if job needs to be started` | 過時 | https://raw.githubusercontent.com/kubernetes/kubernetes/master/pkg/controller/cronjob/utils.go | "If there are too many (>100) unstarted times, it will also record a warning." | 「永遠卡死」和那段訊息都是舊版 v1 controller 的行為。現行 v2 controller 超過 100 次只發一個 Warning 事件 `TooManyMissedTimes`（訊息 "too many missed start times. Set or decrease .spec.startingDeadlineSeconds or check clock skew"），仍會回傳最近一次排程時間。官方概念頁還寫著 "it does not start the Job"，跟原始碼不一致。建議改成「會發 TooManyMissedTimes 警告事件（官方文件說這次不啟動），不要依賴它；設 startingDeadlineSeconds 就不會有這個問題」，並刪掉「永遠不再排程」。 | ✓ |
| P06-215 | 2503, 2505 | 錯過不到 100 次又是 Allow，會一次補跑所有錯過的排程 | 錯誤 | https://raw.githubusercontent.com/kubernetes/kubernetes/master/pkg/controller/cronjob/utils.go | "the most recent time a Job should be created or nil, if that's after now," | controller 只會為「最近一次」錯過的排程建一個 Job，不會一次補跑全部，也不會爆出一堆 Pod。官方說法是 "the Jobs will always run at least once"（https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/）。刪掉這條，2505 的「兩個問題都解決了」改成「設了就不會觸發 >100 的警告，而且超過窗口的那次會被跳過（MissSchedule 事件）」。 | ✓ |
| P06-216 | 2537–2539 | `set -e` 之後 `java -jar ...`、`RC=$?`、`curl ... quitquitquit`、`exit $RC` | 錯誤 | https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html | "When this option is on, when any command fails" "the shell immediately shall exit, as if by executing the exit special built-in utility with no arguments," | 有 `set -e` 時 java 一失敗 shell 就直接退出，`RC=$?` 和 curl 都不會執行，sidecar 不會被叫停，Job 正好在失敗時卡住。RC 也永遠是 0。改成第一行寫 `set +e`（或不要 set -e），接著 `java -jar /app/sync.jar`、`RC=$?`、`curl -sf -X POST http://127.0.0.1:15020/quitquitquit`、`exit $RC`。另外註明 app image 要有 curl，而且這個端點只接受 localhost 的 POST。 | ✓ |
| P06-217 | 2543–2545 | 需要 K8s 1.29+ 且 Istio 開啟 native sidecar；需要在 istiod 設 `ENABLE_NATIVE_SIDECARS=true` | 過時 | https://istio.io/latest/news/releases/1.27.x/announcing-1.27/change-notes/ | "Promoted the environment variable ENABLE_NATIVE_SIDECARS to default to true." "This means native sidecars will be injected into all eligible pods unless explicitly disabled." | 改成「Istio 1.27 起預設就是 native sidecar，不需要再設；舊版 Istio 才要設 `ENABLE_NATIVE_SIDECARS=true` 或在 Pod 加 `sidecar.istio.io/nativeSidecar: "true"`」。K8s 端的 SidecarContainers 1.28 alpha、1.29 起預設開啟、1.33 GA（https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/："Stable since Kubernetes v1.33"）。也就是說在 1.27+ 環境裡，「Job 卡住」本來就不該發生，排查時要先確認 istio-proxy 是不是在 initContainers 裡。 | ✓ |
| P06-218 | 2559 | `schedule` 用 UTC | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ | "For CronJobs with no time zone specified, the kube-controller-manager interprets schedules relative to its local time zone." | 改成「不設 timeZone 時用 kube-controller-manager 的本地時區（多數 cluster 是 UTC）」。 | ✓ |
| P06-219 | 2561 | CronJob 名稱建議不超過 52 字元 | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ | "Even when the name is a DNS subdomain, the name must be no longer than 52 characters. This is because the CronJob controller will automatically append 11 characters to the name you provide and there is a constraint that the length of a Job name is no more than 63 characters." | 「建議」改成「必須」：超過 52 字元就違反限制（controller 會再加 11 字元，Job 名稱上限 63）。 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P06-220 | 2239 | Secret 預設只是 base64、未加密 | https://kubernetes.io/docs/concepts/configuration/secret/ |
| P06-221 | 2249 | immutable 之後只能刪掉重建 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-222 | 2260 | data 值必須是字串 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-223 | 2262 | binaryData 用 base64 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-224 | 2288, 2356 | optional 時不擋 Pod 啟動 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ |
| P06-225 | 2291 | 整個 volume 掛載會自動更新 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-226 | 2319 | env 不會更新，要重啟 Pod | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-227 | 2341 | Helm checksum/config 寫法 | https://helm.sh/docs/howto/charts_tips_and_tricks/ |
| P06-228 | 2344 | rollout restart 可手動觸發 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-229 | 2353 | immutable 減少 apiserver watch 負擔 | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-230 | 2362 | 1 MiB 上限，可改用 volume | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-231 | 2364 | Pod 與 ConfigMap 須同 namespace | https://kubernetes.io/docs/concepts/configuration/configmap/ |
| P06-232 | 2384 | cron 五欄格式 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-233 | 2385 | timeZone 1.27 GA，未設用 controller 時區 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-234 | 2388, 2455, 2469–2471 | concurrencyPolicy 三值，預設 Allow | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-235 | 2391–2392 | startingDeadlineSeconds 補跑窗口 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-236 | 2395, 2457 | 成功歷史預設 3，設 0 不保留 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-237 | 2458 | 失敗歷史預設 1 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-238 | 2398, 2459 | suspend 不影響已啟動的 Job | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-239 | 2403 | 指數退避 10s、20s、40s | https://kubernetes.io/docs/concepts/workloads/controllers/job/ |
| P06-240 | 2404–2405 | activeDeadline 含重試且優先 | https://kubernetes.io/docs/concepts/workloads/controllers/job/ |
| P06-241 | 2406 | ttl 刪 Job 時連帶刪 Pod | https://kubernetes.io/docs/concepts/workloads/controllers/job/ |
| P06-242 | 2411 | podFailurePolicy 1.31 GA | https://kubernetes.io/docs/concepts/workloads/controllers/job/ |
| P06-243 | 2425, 2463, 2560 | Job 只允許 OnFailure 或 Never | https://kubernetes.io/docs/concepts/workloads/controllers/job/ |
| P06-244 | 2438 | 15020 quitquitquit 用 POST | https://raw.githubusercontent.com/istio/istio/master/pilot/cmd/pilot-agent/status/server.go |
| P06-245 | 2453 | 支援 @daily、@hourly | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-246 | 2460 | backoffLimit 預設 6 | https://kubernetes.io/docs/concepts/workloads/controllers/job/ |
| P06-247 | 2489 | create job --from=cronjob | https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_job/ |
| P06-248 | 2505 | 設 deadline 只看窗口內的排程 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |
| P06-249 | 2513 | 傳統 sidecar 讓 Pod 不會結束 | https://istio.io/latest/blog/2023/native-sidecars/ |
| P06-250 | 2544 | native sidecar 不擋 Job 完成 | https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/ |
| P06-251 | 2552 | nativeSidecar 註解存在（Alpha） | https://istio.io/latest/docs/reference/config/annotations/ |
| P06-252 | 2562 | 歷史上限之內的 Job 會保留 | https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ |

---

## Part 6.5–6.6：Gateway、VirtualService

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P06-401 | 2587, 2641 | 選錯 = 設定下發到不存在的 Pod，完全沒作用也沒錯誤 ／ 選錯完全沒反應，也不會報錯 | 不精確 | https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/ | "Error [IST0101] (Gateway default/bookinfo-gateway samples/bookinfo/networking/bookinfo-gateway.yaml:9) Referenced selector" "not found: "istio=ingressgateway"" | 改成「istiod 會照樣接受、不會拒絕 apply，但 `istioctl analyze` 會回報 IST0101 Referenced selector not found」。2652 行已經提到 analyze，把兩處講法統一。 | ✓ |
| P06-402 | 2594 | HTTP / HTTPS / GRPC / HTTP2 / TCP / TLS / MONGO | 不精確 | https://istio.io/latest/docs/reference/config/networking/gateway/ | "The protocol exposed on the port. MUST be one of HTTP…GRPC-WEB…TLS." (原文用分隔符列出 HTTP、HTTPS、GRPC、GRPC-WEB、HTTP2、MONGO、TCP、TLS) | 補上 `GRPC-WEB`。 | ✓ |
| P06-403 | 2593 | 名稱在同一個 Gateway 內要唯一 | 無法驗證 | https://istio.io/latest/docs/reference/config/networking/gateway/ | Port.name: "Label assigned to the port." ／ Server.name: "An optional name of the server, when set must be unique across all servers." | 官方文件對 `port.name` 沒有唯一性要求，有寫明要唯一的是 `servers[].name`。改成「port.name 必填；要唯一的是選填的 `servers[].name`」，或直接刪掉這句註解。 | ✓ |
| P06-404 | 2597, 2662 | 對應到 K8s Secret（type: kubernetes.io/tls）／ 檢查 secret 的 type 是不是 kubernetes.io/tls，以及有沒有 tls.crt / tls.key | 不精確 | https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/ | "A TLS Secret with keys `tls.key` and `tls.crt`" ／ "A generic Secret with keys `key` and `cert`." | 改成「TLS Secret（tls.crt／tls.key）或 generic Secret（cert／key）都可以」。排錯那條不要只要求 `kubernetes.io/tls`。 | ✓ |
| P06-405 | 2622 | 這個 secret 要額外包含 ca.crt | 不精確 | https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/ | "a separate generic Secret named `<secret>-cacert`, with a `cacert` key." | 改成「CA 憑證可以放在同一個 secret 的 `ca.crt` key，也可以另外建一個名為 `<secret>-cacert`、key 為 `cacert` 的 secret」。 | ✓ |
| P06-406 | 2627–2635 | TLS 四種 mode（表格實際列了五種） | 不精確 | https://istio.io/latest/docs/reference/config/networking/gateway/ | OPTIONAL_MUTUAL: "Similar to MUTUAL mode, except that the client certificate is optional." | 標題改成「TLS mode」，並補一列 `OPTIONAL_MUTUAL`（client 憑證可有可無）。 | ✓ |
| P06-407 | 2634 | ISTIO_MUTUAL … mesh 內部的 gateway（如 east-west gateway） | 不精確 | https://istio.io/latest/docs/reference/config/networking/gateway/ | ISTIO_MUTUAL: "Compared to Mutual mode, this mode uses certificates, representing gateway workload identity" ／ AUTO_PASSTHROUGH: "This server is typically used to provide connectivity between services in disparate L3 networks." | 跨網路的 east-west gateway 典型用的是 AUTO_PASSTHROUGH。ISTIO_MUTUAL 的意思是 gateway 用 Istio 自動簽發的 workload 身分憑證，跟 sidecar 之間走 mTLS。例子改成「例如 sidecar 到 egress gateway 這一段的 mTLS」。 | ✓ |
| P06-408 | 2642 | `HTTPS` 才會做 TLS 終止 | 不精確 | https://istio.io/latest/docs/reference/config/networking/gateway/ | "TLS can be either used to terminate non-HTTP based connections on a specific port" "or to route traffic based on SNI header to the destination without terminating the TLS connection." | 改成「`HTTPS` 會終止 TLS 再做 L7 路由。`TLS` 搭 `SIMPLE`／`MUTUAL` 也會終止 TLS（給非 HTTP 流量用），搭 `PASSTHROUGH` 則不解密、只看 SNI」。 | ✓ |
| P06-409 | 2643, 2651 | `*` 太寬鬆，多個 Gateway 會互搶 ／ 行為會變得不可預期。永遠寫明確的 host | 不精確 | https://istio.io/latest/docs/ops/common-problems/network-issues/ | "produce 404 errors when accessing a second host after a connection to another host has already been established." ／ "configuring a single wildcard `Gateway`, instead of two" | 官方記載的多 Gateway 問題是：多個 Gateway 共用同一張（萬用字元）憑證時，瀏覽器重用 HTTP/2 連線，導致第二個 host 拿到 404。官方的解法正好是「合併成單一個萬用字元 Gateway」。「互搶、不可預期」改寫成這個具體機制，「永遠寫明確 host」改成「避免多個 Gateway 用重疊的 host 或共用憑證」。 | ✓ |
| P06-410 | 2650, 2656 | （通常是 `istio-system`）／ `deploy/istio-ingressgateway -n istio-system` | 不精確 | https://istio.io/latest/docs/setup/additional-setup/gateway/ | "helm install istio-ingressgateway istio/gateway -n istio-ingress" | 官方現行的 Helm 安裝把 gateway 放在 `istio-ingress` namespace，不是 `istio-system`。改成「istioctl 預設安裝在 istio-system；Helm 則依安裝時的 release 名稱與 namespace 而定，請先 `kubectl get deploy -A` 找出實際名稱再查 label」。selector 的 label 也一併加同樣的提醒。 | ✓ |
| P06-411 | 2650 | 較新的 Istio 支援 `namespace/name` 的跨 namespace 引用 | 錯誤 | https://istio.io/latest/docs/reference/config/analysis/ist0161/ | "ensure that the secret with the specified `credentialName` exists in the same namespace as the Gateway workload" | 刪掉這句。現行官方文件沒有記載 Istio Gateway 的 `credentialName` 有 `namespace/name` 寫法，analyze 訊息 IST0161 也明確要求 secret 跟 gateway workload 同一個 namespace。 | ✓ |
| P06-412 | 2662 | 透過 SDS 動態載入憑證的，更新 secret 後通常幾秒內生效，不需要重啟 | 無法驗證 | https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/ | （現行官方頁面找不到「免重啟、幾秒生效」的敘述。這一頁的示範做法是刪掉 secret 再重建。） | 改成「Istio 透過 SDS 下發憑證，理論上不用重啟 gateway；更新後請用 `istioctl proxy-config secret` 確認新憑證已經生效」，拿掉「幾秒內」這種沒有出處的時間保證。 | ✓ |
| P06-413 | 2722, 2818 | 所有 weight 加起來必須 = 100 ／ 全部加起來必須是 100 | 過時 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ | "Weight specifies the relative proportion of traffic to be forwarded to the destination." ／ "`weight/(sum of all weights)`" | 改成「weight 是相對比例，每個 destination 拿到 weight 除以全部 weight 總和的流量；只有一個 destination 時它拿到全部流量。習慣上湊成 100 比較好讀，但現行版本不是硬性規定」。 | ✓ |
| P06-414 | 2733, 2821 | 單次嘗試的逾時（x attempts 要小於 timeout）／ `attempts x perTryTimeout` 要小於 `timeout`（範例是 attempts 3、perTryTimeout 5s、timeout 15s） | 錯誤 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ ；https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter | "The maximum possible number of requests made will be 1 + `attempts`." ／ "includes all retries." | `attempts` 算的是重試次數，不含第一次呼叫，所以最多會送出 1 + 3 = 4 次請求，4 × 5s = 20s，已經超過 15s。範例本身也只是 3 × 5 = 15，「等於」而非「小於」，違反它自己寫的規則。改成「(1 + attempts) × perTryTimeout ≤ timeout，否則後面的重試會被總 timeout 截斷」，範例改成 attempts: 2、perTryTimeout: 5s、timeout: 15s。 | ✓ |
| P06-415 | 2729–2735 對照 2780–2792 | 同一個 VirtualService 裡同時有 timeout/retries（規則 2）和 fault（規則 5） | 錯誤 | https://istio.io/latest/docs/ops/common-problems/network-issues/ | "Currently, Istio does not support configuring fault injections and retry or timeout policies on the same `VirtualService`." | 把故障注入範例拆成另一個 VirtualService（或另外說明只在測試環境單獨使用），並加註「官方不支援 fault 跟 retries/timeout 放在同一個 VirtualService」。 | ✓ |
| P06-416 | 2700 對照 2768–2783 | 特例一定要放前面（規則 5 的 header 故障注入卻排在規則 2 的 `/gui_epmmFormQuery/` 和規則 4 的 `/api/` 後面） | 不精確 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ | "The first rule matching an incoming request is used." | 範例違反它自己寫的 first-match 原則：帶 `x-chaos-test` 的 `/api/` 和 gui 請求會先被規則 2、4 吃掉，永遠進不了規則 5。把 header 比對的規則移到 path 規則前面，或在註解寫明它只會對前面沒命中的路徑生效。 | ✓ |
| P06-417 | 2822 | `rewrite.uri`：只能配 `prefix` match 使用 | 錯誤 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ | "rewrite the path (or the prefix) portion of the URI with this value." ／ "If the original URI was matched based on prefix, the value provided in this field will replace the corresponding matched prefix." | 改成「配 prefix match 時只取代命中的那段前綴；配 exact 或 regex match 時會取代整段 path。要用 regex 改寫請用 `uriRegexRewrite`」。 | ✓ |
| P06-418 | 2824, 2882–2886 | 兩邊都會加 `Access-Control-Allow-Origin` header，瀏覽器看到重複的 header 會直接報錯 | 無法驗證 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ | （官方文件沒有說明 corsPolicy 和上游 CORS header 並存時會疊加還是覆寫。只有："Indicates whether preflight requests not matching the configured allowed origin shouldn’t be forwarded to the upstream." "Default is forward to upstream."） | 保留「擇一管理」這個建議，但把「必定產生重複 header」改成「可能互相干擾（重複或被覆寫），而且 origin 沒命中的 preflight 預設會被轉給 app」，並建議實測確認。 | ✓ |
| P06-419 | 2836 | 它會走預設的 round-robin 直連 | 過時 | https://istio.io/latest/docs/concepts/traffic-management/ | "By default, the Envoy proxies distribute traffic across each service’s load balancing pool using a least requests model." | 改成「仍然經過 sidecar，但套用預設路由：送到該 Service 的所有 endpoint，演算法是 least request」。「直連」也容易誤會成繞過了 sidecar。 | ✓ |
| P06-420 | 2840 | 內部流量還是 50/50 打到所有 Pod | 不精確 | https://istio.io/latest/docs/concepts/traffic-management/ | "By default, the Envoy proxies distribute traffic across each service’s load balancing pool using a least requests model." | 改成「內部流量會依 endpoint 數量（v1、v2 各有幾個 Pod）用 least request 分配，跟 90/10 的設定無關」。只有兩版 Pod 數量相同時才大約是 50/50。 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P06-421 | 2579, 2681 | apiVersion networking.istio.io/v1 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-422 | 2572–2574 | Gateway 管 L4-L6，路由交給 VS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-423 | 2599 | minProtocolVersion: TLSV1_2 是合法值 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-424 | 2602 | hosts 支援萬用字元 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-425 | 2603 | hosts 的 namespace/ 前綴限定 VS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-426 | 2613 | httpsRedirect 回 301 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-427 | 2631 | SIMPLE 是單向 TLS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-428 | 2621, 2632 | MUTUAL 會驗證 client 憑證 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-429 | 2633 | PASSTHROUGH 不解密，依 SNI 轉發 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-430 | 2635 | AUTO_PASSTHROUGH 不需要 VS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-431 | 2598, 2644, 2650 | secret 要在 gateway workload 的 ns | https://istio.io/latest/docs/reference/config/analysis/ist0161/ |
| P06-432 | 2663 | host 沒有交集就 404 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P06-433 | 2694 | gateways 寫成 ns/name | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-434 | 2695, 2815, 2855 | 預設 mesh，列了 gateway 要自己補 mesh | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-435 | 2700, 2816 | 第一個命中的規則生效 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-436 | 2716 | match 區塊之間是 OR | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-437 | 2705 | header 可用 exact/prefix/regex | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-438 | 2730, 2820 | HTTP timeout 預設停用 | https://istio.io/latest/docs/concepts/traffic-management/ |
| P06-439 | 2733 | perTryTimeout 是單次嘗試的逾時 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-440 | 2734 | retryOn 用的值都是合法的 Envoy 值 | https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/router_filter |
| P06-441 | 2735 | retryRemoteLocalities 欄位存在 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-442 | 2738–2744 | headers 的 set/add/remove | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-443 | 2748–2754 | allowOrigins 用 StringMatch | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-444 | 2761 | prefix 改寫只換前綴 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-445 | 2774–2778 | mirrorPercentage；鏡射回應被丟棄 | https://istio.io/latest/docs/tasks/traffic-management/mirroring/ |
| P06-446 | 2784–2790 | fault 的 delay/abort 欄位 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-447 | 2798–2800 | redirect 可設 redirectCode 302 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-448 | 2802, 2869 | 沒有 match 的預設規則放最後 | https://istio.io/latest/docs/concepts/traffic-management/ |
| P06-449 | 2814 | 建議 hosts 寫 FQDN | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-450 | 2874 | prefix 是字串前綴比對 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P06-451 | 2892 | NC＝找不到 cluster，UH＝沒有健康 host | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P06-452 | 2819, 2890 | subset 未定義就 503 | https://istio.io/latest/docs/ops/best-practices/traffic-management/ |

---
 managedRoutes 為 nil 時："Rollout has missing field '%s'"（代入後為 spec.strategy.canary.trafficRouting.managedRoutes）；managedRoutes 有寫但漏列該 route 時："Steps define a route that does not exist in spec.strategy.canary.trafficRouting.managedRoutes" ||| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P07-001 | 2906 | Deployment 滾動更新是全有全無的……不能控制換多少比例 | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | "the new ReplicaSet can be scaled up immediately when the rolling update starts, such that the total number of old and new Pods does not exceed 130% of desired Pods." | 滾動更新期間新舊版本本來就會並存，只是比例綁死在 Pod 數上，而且會自動推進到 100%。建議改成「比例只能用 Pod 數表達，而且無法停在某個比例上對特定使用者分流」，不要說「全有全無」。 | ✓ |
| P07-002 | 2998 | consistentHash: # 解決 session 黏著（見 7.4） | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "Consistent Hash-based load balancing can be used to provide soft session affinity based on HTTP headers, cookies or other properties." / "The affinity to a particular destination host may be lost when one or more hosts are added/removed" | 這是「軟」黏著，只在同一個 subset 裡有效。7.4 表格自己也說它擋不住跨 subset。註解改成「subset 內的軟黏著，不解決 canary 跨版本問題」。 | ✓ |
| P07-003 | 3000–3001 | httpCookie: name: JSESSIONID, ttl: 10800s | 錯誤 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "Lifetime of the cookie. If specified, a cookie with the TTL will be generated if the cookie is not present." | 設了 ttl，Envoy 會在 cookie 不存在時自己產生一個同名 cookie，會跟 Spring 的 JSESSIONID 打架（前一批已確認）。改用專屬名稱，例如 `istio-affinity`。 | ✓ |
| P07-004 | 3056 | 只改這兩個數字就完成灰度 | 不精確 | https://istio.io/latest/blog/2017/0.1-canary/ | "the autoscalers bound to the 2 version Deployments will automatically scale the replicas accordingly" | v2 寫死 `replicas: 1`、也沒有 HPA。權重拉到 50% 或 100% 時，一個 Pod 會被打爆。要補一句：推進權重的同時要擴 v2，或替 v2 也配一個 HPA。 | ✓ |
| P07-005 | 3122 | 你的 Spring Boot 用 in-memory HttpSession + Keycloak OIDC | 環境特定 | — | — | 跟上層 CLAUDE.md 的描述一致，沒有另外查證。 | ✓ |
| P07-006 | 3130 | 解法 A：DestinationRule 用 `httpCookie: JSESSIONID` | 錯誤 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "If specified, a cookie with the TTL will be generated if the cookie is not present." | 「只在 subset 內生效」這段是對的，但 cookie 名稱同 P07-003，要改成專屬名稱。 | ✓ |
| P07-007 | 3150 | 用解法 A + 只在離峰時段灰度就夠 | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "Consistent Hash-based load balancing can be used to provide soft session affinity" | 跟 3130 自相矛盾：A 擋不住 weight 把同一位使用者送到另一個 subset。離峰只是降低受影響的人數。改成「A 無法避免登出，只能降低影響；要保證不登出用 B 或 C」。 | ✓ |
| P07-008 | 3150 | 你現在其實已經在承受「使用者偶爾被登出」的風險 | 環境特定 | — | — | 推論本身成立（ClientIP 在 mesh 下沒作用，前一批已確認），但實際影響要看他們的叢集，沒有查證。 | ✓ |
| P07-009 | 3170 | scaleTargetRef name: pmc-epmmformquerygui | 不精確 | https://istio.io/latest/blog/2017/0.1-canary/ | "the autoscalers bound to the 2 version Deployments will automatically scale the replicas accordingly" | 文件內部不一致：7.2 的 Deployment 叫 `-v1`、`-v2`，沒有叫這個名字的 Deployment。而且 7.2 兩份 Deployment 都沒有 `resources.requests`，依 3183 自己的說法 HPA 不會動。建議改成每一版各一個 HPA，並在 7.2 的 YAML 補上 requests。 | ✓ |
| P07-010 | 3172 | 1 個的話滾動更新會有空窗 | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | "The absolute number is calculated from percentage by rounding down." (maxUnavailable) / "The absolute number is calculated from the percentage by rounding up. The default value is 25%." (maxSurge) | 1 個 replica 套預設值時 maxUnavailable=0、maxSurge=1，會先起新 Pod 再砍舊的，不會有空窗（前提是有 readinessProbe，7.2 沒設）。建議至少 2 個的理由應寫成：節點故障、drain 和 PDB。 | ✓ |
| P07-011 | 3184–3189 | 範例裡啟用了 memory averageUtilization: 80（只註明「慎用」） | 不精確 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ | "If multiple metrics are specified in a HorizontalPodAutoscaler, this calculation is done for each metric, and then the largest of the desired replica counts is chosen." | 多個指標取最大值，所以 JVM 記憶體降不下來時，這一項會讓 HPA 永遠縮不回去。這跟 3271 的踩雷互相矛盾。範例中應把 memory 那段註解掉。 | ✓ |
| P07-012 | 3195 | istio_requests_per_second # 需要 prometheus-adapter | 無法驗證 | https://istio.io/latest/docs/reference/config/metrics/ | — | Istio 標準指標是 `istio_requests_total`（counter），沒有找到官方叫這個名字的指標。實際上要在 adapter 裡自己寫 rate 規則定義它，而且任何 custom.metrics API 的實作都可以，不一定是 prometheus-adapter。建議註明「名稱由 adapter 規則自訂」。 | ✓ |
| P07-013 | 3272 | 你的 Spring Boot 可能要 60 秒 | 環境特定 | — | — | 沒有查證。 | ✓ |
| P07-014 | 3289–3309 | Rollout 範例沒有 selector、template（也沒有 workloadRef） | 無法驗證 | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ | —（查證途中被額度限制擋下，沒有取得原文） | 依我所知 Rollout 必須有 selector 加 template，或用 workloadRef，否則 controller 會判 InvalidSpec。至少要標「已省略 selector/template」。 | ✓ |
| P07-015 | 3292 | canaryService / stableService # Argo 自動維護這兩個 Service | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ | "Finally, a canary and stable Service should be deployed." | 這兩個 Service 要自己建立，Argo 只會在發布期間改它們的 selector。 | ✓ |
| P07-016 | 3292–3298 | host-level（canaryService/stableService）搭配 7.2 的 `app-routing` VS | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ | "containing two route destinations with `host` values that match the `canaryService` and `stableService`" | 7.2 的 `main` route 兩個 destination 是同一個 host、靠 subset 區分，跟 host-level 的要求不合。二選一：(a) 改用 `trafficRouting.istio.destinationRule: {name, canarySubsetName: v2, stableSubsetName: v1}`，拿掉 canaryService/stableService；(b) 把 VS 改成兩個 host 對應兩個 Service。 | ✓ |
| P07-017 | 3304 | analysis: # 自動跑指標分析，不通過就回滾 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ | "Analysis can be run in the background -- while the canary is progressing through its rollout steps." | inline analysis 只在 20% 之後跑一次，5% 和 20% 的兩個階段完全沒有自動回滾。範例也沒給 AnalysisTemplate，看不到 failureLimit／inconclusiveLimit 這些中止條件。建議改用 `strategy.canary.analysis`（背景分析），並把 template 一起列出來。 | ✓ |
| P07-018 | 3314、3357 | Deployment 要改寫成 Rollout CRD ／ Argo 要你改 workload 定義 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | "Instead of removing Deployment you can scale it down to zero and reference it from the Rollout resource:" / "Reference an existing Deployment using `workloadRef` field." | 補充 workloadRef：可以保留原本的 Deployment，用 scaleDown 的 never／onsuccess／progressively 漸進接管。 | ✓ |
| P07-019 | 3319、3353 | Flagger 不改你的 Deployment | 不精確 | https://docs.flagger.app/usage/how-it-works | "the target deployment is scaled to zero" | Flagger 會另外建 `<name>-primary` 承接正式流量，再把原本的 Deployment 縮到 0 當成 canary 用。另外會建 `<name>`、`-primary`、`-canary` 三個 Service。應寫成「不用改寫 YAML，但會接管它的副本數」。 | ✓ |
| P07-020 | 3335 | threshold: 5 # 連續 5 次分析失敗就回滾 | 不精確 | https://docs.flagger.app/usage/deployment-strategies | "max number of failed metric checks before rollback" | 官方沒說「連續」。原始碼（fluxcd/flagger pkg/controller/scheduler.go）只有 `SetStatusFailedChecks(cd, cd.Status.FailedChecks+1)`，成功時不歸零，所以是整次分析的累計失敗次數。把「連續」拿掉。 | ✓ |
| P07-021 | 3348 | cmd: "hey -z 1m -q 10 http://myapp.example.com/" | 不精確 | https://docs.flagger.app/tutorials/istio-progressive-delivery | "hey -z 1m -q 10 -c 2 http://podinfo-canary.test:9898/" | 官方範例直接打 canary Service。打公開網域要經過權重，只有 stepWeight% 會到 canary，低流量時分析樣本不夠。改成 `http://pmc-epmmformquerygui-canary.ea-pmc:8080/`。 | ✓ |
| P07-022 | 3361 | HPA 只能看 CPU / memory / 自訂指標 | 不精確 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ | "For HorizontalPodAutoscalers that scale on custom (object) or external metrics, you can set `spec.minReplicas` to `0`." | HPA 本身就支援 External 指標，3207–3211 也示範了。KEDA 的價值在內建 scaler 和不用自己架 adapter，不是 HPA 看不到外部指標。 | ✓ |
| P07-023 | 3371 | minReplicaCount: 0 # 【HPA 做不到】 | 過時 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ | "Feature state: Beta since Kubernetes v1.37; enabled by default" / "Setting `minReplicas: 0` requires at least one object or external metric to be configured; the API server rejects the HorizontalPodAutoscaler otherwise." | 改成「原生 HPA 從 v1.37 起（HPAScaleToZero 進入 beta、預設開啟）可以縮到 0，但只限 Object/External 指標。KEDA 的優勢是內建 scaler，而且從 0 喚醒更成熟」。 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P07-024 | 2910 | 用 Pod 數湊 1% 至少要 100 個 Pod | https://istio.io/latest/blog/2017/0.1-canary/ |
| P07-025 | 2914 | Istio 讓流量比例和 Pod 數量解耦 | https://istio.io/latest/blog/2017/0.1-canary/ |
| P07-026 | 2977 | Service 的 selector 不加 version，才能同時選中 v1 和 v2 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P07-027 | 2988、3021 | `networking.istio.io/v1` 的 DR 和 VS | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P07-028 | 2996 | 頂層 trafficPolicy 會套用到所有 subset（subset 可覆寫） | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P07-029 | 3004 | maxRequestsPerConnection: 0 代表不限制 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P07-030 | 3006–3009 | consecutive5xxErrors 5、interval 10s、baseEjectionTime 30s 都是合法值（剛好等於預設）；maxEjectionPercent 是「最多可剔除的 % 數」（預設 10%） | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P07-031 | 3032 | 有寫 gateways 時必須加 `mesh`，sidecar 才會套用 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P07-032 | 3039 | header match 用小寫 `x-canary` 搭配 exact | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P07-033 | 3077–3087 | JSON patch 路徑 `/spec/http/1/route/0/weight` 指向 `main` route（index 0 是 canary-testers） | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P07-034 | 3095–3101 | `istio_requests_total` 和 `istio_request_duration_milliseconds_bucket`，以及 `destination_workload`、`response_code` 這兩個 label | https://istio.io/latest/docs/reference/config/metrics/ |
| P07-035 | 3106、3112–3115 | 鏡射會丟掉回應；`mirror` 加 `mirrorPercentage` 的寫法正確（沒寫時預設 100%） | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P07-036 | 3118 | 有副作用的請求被鏡射後，副作用會真的發生 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P07-037 | 3124、3130 | weight 是每個請求各自決定；consistentHash 只在 subset 內生效 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P07-038 | 3141 | cookie header 用 RE2 regex 比對 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P07-039 | 3150 | sessionAffinity: ClientIP 在 Istio 下沒有作用（前一批已確認） | https://kubernetes.io/docs/reference/networking/virtual-ips/ |
| P07-040 | 3161、3213 | `autoscaling/v2`；behavior 是 v2 的欄位（從 v1.23 起 stable，之前在 v2beta2） | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-041 | 3182–3183、3261、3269 | 使用率的分母是 requests；容器沒設 requests 時 HPA 對該指標不採取動作 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-042 | 3216–3224、3263 | scaleUp 預設穩定窗 0、100%/15s 和 4 Pods/15s、selectPolicy Max（範例等於預設值） | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-043 | 3227、3262 | scaleDown 穩定窗預設 300 秒 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-044 | 3264 | selectPolicy: Disabled 會關掉該方向的縮放（可以做到只擴不縮） | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-045 | 3240、3247 | PDB 用 `policy/v1`；minAvailable 和 maxUnavailable 只能二選一 | https://kubernetes.io/docs/tasks/run-application/configure-pdb/ |
| P07-046 | 3253 | minAvailable 等於 replicas 時，node drain 永遠卡住 | https://kubernetes.io/docs/tasks/run-application/configure-pdb/ |
| P07-047 | 3268 | manifest 留著 replicas 會讓 apply 跟 HPA 來回拉扯，應該刪掉 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-048 | 3272 | HPA 預設 15 秒同步一次 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/ |
| P07-049 | 3283、3298、3301 | `argoproj.io/v1alpha1` Rollout、`routes: [main]` 對得上 VS 的 route 名稱、`pause.duration` 的寫法 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P07-050 | 3304 | inline analysis 失敗會 abort 整個 rollout | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P07-051 | 3322–3343 | `flagger.app/v1beta1` Canary；interval、maxWeight、stepWeight 的欄位；request-duration 是 P99（毫秒） | https://docs.flagger.app/tutorials/istio-progressive-delivery |
| P07-052 | 3354 | Flagger 會自己產生 VS 和 DR | https://docs.flagger.app/tutorials/istio-progressive-delivery |
| P07-053 | 3364、3370、3373 | `keda.sh/v1alpha1` ScaledObject；scaleTargetRef 只寫 name 時預設是 apps/v1 Deployment；cooldownPeriod 預設 300 | https://keda.sh/docs/latest/reference/scaledobject-spec/ |
| P07-054 | 3376–3381 | kafka trigger 的 bootstrapServers、consumerGroup、topic、lagThreshold 欄位 | https://keda.sh/docs/latest/scalers/apache-kafka/ |
| P07-055 | 3384–3389 | cron trigger 的 timezone、start、end、desiredReplicas；配合 minReplicaCount 0 可以在時段外縮到 0 | https://keda.sh/docs/latest/scalers/cron/ |
| P07-056 | 3395 | KEDA 會自己建 HPA；admission webhook 會擋下已經被 HPA 管理的 workload | https://keda.sh/docs/latest/concepts/admission-webhooks/ |

---

## Part 12：用 Argo Rollouts 取代人工 pilot run

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P12-001 | 4500–4505（12.5 L4756、12.6 L4778/4788、12.7 L4817 也一樣） | 12.2 骨架的 `trafficRouting` 只有 `istio.virtualService`，steps 卻用了 `setHeaderRoute` | 錯誤 | https://github.com/argoproj/argo-rollouts/blob/master/pkg/apis/rollouts/validation/validation.go ／ https://argo-rollouts.readthedocs.io/en/stable/features/specification/ | managedRoutes 為 nil 時（guide 的情況）："Rollout has missing field '%s'"（代入 spec.strategy.canary.trafficRouting.managedRoutes）；managedRoutes 有寫但漏列該 route 時："Steps define a route that does not exist in spec.strategy.canary.trafficRouting.managedRoutes" | 在 `trafficRouting` 補上 `managedRoutes: [{name: canary-test}]`。12.5/12.6 的 `mirror`、`canary-testers` 也要列進去，列的順序就是優先序。另外註明 setHeaderRoute／setMirrorRoute 需要 Argo Rollouts v1.3 以上（release-1.2 的文件沒有這兩個功能，release-1.3 才有） | ✓ |
| P12-002 | 4563 | 「之後所有操作都固定走 v2」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ | "All routes listed in managed routes will be removed at the end of a rollout or on an abort." | 改成「只在 header route 存在的那幾個 step 有效」。12.2 的步驟 3 就會把它移除 | ✓ |
| P12-003 | 4565–4576、4899–4909 | 指向 Part 9 發現 2／3／4 的環境現況（沒有 mesh、route 沒有 name、session 存在 in-memory） | 環境特定 | — | 未研究（環境特定） | 不在本批範圍 | ✓ |
| P12-004 | 4605 | `annotations: sidecar.istio.io/inject: "false"` | 過時 | https://istio.io/latest/docs/reference/config/annotations/ | "This annotation has been deprecated in favor of the sidecar.istio.io/inject label" | 改放 pod template 的 `labels`。另外 Istio 1.27 起預設是 native sidecar，有注入的 Job 也能正常結束（前批已確認） | ✓ |
| P12-005 | 4686–4696、4708–4712、4723–4726、5446–5455、5510–5513 | 以 `destination_workload="pmc-epmmformquerygui"` 算成功率、延遲、樣本數 | 不精確 | https://github.com/istio/istio/blob/master/pkg/kube/util.go ／ https://istio.io/latest/docs/reference/config/metrics/ ／ https://argo-rollouts.readthedocs.io/en/stable/analysis/prometheus/ | "// Heuristic for ArgoCD Rollout" ／ "name := strings.TrimSuffix(controllerRef.Name, "-"+pod.Labels["rollouts-pod-template-hash"])"；"It is set to destination if report is from a server Istio proxy and source if report is from a client Istio proxy or a gateway."；官方範例用 `destination_service=~"{{args.service-name}}"` | Istio 對 Rollout 的兩組 ReplicaSet 都回報同一個 workload 名，所以這條 query 量到的是 stable＋canary 的合計，不是 canary。12.11 步驟 3 的 canary 權重是 0，量到的幾乎全是 stable。另外沒有過濾 reporter，經過 gateway 的請求會算兩次，enough-traffic 的門檻 20 實際只要 10 個請求。改成 `reporter="destination",destination_service_name="pmc-epmmformquerygui-canary"`，用 args 傳入 | ✓ |
| P12-006 | 4714–4719、4735 | 12.4 的 `enough-traffic` 沒寫 failureLimit，說「流量不夠就不下結論」 | 錯誤 | https://github.com/argoproj/argo-rollouts/blob/master/pkg/apis/rollouts/v1alpha1/analysis_types.go ／ https://github.com/argoproj/argo-rollouts/blob/master/analysis/analysis.go | "FailureLimit is the maximum number of times the measurement is allowed to fail, before the entire metric is considered Failed (default: 0)"；"Once all metrics are complete, the worst status is used as the overall AnalysisRun status" | failureLimit 預設是 0，只要有一次樣本低於 20，整個 AnalysisRun 就 Failed，Rollout 跟著 abort，跟「不下結論」正好相反。metrics 之間沒有依附關係。要把樣本數檢查併進同一條 query／條件，或設計成 success／failure 兩個條件之間有空隙，讓它落到 Inconclusive | ✓ |
| P12-007 | 4737 | 「`interval` 拉長，讓每次取樣涵蓋足夠的請求」 | 不精確 | https://prometheus.io/docs/prometheus/latest/querying/basics/ | "Range vector literals work like instant vector literals, except that they select a range of samples back from the current instant." | 每次取樣涵蓋多少請求是由 query 的 `[2m]` 決定，不是 interval。要涵蓋更多請求就把 range 拉長 | ✓ |
| P12-008 | 4745、4747、5488、5490 | 「Inconclusive：查詢沒有資料／無法判斷 → 暫停等人」 | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ ／ analysis_types.go | "One example of how analysis runs could become `Inconclusive`, is when a metric defines no success or failure conditions."；"`Inconclusive` analysis runs might also happen when both success and failure conditions are specified, but the measurement value did not meet either condition."；NaN 範例："successCondition: result >= 0.95 … phase: Failed … value: NaN"；"ConsecutiveErrorLimit … before the metric is considered error (default: 4)" | 只寫 successCondition 時：0/0 = NaN 會判 Failed；空陣列必須用 `len(result)` 處理，否則算 Error，連續超過 4 次就變 Error。rollout/analysis.go 把 Error 和 Failed 同樣處理成 abort。結論是「沒資料」在這份 YAML 下會自動 abort，不會停下來等人。要停下來等人，得同時寫 successCondition 和 failureCondition，並設 inconclusiveLimit | ✓ |
| P12-009 | 4817–4824、4832 | 階段 1 先移除 header route，再 `pause: {}`，說「使用者一樣做 pilot run」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ | "To disable header based traffic routing just need to specify empty `setHeaderRoute` with only the name of the route." | pause 之前 header route 已經關掉，pilot 使用者只能靠 5% 的隨機權重碰到 v2，這正是 L4469 自己批評的情況。應該把 `pause: {}` 移到移除 header route 之前 | ✓ |
| P12-010 | 4851–4852 | 階段 3 沒有 `setHeaderRoute` 就直接跑 `smoke-test` | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ | "Header-based traffic routing is configured using the `setHeaderRoute` step, which contains a list of header matchers." | 這時 `x-canary` header 不會被路由到 canary（權重 0），smoke test 測到的是 v1。要保留 setHeaderRoute 的開啟和關閉兩步 | ✓ |
| P12-011 | 4861 | 「失敗時 Argo 會自動 abort 回滾，並發通知」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/notifications/ | "Both triggers and templates are configured in the `argo-rollouts-notification-configmap` ConfigMap." | 註明要先設好 notification ConfigMap，並在 Rollout 上加訂閱 annotation（12.8） | ✓ |
| P12-012 | 4878–4879、5105–5106 | 「30 分鐘還沒完成 = 判定失敗」；「不設的話只是標記失敗但卡住」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ | "The maximum time in seconds in which a rollout must make progress during an update, before it is considered to be failed. Argo Rollouts will continue to process failed rollouts … Note that progress will not be estimated during the time a rollout is paused."；"Optional and default is false." | 改成「連續 1800 秒沒有進展（pause 期間不計）」。不設 abort 時 controller 會照常繼續處理，只是在 status 標上 ProgressDeadlineExceeded | ✓ |
| P12-013 | 4884–4887 | 背景分析「整個 rollout 期間持續監控」；「startingStep: 2 從第 2 個 step 開始」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ | "startingStep: 2 # delay starting analysis run until setWeight: 40%"；"Delay starting the analysis run until step 3 (Set Weight 40%)"；"The `count` can have 0 as value which means that it will run until the end of the Rollout execution for background analysis" | startingStep 從 0 起算，2 是第 3 個 step。引用的 success-rate 有 `count: 5`，跑完 5 次就結束，不會持續整個 rollout。背景分析要另寫一份不設 count 的 template | ✓ |
| P12-014 | 4919–4920、5564 | `deploy/pmc-epmmformquerygui`、`deploy/pmc-epmmformquerygui-stable` | 不精確 | `canary-manual/track-b/release/20-rollout.yaml` | 檔內 `kind: Rollout`，沒有 Deployment；Track A 的 Deployment 叫 `-stable`／`-canary` | 第一個名字在兩軌都不存在，第二個只存在於 Track A。Track B 改用 `kubectl get pod -l app=pmc-epmmformquerygui` 挑一個 pod。istio-proxy 映像裡有沒有 curl 屬環境特定，未研究 | ✓ |
| P12-015 | 4943、5088、5516 | 「內容與 `canary-manual/track-b/` 的檔案相同」；`track-b/00-configmap.yaml`；`track-b/05-analysistemplate.yaml` | 不精確 | `canary-manual/CANARY-COMPLETE.md §10 #11` ／ `canary-manual/track-b/` | 實際檔案是 `base/00-serviceaccount…04-analysistemplate.yaml`、`release/10-configmap-1.2.3.yaml`、`release/20-rollout.yaml`；§10 #11：「`10-configmap` 還被截斷」 | 改成實際路徑，並列出差異。repo 的步驟 3 是 `pause: {}`，guide 是 analysis；repo 的 image／ConfigMap 是 1.2.3，沒有 1.3.0；repo 的 user-name-attribute 是 `sub`，也沒有 cors／sso；repo 多一個 `-svc` Service 和 ServiceAccount | ✓ |
| P12-016 | 4945、5150 | 「可以直接 apply 的完整版」；`SPRING_CONFIG_ADDITIONAL_LOCATION` | 不精確 | `canary-manual/CANARY-COMPLETE.md §3.1` | 「Spring Boot 2.4+ 對非 `optional:` 且找不到的 `spring.config.location` 丟 `ConfigDataLocationNotFoundException` → **CrashLoopBackOff**」 | image 本身的 `SPRING_CONFIG_LOCATION=file:/config/application.yaml` 還在，pod 會 CrashLoop。標成「未完成、不可直接 apply」。依 k8s/CLAUDE.md，要等 track-b 的 ConfigMap 依附錄 C 補齊後，才能改成 `SPRING_CONFIG_LOCATION` | ✓ |
| P12-017 | 5022 | `user-name-attribute: preferred_username` | 不精確 | `canary-manual/CANARY-COMPLETE.md 附錄 C` | 「但**絕對不能寫成 `preferred_username`**」 | 改成 `sub`，跟 track-b 檔案一致 | ✓ |
| P12-018 | 5026–5035 | `app.cors.*`、`app.sso.*` | 不精確 | `canary-manual/CANARY-COMPLETE.md 附錄 C、§10 #13` | 「`app.cors.*`、`app.test-endpoints.*`、`app.sso.*` ｜ **哪裡都不要放** ｜ 沒有任何程式讀它們」 | 刪掉。post-logout 的正確 key 是 `app.post-logout-redirect-uri`（§3.5） | ✓ |
| P12-019 | 5214 | 「沒宣告的話 setHeaderRoute 不生效」 | 不精確 | validation.go（同 P12-001） | managedRoutes 為 nil 時（guide 的情況）："Rollout has missing field '%s'"（代入 spec.strategy.canary.trafficRouting.managedRoutes）；managedRoutes 有寫但漏列該 route 時："Steps define a route that does not exist in spec.strategy.canary.trafficRouting.managedRoutes" | 不是「不生效」，是整個 Rollout 驗證失敗（InvalidSpec），完全不會推進 | ✓ |
| P12-020 | 5312–5317、5335–5339 | `httpCookie: name: JSESSIONID, ttl: 10800s` | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route_components.proto ／ `canary-manual/CANARY-COMPLETE.md §3.3` | "If specified, a cookie with the TTL will be generated if the cookie is not present."；§3.3：「親和 cookie 改名 `epmm-affinity`」 | 改名 `epmm-affinity`，避免和 Spring 的 session cookie 同名、兩邊互寫 | ✓ |
| P12-021 | 4950–4968、5361–5363 | 「六份資源」只列 Service ×2，VirtualService 卻有 `pmc-epmmformquerygui-svc` 這個 host | 不精確 | `canary-manual/track-b/base/01-services.yaml`、`00-serviceaccount.yaml` | repo 有第三個 Service `pmc-epmmformquerygui-svc`，還有 ServiceAccount | 補上 `-svc` Service 和 ServiceAccount（Rollout 用了 `serviceAccountName`） | ✓ |
| P12-022 | 5386–5389 | `retryOn: "5xx,reset,connect-failure"` | 不精確 | `canary-manual/CANARY-COMPLETE.md §3.4` | 「Istio 的 retry **不分 HTTP method**。`5xx` 會讓一個失敗的 `POST` 表單最多重送 3 次。」 | 改成 `reset,connect-failure,refused-stream` | ✓ |
| P12-023 | 5408–5409 | 「必須先刪掉 Deployment，否則兩個 controller 會搶 pod」 | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | "The Rollout won't try to manage existing Deployment Pods."；"a Rollout should run next to the Deployment before deleting the Deployment or scaling down the Deployment. **Not following this approach might result in downtime**." | 先建 Rollout，確認健康後再刪 Deployment，或用 `workloadRef` 加 `scaleDown: onsuccess`。照現在的順序（先刪、Rollout 最後套）會有停機空窗 | ✓ |
| P12-024 | 5411–5418 | 套用清單 `00-configmap…05-analysistemplate`，最後一行 `--dry-run=server`，註解寫「套用前先驗語法」 | 不精確 | `canary-manual/track-b/`（實際檔案配置） | 實際檔案在 `base/`、`release/`，而且有 `00-serviceaccount.yaml` | 檔名改成實際路徑，補上 ServiceAccount（缺了 pod 建不起來），dry-run 移到最前面 | ✓ |
| P12-025 | 5503–5505 | `enough-traffic`：`count: 5`、`failureLimit: 5`，說這樣「省掉很多假警報」 | 錯誤 | analysis_types.go ／ analysis.go | "maximum number of times the measurement is allowed to fail, before the entire metric is considered Failed"；"the worst status is used as the overall AnalysisRun status" | 5 次量測最多 5 次失敗，永遠不會超過 failureLimit，這個指標形同虛設；它也擋不住 success-rate 自己失敗。`track-b/base/04-analysistemplate.yaml` 的 `success-rate-safe` 有同樣的問題。改法同 P12-006 | ✓ |
| P12-026 | 5555 | 「想在失敗時停下來等人…把 `analysis` 後面接一個 `pause: {}`」 | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ | "The success or failure of the analysis run decides if the rollout will proceed to the next step, or abort the rollout completely." | analysis 一失敗就 abort，根本走不到下一個 pause。要「失敗就停下來等人」，應設計成 Inconclusive（success／failure 條件之間留空隙），或用 `dryRun` 只收集數據 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P12-027 | 4474、4583、5095 | `argoproj.io/v1alpha1` 的 Rollout／AnalysisTemplate | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ |
| P12-028 | 4498、5208–5209、5269、5296 | Argo 會把 `rollouts-pod-template-hash` 寫進 stable／canary Service 的 selector | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P12-029 | 4505、5219、5372 | VirtualService 有多條 route 時，必須用名字指定 primary（"optional if there is a single route in VirtualService, required otherwise"） | 同上 |
| P12-030 | 4509、5223 | `setCanaryScale.replicas` 只在有 trafficRouting 時可用 | https://argo-rollouts.readthedocs.io/en/stable/features/canary/ |
| P12-031 | 4511–4516、4555–4561、5227–5232 | setHeaderRoute 的 `headerName`／`headerValue`（exact／regex 擇一）語法 | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ |
| P12-032 | 4528、4764、4784、5242 | 同名、不帶 match 就是移除 header／mirror route | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P12-033 | 4519–4524、4613 | analysis step 傳 args，Job 裡用 `{{args.canary-host}}` 取值 | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P12-034 | 4594–4596 | Job metric 以 exit 0 判成功（"successful if the Job completes and had an exit code of zero"），`count: 1`／`failureLimit: 0` 合理 | https://argo-rollouts.readthedocs.io/en/stable/analysis/job/ |
| P12-035 | 4682、5441 | failureLimit: 1 代表第 2 次失敗才判 Failed | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P12-036 | 4685、5444、5478、5568 | Istio addon 的 Prometheus 是 `prometheus.istio-system`、port 9090 | https://github.com/istio/istio/blob/master/samples/addons/prometheus.yaml |
| P12-037 | 4687–4712 | `istio_requests_total`、`istio_request_duration_milliseconds`、`response_code`、`destination_workload(_namespace)` 都是 Istio 標準名稱 | https://istio.io/latest/docs/reference/config/metrics/ |
| P12-038 | 4744、5487 | 判定 Failed 會 abort，canary 權重歸 0 | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P12-039 | 4745（行為部分）、5488 | Inconclusive 會讓 rollout 停在當前 step，等人 resume 或 abort | 同上 |
| P12-040 | 4757–4761 | setMirrorRoute 的 `percentage` 和 `match.method.exact: GET` 語法 | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ |
| P12-041 | 4768 | mirror 的回應被丟棄（"the response is ignored"） | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P12-042 | 4823、4826 | `pause: {}` 會無限期等待，直到手動 promote（"Pauses indefinitely until manually resumed"） | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ |
| P12-043 | 4868–4871 | `get rollout --watch`、`pause`、`abort`、`promote --full`（"skipping analysis, pauses, and steps"） | https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_promote/ |
| P12-044 | 4883、5210、5548 | abortScaleDownDelaySeconds 預設 30 秒，abort 後延遲縮掉 canary | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ |
| P12-045 | 4895–4896 | `notifications.argoproj.io/subscribe.<trigger>.<service>` 格式，`on-rollout-aborted`／`on-rollout-completed` 是內建 trigger | https://argo-rollouts.readthedocs.io/en/stable/features/notifications/ |
| P12-046 | 4920 | 15020 的 `/stats/prometheus` 是合併後的指標 | https://istio.io/latest/docs/ops/integrations/prometheus/ |
| P12-047 | 4971、5302 | host-level 分流不需要 subset，每個 Service 各配一份 DestinationRule（"The user can also create specific DestinationRules for each of the services."） | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P12-048 | 4999 | immutable ConfigMap 可減輕 kube-apiserver 負擔；Track B 是版本化命名，所以可以用 | https://kubernetes.io/docs/concepts/configuration/configmap/#configmap-immutable |
| P12-049 | 5246–5248 | `setCanaryScale.matchTrafficWeight: true` 會恢復讓 canary 規模跟著權重走 | https://argo-rollouts.readthedocs.io/en/stable/features/canary/ |
| P12-050 | 5369 | managed route 會插在手寫的 route 之前（"placed in the specified order above any manually defined routes"） | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P12-051 | 5398–5399 | 用 Argo CD 要忽略 VirtualService 的 weight 差異 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P12-052 | 5480 | Prometheus 回傳 vector，所以取 `result[0]` | https://argo-rollouts.readthedocs.io/en/stable/analysis/prometheus/ |
| P12-053 | 5539–5551 | 失敗流程：Degraded → 權重回到 stable → 延遲縮掉 canary（"the Rollout would be considered in a `Degraded`"） | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |

---

## Part 14：保留人工 pilot run 的 Canary 發布（概念逐行查證＋manifest／SOP 改成指標）

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P14-001 | 5897 | 「pilot 使用者（帶 canary=always cookie）」 | 過時 | canary-manual/CANARY-COMPLETE.md §0 | 「只有帶 `canary=always` cookie 的 pilot 使用者會被 Istio 送進 canary。cookie 由 stable pod 在**登入成功那一刻**依名單自動發放。」 | 圖說改成「BFF 依名單自動發 cookie」，名單維護指向 §7.1 | ✓ |
| P14-002 | 5909 | 「驗證期間對正式使用者的風險：零」 | 不精確 | canary-manual/CANARY-COMPLETE.md §0 | 「這代表 pilot 期間對正式使用者的路由風險是零 —— 但程式風險不是零，發 cookie 的那段程式跑在 stable 的每一次登入上。」 | 改成「路由風險為零；程式風險不為零（§10 #1）」 | ✓ |
| P14-003 | 5911 | 「canary 掛掉的影響：完全沒有影響」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.2 | 「→ 沒有 endpoint → 503（access log 的 response_flags = UH）→ 他們永遠打不到 stable，app 端「清 cookie」的邏輯根本沒機會執行 → 卡死到 cookie 過期為止（8 小時）」 | 改成：正式使用者不受影響；持有 cookie 的人會吃 503 UH，而且 cookie 是自動發的，持有者不知道自己有 | ✓ |
| P14-004 | 5923 | 「每次發布要改：只改 canary 的 image tag」 | 不精確 | canary-manual/CANARY-COMPLETE.md §5 步驟 1 | 「`replicas: 1  # 0 → 1`」；「**ConfigMap 與 Deployment 的改動必須在同一個 commit。** 這是回滾能運作的前提。」 | 改成：canary ConfigMap（若有差異）＋ image ＋ replicas 0→1 ＋ `sync-config-hash.sh`，全部放同一個 commit | ✓ |
| P14-005 | 5931 | 「promote 的動作 = 把 stable 的 image 改成 canary 現在跑的那一版，然後 canary 縮到 0」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4a | 「**promote 不是「stable 換 image、canary 縮到 0」那麼簡單。** 縮到 0 會讓還握著 cookie 的人吃 503」 | 改成兩個 commit：① canary data 複製進 stable ConfigMap、stable 換 image、canary 設 `APP_CANARY_ENABLED=false` 且 replicas 維持 1、跑 sync；② 排空之後才設 replicas 0 | ✓ |
| P14-006 | 6459 | 「真的需要多個 canary pod 時，必須在 canary subset 上加 `consistentHash`」 | 錯誤 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ ／ canary-manual/CANARY-COMPLETE.md §8.3 | 「Subsets inherit the traffic policies specified at the DestinationRule level.」／§8.3：「**canary 開超過 1 個 replica** ／ in-flight OAuth2 `state` 在 pod 記憶體，使用者會拿到 `authorization_request_not_found`」 | 刪掉這句。頂層的 consistentHash 本來就會被 subset 繼承，而且 repo 規定 canary 一律只開 1 個 replica | ✓ |
| P14-007 | 6463 | 「沒有 `name: http`／`appProtocol: http` 時，Istio 可能用 L4 處理，cookie 路由會直接失效」 | 不精確 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ | 「Istio can automatically detect HTTP and HTTP/2 traffic.」「If the protocol cannot automatically be determined, traffic will be treated as plain TCP traffic.」 | 改成：沒宣告時靠自動偵測，通常認得出 HTTP；偵測失敗才當 TCP。明確宣告才可靠（`appProtocol` 優先於 port name）。CANARY §4.1 也有同樣的過強說法 | ✓ |
| P14-008 | 6512、6654 | 「對這個 Service 的【所有 endpoint】做 round-robin」 | 錯誤 | https://istio.io/latest/docs/concepts/traffic-management/ | 「By default, Istio uses a least requests load balancing policy」；「Without virtual services, Envoy distributes traffic using least requests load balancing」 | round-robin 改成 least request；「約 1/3」保留，並註明是近似值 | ✓ |
| P14-009 | 6576 | 「`retries`：不行」 | 不精確 | https://istio.io/latest/docs/concepts/traffic-management/ | 「The default retry behavior for HTTP requests is to retry twice before returning the error.」 | 改成：VS 的 retries 不生效，但仍會套用 Istio 預設重試（attempts 2，retryOn connect-failure,refused-stream,unavailable,cancelled） | ✓ |
| P14-010 | 6604 | 「Prometheus 抓 metrics（如果 Prometheus 有 sidecar）」也算受影響的內部呼叫方 | 無法驗證 | https://istio.io/latest/docs/ops/integrations/prometheus/ | （本輪抓取失敗，沒有引文） | Prometheus 抓的目的地是 pod IP／埠，不是 Service host，照理不會比對到這條 VS。建議刪掉或補查之後改寫 | ✓ |
| P14-011 | 6639–6644 | 方法 2：「有 x-app-track: stable = mesh 生效；完全沒有這個 header = 沒生效」 | 不精確 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ | 「The reserved word `mesh` is used to imply all the sidecars in the mesh.」 | mesh 規則是在「呼叫端」sidecar 執行。`kubectl run` 的臨時 pod 沒注入 sidecar 時一樣拿不到 header，不代表 VS 缺 mesh。要先確認測試 pod 是 2/2；另外舊式 sidecar 會讓 `--rm -i` 的 pod 不會結束 | ✓ |
| P14-012 | 6660、6680 | 「使用者要能確認自己真的在 canary 上」（靠 x-app-track） | 不精確 | canary-manual/CANARY-COMPLETE.md §10 #5 | 「**`x-app-track` 只證明 pod，不證明 bytes** ／ header 對了畫面仍可能是舊的（快取） ／ 要同時看 ETag，見 6.4」 | 加註，並指向 §6.4 | ✓ |
| P14-013 | 6664–6678 | pilot-run 範例只比對 cookie，沒有 uri 條件 | 過時 | canary-manual/CANARY-COMPLETE.md §3.4 | 「`【修正】` 規則 1 加 `uri: prefix: /gui_epmmFormQuery`。」 | 改成指向 §3.4（track-a/base/03 目前也還沒改） | ✓ |
| P14-014 | 6702 | 「流量切換：你自己 `kubectl`」 | 不精確 | canary-manual/CANARY-COMPLETE.md §0 適用範圍 | 「CD 只能 `kubectl apply`（不能 patch / scale / delete）」 | 改成「改 YAML → commit → pipeline apply；正式流量權重不調整」 | ✓ |
| P14-015 | 6703 | Track A 的 promote：「把 stable 的 image 改成 canary 的」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4a | 「1. 把 `11-configmap-canary.yaml` 的 `data:` 整段複製進 `10-configmap-stable.yaml` 2. `20-deployment-stable.yaml` 的 `image` 改成 `1.3.0` 3. `21-deployment-canary.yaml` 的 `APP_CANARY_ENABLED` 改成 `"false"`，**`replicas` 維持 1**」 | 同 P14-005 | ✓ |
| P14-016 | 6708 | 「同時存在 Deployment 的話兩個 controller 會互搶 pod。切換前必須先刪掉 Track A 的兩個 Deployment」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | 「The Rollout won't try to manage existing Deployment Pods.」；「a Rollout should run next to the Deployment before deleting the Deployment or scaling down the Deployment. Not following this approach might result in downtime.」 | 改成：不會搶同一批 pod。本 repo 互斥的原因是共用 `app` label 與 VS `app-routing`。「先刪 Deployment」正是官方警告會造成中斷的順序 | ✓ |
| P14-017 | 6764–6770 | 14.11 圖的「現在」欄：「cookie 指定 canary／人工 pilot run」 | 過時 | canary-manual/CANARY-COMPLETE.md §0 | 「cookie 由 stable pod 在**登入成功那一刻**依名單自動發放。」 | 「現在」欄補上「BFF 依名單自動發 cookie」 | ✓ |
| P14-018 | 5933–6452（14.4） | 五份完整 manifest | 改成指標 | canary-manual/CANARY-COMPLETE.md §2、§3.2–§3.9 | 「## 3. 怎麼寫這些 YAML」「以下是**修正後**的版本。跟目前 repo 裡的 `track-a/` 有差異的地方都標了 `【修正】`。」 | 保留「四層 label 串接」圖（pod label → Service 只比對 app → DR 以 version 分 subset → VS 選 subset）和四種接錯方式表（UH／NC）。說明實際檔案在 `canary-manual/track-a/{base,release,runtime}/`，目標狀態以 §3 為準；刪掉整段 YAML 複本 | ✓ |
| P14-019 | 5936 | 「內容與 `canary-manual/track-a/` 的檔案完全相同」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §2 | 「├── 10-configmap-stable.yaml ／ ├── 11-configmap-canary.yaml」「└── 05-configmap-canary-pilot.yaml」 | 實際的 track-a 已經是 `SPRING_CONFIG_LOCATION`、`config-hash`、-stable／-canary ConfigMap、canary-pilot volume、readiness／liveness 分開。刪掉這句（由指標取代） | ✓ |
| P14-020 | 6068、6198 | `SPRING_CONFIG_ADDITIONAL_LOCATION` | 錯誤 | canary-manual/CANARY-COMPLETE.md §3.1 | 「`【修正】` **Deployment 改用 `SPRING_CONFIG_LOCATION`，路徑對上 mount 點：**」 | 改成 `SPRING_CONFIG_LOCATION`（validate.sh 檢查 [6] 會擋回頭的寫法） | ✓ |
| P14-021 | 6030、6169 | `checksum/config: "REPLACE_WITH_SHA256_OF_CONFIGMAP"` | 過時 | canary-manual/CANARY-COMPLETE.md §3.6 | 「改成 ConfigMap data 區塊的 sha256 前 8 碼，由 scripts/sync-config-hash.sh 回寫。」 | 改成 `config-hash`。佔位字串永遠不會變，改了設定也不會觸發滾動更新 | ✓ |
| P14-022 | 6126、6255 | 兩份 Deployment 都掛 `pmc-epmmformquery-config` | 錯誤 | canary-manual/CANARY-COMPLETE.md §3.7 | 「`volumes[config].configMap.name` ／ `pmc-epmmformquery-config-canary`」 | 每份掛自己那一軌的 ConfigMap（CLAUDE.md 規則 4） | ✓ |
| P14-023 | 6064–6129、6194–6258 | 沒有 canary-pilot volume；canary 沒有 `APP_CANARY_ENABLED` | 過時 | canary-manual/CANARY-COMPLETE.md §3.6、§3.7 | 「mountPath: /app/canary          # 【關鍵】掛目錄，不是 subPath」；「`env` 多一個 ／ `APP_CANARY_ENABLED: "true"`」 | 由指標取代 | ✓ |
| P14-024 | 6083、6091、6099、6213–6229 | 三個探針都打 `/gui_epmmFormQuery/actuator/health` | 過時 | canary-manual/CANARY-COMPLETE.md §3.6 | 「`【修正】` liveness 與 readiness 分開，不要共用同一個端點。」 | 由指標取代，並引用「探針目前是假的」那段警告 | ✓ |
| P14-025 | 6308 | `httpCookie: name: JSESSIONID` | 過時 | canary-manual/CANARY-COMPLETE.md §3.3 | 「`【修正】` **親和 cookie 改名 `epmm-affinity`。**」 | track-a/base/02 目前仍是 JSESSIONID，目標狀態還沒落地 | ✓ |
| P14-026 | 6334–6339 | 註解「canary 若要開超過 1 個 replica，解開這段」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.3 | 「**canary 開超過 1 個 replica** ／ in-flight OAuth2 `state` 在 pod 記憶體，使用者會拿到 `authorization_request_not_found`」 | 刪掉 | ✓ |
| P14-027 | 6385、6415 | `retryOn: "5xx,reset,connect-failure"` | 錯誤 | canary-manual/CANARY-COMPLETE.md §3.4 | 「`【修正】` **`retryOn` 拿掉 `5xx`。** Istio 的 retry **不分 HTTP method**。`5xx` 會讓一個失敗的 `POST` 表單最多重送 3 次。」 | 改成 `reset,connect-failure,refused-stream`（track-a/base/03 也還沒改） | ✓ |
| P14-028 | 6365–6370、6400–6406 | pilot-run 沒有 uri 條件；primary 留著 `weight: 0` 的 canary destination | 過時 | canary-manual/CANARY-COMPLETE.md §3.4 | 「`【修正】` 規則 2 拿掉 `weight: 0` 的 canary destination。」 | 由指標取代 | ✓ |
| P14-029 | 6439–6447 | 套用順序（沒有 ConfigMap、沒有 runtime/）＋ `kubectl scale ... --replicas=0` | 錯誤 | canary-manual/CANARY-COMPLETE.md §4.2、§0 | 「kubectl apply -f track-a/runtime/    # pilot 名單（先建立，Deployment 才掛得到）」；「CD 只能 `kubectl apply`（不能 patch / scale / delete）」 | 改成 base → runtime → release 三次目錄 apply；canary 靜止時的 0 寫在 YAML 裡，而且只能在排空後設（§3.7） | ✓ |
| P14-030 | 6725–6758（14.10） | 完整流程速查 | 改成指標 | canary-manual/CANARY-COMPLETE.md §5、§8.1 | 「## 5. 每次發布」「**所有動作都只是「改 YAML + apply」。**」 | 摘要：開分支 → canary ConfigMap＋Deployment（image、replicas 1）＋ sync-config-hash 放同一個 commit → 驗 cookie 路由（§6.1）→ pilot run → 兩段式 promote → 回滾用 git revert | ✓ |
| P14-031 | 6731–6733 | `kubectl set image`／`scale --replicas=1` | 錯誤 | canary-manual/CANARY-COMPLETE.md §0 | 「CD 只能 `kubectl apply`（不能 patch / scale / delete）」 | 這樣做也繞過 git，下次 apply 會被蓋掉，而且不會更新 config-hash | ✓ |
| P14-032 | 6745–6748 | promote 後立刻 `scale canary --replicas=0` | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4a | 「縮到 0 會讓還握著 cookie 的人吃 503 —— 跟「canary 不通過」那條路徑是同一個坑。正確的順序是**先讓 canary 變成無害，排空之後才縮**。」 | 照 §5 步驟 4a 做 | ✓ |
| P14-033 | 6750–6751 | 「不通過 → 關掉 canary（使用者完全無感）」`scale --replicas=0` | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.2 | 「### 8.2 為什麼 `replicas: 0` 是 outage 不是不方便」 | 改用 §8.1 第 1 張牌（`APP_CANARY_ENABLED=false` ＋ image 改回，replicas 維持 1） | ✓ |
| P14-034 | 6754 | `kubectl rollout undo deploy/...-stable` | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.3 | 「固定名稱的 ConfigMap 是可變的。undo 還原 pod template（含舊的 `config-hash`），但 ConfigMap 內容已經是新的 → pod 用**舊 annotation** 重啟卻掛到**新設定**。沒有錯誤訊息」 | 改成 git revert ＋ apply（§8.4） | ✓ |
| P14-035 | 6757 | 「`canary.sh` 把這些包成 deploy / verify / status / promote / rollback / undo 六個指令」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §10 #12 | 「**`scripts/canary.sh` 與 `README.md` 仍在教 `replicas: 0`** ／ 照著做就會製造 8.2 的 outage ／ 待修；在那之前不要用那個腳本的 `rollback` / `promote`」 | 刪掉，或改成「勿用（US-010 未完成）」 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P14-201 | 5884 | 權重是逐請求的機率分流 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P14-202 | 5886–5887 | in-memory session 在 pod／軌之間跳動會被要求重新登入 | https://istio.io/latest/docs/concepts/traffic-management/ |
| P14-203 | 5902 | canary 的正式流量權重永遠是 0 | canary-manual/CANARY-COMPLETE.md §0 |
| P14-204 | 5929 | `version` label 會成為 metrics 的版本維度 | https://istio.io/latest/docs/ops/deployment/application-requirements/ |
| P14-205 | 6457 | sidecar 底下 `sessionAffinity: ClientIP` 不生效 | canary-manual/CANARY-COMPLETE.md §3.2（前批已驗證） |
| P14-206 | 6455–6457 | canary 只能 1 個 replica | canary-manual/CANARY-COMPLETE.md §3.7 |
| P14-207 | 6469、6532–6538 | 沒有 mesh 時內部流量按 endpoint 數大約平均分到兩軌（約 1/3） | https://istio.io/latest/docs/concepts/traffic-management/ |
| P14-208 | 6504 | 呼叫端 outbound 被 iptables 導到 15001（本輪沒能重新抓取） | https://istio.io/latest/docs/ops/deployment/application-requirements/ |
| P14-209 | 6481–6487 | gateways 省略時是 mesh；列了 gateway 就只套用到 gateway | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P14-210 | 6520、6592 | 沒有 VS 引用時 subset 不會被用到 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P14-211 | 6541–6566 | `hosts` 要同時包含內部 FQDN | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P14-212 | 6575 | timeout 預設是關閉的 | https://istio.io/latest/docs/concepts/traffic-management/ |
| P14-213 | 6574、6577–6581 | route／headers／rewrite／fault／mirror／corsPolicy 在沒有 mesh 時對內部呼叫不生效 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P14-214 | 6591–6594 | DR 的 trafficPolicy、PeerAuthentication、AuthorizationPolicy 不依賴 VS | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P14-215 | 6595 | kubelet 探針不經過 VS 路由 | https://istio.io/latest/docs/concepts/traffic-management/ |
| P14-216 | 6613 | NR 對應 404、沒有 route | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P14-217 | 6625 | catch-all 規則要放最後（第一條符合的規則勝出） | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P14-218 | 6647 | `istioctl x describe pod` 可以看到套用到 pod 的規則 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P14-219 | 6662、6677 | 用 VS 的 `headers.response.set` 加 header，不用改程式 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P14-220 | 6684–6692 | `.*canary=always.*` 太寬鬆；帶分隔符的 regex 才精準；cookie 格式是 `a=1; b=2` | https://istio.io/latest/docs/reference/config/networking/virtual-service/ ／ RFC 6265 §4.2.1 |
| P14-221 | 6700–6701 | Track A 不用安裝；Track B 靠 `pause: {}` ＋ promote 推進 | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ |
| P14-222 | 6704 | 之後可以直接加 analysis step | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P14-223 | 6706 | 建議先用 Track A | canary-manual/CANARY-COMPLETE.md §0 |
| P14-224 | 6715 | `setHeaderRoute` 需要宣告 `managedRoutes` | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P14-225 | 6720 | VS 有多條 route 時 `routes` 必填 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P14-226 | 6723 | 用過明確的 `setCanaryScale` 之後，要 `matchTrafficWeight: true` 才恢復跟權重走 | https://argo-rollouts.readthedocs.io/en/stable/features/canary/ |
| P14-227 | 6775 | pilot-run-guide 要求驗證人員寫下第 6 項實際測了什麼 | canary-manual/pilot-run-guide.md:62 |

---

## Part 15：兩種上版方式的完整對照與 SOP（概念逐行查證＋SOP 改成指標）

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P15-001 | 6800、7302 | 「兩個 controller 互相搶 pod —— pod 反覆被建立和刪除」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | 「The Rollout won't try to manage existing Deployment Pods.」 | 改成：各自透過 ownerReference 管自己的 ReplicaSet；本 repo 互斥是因為共用 `app` label 與 VS | ✓ |
| P15-002 | 6802 | 「切換 track 要刪掉 Deployment、建立 Rollout…有服務中斷的風險」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | 「When migrating a Deployment which is already serving live production traffic, a Rollout should run next to the Deployment before deleting the Deployment or scaling down the Deployment.」 | 補上官方的 `workloadRef`（scaleDown：never／onsuccess／progressively）遷移路徑 | ✓ |
| P15-003 | 6822–6855 | 做法二「同一個服務用 Track B（推薦）」、6855「直接上 Track B 並保留 `pause: {}`」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §0、§10 #11 | 「Track A（純 Deployment + Istio）。Track B（Argo Rollouts）目前**沒有跟上自動分流**，見第 10 章。」；「自動分流在 Track B 跑不起來。**要嘛補齊，要嘛把 track-b 標成不維護**」 | 改成：本 repo 現況只支援 Track A，Track B 是未來選項 | ✓ |
| P15-004 | 6850、6853 | 「`promote --full`…前面已經跑完的 analysis 仍然生效」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_promote/ | 「Perform a full promotion, skipping analysis, pauses, and steps」 | 只有已經停在 analysis 之後的 pause 時才成立；analysis 還在跑時下 `--full` 會直接跳過它 | ✓ |
| P15-005 | 6867、6882 | 「ConfigMap：2 份（版本化）」、Track A「版本化（也可用 -stable/-canary）」 | 過時 | canary-manual/CANARY-COMPLETE.md §2 命名規則 | 「**改動重點：整個 repo 只剩 image tag 一處帶版本號。**」 | Track A 欄改成「固定 -stable／-canary」，這不是選項（validate.sh 檢查 [8] 會擋版本號） | ✓ |
| P15-006 | 6873 | 「檔案總數 5 ／ 6」 | 過時 | canary-manual/CANARY-COMPLETE.md §2 | 「└── runtime/       變更頻率：pilot 期間一天數次    → 獨立，不經過發布流程」 | 改成 Track A 9 檔（base 4＋release 4＋runtime 1）、Track B 7 檔 | ✓ |
| P15-007 | 6891 | 「權重誰改：Track A 你手動 `kubectl patch`」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §3.4 | 「這套機制的定位是「不做百分比分流」，那就不要留一個 weight 欄位在那裡引誘人去改它」 | 改成「Track A 不調權重」 | ✓ |
| P15-008 | 6892 | promote 機制：「改 stable Deployment 的 image + ConfigMap 引用」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4a | 「1. 把 `11-configmap-canary.yaml` 的 `data:` 整段複製進 `10-configmap-stable.yaml`」 | 指向 §5 步驟 4a | ✓ |
| P15-009 | 6893 | 回滾：「`kubectl rollout undo` / 縮 canary 到 0」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.3 | 「**單獨把 canary `replicas` 設成 0** ／ 見 8.2」 | 改成 git revert（§8.4）、§8.1 第 1 張牌 | ✓ |
| P15-010 | 6898–6899 | 「ConfigMap 的內容：完全一樣」「pod template…完全一樣，可以整段複製」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §10 #11 | 「`20-rollout.yaml` 沒有 `APP_TRACK` / `APP_CANARY_ENABLED` / 名單掛載，`10-configmap` 還被截斷」 | 另外 track-b 仍是 ADDITIONAL（merge），track-a 是 LOCATION（replace），整段複製會把語意搞混 | ✓ |
| P15-011 | 6904 | 只開 1 個 replica 的理由只寫 in-memory session | 不精確 | canary-manual/CANARY-COMPLETE.md §3.7 | 「in-flight 的 OAuth2 `state`、`HttpSession`、authorized-client token 全部在 pod 記憶體裡。」 | 補上 OAuth2 state | ✓ |
| P15-012 | 6908–7067（15.4） | 完整 kubectl 權限版的 Track A SOP | 改成指標 | canary-manual/CANARY-COMPLETE.md §4.1、§5、§8 | 「## 5. 每次發布」 | 摘要：本環境 CD 只能 apply，這份 SOP 不再維護；前置檢查看 §4.1，發布看 §5，關閉／回滾看 §8 | ✓ |
| P15-013 | 6912、6987 | 指向 `canary-manual/SOP.md`、`README.md` 的排查表 | 過時 | canary-manual/CANARY-COMPLETE.md 開頭「這份取代了什麼」 | 「`SOP.md` ／ 已被取代（需要完整 kubectl 權限的版本）」 | 排查改指 §9 | ✓ |
| P15-014 | 6924 | 用 `kubectl get endpoints` 檢查兩個 subset | 過時 | canary-manual/CANARY-COMPLETE.md §4.3 | 「兩個 subset 都要有 endpoint（沒有就是 503 UH 的來源）」 | Endpoints 列的是兩軌合併、分不出 subset，且該 API 自 v1.33 已 deprecated。改用 istioctl proxy-config endpoint | ✓ |
| P15-015 | 6929–6940 | 版本化 ConfigMap ＋ `immutable: true` | 錯誤 | canary-manual/CANARY-COMPLETE.md §2.2 | 「固定名稱的 ConfigMap 是**可變**的（必須拿掉 `immutable: true`，否則 `kubectl apply` 會噴 `field is immutable`）。」 | 由指標取代 | ✓ |
| P15-016 | 6947–6959 | patch image＋configMap.name＋config-version、`./canary.sh deploy` | 錯誤 | canary-manual/CANARY-COMPLETE.md §2 命名規則 | 「舊做法有「三處版本號」（image、`configMap.name`、`config-version` annotation）要人工同步，少改一處就是「新版程式配舊版設定」。」 | 由指標取代 | ✓ |
| P15-017 | 7009–7021 | promote 後立刻 scale canary 0、`./canary.sh promote` | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4a | 「正確的順序是**先讓 canary 變成無害，排空之後才縮**。」 | 由指標取代 | ✓ |
| P15-018 | 7035–7041 | 5b `scale --replicas=0`「使用者完全無感」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.2 | 「現在 cookie 是系統自動發的，持有者可能是幾十個人，**而且他們不知道自己有**。」 | 由指標取代 | ✓ |
| P15-019 | 7045–7052 | `rollout undo`「會把 image **和** ConfigMap 引用一起還原」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §2.2 | 「**`kubectl rollout undo` 不再會回滾設定。**」 | 由指標取代 | ✓ |
| P15-020 | 7056–7064 | 清理舊 ConfigMap、`./canary.sh cleanup` | 錯誤 | canary-manual/CANARY-COMPLETE.md §2.1 | 「但 `scripts/canary.sh cleanup` 預設只留 3 個。回滾超過 3 版 → ConfigMap 不存在 → pod 卡在 `ContainerCreating`。」 | 刪掉 | ✓ |
| P15-021 | 7068–7195（15.5） | Track B（Argo）SOP | 改成指標 | canary-manual/CANARY-COMPLETE.md §0、§10 #11 | 「**Track B（Argo Rollouts）沒有跟上**」 | 摘要：需要 `kubectl argo rollouts` 指令，與 apply-only 不相容；track-b manifest 沒依附錄 C 補齊、跑不了自動分流。只保留一句「若日後補齊 Track B，以 Argo 官方文件為準」 | ✓ |
| P15-022 | 7203 | 「緊急修補：Track B 的 `promote --full` ／ 指標仍會跑」 | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/generated/kubectl-argo-rollouts/kubectl-argo-rollouts_promote/ | 「To skip analysis, pauses and steps entirely, use '--full' to fully promote the rollout」 | 改成「會跳過還沒跑的 analysis」 | ✓ |
| P15-023 | 7203–7204 | 緊急／夜間用 Track B 全自動 | 環境特定 | canary-manual/CANARY-COMPLETE.md §0 | 「CD 只能 `kubectl apply`（不能 patch / scale / delete）」 | 標明本環境不適用 | ✓ |
| P15-024 | 7217–7308（15.7） | 兩種 track 之間的切換 | 改成指標 | canary-manual/CANARY-COMPLETE.md §0、§10 #11 | 「Track A（純 Deployment + Istio）。Track B（Argo Rollouts）目前**沒有跟上自動分流**」 | 摘要：本 repo 兩軌互斥、只維護 Track A，不提供切換 SOP；真要遷移時以 Argo 官方 migrating（workloadRef）為準 | ✓ |
| P15-025 | 7231–7242、7278–7290 | `track-b/00-configmap.yaml`、`track-a/01-deployment-stable.yaml` 等路徑 | 過時 | canary-manual/CANARY-COMPLETE.md §2 | 「├── base/ … ├── release/ … └── runtime/」 | 這些檔名都不存在，實際是 `track-*/base/`、`release/` 底下的編號檔 | ✓ |
| P15-026 | 7236–7242 | 先套 VS 再建 Rollout（自己也寫了「會造成短暫的 503」） | 錯誤 | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | 「Not following this approach might result in downtime.」 | 刪掉這個順序 | ✓ |
| P15-027 | 7254 | 「先讓 Rollout 把 pod 跑起來（此時新舊 pod 並存）」 | 錯誤 | repo 根目錄 CLAUDE.md | 「track-a 是兩份 Deployment… track-b 是 Argo Rollouts 的一份 Rollout。兩者同時存在時兩個 controller 會搶 pod。」 | 並存時 Rollout 的 pod 帶 `app` label，會被 track-a 的 `-svc` 選進 endpoint。Argo 官方雖然建議並存遷移，本 repo 規則是互斥，要寫明 | ✓ |
| P15-028 | 7280 | `kubectl scale ...canary --replicas=0` | 錯誤 | canary-manual/CANARY-COMPLETE.md §0 | 「CD 只能 `kubectl apply`（不能 patch / scale / delete）」 | 刪掉 | ✓ |
| P15-029 | 7331、7342 | 「`replicas` 寫死在 YAML」「canary 一定要寫（靠它開關 0 / 1）」 | 不精確 | canary-manual/CANARY-COMPLETE.md §8.1 | 「`replicas: 1 → 0` ／ 瞬間 ／ **503 UH，卡到 cookie 過期（8h）** ／ **不可單獨使用**，只能在確認排空後收尾」 | 改成：開＝replicas 1；關＝`APP_CANARY_ENABLED=false` ＋ image 改回，排空後才設 0 | ✓ |
| P15-030 | 7333 | 「`kubectl delete`：舊 ConfigMap 清不掉」 | 過時 | canary-manual/CANARY-COMPLETE.md §2.1 | 「**版本化命名 + cleanup 會互咬。** 舊做法把 ConfigMap 命名成 `...-config-1.2.3` 並保留舊版供回滾」 | 名稱固定之後不會累積，這一列可以刪 | ✓ |
| P15-031 | 7334 | 「promote 改的是 `status`，apply 只能改 `spec` → 改用 `spec.paused`」 | 無法驗證 | https://argo-rollouts.readthedocs.io/en/stable/features/specification/ | 「Pause allows a user to manually pause a rollout at any time.」；pause step：「Pauses indefinitely until manually resumed」 | 官方文件沒有寫 promote 的實作細節，也沒說 `spec.paused` 能取代 pause step。15.12 自己也說要先驗證 | ✓ |
| P15-032 | 7343–7345 | 「省略 replicas 的話，`kubectl apply` 不會管這個欄位，HPA 設定的值就保留得住」 | 不精確 | https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/ | 「Keep in mind that the removal of `spec.replicas` may incur a one-time degradation of Pod counts as the default value of this key is 1」 | 補上 `kubectl apply edit-last-applied` 的遷移步驟 | ✓ |
| P15-033 | 7354–7376 | 目錄樹有 `10-configmap-1.2.3.yaml`／`10-configmap-1.3.0.yaml`、沒有 runtime/ | 過時 | canary-manual/CANARY-COMPLETE.md §2 | 「│   ├── 10-configmap-stable.yaml ／ │   ├── 11-configmap-canary.yaml」 | 換成 §2 的樹 | ✓ |
| P15-034 | 7384（另 7704） | 「發布途中 apply 它會把權重打回 100/0，直接中斷 canary」 | 不精確 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ | 「the controller will instantly set the VirtualService weights back to the canary weight」 | 改成「controller 會立刻改回，但權重會短暫跳動」。VS 仍然要放 base/；Argo CD 要設 ignoreDifferences | ✓ |
| P15-035 | 7391 | 「`10-`：release ConfigMap（每版一個檔）」 | 過時 | canary-manual/CANARY-COMPLETE.md §2 | 「所以 ConfigMap（`10-`/`11-`）一定先於 workload（`20-`/`21-`）建立。」 | 改成 10-／11- 兩份固定，並補上 runtime 的 05- | ✓ |
| P15-036 | 7394 | 「`kubectl apply -f release/` 會按檔名排序套用」 | 無法驗證 | https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/ ／ https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ | 官方只說 `-f <directory>` 會建立目錄內所有物件，沒有寫順序；後果有官方依據：「If you reference a ConfigMap that doesn't exist and you don't mark the reference as `optional`, the Pod won't start.」 | 註明這是 kubectl 走目錄的實作行為，不是文件保證（CANARY §2 也依賴它） | ✓ |
| P15-037 | 7398–7607（15.10） | Track A 的 apply-only SOP | 改成指標 | canary-manual/CANARY-COMPLETE.md §5 | 「### 步驟 1【改動】canary 的設定與 image」 | 摘要：主線就是 §5 的步驟 0–5，【改動】／【驗證】的分法保留；關閉看 §8.2 | ✓ |
| P15-038 | 7407–7419 | 起始狀態：`configMap.name: ...-1.2.3`、`config-version` | 過時 | canary-manual/CANARY-COMPLETE.md §3.6 | 「# 【修正】原本是 config-version: "1.2.3"。」 | 由指標取代 | ✓ |
| P15-039 | 7423–7447 | 新增 `10-configmap-1.3.0.yaml`，帶 `immutable: true`、label `config-version` | 錯誤 | canary-manual/CANARY-COMPLETE.md §2.2 | 「（必須拿掉 `immutable: true`，否則 `kubectl apply` 會噴 `field is immutable`）」 | 改成直接改 `11-configmap-canary.yaml` | ✓ |
| P15-040 | 7453–7482 | 「三處版本號 + replicas 共四個地方」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §2 命名規則 | 「現在 ConfigMap 名稱固定，annotation 改成**內容雜湊**（第 2.2 節），所以只剩一處需要人工維護。」 | 由指標取代 | ✓ |
| P15-041 | 7553–7561 | promote 的同一個 commit 把 canary `replicas: 1 → 0` | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4a | 「`21-deployment-canary.yaml` 的 `APP_CANARY_ENABLED` 改成 `"false"`，**`replicas` 維持 1**」 | 由指標取代 | ✓ |
| P15-042 | 7581–7592 | 5b `replicas: 0`「使用者完全無感」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §5 步驟 4b | 「**同樣不是 `replicas: 0`。** 見第 8 章。」 | 由指標取代 | ✓ |
| P15-043 | 7598–7602 | 操作對照總表（三處版本號、promote／不通過都是 `1 → 0`） | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.1 | 「`APP_CANARY_ENABLED=false` + image 改回 stable 版 ／ 下一次頁面導航 ／ **乾淨排空，零 503** ／ **預設做法**」 | 由指標取代 | ✓ |
| P15-044 | 7630 | 「revert 它（會把三處版本號改回 1.2.3）」 | 過時 | canary-manual/CANARY-COMPLETE.md §5 步驟 5 | 「git revert <promote 那個 commit 的 sha>     # ConfigMap 與 Deployment 一起還原」 | 改寫 | ✓ |
| P15-045 | 7636 | 「revert 把 image 和 ConfigMap 引用**一起**改回去」 | 不精確 | canary-manual/CANARY-COMPLETE.md §2.2 | 「**ConfigMap 與 Deployment 的改動必須在同一個 commit。** 回滾一律 `git revert <該 commit>` → 重跑 apply」 | 現在還原的是 ConfigMap 內容＋image＋config-hash，前提是放在同一個 commit；用 §8.4 比對 hash 驗證 | ✓ |
| P15-046 | 7638–7659 | 「舊 ConfigMap 絕對不能刪」、保留 3 版、接受累積 | 過時 | canary-manual/CANARY-COMPLETE.md §2.1 | 「回滾超過 3 版 → ConfigMap 不存在 → pod 卡在 `ContainerCreating`。這正是「回滾時找不到檔案」。」 | 名稱固定後這個問題已經消失，刪掉或改成歷史說明 | ✓ |
| P15-047 | 7657 | prune「會刪掉不在這次 apply 檔案裡、但帶有該 label 的所有資源」 | 不精確 | https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/ | 「Allowlist-based pruning: This mode has existed since kubectl v1.5 but is still in alpha due to usability, correctness and performance issues with its design.」 | 補上 alpha 狀態、只刪帶 last-applied annotation 且在 allowlist 內的物件；「不建議」的結論不變 | ✓ |
| P15-048 | 7663–7726（15.12） | Track B 在 apply-only 下的限制 | 改成指標 | canary-manual/CANARY-COMPLETE.md §0、§10 #11 | 「CD 只能 `kubectl apply`（不能 patch / scale / delete）」 | 摘要：promote 需要 CLI；apply-only 只能靠 `spec.paused`，而且沒驗證過；VS 必須放 base/；結論是 apply-only 用 Track A（與 §0 一致） | ✓ |
| P15-049 | 7727–7771（15.13） | Azure Pipeline 設定建議 | 改成指標 | canary-manual/CANARY-COMPLETE.md §2、§4.1 | 「base/          變更頻率：極低（網路設定）      → 單獨 stage，額外簽核」 | 摘要：base 和 release 分 stage、base 加核准；validate stage 用 `--dry-run=server`（§4.1）；去問平台團隊用的是哪個 task | ✓ |
| P15-050 | 7759 | 「`KubernetesManifest@1` 支援 deploy / promote / reject / scale / patch / delete」 | 不精確 | https://learn.microsoft.com/en-us/azure/devops/pipelines/tasks/reference/kubernetes-manifest-v1 | 「Allowed values: `bake`, `createSecret` (create secret), `delete`, `deploy`, `patch`, `promote`, `scale`, `reject`.」「Choosing the `canary` strategy with the `deploy` action leads to the creation of workload names suffixed with `-baseline` and `-canary`.」 | 補充：那裡的 promote／reject 是這個 task 自己的 baseline／canary 機制，跟 Argo promote 或本 repo 的 stable／canary 無關；scale／patch 在本 repo 是禁止的捷徑 | ✓ |
| P15-051 | 7767 | 「如果問完發現其實可以跑指令，就回頭用 15.4 / 15.5 那兩份 SOP」 | 錯誤 | canary-manual/CANARY-COMPLETE.md §8.3 | 「**`kubectl rollout undo`** ／ 固定名稱的 ConfigMap 是可變的。」 | 就算有權限，也不能用 15.4 裡的 scale 0 和 rollout undo | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P15-201 | 6793 | 同一個服務不能這次用 A、下次用 B（repo 規定互斥） | repo 根目錄 CLAUDE.md |
| P15-202 | 6836 | `setHeaderRoute` 支援 regex 比對 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P15-203 | 6840 | 只帶 name 的空 `setHeaderRoute` 會移除那條 route | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P15-204 | 6851、6894 | analysis 失敗會自動 abort | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P15-205 | 6869–6870、6884–6886 | Track B 是 host-level 分流：2 個 Service、2 份 DR、沒有 subsets | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P15-206 | 6883 | Argo 會動態改 Service 的 selector | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P15-207 | 6887–6890 | pilot-run 由 Argo 動態插入，放在手寫 route 之上 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/ |
| P15-208 | 6889 | `primary` 這個 route 名稱是必要的 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |
| P15-209 | 7132 相關 | Inconclusive 會讓 rollout 暫停在當前 step | https://argo-rollouts.readthedocs.io/en/stable/features/analysis/ |
| P15-210 | 7209 | 只能 apply 的 CD 就用 Track A | canary-manual/CANARY-COMPLETE.md §0 |
| P15-211 | 7311、7319 | pipeline 只能 apply；本人只有唯讀 | canary-manual/CANARY-COMPLETE.md §0 |
| P15-212 | 7332、7610 | 回滾靠 git revert ＋ 重新 apply | canary-manual/CANARY-COMPLETE.md §2.2、§5 步驟 5 |
| P15-213 | 7338–7341 | YAML 裡寫死 replicas 會跟 HPA 打架 | https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/ |
| P15-214 | 7382–7383 | base 要跟 release 分開 | canary-manual/CANARY-COMPLETE.md §2 |
| P15-215 | 7394 | ConfigMap 不存在時 Pod 起不來 | https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ |
| P15-216 | 7657 | 不建議用 prune | https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/ |
| P15-217 | 7709 | 用 Argo CD 時要忽略 VS weight 的差異 | https://argo-rollouts.readthedocs.io/en/stable/features/traffic-management/istio/ |

---

## Part 8：除錯速查表

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P08-001 | 3426 | STALE / NOT SENT = 設定沒下發成功，八成是 istiod 有問題 | 錯誤 | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ | "NOT SENT means that Istiod hasn't sent anything to Envoy. This usually is because Istiod has nothing to send." ／ "STALE means that Istiod has sent an update to Envoy but has not received an acknowledgement." | 只有 STALE 代表 Envoy 沒有 ACK，可能有問題。NOT SENT 通常是正常狀態（官方範例裡 ingressgateway 的 RDS 就是 NOT SENT），要拆開寫。 | ✓ |
| P08-002 | 3444 | `--level default:warning   # 復原` | 錯誤 | https://istio.io/latest/docs/reference/commands/istioctl/ ／ https://raw.githubusercontent.com/istio/istio/master/istioctl/pkg/proxyconfig/proxyconfig.go | "Reset levels to default value (warning)." ／ istioctl 原始碼：`return fmt.Errorf("unrecognized logger name: %v", loggerLevel[0])`。Envoy 的 ALL_LOGGER_IDS 裡沒有名為 default 的 logger | 改成 `istioctl proxy-config log deploy/epmm-api -n ea-epmm -r`，或 `--level warning`（不加 logger 名稱就套用到全部 logger）。 | ✓ |
| P08-003 | 3450–3457 | 直接 `kubectl logs ... -c istio-proxy` 看 access log；格式以 "upstream_host" 收尾 | 不精確 | https://istio.io/latest/docs/tasks/observability/logs/access-log/ | "Istio offers a few ways to enable access logs." ／ "The egress gateway and access logging will be enabled if you install the `demo` configuration profile." ／ 預設格式在 "%UPSTREAM_HOST%" 之後還有 "%UPSTREAM_CLUSTER_RAW% %UPSTREAM_LOCAL_ADDRESS%" 等欄位 | 補一句前提：access log 預設關閉，要用 Telemetry API 或 `meshConfig.accessLogFile=/dev/stdout` 打開。格式範例在 upstream_host 後面補「...」。 | ✓ |
| P08-004 | 3473 | 表格把「`RBAC` 相關」列成一種 response flag | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | Envoy 的 RESPONSE_FLAGS 清單沒有任何 RBAC flag。最接近的是 "UnauthorizedExternalService / UAEX: The request was denied by the external authorization service." | 註明 RBAC 拒絕時 flag 是 `-`，判讀要看 403 加上 RESPONSE_CODE_DETAILS 的 `rbac_access_denied_matched_policy[...]`。 | ✓ |
| P08-005 | 3479 | 404 且 gateway 完全沒 log → Gateway 的 hosts 沒對上（連 listener 都沒進來） | 錯誤 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter ／ https://istio.io/latest/docs/reference/config/networking/gateway/ | NR: "No route configured for a given request in addition to 404 response code" ／ "or no matching filter chain for a downstream connection." | HTTP host 不符時，gateway 有 log，顯示 404 加 NR。HTTPS SNI 不符時是 TLS 握手失敗，不會回 404。「完全沒 log」通常代表 access log 沒開，或流量根本沒到 gateway（DNS、LB、防火牆）。 | ✓ |
| P08-006 | 3484（同 3689） | 偶發 502 且集中在部署期間 → 缺 preStop | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | "UpstreamConnectionTermination / UC: Upstream connection termination in addition to 503 response code." ／ UF、UR、LR 也都是 "in addition to 503 response code" | 在 Envoy 底下多半看到的是 503 加 UC／UF／URX；502 比較常是外層 F5／nginx 回的。建議寫「502／503」並附上 flag。 | ✓ |
| P08-007 | 3491 | `istioctl proxy-status ／ grep -v SYNCED  # 有輸出 = 有 pod 設定不同步` | 錯誤 | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ | 官方範例列："istio-ingressgateway-66c994c45c-cmb7x.istio-system SYNCED SYNCED SYNCED NOT SENT ..." | 一列裡只要任一欄是 SYNCED，整列就被過濾掉，所以 CDS 是 SYNCED、RDS 是 STALE 的 pod 會被隱藏。標題列又一定會印出來，「有輸出 = 不同步」不成立。改成 `istioctl proxy-status ／ awk 'NR==1 ／／ /STALE/'`。 | ✓ |
| P08-008 | 3500 | `kubectl get endpoints -n ea-pmc pmc-epmmformquerygui-svc` | 過時 | https://kubernetes.io/docs/concepts/services-networking/service/ | "Deprecated since Kubernetes v1.33" ／ "it is recommended that all clients use the EndpointSlice API rather than Endpoints." | `kubectl get endpointslices -n ea-pmc -l kubernetes.io/service-name=pmc-epmmformquerygui-svc` | ✓ |
| P08-009 | 3502–3505 | 從 gateway 內部用 curl 打 `http://pmc-...svc.ea-pmc:8080`，用來排除外部網路因素 | 不精確 | https://istio.io/latest/docs/reference/config/security/peer_authentication/ | STRICT: "Connection is an mTLS tunnel (TLS with client cert must be presented)." | gateway pod 沒有 iptables 攔截，curl 送出的是明文。ea-pmc 若是 STRICT，這一步一定失敗，但不代表服務壞了。要註明這個前提，或改從有 sidecar 的 pod 測試。 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P08-201 | 3424、3494 | `istioctl analyze -A` 掃描所有 namespace（"--all-namespaces -A Analyze all namespaces"） | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P08-202 | 3425 | proxy-status 顯示 istiod 到各 Envoy 的 xDS 同步狀態 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P08-203 | 3429、3497 | `istioctl x describe pod` 存在（experimental，`x` 是別名），會列出 Service、DR、VS、mTLS | https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-describe/ |
| P08-204 | 3432–3436 | proxy-config 的 listener／route／cluster／endpoint／secret 都接受 `[<type>/]<name>`，所以 `deploy/xxx` 可以用 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P08-205 | 3439 | `istioctl x authz check deploy/...` 存在，可以接 deployment；頂層的 `authz` 會提示改用 experimental | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P08-206 | 3442–3443 | `--level logger:level` 用逗號分隔；rbac、router、connection 都是 Envoy 的 logger；官方也用 `--level "rbac:debug"` | https://istio.io/latest/docs/ops/common-problems/security-issues/ |
| P08-207 | 3463–3472 | NR、NC、UH、UF、UO、URX、UT、UAEX、DC 的意義 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P08-208 | 3480 | 404 加 NR 時，查 VS 的 match 或 gateways | 同上 |
| P08-209 | 3481 | 503 加 UH／NC 時，是 subset 或 selector 問題 | 同上 |
| P08-210 | 3485 | gateways 少了 mesh，內部呼叫不會套用 VS | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |

---

## Part 9：你目前環境的具體發現（已對照 track-a 現況）

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P09-001 | 3518 | 以下是對照 spring_full_v4.md §24 的實際 manifest 找到的問題 | 環境特定 | — | — | 加一段說明：發現 1、2（sessionAffinity）、3、4、6，以及發現 5 的 strategy 部分，`canary-manual/track-a/` 已經修掉。這一章描述的是修正前的狀態。 | ✓ |
| P09-002 | 3522 | Pod spec 沒有 `serviceAccountName`，所有 Pod 都使用 default SA | 過時 | canary-manual/track-a/release/20-deployment-stable.yaml（L67）；21-deployment-canary.yaml（L59）；base/00-serviceaccount.yaml | `serviceAccountName: pmc-epmmformquerygui` ／ `automountServiceAccountToken: false` | 標為「track-a 已修」。 | ✓ |
| P09-003 | 3546 | 需要 rollout restart 才會拿到新身分 | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | "A Deployment's rollout is triggered if and only if the Deployment's Pod template (that is, .spec.template) is changed" | 改了 `spec.template.spec.serviceAccountName` 再 apply，就會自動滾動更新，不需要另外 restart。 | ✓ |
| P09-004 | 3552 | Service 設了 `sessionAffinity: ClientIP` + 3 小時 timeout | 過時 | canary-manual/track-a/base/01-service.yaml（L31）；base/02-destinationrule.yaml（L21） | `# 【不要加 sessionAffinity: ClientIP】` ／ `consistentHash:` | 標為「track-a 已修」。另外 3566 的 DR `pmc-query-affinity` 和 repo 的 `pmc-epmmformquerygui-dr` 是同一個 host，兩份同時套用會衝突，不要另外再建一份。 | ✓ |
| P09-005 | 3556 | gateway 的 Envoy 用自己的負載平衡演算法（預設 round-robin） | 錯誤 | https://istio.io/latest/docs/concepts/traffic-management/ | "By default, the Envoy proxies distribute traffic across each service's load balancing pool using a least requests model" | 改成「預設 least request」。 | ✓ |
| P09-006 | 3573–3575 | `httpCookie: name: JSESSIONID, ttl: 10800s` | 錯誤 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | ttl: "Lifetime of the cookie. If specified, a cookie with the TTL will be generated if the cookie is not present." | 設了 ttl，Envoy 就會自己產生一個名為 JSESSIONID 的 cookie，跟 Spring 的 session cookie 打架；Spring 換 session id 時 hash 也會跟著變。改用專用名稱，例如 `name: istio-affinity`。repo 的 base/02-destinationrule.yaml（L23–24）還是同樣寫法，還沒修。 | ✓ |
| P09-007 | 3586–3590 | VS 只有 `gateways: [istio-system/my-gateway]`，沒有 mesh | 過時 | canary-manual/track-a/base/03-virtualservice.yaml（L26–29） | `- pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local     # mesh 內部呼叫的 host` ／ `- mesh                                                  # 必要，見上方說明` | 標為「track-a 已修」。 | ✓ |
| P09-008 | 3622–3626 | Service port 沒有 name、沒有 appProtocol | 過時 | canary-manual/track-a/base/01-service.yaml（L25–29） | `- name: http                  # 必要：Istio 協定判定` ／ `appProtocol: http           # 必要：比 port 命名更明確` | 標為「track-a 已修」。 | ✓ |
| P09-009 | 3632、3709 | L7 功能沒有明確保證；port 命名是其他 L7 功能的前提 | 不精確 | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ | "Istio can automatically detect HTTP and HTTP/2 traffic." ／ "Server First protocols, such as MySQL, are incompatible with automatic protocol selection." | 改成：自動偵測對 HTTP 有效，明確宣告是為了消除不確定性。只有 server-first 協定才必須明確宣告，不是所有 L7 功能的前提。 | ✓ |
| P09-010 | 3650 | `replicas: 2` 寫死，沒有 PodDisruptionBudget，也沒有 HPA | 環境特定 | — | — | repo 現況一致：track-a 沒有 PDB 也沒有 HPA。`base/04-poddisruptionbudget.yaml` 只出現在 CANARY-COMPLETE.md 3.9 的目標狀態，檔案還不存在。 | ✓ |
| P09-011 | 3656 | maxUnavailable 預設 25%，2 個 replica 時允許 1 個不可用，滾動更新期間容量減半 | 錯誤 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | maxUnavailable: "The absolute number is calculated from percentage by rounding down. ... The default value is 25%." ／ maxSurge: "calculated from the percentage by rounding up" | 2 × 25% = 0.5，無條件捨去後 maxUnavailable 是 0，maxSurge 是 1。預設本來就不會減半，這段推論要刪掉。repo 也已經明確寫了 0（見 P09-013）。 | ✓ |
| P09-012 | 3667–3670 | PDB `selector: matchLabels: app: pmc-epmmformquerygui`，`minAvailable: 1` | 不精確 | canary-manual/CANARY-COMPLETE.md 3.9 | `version: stable        # 只保護 stable —— canary 只有 1 個 pod，` | 只用 app 選，canary pod 也會被算進去：canary 在線時，兩個 stable 可能同時被驅逐，但正式流量 100% 走 stable。selector 要加上 `version: stable`。 | ✓ |
| P09-013 | 3676–3680 | 建議補 `maxUnavailable: 0`、`maxSurge: 1`、`minReadySeconds: 15` | 過時 | canary-manual/track-a/release/20-deployment-stable.yaml（L22–28） | `maxUnavailable: 0          # 更新期間不減少可用數` ／ `minReadySeconds: 15` | 標為「track-a 已修」。canary 那份（21-）也已經加了。 | ✓ |
| P09-014 | 3687 | 沒有 `lifecycle.preStop`，grace period 用預設 30 | 過時 | canary-manual/track-a/release/20-deployment-stable.yaml（L69、L216–220） | `command: ["/bin/sh", "-c", "sleep 10"]` ／ `terminationGracePeriodSeconds: 60` | 標為「track-a 已修」。K8s 1.34 以上可以改用不需要 shell 的 `preStop.sleep`。 | ✓ |
| P09-015 | 3689 | 流量繼續打到正在關閉的 Pod → **502** | 不精確 | 同 P08-006 | 同 P08-006 | 在 mesh 內通常是 503 加 UC／UF。 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P09-201 | 3524 | Istio 的 workload 身分來自 SA，共用 default SA 就代表身分相同 | https://istio.io/latest/docs/concepts/security/ |
| P09-202 | 3554 | sessionAffinity 是 kube-proxy 的功能，sidecar 直接送到 pod IP，會繞過它 | https://kubernetes.io/docs/reference/networking/virtual-ips/ |
| P09-203 | 3592–3597 | 沒有 mesh 的 VS 只管 gateway 進來的流量（"The reserved word `mesh` is used to imply all the sidecars in the mesh."） | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P09-204 | 3612 | 加了 mesh 之後 match 不完整，內部呼叫會 404 加 NR | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P09-205 | 3641 | appProtocol 優先於 port 名稱（"If both are defined, appProtocol takes precedence over the port name."） | https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/ |
| P09-206 | 3654 | 沒有 PDB 時，drain 可能同時驅逐全部 Pod | https://kubernetes.io/docs/concepts/workloads/pods/disruptions/ |
| P09-207 | 3687 | terminationGracePeriodSeconds 預設 30 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ |
| P09-208 | 3689 | 移除 endpoint 和送 SIGTERM 是並行發生的 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ |
| P09-209 | 3700 | grace period 要涵蓋 preStop 的時間加上請求時間 | https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/ |

---

## Part 10：istio-ingressgateway 與一般 Service 的差別（含雙 VIP 架構）

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P10-001 | 3734 | `LoadBalancer ... 80:31380/TCP,443:31390/TCP` | 不精確 | https://istio.io/latest/docs/reference/config/analysis/ist0162/ | 預設 ingress gateway Service "only open on target ports 15021, 8080 and 8443"（port 是 15021／80／443） | 31380／31390 是舊版 chart 固定的 nodePort，現在預設是隨機分配，而且多一個 15021 狀態埠。要嘛標成示意，要嘛改成現代輸出。 | ✓ |
| P10-002 | 3800–3816 | 10.x 可路由、100.64.x 不可路由，兩個 VIP 的分層 | 環境特定 | — | — | 要跟網路組確認。 | ✓ |
| P10-003 | 3803 | 很多 K8s 發行版也拿 100.64.0.0/10 當 Pod / Service CIDR | 無法驗證 | https://www.rfc-editor.org/rfc/rfc6598 | 第 4 節：非 CGN 用途的使用者 "are likely to experience problems" | 刪掉「很多發行版」的概括，或點名具體發行版並附出處。可以補 RFC 的警告。 | ✓ |
| P10-004 | 3831、3853、3985 | `metallb.universe.tf/address-pool` | 過時 | https://metallb.io/release-notes/ | "The annotation prefix "metallb.universe.tf" is deprecated by now. Please use the new prefix "metallb.io"." ／ "E.g. "metallb.io/address-pool" instead of "metallb.universe.tf/address-pool"." | 改成 `metallb.io/address-pool`，註明 MetalLB 0.14.9 起適用。 | ✓ |
| P10-005 | 3836 | `loadBalancerSourceRanges` 是 LB 層的第一道白名單 | 不精確 | https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/ | "If specified and supported by the platform, ... This field will be ignored if the cloud-provider does not support the feature." | 註明是否生效取決於 LB 實作（F5 CIS／MetalLB），不支援時會被靜默忽略。 | ✓ |
| P10-006 | 3827、3874 | 第二組 gateway 也裝在 istio-system | 不精確 | https://istio.io/latest/docs/setup/additional-setup/gateway/ | "As a security best practice, it is recommended to deploy the gateway in a different namespace from the control plane." | 建議放到獨立的 namespace，例如官方 Helm 範例的 istio-ingress。憑證跟著搬（見 4083）。 | ✓ |
| P10-007 | 3883 | `sidecar.istio.io/inject: "false"  # gateway 本身不注入 sidecar` | 錯誤 | https://istio.io/latest/docs/setup/additional-setup/gateway/ | `sidecar.istio.io/inject: "true"` 加註解 "Enable gateway injection." ／ `image: auto # The image will automatically update each time the pod starts.` | 必須是 `"true"`。設成 false 不會注入，`image: auto` 不會被替換成真的 image，Pod 就拉不到 image。這個 label 跟 3897 的註解互相矛盾。 | ✓ |
| P10-008 | 3887–3893 | 內部（non-routable）那組 gateway 寫 `nodeSelector: network: routable` 和 routable 的 toleration | 錯誤 | — | 文件內前後矛盾：3846 標題是「對內（non-routable，100.x）」 | 改成 non-routable 的 node label。label 名稱屬於環境特定，要跟 Part 13 對齊。 | ✓ |
| P10-009 | 3969 | 要換入口，只要改 VirtualService 的 `gateways` 那一行 | 不精確 | https://istio.io/latest/docs/reference/config/networking/gateway/ | "A VirtualService must be bound to the gateway and must have one or more hosts that match the hosts specified in a server." | VS 的 `hosts` 也要符合新 Gateway 的 hosts（例如 internal-api.example.com），否則會是 404 NR。 | ✓ |
| P10-010 | 4045 | DENY `paths: ["/actuator/*"]`，管理端點不對外 | 錯誤 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | "Any string field in the rule supports Exact, Prefix, Suffix and Presence match" ／ "`{*}` matches a single glob that cannot extend beyond a path segment." ／ "`{**}` matches zero or more globs." | 本專案的 actuator 在 `/gui_epmmFormQuery/actuator/...`，前綴比對打不中，這條 DENY 等於沒作用。改成 `"/{*}/actuator/{**}"`（必要時加上 `"/actuator/{**}"`）。path template 的最低 Istio 版本未驗證。 | ✓ |
| P10-011 | 4048 | routable 那組前面有 F5（1 層），numTrustedProxies 設 1 | 環境特定 | https://istio.io/latest/docs/reference/config/security/authorization-policy/ | remoteIpBlocks: "A list of IP blocks, populated from `X-Forwarded-For` header or proxy protocol." | F5 若是 L4 virtual server，不會加 XFF，要改用 PROXY protocol。要確認 F5 的模式。 | ✓ |
| P10-012 | 4071–4072 | `istioctl proxy-config listener ... --port 443` | 不精確 | https://istio.io/latest/docs/reference/config/analysis/ist0162/ | 預設 ingress gateway Service "only open on target ports 15021, 8080 and 8443" | 標準安裝的 gateway listener 綁在 targetPort（0.0.0.0_8443），用 `--port 443` 可能什麼都篩不出來。改用 `--port 8443`，或不加篩選再 grep host。 | ✓ |
| P10-013 | 4076–4078 | 從 routable VIP 打內部 host，「應該要 404，不是 200」 | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | NR: "or no matching filter chain for a downstream connection." | HTTPS 的 SNI 對不到時是 TLS 握手失敗（curl exit 35，`-w` 印出 000），不是 404。改成「000 或 404 都算正常，只有 200 才有問題」。 | ✓ |
| P10-014 | 4092 | `kubectl get endpoints -n istio-system istio-ingressgateway-internal` | 過時 | 同 P08-008 | 同 P08-008 | `kubectl get endpointslices -n istio-system -l kubernetes.io/service-name=istio-ingressgateway-internal` | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P10-201 | 3727 | ingressgateway 就是 Deployment 加 Service | https://istio.io/latest/docs/setup/additional-setup/gateway/ |
| P10-202 | 3741–3742 | gateway pod 跑 Envoy，規則來自 Gateway 和 VS | 同上 |
| P10-203 | 3752 | LB Service 是 L4；Istio gateway 能處理 L7 和 TCP／TLS | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P10-204 | 3756 | 百分比分流靠 VS 的 weight | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P10-205 | 3801 | 100.64.0.0/10 是 RFC 6598 的 Shared Address Space，原本給 CGN 用 | https://www.rfc-editor.org/rfc/rfc6598 |
| P10-206 | 3805 | 「不可路由」是政策決定的；RFC 只規定 "MUST NOT be forwarded across Service Provider boundaries" | https://www.rfc-editor.org/rfc/rfc6598 |
| P10-207 | 3882、3900–3925 | Gateway 用 pod label 選 gateway，預設跨 namespace（"a gateway resource in the namespace "foo" can select pods in the namespace "bar" based on labels"） | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P10-208 | 3885、3897 | `inject.istio.io/templates: gateway` 搭配 `image: auto`（前提是注入真的有開，見 P10-007） | https://istio.io/latest/docs/setup/additional-setup/gateway/ |
| P10-209 | 3945–3946 | `<ns>/<name>` 加 mesh 的寫法 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P10-210 | 3976 | loadBalancerIP 從 v1.24 起 deprecated，建議改用實作專屬的 annotation | https://kubernetes.io/docs/concepts/services-networking/service/ |
| P10-211 | 3990 | F5 CIS 的 `cis.f5.com/ipamLabel` 用在 type LoadBalancer | https://clouddocs.f5.com/containers/latest/userguide/loadbalancer/ |
| P10-212 | 4027 | remoteIpBlocks 需要設 numTrustedProxies | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |
| P10-213 | 4054–4062 | 兩組 pod 帶同一個 label，Gateway 會同時下發到兩組 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P10-214 | 4083 | 憑證要放在 gateway 所在的 namespace（"The `Certificate` should be created in the same namespace as the `istio-ingressgateway` deployment."） | https://istio.io/latest/docs/ops/integrations/certmanager/ |
| P10-215 | 4087 | Service selector、Deployment matchLabels、Pod labels、Gateway selector 四處要對齊 | https://istio.io/latest/docs/setup/additional-setup/gateway/ |
| P10-216 | 3734 | LB Service 預設會配 NodePort（`allocateLoadBalancerNodePorts` 預設 true），範圍 30000-32767 | https://kubernetes.io/docs/concepts/services-networking/service/ |

---

## Part 11：FZ1 與 FZ2 雙 cluster 的入口設計

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P11-001 | 4114 | 這是 CD 預設會做的事——A record 只指向 FZ1 的 VIP | 環境特定 | — | — | 加註「依貴司 CD 工具行為，需向 CD 團隊確認」 | ✓ |
| P11-002 | 4149, 4156, 4355, 4365 | 模式 A：session 沒問題（流量不會在兩座 cluster 間跳）／in-memory session 沒問題 | 不精確 | canary-manual/CANARY-COMPLETE.md §3.6、§3.7、§9.1 | §3.6：`replicas: 2`；§3.7：「in-flight 的 OAuth2 `state`、`HttpSession`、authorized-client token 全部在 pod 記憶體裡」；§9.1：「使用者偶發被登出 ／ ① ／ canary 開了 >1 replica，或親和 cookie 沒生效」 | 改成「沒有跨 cluster 的 session 問題」。同時補一句：FZ1 內 stable 有 2 個 replica，加上 canary pod，跨 pod 跳轉一樣會被登出。黏著靠 DR `consistentHash`（epmm-affinity cookie），只是軟性黏著，pod 重啟或滾動更新仍會掉 session | ✓ |
| P11-003 | 4193 | FZ1 整座掛掉，GSLB 幾十秒內把流量切到 FZ2 | 不精確 | — | 同一份文件 4426：「TTL 設 3600 秒，FZ1 掛掉後最久要等一小時」；4348：「秒~分鐘級，看 TTL 與檢查間隔」 | 改成「切換時間 ≈ 健康檢查判定時間 ＋ DNS TTL ＋ 用戶端快取」，跟 11.6、11.10 的說法統一 | ✓ |
| P11-004 | 4183, 4313–4315 | 打 `/gui_epmmFormQuery/actuator/health`…期望：200 | 不精確 | canary-manual/CANARY-COMPLETE.md §3.6 | 「`SecurityConfig` 的 permitAll 清單裡只有沒有前綴的 `/actuator/health`…前綴路徑落在 `anyRequest().authenticated()` → 回 302」 | 加註：後端補上 permitAll（PRD 階段 1）之前，這條路徑回 302，不是 200。期望 200 會讓兩邊都被判定不健康；若 GSLB 把 3xx 也算成功，就成了假綠燈。在那之前不要拿它當 GSLB 的深度檢查 | ✓ |
| P11-005 | 4206–4248 | `name: app-routing`…（VS 沒有 subset、沒有 pilot-run）「這兩份必須逐字相同」 | 不精確 | canary-manual/CANARY-COMPLETE.md §3.4 | repo 的 `app-routing` 有 `pilot-run`（cookie → `subset: canary`）、`primary`（`subset: stable`）、`default` 三條規則 | 註明這是簡化範例。照抄套用會蓋掉同名的 track-a VS：canary 路由消失，而且沒有 subset 時正式流量也會分到 canary pod。兩邊一致應以 track-a 的 `03-virtualservice.yaml` 為準 | ✓ |
| P11-006 | 4262, 4278 | `metallb.universe.tf/address-pool: fz1-routable` | 過時 | https://metallb.io/release-notes/ | "The annotation prefix "metallb.universe.tf" is deprecated by now. Please use the new prefix "metallb.io". E.g. "metallb.io/address-pool" instead of "metallb.universe.tf/address-pool"."（0.14.9） | MetalLB ≥ 0.14.9 改用 `metallb.io/address-pool`。另外註明：叢集是否用 MetalLB、位址池名稱，都屬環境特定 | ✓ |
| P11-007 | 4267, 4283 | `ports: - { name: https, port: 443, targetPort: 8443 }` | 不精確 | https://github.com/istio/istio/blob/master/manifests/charts/gateway/values.yaml | `- name: https` `port: 443` `protocol: TCP` `targetPort: 443`（舊的 istio-ingress chart 與 istioctl 才是 `targetPort: 8443`） | 註明 targetPort 依安裝方式而異：istioctl 是 8443，Helm `gateway` chart 是 443。也提醒這份 Service 少了 status-port 15021 和 http2，直接 apply 可能蓋掉安裝工具產生的 ports；位址池應透過安裝工具的 values 設定 | ✓ |
| P11-008 | 4314, 4318 | 必須帶 Host header，否則 Gateway 的 hosts 比對不到會 404 | 不精確 | https://istio.io/latest/docs/ops/common-problems/network-issues/ | "An HTTPS Gateway that specifies the hosts field will perform an SNI match on incoming requests." ／ "…no SNI will be set, causing the request to fail." | 對 `https://<VIP>` 做檢查時，沒帶 SNI 會先在 TLS 握手失敗，根本走不到 Host 比對。要同時設 SNI＝myapp.example.com 和 Host header（curl 可用 `--resolve`）。Host 不符回 404 這點只在 TLS 握手成功之後才成立 | ✓ |
| P11-009 | 4326 | FZ2 不認得他 → 被踢回 Keycloak 登入頁 | 不精確 | canary-manual/CANARY-COMPLETE.md §9.1、§3.7 | §9.1：「剛登入完又被要求登入 ／ ② ／ 跨軌切換會重新認證一次；那一刻 Keycloak SSO session 剛好過期 ／ 重登即可」；§3.7：「使用者隨機拿到 `authorization_request_not_found` 並被踢回 Keycloak」 | 改成：Keycloak SSO session 還在時，是不用輸入帳密的重新認證；這時正在送出的表單或 POST 會遺失。登入流程進行到一半就跳邊，會出現 `authorization_request_not_found`。只有 SSO session 也過期時，才真的看到登入頁 | ✓ |
| P11-010 | 4328 | 瀏覽器開了多個分頁、各自解析 → 有機會分散到兩邊 | 無法驗證 | — | — | 主流瀏覽器的 DNS 快取由所有分頁共用。建議刪除，或改成「不同瀏覽器或不同裝置」 | ✓ |
| P11-011 | 4332–4336 | 三種處理方式（GSLB source-IP affinity／Redis 複寫／外部化） | 不精確 | https://techdocs.f5.com/kb/en-us/products/big-ip_ltm/manuals/product/big-ip-local-traffic-manager-implementations-14-0-0/12.html | "Cookie persistence directs session requests to the same server based on HTTP cookies…" | 11.3 的圖寫了 F5。如果前面是 L7 的 F5 LTM（終結 TLS、兩個 VIP 都是 pool member），可以用 cookie persistence 黏住 cluster，這比 source-IP 可靠。建議補上這第四種方式，並註明它需要在 F5 終結 TLS | ✓ |
| P11-012 | 4370 | 目前的狀態（in-memory session、沒有 PDB/HPA、設定還是手動 apply） | 環境特定 | — | — | 與 CANARY-COMPLETE §3.9「目前沒有 PDB」一致。PDB 加上後要回頭更新這句 | ✓ |
| P11-013 | 4374–4384 | 要跟 CD 團隊問清楚的四件事（routable 10.x／non-routable 100.x 等） | 環境特定 | — | — | 不需改，維持「問人」的寫法 | ✓ |
| P11-014 | 4407–4411 | `for R in gateway virtualservice …; kubectl get $R -A` | 不精確 | https://www.alibabacloud.com/help/en/asm/support/why-are-no-gateways-or-non-istio-gateways-returned-when-i-run-the-kubectl-command-to-query-gateways（廠商文件，istio.io 上找不到對應文字） | "Both APIs define a resource named `Gateway`, and kubectl cannot distinguish between them." | 改成 `gateways.networking.istio.io`（或短名 `gw`）。否則叢集裝了 Gateway API CRD 時，比對的可能是 gateway.networking.k8s.io 的 Gateway，兩邊都空也會印「一致」 | ✓ |
| P11-015 | 4426–4428 | 自動切換速度上限就是 DNS TTL…最久要等一小時；有些企業 DNS 或作業系統會忽略過短的 TTL | 無法驗證 | — | — | 方向合理，但要補上「健康檢查判定時間」和用戶端自己的快取（例如 JVM、瀏覽器）。「最久一小時」低估了 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P11-201 | 4137, 4146 | 從 FZ1 轉發到 FZ2：兩邊 CA 各自獨立，身分在 gateway 斷掉，`principals` 失效，要改用 JWT | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P11-202 | 4184, 4220, 4291 | 每座 cluster 的 istio-system 各放一份 TLS secret，以 `credentialName` 引用 | https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/ |
| P11-203 | 4208, 4224 | `networking.istio.io/v1`（Istio ≥ 1.22 才有） | https://istio.io/latest/news/releases/1.22.x/announcing-1.22/ |
| P11-204 | 4214–4222 | Gateway `selector`／`servers.port`／`tls.mode: SIMPLE`／`credentialName`／`hosts` 欄位合法 | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P11-205 | 4233–4235 | 寫了 gateways 就要顯式加 `mesh`，才會套用到 sidecar | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P11-206 | 4238–4245 | `uri.prefix`／`exact` match、`timeout: 15s` 寫法合法 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P11-207 | 4291–4293 | `create secret tls --dry-run=client -o yaml \ kubectl apply -f -` 可冪等建立 secret | https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_secret_tls/ |
| P11-208 | 4299–4300 | jsonpath `{.data.tls\.crt}` 跳脫點號，接 `openssl x509 -noout -enddate` | https://kubernetes.io/docs/reference/kubectl/jsonpath/ |
| P11-209 | 4393 | 用 `curl --resolve` 直接測 FZ2 VIP（同時帶對 SNI 與 Host） | https://istio.io/latest/docs/ops/common-problems/network-issues/ |
| P11-210 | 4377 | 交叉引用的 Part 10.6 踩雷 1 確實存在（4052 行，Gateway selector 綁到兩組） | （本文件內部） |

---

## Part 13：node 排程與 routable 網段

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P13-001 | 5580–5585 | 10.x routable／100.64.x non-routable，可路由 node 是稀缺資源 | 環境特定 | — | — | 不需改，已標示 placeholder | ✓ |
| P13-002 | 5626, 5767–5775 | ingressgateway 一定要 routable，Pod 必須在那個網段的 node 上；排到 non-routable：Service 拿得到 VIP，但流量進不來 | 不精確 | https://kubernetes.io/docs/reference/networking/virtual-ips/ | "Set the field to `Cluster` to route external traffic to all ready endpoints and `Local` to only route to ready node-local endpoints. If the traffic policy is `Local` and there are no node-local endpoints, the kube-proxy does not forward any traffic for the relevant Service." | 這不是 K8s 的通則。`externalTrafficPolicy: Cluster` 時，VIP 落到任何一台 node 都會轉發到其他 node 上的 Pod。只有 `Local`，或貴司 LB／CNI 的限制（環境特定）時才成立。請改成條件句，並列出要檢查 `externalTrafficPolicy` | ✓ |
| P13-003 | 5629 | `pmc-epmmformquerygui` 這類 GUI：不用 routable，流量從 ingressgateway 進來 | 不精確 | canary-manual/CANARY-COMPLETE.md §3.1、§4.3 | 「`spring...provider.keycloak.issuer-uri`…OAuth2 client 建不起來 → 啟動失敗」；「Unable to resolve Configuration with the provided Issuer」 | 這支 app 是 BFF，啟動時和登入時都會主動連 Keycloak（discovery、token、JWKS），屬於 5628「主動連外部系統」那一類。請改成「看 Keycloak 位置與出向 SNAT，要問網路組」 | ✓ |
| P13-004 | 5639–5662 | `kind: Deployment`…`spec: template: …`（沒有 selector） | 不精確 | https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | "`.spec.selector` is a required field that specifies a label selector" | 註明這是片段，直接 apply 會被 apps/v1 拒絕。ingressgateway 的 Deployment 由安裝工具管理，nodeSelector／tolerations 應寫在 IstioOperator 或 Helm values，直接改 Deployment 可能被安裝工具蓋回去 | ✓ |
| P13-005 | 5704–5711 | `effect: "NoExecute"` `tolerationSeconds: 300`：被打上 taint 後還能撐 300 秒才被驅逐 | 不精確 | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ | "Pods that tolerate the taint without specifying `tolerationSeconds` in their toleration specification remain bound forever" ／ "Pods that tolerate the taint with a specified `tolerationSeconds` remain bound for the specified amount of time. After that time elapses, the node lifecycle controller evicts the Pods from the node." | 對 `network=routable` 這種永久的專用 taint 加 tolerationSeconds，等於 gateway Pod 每 300 秒被驅逐一次。專用 node 的 toleration 不要加 tolerationSeconds；它只適合 not-ready 這類暫時性 taint | ✓ |
| P13-006 | 5796–5801 | `3 node(s) had untolerated taint {network: routable},` | 過時 | https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/scheduler/framework/plugins/tainttoleration/taint_toleration.go | v1.34+：`"node(s) had untolerated taint(s)"`；v1.33 以前：`"node(s) had untolerated taint {%s: %s}"` | 註明 K8s ≥ 1.34 的事件不再印出 taint 的 key/value，要再跑 `kubectl describe node` 看 Taints | ✓ |
| P13-007 | 5823–5833 | 當 replica 數超過 routable node 數量時，多出來的 Pod 會排不上去（因為 `DoNotSchedule` 不允許同一台放兩個以上造成傾斜） | 錯誤 | https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ | "`maxSkew` defines the maximum permitted difference between the number of matching pods in the target topology and the _global minimum_" | 3 台 node 放第 4 個 Pod，結果是 2/1/1，skew＝1 ≤ maxSkew，可以排上去。DoNotSchedule 加 maxSkew 1 擋的是不均勻，不是「一台最多一個」。會排不上去的是 hostname 上的 required podAntiAffinity。另外範例缺 `labelSelector`："Pods that match this label selector are counted"，沒有它就不會計入任何 Pod，這個約束不起作用 | ✓ |
| P13-008 | 5823 | routable node 通常只有 2~3 台 | 環境特定 | — | — | 不需改 | ✓ |
| P13-009 | 5845 | `kubectl get hpa` 會顯示 `CURRENT` 一直達不到 `DESIRED` | 錯誤 | https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/ | "NAME REFERENCE TARGET MINPODS MAXPODS REPLICAS AGE"；Deployment status.replicas："Total number of non-terminating pods targeted by this deployment (their labels match the selector)." | `get hpa` 沒有 CURRENT／DESIRED 欄位，REPLICAS 也會把 Pending 算進去（會顯示 10）。應改看 `kubectl get deploy` 的 READY（4/10），或 `kubectl describe hpa` 的「Deployment pods: X current / Y desired」 | ✓ |
| P13-010 | 5735–5741 | 常見的 key 名稱：network / node-role / zone / topology / nodepool / net-type | 環境特定 | — | — | 不需改 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P13-201 | 5589 | `routable` 不是 K8s 的標準 label | https://kubernetes.io/docs/reference/labels-annotations-taints/ |
| P13-202 | 5595–5598 | label 加 affinity 是吸引，taint 是排斥（"Taints are the opposite -- they allow a node to repel a set of pods."） | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ |
| P13-203 | 5615, 5618 | 有 nodeSelector 沒 toleration：目標 node 全被 taint 擋住，Pod 一直 Pending | 同上 |
| P13-204 | 5616, 5620 | 單有 toleration 不會吸引 Pod（"Tolerations allow scheduling but don't guarantee scheduling"）。Dedicated Nodes 要 taint 加 label 加 affinity 一起用 | 同上 |
| P13-205 | 5655 | Equal 要比對 value；Exists 只要 key 存在（operator 預設是 Equal） | 同上 |
| P13-206 | 5657 | effect 要跟 taint 一致（例外：effect 留空時符合所有 effect） | 同上 |
| P13-207 | 5666, 5672 | nodeSelector 只能做完全相等；required 是硬性條件，「This functions like nodeSelector, but with a more expressive syntax」；`In` 運算子 | https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/ |
| P13-208 | 5682 | `weight: 100` 在合法範圍 1–100 內 | 同上 |
| P13-209 | 5685 | `topology.kubernetes.io/zone` 是 well-known label | https://kubernetes.io/docs/reference/labels-annotations-taints/ |
| P13-210 | 5698–5702 | NoSchedule 不驅逐已在跑的；PreferNoSchedule 是軟性；NoExecute 驅逐不容忍的 Pod | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ |
| P13-211 | 5718–5724 | `kubectl label node`／`kubectl taint node k=v:Effect`／尾端加 `-` 移除 | https://kubernetes.io/docs/reference/kubectl/generated/kubectl_taint/ |
| P13-212 | 5733, 5738, 5742 | `get nodes -o wide`（INTERNAL-IP 欄）、`--show-labels`、describe 裡的 Taints | https://kubernetes.io/docs/reference/kubectl/ |
| P13-213 | 5745, 5752 | custom-columns 和 jsonpath 支援 `[?(@.type=="InternalIP")]` 這種過濾 | https://kubernetes.io/docs/reference/kubectl/jsonpath/ |
| P13-214 | 5801 | `untolerated taint` 代表缺 toleration；`didn't match Pod's node affinity/selector` 代表 label 不符 | https://github.com/kubernetes/kubernetes/blob/master/pkg/scheduler/framework/plugins/nodeaffinity/node_affinity.go |
| P13-215 | 5806–5811 | `key: network, operator: Exists` 會容忍所有 value 的 network taint（同一個 effect 下） | https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ |
| P13-216 | 5816 | 只寫 `operator: Exists`（不寫 key 和 effect）會容忍所有 taint：空 key 符合所有 key 與 value，空 effect 符合所有 effect | 同上 |
| P13-217 | 5819 | DaemonSet 只會自動加 `node.kubernetes.io/*` 的 toleration，自訂 taint 要自己寫（監控 agent 常用 Exists） | 同上 |
| P13-218 | 5838 | `ScheduleAnyway` 是軟性的，排不下就照樣排 | https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ |
| P13-219 | 5853 | nodeSelector 和 nodeAffinity 同時寫是 AND（"both must be satisfied"） | https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/ |
| P13-220 | 5843 | Pending 的 Pod 不會讓 HPA 自己縮回去，要用 maxReplicas 控制上限 | https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/ |

---

## Part 16：active zone DNS 下 request 落在哪

### 需要處理的說法

| ID | 行號 | 原文摘錄 | 判定 | 官方 URL | 來源引文 | 建議改法 | 使用者確認 |
|---|---|---|---|---|---|---|---|
| P16-001 | 7776–7780 | 公司的 DNS 是 active/standby：同一個 host 永遠只回 active zone 那座 cluster 的 VIP；FZ1 什麼都沒部 | 環境特定 | — | — | 不必改。所依賴的通用機制（DNS 決定落點）見 P16-201 | ✓ |
| P16-002 | 7809、7839、7871、7893 | 「4d AP 的 Service + Endpoints」；「K8s 依 selector 自動產生的 Endpoints」；`kubectl -n ea-pmc get endpoints pmc-epmmformquerygui-svc`；「istiod 去 watch … Service / Endpoints」 | 過時 | https://kubernetes.io/blog/2025/04/24/endpoints-deprecation/ | "As of Kubernetes 1.33, the Endpoints API is now officially deprecated, and the API server will return warnings to users who read or write Endpoints resources rather than using EndpointSlices." ／ "Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice" | 改寫成 EndpointSlice；指令改為 `kubectl -n ea-pmc get endpointslice -l kubernetes.io/service-name=pmc-epmmformquerygui-svc`。如果要保留 `get endpoints`，註明 1.33 以後會出現棄用警告 | ✓ |
| P16-003 | 7876–7886 | 範例輸出的欄位：`SERVICE FQDN  PORT  SUBSET  DIRECTION  TYPE` ／ `ENDPOINT  STATUS` | 不精確 | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ | cluster 的標題列："SERVICE FQDN PORT SUBSET DIRECTION TYPE DESTINATION RULE"；endpoints 的標題列："ENDPOINT STATUS OUTLIER CHECK CLUSTER" | 範例輸出補上 `DESTINATION RULE` 欄（subset 那兩行會顯示 `pmc-epmmformquerygui-dr.ea-pmc`），以及 `OUTLIER CHECK`、`CLUSTER` 兩欄。或者註明這是節錄 | ✓ |
| P16-004 | 7889、7926、7953 | 「gateway access log 的 `upstream_host` 欄位…」；表頭「access log `response_flags`」；「4. FZ1 gateway 的 access log：看到 404 + NR」 | 不精確 | https://istio.io/latest/docs/tasks/observability/logs/access-log/ | "The egress gateway and access logging will be enabled if you install the `demo` configuration profile." ／ "Use of the Telemetry API is recommended." | 加一句前提：Istio 預設不開 access log。要用 Telemetry API 或 `meshConfig.accessLogFile: /dev/stdout` 開啟，否則 16.4 整張表和 16.5 第 4 步都看不到東西 | ✓ |
| P16-005 | 7901–7903 | FZ1：「Gateway ✔（CD 建的共用 *）」「VS ✗ Service ✗ DR ✗ Pod ✗」 | 環境特定 | — | — | 不必改。通用機制見 P16-208 | ✓ |
| P16-006 | 7928 | Gateway 不收這個 host（HTTPS，SNI 對不到任何 server）→ TLS handshake 失敗 / 連線被 reset → 「通常沒有 log」 | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | NR: "No route configured for a given request in addition to 404 response code or no matching filter chain for a downstream connection." | 「通常沒有 log」改成：開了 access log 時，gateway 通常會留一行沒有 method、沒有 path 的紀錄，flag 是 `NR`、details 是 `filter_chain_not_found`。症狀描述（handshake 失敗）不變 | ✓ |
| P16-007 | 7945–7958 | `kubectl --context=fz1` / `--context=fz2`、`<FZ2_VIP>`、`grep myapp.example.com` | 環境特定 | — | — | context 名稱和 VIP 是環境值，加註「依你的 kubeconfig 調整」。指令語法本身正確（見 P16-205、P16-211） | ✓ |
| P16-008 | 7954–7955 | `kubectl --context=fz1 -n istio-system logs deploy/istio-ingressgateway --tail=200` | 不精確 | https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/ | "# Return snapshot logs from all pods in the deployment nginx" `kubectl logs deployment/nginx --all-pods=true` ／ `--all-pods`: "Get logs from all pod(s). Sets prefix to true." | `logs deploy/x` 不加 `--all-pods` 時只讀其中一個 pod。ingressgateway 多半有多個 replica，可能剛好漏掉那筆 404。改用 `--all-pods=true`，或 `-l app=istio-ingressgateway --prefix`（舊版 kubectl 沒有 `--all-pods`） | ✓ |
| P16-009 | 8010 | ServiceEntry `exportTo: ["."]`（namespace ea-pmc），由 istio-system 的 ingressgateway 透過 VS 使用 | 錯誤 | https://istio.io/latest/docs/reference/config/networking/service-entry/ | "Exporting a service allows it to be used by sidecars, gateways and virtual services defined in other namespaces." ／ "The value "." is reserved and defines an export to the same namespace that the service is declared in." | `"."` 只開放給 ea-pmc，istio-system 的 ingressgateway 看不到這個 ServiceEntry，VS 的 destination 會指向 gateway 沒有的 cluster（預期是 503 NC）。改成 `exportTo: [".", "istio-system"]`，或拿掉 exportTo（預設是 `*`） | ✓ |
| P16-010 | 8012–8025 | 「sni 要填 myapp.example.com…填成 relay 的名字會在 FZ2 那邊 handshake 失敗」；DR 只寫 `mode: SIMPLE` + `sni` | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | sni: "If unspecified, SNI will be automatically set based on downstream HTTP host/authority header for SIMPLE and MUTUAL TLS modes." ／ caCertificates: "If omitted, the proxy will verify the server’s certificate using the OS CA certificates." | (1) sni 不填也行：Host 原樣帶過去，auto SNI 自然就是 myapp.example.com。寫上是明確化，不是必要。(2)「填 relay 名字一定 handshake 失敗」要看 FZ2 Gateway：如果是 `*` wildcard，SNI 還是對得到 server。(3) 要補一點：沒給 CA 時用 OS 根憑證驗 FZ2 的憑證。FZ2 憑證若是公司內部 CA 簽的，要用 `credentialName` 或 `caCertificates`，否則上游 TLS 驗證失敗（預期是 503） | ✓ |
| P16-011 | 8068 | `mTLS，SNI = outbound_.8080_._.pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local` | 不精確 | https://istio.io/latest/docs/reference/config/networking/gateway/ | AUTO_PASSTHROUGH: "The destination details such as the service/subset/port are encoded in the SNI value." | repo 的 VS 走 `subset: stable`（03-virtualservice.yaml），SNI 的 subset 段就不是空的 `_`。社群資料顯示的形式是 `outbound_.8080_.stable_.pmc-epmmformquerygui-svc.ea-pmc.svc.cluster.local`；istio.io 沒有寫出這個字串格式，只說 subset 會編進去。可以改寫成這個形式，或註明「subset 為空時才是 `_`」 | ✓ |
| P16-012 | 8080 | 「每座 cluster 標 `topology.istio.io/network`」 | 不精確 | https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/ | "kubectl --context="${CTX_CLUSTER1}" label namespace istio-system topology.istio.io/network=network1" ／ values："meshID: mesh1"、"clusterName: cluster1"、"network: network1" | 寫清楚 label 是標在每座 cluster 的 `istio-system` namespace 上。安裝時另外要設 `global.meshID`、`global.multiCluster.clusterName`、`global.network`，還要套 `expose-services.yaml`（east-west gateway 對外開 `*.local`） | ✓ |
| P16-013 | 8081 | 前提（缺一不可）第 5 點：「兩邊 istiod 版本要一起升級」 | 無法驗證 | https://istio.io/latest/docs/releases/supported-releases/ | "The Istio control plane can be one version ahead of the data plane. However, the data plane cannot be ahead of control plane." | 官方 multi-primary 安裝與 deployment-models 文件的前提裡都沒有這一條，也沒寫跨 cluster 的 control plane 版本差規則。建議移出「缺一不可」，改成「建議同步升級、遵守版本差政策，以平台組實測為準」 | ✓ |
| P16-014 | 8096 | 「DR 加 `localityLbSetting` ＋ `outlierDetection`… 沒有 `outlierDetection` 就不會 failover」 | 不精確 | https://istio.io/latest/docs/reference/config/networking/destination-rule/ | "Istio's default mesh configuration enables locality load balancing (`localityLbSetting.enabled: true`)." ／ "configuring `OutlierDetection` in a `DestinationRule` will automatically activate locality-aware failover behavior" | 後半句正確。但 `localityLbSetting` 不是必填，mesh 預設已開，只要 outlierDetection 就會啟動 failover。另外 repo 的 02-destinationrule.yaml 已經有 outlierDetection，接上 multi-cluster 後 locality failover 會自動生效，要寫出來。關閉方式是設 `localityLbSetting.enabled: false` | ✓ |
| P16-015 | 8102–8117 | 16.7 表格與建議：誰能做（AP 團隊／平台組）、FZ1 ingressgateway 掛了「要等 DNS 切 zone」 | 環境特定 | — | — | 分工和切 zone 流程是公司環境的事。表中的機制欄位（身分斷在 FZ2 gateway、relay 在切 zone 後失效）與 P16-219、P16-226 一致 | ✓ |
| P16-016 | 8135 | 「沒帶 `Host: myapp.example.com`（或 `--resolve`）時 Gateway 的 hosts 比對不到，會回 404」 | 不精確 | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter | NR: "No route configured for a given request in addition to 404 response code or no matching filter chain for a downstream connection." | 這句和 16.4 第一列（7928：HTTPS 時 Gateway 不收 host → TLS 失敗）矛盾。curl 打 VIP IP 時不會送 SNI。Gateway hosts 是具體名字時，結果是 TLS 失敗（NR filter_chain_not_found），不是 404。只有 HTTP，或 wildcard `*` Gateway 收下之後 VS host 對不到時，才是 404 NR。建議分成兩種情況寫 | ✓ |

### 查證為正確的說法

| ID | 行號 | 說法 | 官方 URL |
|---|---|---|---|
| P16-201 | 7782、7913 | 去哪座 cluster 由 DNS 決定。沒有 multi-cluster 時，兩座 istiod 互不相通，FZ2 的 VS 不會出現在 FZ1 | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P16-202 | 7791、7811、7822、7857–7858、7889 | gateway 的 Envoy 依 EDS 拿到 Pod IP，直接連，不經 ClusterIP／kube-proxy；`upstream_host` 印的是 Pod IP | https://istio.io/latest/docs/concepts/traffic-management/ |
| P16-203 | 7852 | Envoy cluster 名稱格式是 outbound、port、subset、FQDN 四段；port 8080 與 01-service.yaml 的 `port: 8080` 相符 | https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/ |
| P16-204 | 7853、7873 | subset cluster 的成員 = Service 的 endpoints ∩ DR subset labels；一個 Service 會展開成「無 subset」加上每個 subset 各一個 cluster | https://istio.io/latest/docs/reference/config/networking/destination-rule/ |
| P16-205 | 7874–7883、7958 | `istioctl proxy-config cluster/endpoint/route` 可以接 `<type>/<name>`；`--fqdn`（cluster）、`--cluster`（endpoint）旗標存在；`--context` 是 istioctl 頂層旗標 | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P16-206 | 7893 | istiod 讀 K8s API，把設定翻成 xDS 推給 Envoy | https://istio.io/latest/docs/ops/deployment/architecture/ |
| P16-207 | 7918–7919、7929 | wildcard Gateway 收下 host，但沒有任何 VS 宣告這個 host → 404 NR | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P16-208 | 7930 | 有 VS，但沒有 Service 或 subset 未定義 → 503 NC（"Upstream cluster not found."） | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P16-209 | 7931 | 沒有 Pod，或 label 對不上 → 503 UH（"No healthy upstream hosts in upstream cluster in addition to 503 response code."） | https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter |
| P16-210 | 7934、8123 | 只補 VS，404 會變成 503 | 同上 |
| P16-211 | 7950、7962 | `curl -vk --resolve host:443:<VIP> https://host/...` 的語法；用來繞過 DNS、測 standby | https://curl.se/docs/manpage.html |
| P16-212 | 7996–8009、8020–8025 | 由 gateway 路由到 ServiceEntry 的 443（protocol HTTPS）並以 DR `tls.mode: SIMPLE` 發起 TLS，是官方 egress gateway TLS origination 的同款寫法 | https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/ |
| P16-213 | 7992–7995、8127 | `resolution: DNS` 會向 proxy 所在環境的 DNS 查詢（"Attempt to resolve the IP address by querying the ambient DNS"），所以會解回 active zone；用 STATIC 寫死對方 VIP 可以避開。迴圈的具體症狀屬推論 | https://istio.io/latest/docs/reference/config/networking/service-entry/ |
| P16-214 | 8003 | STATIC 加 gateway 端路由時，relay host 不需要真的 DNS record | https://istio.io/latest/docs/reference/config/networking/service-entry/ |
| P16-215 | 8028–8030 | Host header 預設原樣帶到上游；`rewrite.authority` 會改掉它，導致 FZ2 的 VS 對不上 | https://istio.io/latest/docs/reference/config/networking/virtual-service/ |
| P16-216 | 8038 | VS `gateways` 用 `<namespace>/<name>` 引用其他 namespace 的 Gateway；VS 必須 export 到 gateway 的 namespace（預設 `*` 符合） | https://istio.io/latest/docs/reference/config/networking/gateway/ |
| P16-217 | 8052 | 同一 host 綁同一 gateway 的多份 VS 會被合併，"the cross-resource order is UNDEFINED" | https://istio.io/latest/docs/ops/best-practices/traffic-management/ |
| P16-218 | 8056、8060–8061、8088–8089 | multi-primary：remote secret 讓 istiod 讀對方 API server 做服務探索；同名 namespace 視為同一個（"namespaces in each cluster sharing the same name are considered the same namespace by default"）；VS/DR 等設定只從自己 cluster 的 API server 讀，所以 FZ1 要有自己的 VS/DR | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P16-219 | 8063、8067、8070、8072、8079 | 跨 network 的 endpoint 經由對方 east-west gateway 的 15443；AUTO_PASSTHROUGH 依 SNI 轉發、不終止 mTLS，不需要 VS；east-west gateway 與 ingressgateway 是分開的兩組 | https://istio.io/latest/docs/setup/install/multicluster/multi-primary_multi-network/ |
| P16-220 | 8077 | 需要共用信任根，透過 `cacerts` 外掛 CA | https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/ |
| P16-221 | 8078 | `istioctl create-remote-secret` 仍存在（"Create a secret with credentials to allow Istio to access remote Kubernetes apiservers"），且 istiod 要連得到對方 API server | https://istio.io/latest/docs/reference/commands/istioctl/ |
| P16-222 | 8090 | FZ1 建 Service 是為了 kube-dns（"you must deploy a Kubernetes Service to each cluster that consumes that service"）；或者用 DNS proxying | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P16-223 | 8095 | multi-cluster 下身分端到端保留；兩座共用 trust domain 時，SPIFFE ID 分不出是哪一座的 ingressgateway | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P16-224 | 8096（後半） | failover 依賴 outlierDetection（"Envoy relies on outlier detection to identify unhealthy endpoints and trigger failover to the next locality."） | https://istio.io/latest/docs/tasks/traffic-management/locality-load-balancing/ |
| P16-225 | 8109 | 預設會跨 cluster 分散到各 endpoint（"By default, Istio will load balance requests evenly between endpoints in each cluster."），所以 in-memory session 有被登出的風險 | https://istio.io/latest/docs/ops/deployment/deployment-models/ |
| P16-226 | 8048 | VIP 接力時，來源身分斷在 FZ2 的 ingressgateway（與已查證的 Part 5 結論一致） | https://istio.io/latest/docs/reference/config/security/authorization-policy/ |

---

## 超出 guide 範圍的發現（批次 ⑤⑥）

這兩項不是 guide 的錯，是查證途中順帶發現的 repo 本身的問題。不進修正 guide 的故事，處理方式由使用者決定：

| ID | 對象 | 發現 | 來源 | 處理 | 使用者確認 |
|---|---|---|---|---|---|
| X-001 | `canary-manual/track-a/base/02-destinationrule.yaml`、`03-virtualservice.yaml` | 還沒落地 CANARY-COMPLETE.md 3.3／3.4 的【修正】：親和 cookie 仍叫 `JSESSIONID`、`retryOn` 含 `5xx`、主路由留著 `weight: 0` 的 canary destination、pilot 規則沒有 uri 條件。所以 P14-013／025／027／028 判「過時（相對目標狀態）」而非「錯誤」 | canary-manual/CANARY-COMPLETE.md §3.3、§3.4 | 只記錄，另開 PRD 修 manifest（照 CLAUDE.md「改 manifest 就要加檢查」）；已寫進 CLAUDE.md「已知過時」清單 | ✓ |
| X-002 | repo 根目錄 `CLAUDE.md`「兩者同時存在時兩個 controller 會搶 pod」 | Argo 官方："The Rollout won't try to manage existing Deployment Pods."，並建議遷移時讓 Rollout 與 Deployment 並存。兩軌互斥的規則仍成立，但真正原因是共用 `app` label（會被對方的 Service 選進 endpoint）與同一條 VirtualService | https://argo-rollouts.readthedocs.io/en/stable/migrating/ | loop 最後的 retro 故事改寫這句的理由（互斥規則不變） | ✓ |
| X-003 | `canary-manual/track-a/base/`（缺 `04-poddisruptionbudget.yaml`） | CANARY-COMPLETE.md 3.9 的 PDB 還沒建立；目標狀態的 selector 要帶 `version: stable`（只用 `app` 選會把 canary pod 算進去，canary 在線時兩個 stable 可能同時被驅逐）。批次 ⑥ P09-010／P09-012 發現 | canary-manual/CANARY-COMPLETE.md §3.9 | 同 X-001：只記錄，另開 PRD；已併入 CLAUDE.md「已知過時」那一條 | ✓ |

## guide 文末「需向他人確認」清單的新增候選（批次 ⑥）

除了各 Part 判定為「環境特定」的列之外，查證 Part 16 時建議再加這兩項（格式照 guide 文末那張表：項目／問誰／在哪一節）：

| ID | 項目 | 問誰 | 在哪一節 | 使用者確認 |
|---|---|---|---|---|
| Q-001 | FZ2 ingressgateway 的憑證由哪個 CA 簽發（決定路線一的 DR 要不要 `credentialName`／`caCertificates`） | 平台組 | Part 16.6 路線一 | ✓ |
| Q-002 | 環境有沒有開 access log（Telemetry API 或 `meshConfig.accessLogFile`）—— Part 1、8、16 的除錯步驟都假設有 | 平台組 | Part 8.2、16.4、16.5 | ✓ |
