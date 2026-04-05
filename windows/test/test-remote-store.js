/**
 * Test: Remote Host Store
 */
const store = require('../src/remote-host-store');

// Mock configStore
const mockConfig = {};
const mockConfigStore = {
  get: (k) => mockConfig[k],
  set: (k, v) => { mockConfig[k] = v; },
};

store.init(mockConfigStore);
console.log('=== Test: Remote Host Store ===\n');

// Add a host
store.addHost('myserver', { port: 51515, autoConnect: true });
store.addHost('dev-box', { port: 51515, autoConnect: false });

let all = store.getAll();
console.log('After adding 2 hosts:', all.length, '(expect 2)');
if (all.length !== 2) { console.log('[FAIL]'); process.exit(1); }

// AutoConnect filter
const auto = store.getAutoConnect();
console.log('AutoConnect hosts:', auto.length, '(expect 1)');
if (auto.length !== 1 || auto[0].alias !== 'myserver') {
  console.log('[FAIL] wrong autoConnect filter'); process.exit(1);
}

// markConnected
store.markConnected('myserver');
all = store.getAll();
const srv = all.find(h => h.alias === 'myserver');
console.log('myserver.lastConnected:', srv.lastConnected ? 'set' : 'null', '(expect set)');
if (!srv.lastConnected) { console.log('[FAIL]'); process.exit(1); }

// Remove
store.removeHost('dev-box');
all = store.getAll();
console.log('After remove:', all.length, '(expect 1)');
if (all.length !== 1) { console.log('[FAIL]'); process.exit(1); }

console.log('\n[PASS] All RemoteHostStore tests passed');
