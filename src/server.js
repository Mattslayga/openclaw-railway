/**
 * OpenClaw Railway Health Check Server
 * Minimal server for Railway health checks only.
 */

import http from "node:http";
import { execSync } from "node:child_process";

const PORT = Number.parseInt(process.env.PORT ?? "8080", 10);
const PLAIN_HEADERS = {
  "Content-Type": "text/plain",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
};

function isGatewayRunning() {
  try {
    execSync("pgrep -f 'openclaw gateway run|openclaw-gateway'", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function sendPlain(res, status, body) {
  res.writeHead(status, PLAIN_HEADERS);
  res.end(body);
}

// fallow-ignore-next-line complexity
const server = http.createServer((req, res) => {
  // Health check - verify gateway is actually running
  if (req.url === "/healthz" && req.method === "GET") {
    const gatewayUp = isGatewayRunning();
    sendPlain(res, gatewayUp ? 200 : 503, gatewayUp ? "OK" : "GATEWAY_DOWN");
    return;
  }

  // Everything else - minimal info (no product name leak)
  sendPlain(res, 200, "OK");
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[openclaw] Health server on :${PORT}`);
});
