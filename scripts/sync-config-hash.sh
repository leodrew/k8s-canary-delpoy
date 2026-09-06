#!/usr/bin/env bash
#
# scripts/sync-config-hash.sh — 把每一份 Deployment 的 config-hash annotation
#                               同步成「它自己掛的那一份 ConfigMap」的內容雜湊
#
# 為什麼需要這支腳本：
#   US-008 之前，ConfigMap 的名字帶版本號（...-config-1.2.3），Deployment 的
#   volumes[config].configMap.name 也跟著寫版本號 —— 改設定 = 改名字 = 改到
#   pod template，於是 kubectl apply 會自動滾動更新。US-008 把名字固定成
#   ...-config-stable / -canary 之後，那條因果鏈斷了：
#
#       改 ConfigMap 內容 → apply → pod template 一個欄位都沒變
#         → 沒有任何 pod 重啟 → 而 Spring 只在【啟動時】讀一次設定檔
#         → 新設定 apply 了卻沒有生效
#
#   這個失效是完全安靜的：沒有錯誤訊息，kubectl get / describe 都正常，
#   ConfigMap 裡確實是新內容 —— 只有「行為跟你以為的不一樣」。
#
#   config-hash 把那條鏈接回來：值是 ConfigMap data["application.yml"] 的
#   sha256 前 8 碼，內容變 → hash 變 → pod template 變 → 觸發滾動更新。
#   （CANARY-COMPLETE.md 2.2 表格第 3 條、3.6）
#
# 用法：
#   bash scripts/sync-config-hash.sh        # 從哪個目錄呼叫都一樣，腳本自己 cd
#
#   改完 ConfigMap 之後跑一次，然後把 ConfigMap 與 Deployment 的改動放進
#   【同一個 commit】—— 那是回滾能運作的前提（2.2 表格第 1 條）。
#   忘了跑會怎樣：hash 停在舊值 → apply 不重啟 → 設定沒生效，而且不會報錯。
#   所以 scripts/validate.sh 的檢查 [9] 會重算一次跟檔案裡的值比對，
#   忘了跑就會在閘門上 FAIL —— 那是這個安靜失效唯一的攔截點。
#
# 這支腳本刻意做的事：
#   - 只改 config-hash 那一行的值，用文字取代，不重新序列化 YAML。
#     這個 repo 的 manifest 有大量中文註解，js-yaml dump 一次就全部消失。
#   - 冪等：連跑兩次第二次不會產生任何 diff（validate.sh 檢查 [9b] 會驗這件事）。
#   - 從 Deployment 讀 volumes[config].configMap.name、再去查 ConfigMap 的
#     metadata.name，而不是靠檔名配對 —— Deployment 認的是名字不是檔案。
#     查不到名字時【失敗並說明】，不是安靜跳過。
#   - 寫完之後重新解析檔案，確認改到的真的是 pod template 的那一個 annotation。
#
# 它刻意不做的事：
#   - 不碰 track-b。canary-manual/track-b/release/20-rollout.yaml 沒有
#     config-hash annotation，而且它的 ConfigMap 還沒依附錄 C 補齊（見
#     validate.sh 檢查 [6] 的排除說明）。等 track-b 補齊、也改用固定名稱的
#     ConfigMap 之後，把 RELEASE_DIRS 加上它那一層目錄即可。
#   - 不碰 track-a/runtime/05-configmap-canary-pilot.yaml（pilot 名單）。
#     改名單【不應該】重啟任何 pod，所以它刻意不參與 config-hash；那也是為什麼
#     它的 volume 是 optional: true。這支腳本只看 release/ 目錄，天然不會碰到它。
#
# 工具限制：
#   這台機器沒有 python、也不保證 Git Bash 下有 sha256sum，所以雜湊用
#   node 的 require("crypto")。YAML 一律用釘在 devDependencies 的本地 js-yaml。

set -uo pipefail

# --- 一律切到 repo root ------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# --- Git Bash 的 argv 路徑轉換陷阱（跟 validate.sh 同一個理由，不要拿掉）------
# MSYS2 會把長得像 POSIX 絕對路徑的參數翻成 Windows 路徑再交給原生的 node.exe，
# 於是傳進去的 "canary-manual/..." 相對路徑沒事、但任何 / 開頭的值會被竄改。
# 這支腳本目前只傳相對路徑，設這一行是為了讓它跟 validate.sh 有一致的行為，
# 也為了之後有人加上「傳一個絕對路徑進去」的參數時不會踩到。
export MSYS2_ARG_CONV_EXCL='*'

