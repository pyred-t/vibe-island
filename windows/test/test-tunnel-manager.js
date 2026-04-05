/**
 * Test: Tunnel Manager basic init
 */
const { TunnelManager, TunnelStatus } = require('../src/tunnel-manager');

console.log('=== Test: Tunnel Manager ===\n');

// Check initial state
const statuses = TunnelManager.getAllStatuses();
console.log('Initial statuses:', statuses);
console.log('[PASS] TunnelManager initialized');

// Check SSH binary availability
const { exec } = require('child_process');
exec('ssh -V', (err, stdout, stderr) => {
  const out = (stdout + stderr).trim();
  if (out.includes('OpenSSH')) {
    console.log('[PASS] SSH available:', out);
  } else if (err) {
    console.log('[FAIL] SSH not found:', err.message);
    process.exit(1);
  } else {
    console.log('[PASS] SSH available');
  }
});
