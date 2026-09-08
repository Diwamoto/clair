// Benchmark public VS Code editor APIs; does not claim key-to-photon latency.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const {performance} = require('perf_hooks');
exports.activate = async function () {
  const root = path.resolve(__dirname, '..');
  const results = [];
  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  const timed = async fn => { const start = performance.now(); await fn(); return performance.now() - start; };
  try {
    let first;
    for (const name of ['normal.swift', '1mb.swift', '10mb.swift', 'long-line.ts']) {
      let doc, editor;
      const open = await timed(async () => {
        doc = await vscode.workspace.openTextDocument(path.join(root, 'fixtures', name));
        editor = await vscode.window.showTextDocument(doc, {preview:false});
      });
      if (!first) first = doc;
      await pause(1000);
      const input = [], scroll = [], tabs = [];
      for (let i=0;i<20;i++) {
        input.push(await timed(() => editor.edit(builder => builder.insert(new vscode.Position(0,0),'a'), {undoStopBefore:true,undoStopAfter:true})));
        await pause(20);
      }
      for (let i=0;i<20;i++) {
        scroll.push(await timed(() => editor.revealRange(new vscode.Range(Math.min(doc.lineCount-1, i*12),0,Math.min(doc.lineCount-1,i*12),0),vscode.TextEditorRevealType.AtTop)));
        await pause(20);
      }
      for (let i=0;i<20;i++) tabs.push(await timed(async () => {
        await vscode.window.showTextDocument(first,{preview:false});
        editor = await vscode.window.showTextDocument(doc,{preview:false});
      }));
      results.push({fixture:name,bytes:fs.statSync(path.join(root,'fixtures',name)).size,open_show_api_ms:open,input_api_ms:input,scroll_api_ms:scroll,two_tab_switch_api_ms:tabs,
        note:'extension API response; renderer paint and key-to-photon not measured; Swift extension absent in isolated profile'});
      fs.writeFileSync(path.join(root,'evidence/vscode.json'), JSON.stringify({version:vscode.version,results},null,2));
    }
    const many = await timed(async () => {
      for(let i=0;i<50;i++) {
        const d = await vscode.workspace.openTextDocument({language:'swift',content:`// tab\nlet x = ${i}\n`});
        await vscode.window.showTextDocument(d,{preview:false});
      }
    });
    results.push({fixture:'50 additional retained tabs',open_show_api_ms:many});
    const diff = await timed(() => vscode.commands.executeCommand('vscode.diff',vscode.Uri.file(path.join(root,'fixtures/large-old.txt')),vscode.Uri.file(path.join(root,'fixtures/large-new.txt')),'PoC large diff'));
    results.push({fixture:'10000 lines / 2000 replacements diff',command_api_ms:diff});
    fs.writeFileSync(path.join(root,'evidence/vscode.json'), JSON.stringify({version:vscode.version,results},null,2));
  } catch(error) { fs.writeFileSync(path.join(root,'evidence/vscode-error.txt'),String(error.stack)); }
  finally { fs.writeFileSync(path.join(root,'evidence/vscode-done.txt'),'done\n'); }
};