# --- 前置檢查：本地 js-yaml 一定要在 -----------------------------------------
if [ ! -d node_modules/js-yaml ]; then
  echo "找不到 node_modules/js-yaml" >&2
  echo "請先在 repo root 執行 npm install（js-yaml 是 devDependency）" >&2
  exit 1
fi

# 要掃的目錄。之後 track-b 補齊、也改用固定名稱的 ConfigMap 時加在這裡。
RELEASE_DIR="canary-manual/track-a/release"

SYNC_SCRIPT='
const fs = require("fs");
const path = require("path");
const y = require("js-yaml");
const crypto = require("crypto");

const [dir] = process.argv.slice(1);

// --- 掃目錄，建立 ConfigMap 索引與 Deployment 清單 -------------------------
// 用讀目錄而不是寫死檔名：之後新增一份 Deployment 或 ConfigMap 自動被涵蓋。
const files = fs.readdirSync(dir)
  .filter(n => n.endsWith(".yaml"))
  .sort()
  .map(n => dir + "/" + n);

const cmByName = new Map();
const deployments = [];

for (const f of files) {
  let docs;
  try {
    docs = y.loadAll(fs.readFileSync(f, "utf8")).filter(Boolean);
  } catch (e) {
    console.error(f + ": YAML 解析失敗 —— " + e.message);
    console.error("  先跑 bash scripts/validate.sh 的檢查 [1] 把語法修好再回來。");
    process.exit(1);
  }
  for (const d of docs) {
    if (!d || typeof d !== "object") continue;
    if (d.kind === "ConfigMap" && d.metadata && d.metadata.name) {
      const app = d.data && d.data["application.yml"];
      if (typeof app === "string") cmByName.set(d.metadata.name, { file: f, appYml: app });
    }
    if (d.kind === "Deployment") deployments.push({ file: f, doc: d });
  }
}

if (deployments.length === 0) {
  console.error(dir + " 底下找不到任何 Deployment。");
  console.error("  目錄搬家了嗎？這支腳本什麼都沒做就結束，等於 config-hash 永遠不會更新 ——");
  console.error("  那是這裡最不希望發生的事，所以視為失敗而不是「沒事做」。");
  process.exit(1);
}
if (cmByName.size === 0) {
  console.error(dir + " 底下找不到任何帶 data[application.yml] 的 ConfigMap。");
  process.exit(1);
}

// --- 逐一同步 ---------------------------------------------------------------
function collect(node, key, out) {
  if (Array.isArray(node)) { for (const v of node) collect(v, key, out); return out; }
  if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      if (k === key) out.push(node[k]);
      collect(node[k], key, out);
    }
  }
  return out;
}

let failed = false;

