const WebSocket = require('ws');
const http = require('http');
const url = require('url');
const uuid = require('uuid');

// Configuration
const PORT = process.env.PORT || 8080;
const HEARTBEAT_INTERVAL = 10000; // 10 seconds between pings
const CONNECTION_TIMEOUT = 30000; // 30 seconds of inactivity before timeout

// Create HTTP server
const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end(`
    <html>
      <head><title>WebRTC Signaling Server</title></head>
      <body>
        <h1>WebRTC Signaling Server</h1>
        <p>Status: Running</p>
        <p>Connected clients: ${Object.keys(clients).length}</p>
      </body>
    </html>
  `);
});

// Create WebSocket server
const wss = new WebSocket.Server({
  server: server,
  // Enable compression to handle Flutter's compressed frames
  perMessageDeflate: true
});
const clients = {};

// Log with timestamp
function log(message) {
  console.log(`[${new Date().toISOString()}] ${message}`);
}

// Enhanced error logging
function logError(message, error) {
  console.error(`[${new Date().toISOString()}] ERROR: ${message}`, error);
}

// Enhanced debug logging with categories
function logDebug(category, message) {
  console.log(`[${new Date().toISOString()}] [${category}] ${message}`);
}

// Sanitize message for logging (remove sensitive data)
function sanitizeMessageForLogging(message) {
  // Create a copy to avoid modifying the original
  const sanitized = { ...message };

  // Remove potentially sensitive data
  if (sanitized.data && typeof sanitized.data === 'object') {
    sanitized.data = { type: sanitized.data.type };
  }

  return sanitized;
}

