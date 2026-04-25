# LexLink Signaling Server

WebSocket signaling relay for LexLink. Handles WebRTC offer/answer exchange and ICE candidate forwarding only. It never sees message content.

## How It Works

1. Both peers connect via WebSocket and register with a peer ID
2. The initiator sends an SDP offer; the server forwards it to the target peer
3. The receiver sends an SDP answer; the server forwards it back
4. ICE candidates are exchanged the same way
5. Once the WebRTC DataChannel is established, the signaling server is out of the picture

## Running Locally

```bash
npm install
node server.js
```

Server runs on port 8080 by default. Override with the `PORT` environment variable.

## Production Nginx Setup

Use `nginx.conf` as a starting point. It proxies WebSocket connections and strips compression headers for Flutter compatibility.

```bash
sudo cp nginx.conf /etc/nginx/sites-available/lexlink-signaling
sudo ln -s /etc/nginx/sites-available/lexlink-signaling /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

## Notes

* The server performs no authentication — session security comes from the QR pairing flow in the app
* Hardcoded IPs in `signaling_config.dart` (`192.168.1.6`) are local dev defaults — update for your network
