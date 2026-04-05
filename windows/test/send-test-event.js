/**
 * Test script to send simulated hook events to Claude Island Windows
 * Usage: node test/send-test-event.js [event-type]
 *
 * Available event types:
 *   session-start   - Simulate a new session
 *   processing      - Simulate Claude processing
 *   permission      - Simulate a permission request (keeps connection open)
 *   tool            - Simulate a tool being used
 *   waiting         - Simulate waiting for input
 *   end             - Simulate session end
 *   ask             - Simulate AskUserQuestion
 *   all             - Send a sequence of events
 */
const net = require('net');

const PORT = 51515;
const HOST = '127.0.0.1';
const SESSION_ID = 'test-session-' + Date.now().toString(36);

function sendEvent(event, waitForResponse = false) {
  return new Promise((resolve, reject) => {
    const client = new net.Socket();
    client.connect(PORT, HOST, () => {
      console.log(`→ Sending: ${event.event} (status: ${event.status})`);
      client.write(JSON.stringify(event));

      if (!waitForResponse) {
        setTimeout(() => {
          client.destroy();
          resolve(null);
        }, 100);
      }
    });

    if (waitForResponse) {
      client.on('data', (data) => {
        const response = JSON.parse(data.toString());
        console.log(`← Response:`, response);
        client.destroy();
        resolve(response);
      });
    }

    client.on('error', (err) => {
      console.error(`✗ Connection failed: ${err.message}`);
      console.error('  Make sure Claude Island Windows is running.');
      reject(err);
    });

    // Timeout after 30 seconds
    client.setTimeout(30000, () => {
      console.log('← Timeout waiting for response');
      client.destroy();
      resolve(null);
    });
  });
}

async function delay(ms) {
  return new Promise(r => setTimeout(r, ms));
}

const events = {
  'session-start': {
    session_id: SESSION_ID,
    event: 'SessionStart',
    status: 'waiting_for_input',
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },

  'processing': {
    session_id: SESSION_ID,
    event: 'UserPromptSubmit',
    status: 'processing',
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },

  'tool': {
    session_id: SESSION_ID,
    event: 'PreToolUse',
    status: 'running_tool',
    tool: 'Read',
    tool_input: { file_path: 'src/main.rs' },
    tool_use_id: 'tool-' + Date.now(),
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },

  'permission': {
    session_id: SESSION_ID,
    event: 'PermissionRequest',
    status: 'waiting_for_approval',
    tool: 'Write',
    tool_input: { file_path: 'src/utils.rs', content: 'fn hello() { println!("Hello!"); }' },
    tool_use_id: 'perm-' + Date.now(),
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },

  'waiting': {
    session_id: SESSION_ID,
    event: 'Stop',
    status: 'waiting_for_input',
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },

  'ask': {
    session_id: SESSION_ID,
    event: 'PreToolUse',
    status: 'waiting_for_input',
    tool: 'AskUserQuestion',
    tool_input: { question: 'Should I refactor the database module or add a new endpoint first?' },
    tool_use_id: 'ask-' + Date.now(),
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },

  'end': {
    session_id: SESSION_ID,
    event: 'SessionEnd',
    status: 'ended',
    cwd: 'D:\\Projects\\my-app',
    pid: process.pid,
    agent_id: 'claude',
  },
};

async function main() {
  const type = process.argv[2] || 'all';

  if (type === 'all') {
    console.log('=== Simulating full session lifecycle ===\n');

    await sendEvent(events['session-start']);
    await delay(1000);

    await sendEvent(events['processing']);
    await delay(1500);

    await sendEvent(events['tool']);
    await delay(1000);

    console.log('\n--- Sending permission request (waiting for response) ---');
    const response = await sendEvent(events['permission'], true);
    console.log('Permission decision:', response?.decision || 'no response');

    await delay(500);
    await sendEvent(events['waiting']);
    await delay(2000);

    await sendEvent(events['end']);
    console.log('\n=== Session complete ===');
  } else if (events[type]) {
    const waitForResponse = type === 'permission' || type === 'ask';
    await sendEvent(events[type], waitForResponse);
  } else {
    console.error(`Unknown event type: ${type}`);
    console.error('Available: session-start, processing, tool, permission, waiting, ask, end, all');
    process.exit(1);
  }
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
