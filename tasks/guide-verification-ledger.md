# 查證帳本：k8s-ecosystem-guide.md

> 這份帳本是 `tasks/prd-k8s-guide-verification.md` 與 Ralph loop 的事實依據。
> 每一列是 guide 裡的一條可證偽說法，對照官方文件（kubernetes.io、istio.io、envoyproxy.io、
> argoproj）查證後的結果。**基準是查證當下的官方最新版文件**；版本相關的功能在「建議改法」
> 裡註明最低版本。
>
> - **判定**：正確／錯誤／過時／不精確／環境特定／無法驗證
> - **使用者確認**：✓ 同意要改／✗ 不改（附理由）／待定
> - 只有「使用者確認 ✓」且判定不是「正確」的列，才會變成 loop 的修正故事。
> - 「環境特定」的列不上網查，改併入 guide 文末「需向他人確認」清單。
> - 行號是查證當下（commit `2c26688`）的行號，loop 改過之後會漂移 —— 以「原文摘錄」定位。
> - code-review 的 Spec 軸會 WebFetch 每一列的 URL，確認「來源引文」真的存在。

## 判定統計

| 批 | 範圍 | 說法總數 | 正確 | 錯誤 | 過時 | 不精確 | 環境特定 | 無法驗證 |
|---|---|---|---|---|---|---|---|---|
| ① | Part 0 | 73 | 61 | 1 | 1 | 8 | 0 | 2 |
| ① | Part 1 | 41 | 25 | 2 | 0 | 9 | 4 | 1 |
| ② | Part 2.1–2.2 | 53 | 38 | 4 | 1 | 9 | 1 | 0 |
| ② | Part 2.3–2.5 | 49 | 28 | 4 | 0 | 15 | 0 | 2 |
| ② | Part 3 | 40 | 24 | 3 | 1 | 11 | 0 | 1 |
| ③ | Part 4 | 42 | 25 | 5 | 0 | 9 | 3 | 0 |
| ③ | Part 5（上半） | 38 | 27 | 2 | 1 | 7 | 0 | 1 |
| ③ | Part 5（下半） | 34 | 21 | 3 | 0 | 9 | 0 | 1 |

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
