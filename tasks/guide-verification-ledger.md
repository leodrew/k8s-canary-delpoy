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
