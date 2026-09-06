import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
let failed = false;
const rules = [
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\bgh[pousr]_[A-Za-z0-9]{30,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{30,}\b/,
  /\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b/,
  /\/(?:Users|home)\/[a-zA-Z0-9_.-]+\//,
];
for (const file of new Set(files)) {
  if (!existsSync(file)) continue;
  if (/(^|\/)\.env(?:\.|$)|\.(?:p12|mobileprovision|keychain|xcresult)$/.test(file)) {
    console.error(`Private artifact: ${file}`); failed = true;
  }
  const body = readFileSync(file, 'utf8');
  if (rules.some(rule => rule.test(body))) {
    console.error(`Potential private material: ${file}`); failed = true;
  }
  if (!file.endsWith('.md')) continue;
  for (const match of body.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
    const link = match[1].split('#')[0];
    if (!link || /^(?:https?:|mailto:)/.test(link)) continue;
    if (!existsSync(resolve(dirname(file), link))) {
      console.error(`Broken documentation link: ${file} -> ${link}`); failed = true;
    }
  }
}
execFileSync('git', ['diff', '--check'], { stdio: 'inherit' });
if (failed) process.exit(1);
console.log('Public source and documentation checks passed. Review full history separately before publishing.');
