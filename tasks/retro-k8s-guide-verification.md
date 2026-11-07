# Retro：ralph/guide-verification（修 k8s-ecosystem-guide.md，US-001～US-096）

範圍：這個 run 共 96 個故事、104 個 `feat:` commit、72 個 `fix:` commit（review 後的修正）。
改動全是文件（`k8s-ecosystem-guide.md`）＋ `scripts/validate.sh` 的 [10]／[11] 兩個檢查。
下面是候選項，依嚴重度排序；標「已做」的在 US-096 落到 CLAUDE.md。

## 1. Automated checks

- **[11] 只證明「有官方連結」，不證明「改法跟帳本一致」。** review 的 72 個 `fix:` 大多是
  Spec／Standards 抓到措辭偏離帳本、引文翻譯放進「」、引用字樣沒逐字複製。其中「「」內必須是
  guide 裡真的存在的字串」是機械可查的：可加一個檢查，抽出 guide 內「」包住的英文片段，
  確認不是自己剛刪掉的字樣。未做（誤報風險高，中文引號也用於強調），列為候選。
- **[10] 已擋下縮排錯誤的 yaml 區塊**；`<!-- validate:skip-yaml 原因 -->` 要求原因，避免 skip 變成漏洞。
  這部分運作良好，不需改動。

## 2. Navigation

- **已做：** CLAUDE.md 沒有指向帳本、spec、`VERIFIED_PARTS` 規則的導覽（只在「目前的 run」一句帶過）。
  之後有人改 guide 的某個 Part 卻刪了 `### 參考來源`，只有 [11] 會 FAIL，而 FAIL 訊息不會告訴他
  該去哪裡找來源 URL —— 答案在帳本的 URL 欄。
- 帳本與 spec 各數百 KB，沒有目錄。這輪靠 `Grep` 帳本 ID 定位，每次都能找到，不需處理。

## 3. Coding standards / reviewer

- Standards reviewer 看不到帳本，會把同一個詞在其他帳本列範圍內的出現當成本故事的違規。
  已寫進 `ralph/patterns.md`（「review 的收斂」）。

## 4. 已知不正確的說法（已做）

- CLAUDE.md「兩者同時存在時兩個 controller 會搶 pod」不正確（帳本 X-002）：Argo 官方文件寫
  "The Rollout won't try to manage existing Deployment Pods."，且建議遷移時兩者並存。
  互斥規則不變，真正原因是共用 `app` label 會讓對方的 Service 把 pod 選進 endpoint，
  以及兩軌共用同一條 VirtualService。

## 5. Tool economy

- `WebFetch` 預設只讀前 100000 字，kubernetes.io 長頁的引文常在後段（已寫進 patterns.md）。
- `progress.txt` 與 `prd.json` 不整份讀的做法有效，沒有再發現昂貴呼叫。

## 6. No-ops / 瘦身

- `ralph/patterns.md` 前半（約 140 行）是上一個 run 的 manifest 慣例，這個 run 幾乎用不到。
  下個 run 開始前應刪掉只適用 manifest 的條目（CLAUDE.md 已有「換 run 時順手刪掉」的提醒）。
