# Retro：ralph/guide-explainers（在 k8s-ecosystem-guide.md 新增概念說明，US-097～US-103）

範圍：6 個內容故事（US-097～US-102）＋本 retro。改動全是文件（`k8s-ecosystem-guide.md`、
帳本的引文欄），沒有動 manifest、沒有改 `validate.sh`。內容故事共 6 個 `fix:` commit，
每個故事 0～2 個。下面依嚴重度排序；標「已做」的已落到 CLAUDE.md。

## 1. Automated checks

- **最常見的 review 發現是「引文不在官方頁」，而且是帳本本身的引文過期或被改寫過**
  （US-098 的 `commonName`、US-102 的 Calico 句與 tier order 句）。guide 與帳本都引了
  一句話，兩邊一致但官方頁上沒有這句。這需要 WebFetch，無法放進離線的 `validate.sh`。
  現行做法（Spec reviewer 對每個引文 WebFetch）有效，不加檢查。
  可機械檢查的只有一半：「guide 裡的『』英文引文必須也出現在帳本」。上個 retro 已列為候選，
  誤報風險仍高（中文引號也用於強調），維持未做。
- [10]／[11] 在這個 run 沒有誤報也沒有漏報；新增的 yaml 範例（Spring Session、Indexed Job）
  都靠 [10] 驗過可解析。

## 2. Navigation

- **已做：** CLAUDE.md「目前的 run」原本只寫到「從 US-097 開始」，沒說這個 run 已經做完、
  retro 在哪。改成指向本檔與封存位置。
- **已做：** 「帳本引文可能過期」這個陷阱只存在於 `patterns.md`（每輪讀）與 progress.txt，
  CLAUDE.md 沒有。人類或非 Ralph 的 session 改這幾段說明時會直接信帳本引文。

## 3. Coding standards / reviewer

- Standards reviewer 這個 run 沒有硬性違規，只有判斷題（表格儲存格偏長、措辭強度）。
  沒有需要新增的規則。
- Spec reviewer 抓到的是「帳本沒有的合理推論」（US-100 的 timeout 症狀、Redis TTL）。
  已在 `patterns.md`（progress 的 US-100 learning 所指的慣例）涵蓋，不重複。

## 4. Tool economy

- 兩輪 review 上限在 US-098、US-102 都被用到邊界：第 2 輪之後才修的東西沒有再 review。
  修的都是刪除、拆分、縮小引用範圍這類機械改動，風險可接受；規則本身（`patterns.md`
  「review 的收斂」）不需改。
- 沒有發現昂貴的工具呼叫。

## 5. No-ops / 瘦身

- **未做，下個 run 開始前處理：** `ralph/patterns.md` 前半仍是 manifest／validate.sh 慣例，
  兩個 guide run 都幾乎用不到。換 run 時（見 CLAUDE.md 封存步驟）把它們移到封存目錄，
  只留 guide 慣例與 shell／node 的坑。
