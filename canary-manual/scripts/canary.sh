#!/usr/bin/env bash
# ⚠ 這個腳本需要 kubectl 的 patch / scale 權限。
#   如果你的 CD 只能 kubectl apply，用不到這個腳本 —— 改看 ../SOP-apply-only.md。
# =============================================================================
# Track A 的 canary 操作腳本（不需要 Argo Rollouts）
#
# 用法：
#   ./canary.sh deploy 1.3.0     # 把新版部署到 canary，正式流量不受影響
#   ./canary.sh status           # 看兩軌各是什麼版本、幾個 pod、權重多少
#   ./canary.sh verify           # 驗證 cookie 路由真的有效
#   ./canary.sh promote          # pilot run 簽核通過 → 把 canary 版本升為 stable
#   ./canary.sh rollback         # canary 有問題 → 關掉，正式流量本來就沒受影響
#   ./canary.sh undo             # promote 之後才發現問題 → 回退 stable 到上一版
#   ./canary.sh cleanup          # 清理舊的 ConfigMap（保留最近 3 個版本）
#
# 【重要】ConfigMap 是版本化的，所以 deploy 和 promote 都會同時處理三個地方：
#   1. container image tag
#   2. volumes[0].configMap.name
#   3. pod template annotation config-version
# 少改任何一個，都會出現「新版程式配舊版設定」的問題。
# =============================================================================
set -euo pipefail

NS="${NS:-ea-pmc}"
APP="pmc-epmmformquerygui"
STABLE="${APP}-stable"
CANARY="${APP}-canary"
CONTAINER="app"
CM_PREFIX="pmc-epmmformquery-config"
REGISTRY="${REGISTRY:-your-registry}"
CTX_PATH="/gui_epmmFormQuery"
KEEP_CONFIGMAPS="${KEEP_CONFIGMAPS:-3}"

die() { echo "ERROR: $*" >&2; exit 1; }

get_image() {
  kubectl -n "$NS" get deploy "$1" \
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER}')].image}" 2>/dev/null || echo ""
}

get_config() {
  kubectl -n "$NS" get deploy "$1" \
    -o jsonpath='{.spec.template.spec.volumes[0].configMap.name}' 2>/dev/null || echo ""
}

# 一次改掉 image + configMap 引用 + annotation
patch_deploy() {
  local deploy="$1" ver="$2"
  kubectl -n "$NS" patch deploy "$deploy" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",
     \"value\":\"${REGISTRY}/${APP}:${ver}\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/0/configMap/name\",
     \"value\":\"${CM_PREFIX}-${ver}\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/metadata/annotations/config-version\",
     \"value\":\"${ver}\"}
  ]"
}

cmd_deploy() {
  local ver="${1:-}"
  [ -n "$ver" ] || die "用法: $0 deploy <version>   例如: $0 deploy 1.3.0"

  # 前置檢查：ConfigMap 一定要先存在
  kubectl -n "$NS" get cm "${CM_PREFIX}-${ver}" >/dev/null 2>&1 \
    || die "ConfigMap ${CM_PREFIX}-${ver} 不存在。請先建立它（見 track-a/release/10-configmap-*.yaml）"

  echo "==> 目前 stable : $(get_image "$STABLE")  /  $(get_config "$STABLE")"
  echo "==> 部署到 canary: ${REGISTRY}/${APP}:${ver}  /  ${CM_PREFIX}-${ver}"
  echo ""

  patch_deploy "$CANARY" "$ver"
  kubectl -n "$NS" scale "deploy/${CANARY}" --replicas=1
  kubectl -n "$NS" rollout status "deploy/${CANARY}" --timeout=10m

  echo ""
  echo "canary 已就緒。正式流量仍 100% 在 stable，未受任何影響。"
  echo "下一步：執行 '$0 verify' 確認 cookie 路由，再把 pilot-run-guide.md 發給驗證人員。"
}

cmd_status() {
  echo "=== Deployment（image 與 ConfigMap 要成對）==="
  kubectl -n "$NS" get deploy -l "app=${APP}" -o custom-columns=\
'NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image,CONFIG:.spec.template.spec.volumes[0].configMap.name'
  echo ""
  echo "=== Pod ==="
  kubectl -n "$NS" get pods -l "app=${APP}" -L version
  echo ""
  echo "=== VirtualService 權重（正式流量分配）==="
  kubectl -n "$NS" get virtualservice app-routing \
    -o jsonpath='{range .spec.http[*]}{.name}{"\t"}{range .route[*]}{.destination.subset}{"="}{.weight}{" "}{end}{"\n"}{end}' 2>/dev/null || true
  echo ""
  echo "=== ConfigMap 版本 ==="
  kubectl -n "$NS" get cm -l "app=${APP}" \
    --sort-by=.metadata.creationTimestamp \
    -o custom-columns='NAME:.metadata.name,VERSION:.metadata.labels.config-version,AGE:.metadata.creationTimestamp'
}