// Handle connections
wss.on('connection', (ws, req) => {
  // Generate a unique connection ID
  const connectionId = uuid.v4().substring(0, 8);
  ws.connectionId = connectionId;
  ws.connectionTime = new Date();
  ws.lastActivity = new Date();

  // Log connection headers for debugging
  console.log(`[DEBUG][HEADERS] Connection ${connectionId} headers:`, req.headers);

  // Check for compression headers
  if (req.headers['sec-websocket-extensions']) {
    console.log(`[DEBUG][COMPRESSION] Client requested extensions: ${req.headers['sec-websocket-extensions']}`);
  }

  // Log connection details
  const ip = req.socket.remoteAddress;
  logDebug('CONNECT', `New connection established: ${connectionId} at ${new Date().toISOString()}`);
  logDebug('CONNECTION', `New connection from ${ip} (ID: ${connectionId})`);

  // Send welcome message
  const welcomeMessage = {
    type: 'welcome',
    message: 'Connected to LexLink Signaling Server',
    connectionId: connectionId,
    timestamp: Date.now()
  };

  try {
    ws.send(JSON.stringify(welcomeMessage));
    logDebug('WELCOME', `Sent welcome message to connection: ${connectionId}`);
  } catch (error) {
    logError(`Failed to send welcome message to ${connectionId}`, error);
  }

  // Set up ping interval
  const pingInterval = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'pong', timestamp: Date.now() }));
      logDebug('HEARTBEAT', `Sent pong to ${connectionId}`);
    }
  }, HEARTBEAT_INTERVAL);

  // Set up connection timeout checker
  const connectionTimeoutChecker = setInterval(() => {
    const now = Date.now();
    const inactiveTime = now - ws.lastActivity;

    // Log current activity status
    logDebug('TIMEOUT', `Connection ${connectionId} activity check - inactive for ${inactiveTime/1000}s, limit: ${CONNECTION_TIMEOUT/1000}s`);

    // Use a more generous timeout threshold (2x the original)
    if (inactiveTime > CONNECTION_TIMEOUT * 2) {
      logDebug('TIMEOUT', `Connection ${connectionId} timed out (no activity for ${inactiveTime/1000}s)`);
      clearInterval(pingInterval);
      clearInterval(connectionTimeoutChecker);

      // Send a warning message before terminating
      try {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({
            type: 'warning',
            message: 'Connection timeout due to inactivity',
            code: 'CONNECTION_TIMEOUT',
            timestamp: Date.now()
          }));

          // Give client a chance to respond before terminating
          setTimeout(() => {
            if (ws.readyState === WebSocket.OPEN) {
              ws.terminate();
            }
          }, 2000);
        } else {
          ws.terminate();
        }
      } catch (error) {
        logError('Error sending timeout warning', error);
        ws.terminate();
      }
    }
  }, HEARTBEAT_INTERVAL);

  // Handle ping messages
  function handlePing(message) {
    ws.isAlive = true;
    ws.lastActivity = Date.now();

    // Detailed ping reception logging
    logDebug('HEARTBEAT', `Received ping from ${connectionId}, timestamp: ${message.timestamp}, id: ${message.id || 'none'}`);
    logDebug('PING_FORMAT', `Raw ping message: ${JSON.stringify(message)}`);

    // Send pong response with high priority
    try {
      const pongMessage = {
        type: 'pong',
        timestamp: Date.now(),
        echo: message.timestamp || Date.now(),
        id: message.id || 'server-pong'
      };

      // Log the exact pong format being sent
      const pongJson = JSON.stringify(pongMessage);
      logDebug('PONG_FORMAT', `Sending pong: ${pongJson}`);

      // Ensure we send the response immediately
      process.nextTick(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(pongJson);
          logDebug('HEARTBEAT', `Sent pong response to ${connectionId}, echo: ${pongMessage.echo}, id: ${pongMessage.id}`);
        } else {
          logDebug('HEARTBEAT', `Cannot send pong - socket not open for ${connectionId}, state: ${ws.readyState}`);
        }
      });
    } catch (error) {
      logError(`Failed to send pong to ${connectionId}`, error);
    }
  }

  // Handle incoming messages
  ws.on('message', (message) => {
    try {
      const data = JSON.parse(message);
      ws.lastActivity = Date.now();

      // Handle ping messages for heartbeat
      if (data.type === 'ping') {
        handlePing(data);
        return;
      }

      logDebug('MESSAGE', `Received ${data.type} from ${connectionId}`);

      // Handle registration
      if (data.type === 'register') {
        clients[data.peerId] = ws;
        logDebug('REGISTER', `Client registered with ID: ${data.peerId}`);

        // Log active connections
        logDebug('CLIENTS', `Active clients: ${Object.keys(clients).join(', ')} (total: ${Object.keys(clients).length})`);
        return;
      }

      // Handle receiver registration
      if (data.type === 'register_receiver') {
        const receiverPeerId = data.peerId;
        const targetPeerId = data.to;

        // Register the receiver
        clients[receiverPeerId] = ws;
        logDebug('REGISTER_RECEIVER', `Receiver registered with ID: ${receiverPeerId}, targeting: ${targetPeerId}`);

        // Notify the target (initiator) about the receiver
        if (clients[targetPeerId]) {
          const notificationMessage = {
            type: 'register_receiver',
            peerId: receiverPeerId,
            from: receiverPeerId,
            to: targetPeerId
          };

          try {
            clients[targetPeerId].send(JSON.stringify(notificationMessage));
            logDebug('REGISTER_RECEIVER', `Notified initiator ${targetPeerId} about receiver ${receiverPeerId}`);
          } catch (error) {
            logError(`Failed to notify initiator ${targetPeerId}`, error);
          }
        } else {
          logDebug('REGISTER_RECEIVER', `Target client not found: ${targetPeerId}`);
        }

        // Log active connections
        logDebug('CLIENTS', `Active clients: ${Object.keys(clients).join(', ')} (total: ${Object.keys(clients).length})`);
        return;
      }

      // Handle signaling messages
      if (data.type === 'signal') {
        const to = data.to;

        if (clients[to]) {
          logDebug('SIGNAL', `Forwarding ${data.data.type} signal from ${connectionId} to ${to}`);

          try {
            clients[to].send(message.toString());
            logDebug('SIGNAL', `Successfully forwarded signal to ${to}`);
          } catch (error) {
            logError(`Failed to forward signal to ${to}`, error);

            // Notify sender of failure
            ws.send(JSON.stringify({
              type: 'error',
              message: `Failed to send signal to ${to}: ${error.message}`,
              code: 'SIGNAL_FORWARD_FAILED'
            }));
          }
        } else {
          logDebug('SIGNAL', `Target client not found: ${to}`);
          ws.send(JSON.stringify({
            type: 'error',
            message: `Target client not found: ${to}`,
            code: 'TARGET_NOT_FOUND'
          }));
        }

        return;
      }

      // Handle message type
      if (data.type === 'message') {
        // Handle Phase 2 message relay
        const to = data.to;

        logDebug('MESSAGE', `Relaying encrypted message from ${connectionId} to ${to}`);

        if (clients[to]) {
          // Forward the encrypted message to the target peer
          try {
            clients[to].send(JSON.stringify({
              type: 'message',
              from: connectionId,
              data: data.data, // This contains the encrypted message
              timestamp: data.timestamp || Date.now()
            }));
            logDebug('MESSAGE', `Message relayed successfully from ${connectionId} to ${to}`);

            // Send delivery confirmation back to sender
            ws.send(JSON.stringify({
              type: 'message_delivered',
              to: to,
              timestamp: data.timestamp
            }));
          } catch (error) {
            logError(`Failed to relay message to ${to}`, error);

            // Notify sender of failure
            ws.send(JSON.stringify({
              type: 'message_failed',
              error: `Failed to send message to ${to}: ${error.message}`,
              to: to,
              timestamp: data.timestamp,
              code: 'MESSAGE_RELAY_FAILED'
            }));
          }
        } else {
          logDebug('MESSAGE', `Target client not found for message: ${to}`);
          // Send error back to sender
          ws.send(JSON.stringify({
            type: 'message_failed',
            error: `Target client not found: ${to}`,
            to: to,
            timestamp: data.timestamp,
            code: 'TARGET_NOT_FOUND'
          }));
        }

        return;
      }

      // Log unknown message types
      logDebug('UNKNOWN', `Unknown message type: ${data.type}`);

    } catch (error) {
      logError('Error processing message', error);
    }
  });

  // Handle connection close
  ws.on('close', (code, reason) => {
    const closeReason = reason ? reason.toString() : 'No reason provided';
    logDebug('DISCONNECT', `Client ${connectionId} disconnected. Code: ${code}, Reason: ${closeReason}`);

    // Log connection duration if we have connection time
    if (ws.connectionTime) {
      const duration = Math.round((Date.now() - ws.connectionTime) / 1000);
      logDebug('CONNECTION', `Connection for ${connectionId} lasted ${duration} seconds`);
    }

    // Log last activity time if available
    if (ws.lastActivity) {
      const timeSinceLastActivity = Math.round((Date.now() - ws.lastActivity) / 1000);
      logDebug('CONNECTION', `Last activity from ${connectionId} was ${timeSinceLastActivity} seconds before disconnect`);
    }

    // Remove client from active connections
    clearInterval(pingInterval);
    clearInterval(connectionTimeoutChecker);
    delete clients[connectionId];
    logDebug('CLIENTS', `Remaining clients: ${Object.keys(clients).join(', ')} (total: ${Object.keys(clients).length})`);
  });

  // Handle errors
  ws.on('error', (error) => {
    logError(`WebSocket error for ${connectionId}`, error);
  });
});

// Log active connections every 10 seconds
setInterval(() => {
  console.log(`Active connections: ${Object.keys(clients).length}`);
  console.log('Connected clients:', Object.keys(clients));
}, 10000);

// Start server
server.listen(PORT, '0.0.0.0', () => {
  console.log(`Signaling server running on http://0.0.0.0:${PORT}`);
  console.log(`WebSocket endpoint at ws://0.0.0.0:${PORT}`);
  console.log(`Network endpoint at ws://192.168.1.6:${PORT}`);
});

// Handle server errors
server.on('error', (error) => {
  logError('Server error', error);
});

// Handle process termination
process.on('SIGINT', () => {
  log('Server shutting down...');
  wss.clients.forEach((client) => {
    client.close();
  });
  server.close(() => {
    log('Server stopped');
    process.exit(0);
  });
});