import { readFile, mkdir, copyFile, lstat, chmod } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const apply = process.argv.includes('--apply');
const agentIndex = process.argv.indexOf('--agent-dir');
const agentDir = agentIndex < 0 ? resolve(process.env.PI_CODING_AGENT_DIR ?? join(homedir(), '.pi', 'agent')) : resolve(process.argv[agentIndex + 1]);
if (agentIndex >= 0 && !process.argv[agentIndex + 1]) throw Error('--agent-dir needs a path');
const destination = join(agentDir, 'extensions', 'roampi');
const source = join(dirname(fileURLToPath(import.meta.url)), 'src');
const files = ['index.ts', 'bridge.ts', 'protocol.ts'];
console.log(`Plan: create ${destination} with mode 0700, then install ${files.join(', ')} with mode 0600.`);
console.log('RoamPi must show and obtain approval for this plan before calling --apply on a remote host.');
if (!apply) process.exit(0);
await mkdir(destination, { recursive: true, mode: 0o700 });
const stat = await lstat(destination);
if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw Error('Extension destination must be an owner-only directory');
for (const name of files) {
  const target = join(destination, name);
  try {
    const existing = await lstat(target);
    if (!existing.isFile() || existing.isSymbolicLink() || existing.uid !== process.getuid()) throw Error('Refusing to overwrite non-owned or linked extension file');
    if ((await readFile(target)).equals(await readFile(join(source, name)))) continue;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  await copyFile(join(source, name), target);
  await chmod(target, 0o600);
}
console.log('Installed. Restart Pi or run /reload to load the extension.');