cmd_verify() {
  local pod="canary-verify-$$"
  echo "=== 驗證 cookie 路由 ==="
  kubectl -n "$NS" run "$pod" --rm -i --restart=Never --image=curlimages/curl:8.5.0 --quiet -- sh -c "
    echo '--- 不帶 cookie（應該回 stable）---'
    curl -sS -o /dev/null -D - \
      http://${APP}-svc.${NS}:8080${CTX_PATH}/actuator/health | grep -i x-app-track || echo '  (沒有 x-app-track header)'
    echo '--- 帶 cookie（應該回 canary）---'
    curl -sS -o /dev/null -D - -H 'Cookie: canary=always' \
      http://${APP}-svc.${NS}:8080${CTX_PATH}/actuator/health | grep -i x-app-track || echo '  (沒有 x-app-track header)'
  " 2>/dev/null || true

  echo ""
  echo "兩次都是 stable、或完全沒有 header 的話，最可能的原因："
  echo "  1. VirtualService 的 gateways 沒有包含 mesh（見 guide 14.6）"
  echo "  2. Service 的 port 沒有 name: http / appProtocol: http（L7 功能沒啟用）"
  echo "  3. cookie 規則沒有放在 VirtualService 的 match 最前面"
}

cmd_promote() {
  local canary_img canary_cm stable_img stable_cm ver
  canary_img="$(get_image "$CANARY")"
  canary_cm="$(get_config "$CANARY")"
  stable_img="$(get_image "$STABLE")"
  stable_cm="$(get_config "$STABLE")"

  [ -n "$canary_img" ] || die "找不到 canary deployment"
  [ "$canary_img" != "$stable_img" ] || die "canary 與 stable 已是同一版（${stable_img}），不需要 promote"

  ver="${canary_img##*:}"

  echo "==> 目前 stable : ${stable_img}"
  echo "                  ${stable_cm}"
  echo "==> 升級為      : ${canary_img}"
  echo "                  ${canary_cm}"
  echo ""
  echo "確認 pilot run 已經簽核通過？這會讓「全部正式使用者」換到新版本。"
  read -r -p "輸入 yes 繼續: " ans
  [ "$ans" = "yes" ] || { echo "已取消"; exit 0; }

  patch_deploy "$STABLE" "$ver"
  kubectl -n "$NS" rollout status "deploy/${STABLE}" --timeout=15m

  echo ""
  echo "promote 完成："
  echo "  image  : $(get_image "$STABLE")"
  echo "  config : $(get_config "$STABLE")"
  echo ""
  echo "縮掉 canary 以釋放資源..."
  kubectl -n "$NS" scale "deploy/${CANARY}" --replicas=0
  echo ""
  echo "稍後若發現問題，執行： $0 undo"
}

cmd_rollback() {
  echo "==> 關閉 canary（正式流量本來就沒進 canary，使用者不受影響）"
  kubectl -n "$NS" scale "deploy/${CANARY}" --replicas=0
  echo "完成。stable 仍是 $(get_image "$STABLE")"
}

cmd_undo() {
  echo "==> 回退 stable 到上一個版本（image 與 ConfigMap 引用會一起還原）"
  kubectl -n "$NS" rollout undo "deploy/${STABLE}"
  kubectl -n "$NS" rollout status "deploy/${STABLE}" --timeout=15m
  echo "完成："
  echo "  image  : $(get_image "$STABLE")"
  echo "  config : $(get_config "$STABLE")"
}

cmd_cleanup() {
  local in_use total to_delete
  in_use="$(get_config "$STABLE")
$(get_config "$CANARY")"

  echo "=== 目前使用中的 ConfigMap（不會刪）==="
  echo "$in_use" | grep -v '^$' | sed 's/^/  /'
  echo ""

  total=$(kubectl -n "$NS" get cm -l "app=${APP}" --no-headers 2>/dev/null | wc -l)
  echo "共有 ${total} 個 ConfigMap，保留最近 ${KEEP_CONFIGMAPS} 個"

  to_delete=$(kubectl -n "$NS" get cm -l "app=${APP}" \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
    | head -n -"${KEEP_CONFIGMAPS}" || true)

  [ -n "$to_delete" ] || { echo "沒有需要清理的"; return; }

  echo ""
  echo "=== 準備刪除 ==="
  local safe=""
  for cm in $to_delete; do
    local name="${cm#configmap/}"
    if echo "$in_use" | grep -qx "$name"; then
      echo "  跳過（使用中）: $name"
    else
      echo "  刪除: $name"
      safe="$safe $cm"
    fi
  done

  [ -n "$safe" ] || { echo "沒有可以安全刪除的"; return; }
  echo ""
  read -r -p "輸入 yes 確認刪除: " ans
  [ "$ans" = "yes" ] || { echo "已取消"; exit 0; }
  # shellcheck disable=SC2086
  kubectl -n "$NS" delete $safe
}

case "${1:-}" in
  deploy)   shift; cmd_deploy "$@" ;;
  status)   cmd_status ;;
  verify)   cmd_verify ;;
  promote)  cmd_promote ;;
  rollback) cmd_rollback ;;
  undo)     cmd_undo ;;
  cleanup)  cmd_cleanup ;;
  *)
    sed -n '7,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
