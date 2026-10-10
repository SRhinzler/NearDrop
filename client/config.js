// Override these values before deploying. Settings in the UI override signalingUrl.
window.NEARDROP_CONFIG = {
  signalingUrl: `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host || 'localhost:8080'}/ws`,
  // Add authenticated TURN servers for peers behind restrictive networks.
  iceServers: [],
  maxIncomingBytes: 256 * 1024 * 1024,
};
