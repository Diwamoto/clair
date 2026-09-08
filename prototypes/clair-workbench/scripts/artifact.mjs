// Turn the single-file Vite build into an Artifact-ready fragment: the
// Artifact runtime supplies <!doctype>/<html>/<head>/<body> itself, so this
// emits only <title>, <style> and <script>.
import { readFileSync, writeFileSync } from 'node:fs';

const html = readFileSync(new URL('../dist/index.html', import.meta.url), 'utf8');
const head = html.slice(html.indexOf('<head>'), html.indexOf('</head>'));

const styles = [...head.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)].map((m) => m[1]);
const scripts = [...head.matchAll(/<script(?: type="module")?[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);

if (!styles.length || !scripts.length) throw new Error('unexpected build output');

writeFileSync(
  new URL('../dist/artifact.html', import.meta.url),
  [
    '<title>Clair Workbench</title>',
    ...styles.map((s) => `<style>${s}</style>`),
    '<div id="root"></div>',
    ...scripts.map((s) => `<script type="module">${s}</script>`),
    '',
  ].join('\n'),
);
console.log('wrote dist/artifact.html');
