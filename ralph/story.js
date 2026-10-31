#!/usr/bin/env node
// Ralph 的 prd.json 查詢／更新工具。
//
// 為什麼有這支：prd.json 有 96 個故事、142 KB，代理每一輪只需要其中一個（約 0.7 KB）。
// 讓代理 Read 整份檔案，每一輪就要付 142 KB 的 token；改用這支只拿需要的那一個。
//
//   node ralph/story.js next          下一個要做的故事（priority 最小的 passes:false）；全部完成時印 ALL_COMPLETE
//   node ralph/story.js show <ID>     印出指定故事
//   node ralph/story.js pass <ID>     設 passes: true
//   node ralph/story.js note <ID>     從 stdin 讀入 notes 寫進故事（空 stdin = 清空 notes）
//
// notes 從 stdin 讀、不從 argv 讀：Git Bash（MSYS2）會把長得像 POSIX 路徑的參數翻成 Windows 路徑，
// `/gui_epmmFormQuery` 會變成 `C:/Program Files/Git/gui_epmmFormQuery`。stdin 不會被動。
//
// 寫回用 JSON.stringify(p, null, 2) + '\n' —— 實測跟現有 prd.json 逐位元組相同，不會產生雜訊 diff。
// 路徑用 __dirname，從哪個目錄呼叫都一樣。
'use strict';
const fs = require('fs');
const path = require('path');

const PRD = path.join(__dirname, 'prd.json');

function die(msg) {
  process.stderr.write(`story.js: ${msg}\n`);
  process.exit(1);
}

function load() {
  return JSON.parse(fs.readFileSync(PRD, 'utf8'));
}

function find(p, id) {
  if (!id) die('缺少故事 ID（例如 US-005）');
  const s = p.userStories.find((x) => x.id === id);
  if (!s) die(`prd.json 裡沒有故事 ${id}`);
  return s;
}

function save(p, id, check) {
  fs.writeFileSync(PRD, JSON.stringify(p, null, 2) + '\n', 'utf8');
  // 寫完重新讀一次，確認改到的是預期的欄位
  const again = find(load(), id);
  if (!check(again)) die(`寫回後驗證失敗：${id} 的欄位不是預期的值`);
}

const [cmd, id] = process.argv.slice(2);
const p = load();

switch (cmd) {
  case 'next': {
    const todo = p.userStories
      .filter((s) => s.passes !== true)
      .sort((a, b) => a.priority - b.priority);
    if (todo.length === 0) {
      console.log('ALL_COMPLETE');
      break;
    }
    console.log(JSON.stringify({
      branchName: p.branchName,
      description: p.description,
      remaining: todo.length,
      total: p.userStories.length,
      story: todo[0],
    }, null, 2));
    break;
  }
  case 'show':
    console.log(JSON.stringify(find(p, id), null, 2));
    break;
  case 'pass': {
    find(p, id).passes = true;
    save(p, id, (s) => s.passes === true);
    console.log(`${id}: passes = true`);
    break;
  }
  case 'note': {
    const text = fs.readFileSync(0, 'utf8').replace(/\r\n/g, '\n').replace(/\n+$/, '');
    find(p, id).notes = text;
    save(p, id, (s) => s.notes === text);
    console.log(`${id}: notes 已更新（${text.length} 字）`);
    break;
  }
  default:
    die('用法：node ralph/story.js next | show <ID> | pass <ID> | note <ID> < notes.txt');
}
