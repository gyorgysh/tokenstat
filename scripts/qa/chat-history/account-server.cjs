// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Loopback-only adapter for the native fixture's in-memory account service.
const http = require('node:http');

async function createAccountServer(sync, account) {
  const server = http.createServer(async (request, response) => {
    const send = (status, body) => {
      response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify(body));
    };
    try {
      const route = `${request.method} ${request.url}`;
      if (route === 'GET /api/v1/schema') {
        return send(200, { min_v: sync.SYNC_V_MIN, max_v: sync.SYNC_V_MAX });
      }
      const chunks = [];
      let bytes = 0;
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > 64 * 1024) return send(413, { error: 'too_large' });
        chunks.push(chunk);
      }
      const input = bytes ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
      if (route === 'POST /api/v1/device/redeem') {
        const result = sync.redeemPairingCode(input.code, input.machine);
        return send(result.status, result.body);
      }
      const auth = sync.authToken(request);
      if (auth.error) return send(auth.error.status, auth.error);
      if (auth.user.id !== account) return send(403, { error: 'wrong_fixture_account' });
      let result;
      switch (route) {
        case 'GET /api/v1/me': return send(200, sync.me(account));
        case 'PUT /api/v1/machines/me':
          result = sync.registerMachine(account, input.machine, {
            publicIdentity: input.public_identity, label: input.label,
            kind: input.kind, platform: input.platform,
          });
          break;
        case 'POST /api/v1/tunnel/token':
          result = sync.mintTunnelToken(account, input.machine);
          break;
        default: return send(404, { error: 'fixture_route_unavailable' });
      }
      send(result.status, result.body);
    } catch {
      if (!response.headersSent) send(400, { error: 'invalid_fixture_request' });
      else response.destroy();
    }
  });
  server.requestTimeout = 10000;
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    async close() {
      await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
    },
  };
}
module.exports = { createAccountServer };
