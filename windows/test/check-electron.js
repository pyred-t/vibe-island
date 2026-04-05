// Quick test to check if electron module loads properly
try {
  const electron = require('electron');
  console.log('electron module loaded:', typeof electron);
  console.log('app:', typeof electron.app);
  console.log('BrowserWindow:', typeof electron.BrowserWindow);
  if (electron.app) {
    console.log('SUCCESS: Electron loaded correctly');
  } else {
    console.log('electron is path:', electron);
  }
} catch (err) {
  console.log('ERROR:', err.message);
}
