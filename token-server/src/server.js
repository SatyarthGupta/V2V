import { buildApp } from './app.js';
import { loadConfig } from './config.js';

let config;
try {
  config = loadConfig();
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

// Listen on all interfaces so an iPhone on the same Wi-Fi can reach the Mac
// via http://<ComputerName>.local:<port> (docs/DECISIONS.md D-019, D-021).
buildApp({ config }).listen(config.port, '0.0.0.0', () => {
  console.log(`V2V token server listening on port ${config.port}`);
});