for (const { file, doc } of deployments) {
  // Deployment 引用的是 ConfigMap 的【名字】，不是檔名 —— 所以走索引查，
  // 不要拿檔名配對。這樣改檔名不會讓同步結果悄悄變成另一軌的設定。
  const volumes = [].concat(...collect(doc, "volumes", []));
  const cfgVol = volumes.find(v => v && v.name === "config");
  if (!cfgVol || !cfgVol.configMap || !cfgVol.configMap.name) {
    console.error(file + ": 找不到名為 config 的 volume（或它不是 configMap）");
    console.error("  沒有這個 volume 就沒有「這份 Deployment 讀哪一份設定」可言，");
    console.error("  hash 也就無從算起。");
    failed = true;
    continue;
  }
  const cmName = cfgVol.configMap.name;
  const entry = cmByName.get(cmName);
  if (!entry) {
    console.error(file + ": 它掛的 ConfigMap 叫 " + cmName + "，但 " + dir);
    console.error("  底下沒有任何一份 ConfigMap 的 metadata.name 是這個。");
    console.error("  這不是可以跳過的情況：apply 之後叢集裡不會有這個物件，pod 會卡在");
    console.error("  ContainerCreating（FailedMount）。改名字時兩邊要一起改。");
    failed = true;
    continue;
  }

  // 雜湊的對象是【解析後】的 data[application.yml] 字串，不是原始檔的位元組。
  // 理由：叢集那一端算的也是這個 —— kubectl get cm -o jsonpath={.data.application\.yml}
  // 拿到的是 API server 存的字串（YAML block scalar 解析後，行尾一律 LF），
  // 所以這裡算出來的值可以直接跟 6.3 節那條 kubectl | sha256sum 指令對照。
  // 對原始檔算的話，改一個註解或換個縮排就會讓 hash 變，而那不是設定變更。
  const hash = crypto.createHash("sha256").update(entry.appYml, "utf8").digest("hex").slice(0, 8);

  const raw = fs.readFileSync(file, "utf8");

  // 只改那一行的值，用文字取代 —— 不要 y.dump() 整份寫回去。
  // 這個 repo 的 manifest 有大量中文註解在解釋「為什麼」，dump 一次全部消失。
  // 行尾的 \r 用捕獲群組原樣接回去，這樣在 CRLF 的工作目錄裡也不會製造整檔 diff。
  const lineRe = /^([ \t]*)config-hash:[^\r\n]*(\r?)$/gm;
  const hits = raw.match(lineRe) || [];
  if (hits.length !== 1) {
    if (hits.length === 0) {
      console.error(file + ": 找不到 config-hash: 那一行。");
      console.error("  這支腳本刻意【不會】自己插入它 —— 這個 repo 的規矩是每個 key 都要有");
      console.error("  一段說明「少了它會壞在哪裡」的註解，而註解只有人寫得出來。");
      console.error("  請在 spec.template.metadata.annotations 底下加上");
      console.error("    config-hash: \"0000\"");
      console.error("  以及說明註解（照抄 20-deployment-stable.yaml 的那一段），再跑一次。");
    } else {
      console.error(file + ": 有 " + hits.length + " 行 config-hash:，不知道該改哪一行。");
      console.error("  pod template 底下只能有一個。多出來的那個很可能是 Deployment");
      console.error("  自己的 metadata.annotations —— 那個位置改了【不會】觸發滾動更新。");
    }
    failed = true;
    continue;
  }

  const next = raw.replace(lineRe, (m, indent, cr) => indent + "config-hash: \"" + hash + "\"" + cr);
  const label = path.basename(file);
  if (next === raw) {
    console.log(label + ": config-hash 已經是 " + hash + "（" + cmName + "），不需要更動");
  } else {
    fs.writeFileSync(file, next);
    console.log(label + ": config-hash 更新為 " + hash + "（來源 " + entry.file + "）");
  }

  // 寫完自我驗證：重新解析，確認改到的那一行真的是 pod template 的 annotation。
  // 文字取代永遠有「改到了長得很像的另一個地方」的風險，重新解析是唯一能確定的方法。
  let after;
  try {
    after = y.loadAll(fs.readFileSync(file, "utf8")).filter(Boolean).find(d => d && d.kind === "Deployment");
  } catch (e) {
    console.error(file + ": 寫回之後 YAML 解析不了 —— " + e.message);
    failed = true;
    continue;
  }
  const ann = (after && after.spec && after.spec.template && after.spec.template.metadata &&
    after.spec.template.metadata.annotations) || {};
  if (ann["config-hash"] !== hash) {
    console.error(file + ": 寫回之後 spec.template.metadata.annotations[config-hash]");
    console.error("  仍然不是 " + hash + "（實際 " + JSON.stringify(ann["config-hash"]) + "）。");
    console.error("  剛才改到的多半是別的位置 —— 只有 pod template 底下的 annotation 變動");
    console.error("  才會觸發滾動更新，改在 Deployment 自己的 metadata 上完全沒有效果。");
    failed = true;
  }

  // 順手提醒：config-version 是 US-008/US-009 之前的機制，名稱固定之後它是個
  // 永遠不動的常數。留著不會壞，但會讓人以為版本化那一套還在。
  if (/^[ \t]*config-version:/m.test(raw)) {
    console.error(file + ": 還留著 config-version: 那一行。");
    console.error("  ConfigMap 名稱固定之後那個值不會再跟著設定變動，等於沒有這個機制。");
    console.error("  validate.sh 的檢查 [9] 會為此 FAIL。");
  }
}

process.exit(failed ? 1 : 0);
'

node -e "$SYNC_SCRIPT" "$RELEASE_DIR"
exit $?
