/**
 * Test: Remote session event (with hostname + is_remote)
 * Simulates a hook event from a remote SSH machine
 */
const net = require('net');

const payload = {
  session_id: 'remote-test-001',
  hook_event_name: 'SessionStart',
  event: 'SessionStart',
  status: 'waiting_for_input',
  cwd: '/home/x/projects/api',
  hostname: 'my-dev-server',
  is_remote: true,
  agent_id: 'claude',
  pid: 12345,
};

const sock = net.createConnection({ host: '127.0.0.1', port: 51515 }, () => {
  sock.write(JSON.stringify(payload));
  sock.end();
  console.log('[SENT] Remote session event with hostname=my-dev-server, is_remote=true');
});

sock.on('error', (err) => {
  console.error('[FAIL] Could not connect:', err.message);
  process.exit(1);
});

setTimeout(() => {
  // Send a follow-up processing event
  const sock2 = net.createConnection({ host: '127.0.0.1', port: 51515 }, () => {
    sock2.write(JSON.stringify({
      ...payload,
      event: 'UserPromptSubmit',
      status: 'processing',
    }));
    sock2.end();
    console.log('[SENT] Remote UserPromptSubmit (processing)');
  });
  sock2.on('error', () => {});
}, 500);
