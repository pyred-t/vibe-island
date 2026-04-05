/**
 * Test: SSH Config Reader
 */
const r = require('../src/ssh-config-reader');

console.log('=== Test: SSH Config Reader ===\n');
r.load();
console.log('Config path:', r.getConfigPath());
const hosts = r.getHosts();
console.log('Hosts found:', hosts.length);
hosts.forEach(h => {
  console.log('  -', h.alias, '=>', h.hostname, '  user:', h.user, '  port:', h.port);
});
if (hosts.length === 0) {
  console.log('  (no Host entries in SSH config)');
}
console.log('\n[PASS] loaded without errors');
