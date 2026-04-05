/**
 * Test: ConfigStore machine CRUD operations
 * Tests the new per-machine config model
 */

// Isolate from real config file by patching the path
process.env.APPDATA = require('os').tmpdir();

const configStore = require('../src/config-store');
configStore.load();

console.log('=== Test: ConfigStore Machine CRUD ===\n');

// 1. Local machine should exist by default
const local = configStore.getLocalMachine();
console.log('Local machine exists:', !!local, '(expect true)');
console.log('Local machine type:', local?.type, '(expect local)');
if (!local) { console.log('[FAIL]'); process.exit(1); }

// 2. Add an SSH machine
const added = configStore.addSSHMachine('test-server', {
  claudePaths: ['~/.claude', '/opt/custom/.claude'],
  port: 51515,
  autoConnect: true,
});
console.log('\nAdd SSH machine:', added, '(expect true)');
if (!added) { console.log('[FAIL]'); process.exit(1); }

// 3. Verify it exists
const machines = configStore.getMachines();
console.log('Machines count:', machines.length, '(expect 2)');
if (machines.length !== 2) { console.log('[FAIL]'); process.exit(1); }

// 4. Get SSH machines
const sshMachines = configStore.getSSHMachines();
console.log('SSH machines:', sshMachines.length, '(expect 1)');
if (sshMachines.length !== 1) { console.log('[FAIL]'); process.exit(1); }

const m = sshMachines[0];
console.log('SSH machine alias:', m.sshAlias, '(expect test-server)');
console.log('SSH machine paths:', m.claudePaths.join(', '), '(expect 2 paths)');
if (m.claudePaths.length !== 2) { console.log('[FAIL]'); process.exit(1); }

// 5. autoConnect filter
const autoConnect = configStore.getSSHMachines().filter(x => x.autoConnect);
console.log('\nAutoConnect machines:', autoConnect.length, '(expect 1)');
if (autoConnect.length !== 1) { console.log('[FAIL]'); process.exit(1); }

// 6. updateMachine
configStore.updateMachine('test-server', { lastConnected: new Date().toISOString() });
const after = configStore.getMachine('test-server');
console.log('lastConnected set:', !!after.lastConnected, '(expect true)');
if (!after.lastConnected) { console.log('[FAIL]'); process.exit(1); }

// 7. getMachineBySSHAlias
const byAlias = configStore.getMachineBySSHAlias('test-server');
console.log('\nGetByAlias:', byAlias?.sshAlias, '(expect test-server)');
if (!byAlias) { console.log('[FAIL]'); process.exit(1); }

// 8. addClaudePathToMachine
configStore.addClaudePathToMachine('test-server', '/another/path');
const withExtra = configStore.getMachine('test-server');
console.log('After addPath:', withExtra.claudePaths.length, 'paths (expect 3)');
if (withExtra.claudePaths.length !== 3) { console.log('[FAIL]'); process.exit(1); }

// 9. removeClaudePathFromMachine
configStore.removeClaudePathFromMachine('test-server', '/another/path');
const withRemoved = configStore.getMachine('test-server');
console.log('After removePath:', withRemoved.claudePaths.length, 'paths (expect 2)');
if (withRemoved.claudePaths.length !== 2) { console.log('[FAIL]'); process.exit(1); }

// 10. removeMachine
const removed = configStore.removeMachine('test-server');
console.log('\nRemove machine:', removed, '(expect true)');
if (!removed) { console.log('[FAIL]'); process.exit(1); }

const final = configStore.getMachines();
console.log('Final machines:', final.length, '(expect 1 - local only)');
if (final.length !== 1) { console.log('[FAIL]'); process.exit(1); }

// 11. Cannot remove local
const removedLocal = configStore.removeMachine('local');
console.log('Remove local blocked:', !removedLocal, '(expect true)');
if (removedLocal) { console.log('[FAIL] Should not be able to remove local'); process.exit(1); }

console.log('\n[PASS] All ConfigStore machine CRUD tests passed');
