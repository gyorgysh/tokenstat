#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""A local, synthetic desktop chat fixture. No provider, account, or user files."""
import json
import socket
import socketserver
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'target/mac-chat-demo'
OUT.mkdir(parents=True, exist_ok=True)
SOCKET = OUT / 'demo.sock'
NOW = int(time.time() * 1000)
PROJECTS = [
    {'id': 'atlas', 'name': 'Atlas', 'path': '/Demo/Atlas', 'addedAtMs': NOW,
     'exists': True, 'git': {'isRepo': True, 'branch': 'feature/search', 'ahead': 0, 'behind': 0,
                           'files': [], 'added': 0, 'removed': 0, 'partial': False}},
    {'id': 'notebook', 'name': 'Notebook', 'path': '/Demo/Notebook', 'addedAtMs': NOW,
     'exists': True, 'git': {'isRepo': True, 'branch': 'main', 'ahead': 0, 'behind': 0,
                           'files': [], 'added': 0, 'removed': 0, 'partial': False}},
]
EXAMPLES = [
    ('review', 'Review the search changes', 'codex', 'atlas',
     'Review the search changes for edge cases. Check the tests and suggest the smallest safe fix.',
     [('Read', 'src/search.ts', 'Read the query normalization and result ordering.'),
      ('Read', 'tests/search.test.ts', 'Checked empty queries, accents, and stable ordering.'),
      ('Test', 'Search tests', '12 tests passed. Added coverage for whitespace-only queries.')],
     'The search behaves correctly for empty queries, accents, and equal-score results. I found one edge case and fixed it.\n\n### What changed\nA whitespace-only query now returns the same empty state as an empty query. Normalization happens before the length check.\n\n```ts\nconst query = input.trim();\nif (query.length === 0) return [];\n```\n\n### Validation\nAll **12 search tests pass**, including the new regression. Result ordering and keyboard navigation are unchanged.\n\nThe patch is ready to review.'),
    ('feature', 'Add keyboard navigation', 'claude', 'atlas',
     'Add keyboard navigation to search. Arrow keys should move through results, Enter should open the selected item, and Escape should close the panel.',
     [('Read', 'src/SearchPanel.tsx', 'Checked the focus and selection state.'),
      ('Edit', 'src/SearchPanel.tsx', 'Added arrow-key selection and Escape handling.'),
      ('Test', 'Keyboard navigation', '18 tests passed, including focus restoration.')],
     'Keyboard navigation is ready.\n\n- **↑ / ↓** move through the visible results.\n- **Enter** opens the selected item.\n- **Escape** closes search and restores focus to the button that opened it.\n\nThe first result is selected when results arrive. An empty result list keeps the search field focused, and moving past either end stays within the list.\n\nAll **18 tests pass**. I also checked that clicking a result still works and that typing never loses focus.'),
    ('plan', 'Plan the activity view', 'codex', 'atlas',
     'Plan a compact activity view that makes recent work easy to scan. Keep it accessible and avoid adding another dashboard.', [],
     'I would start with a simple list of recent work, grouped by day.\n\n### First version\n1. Show the project, a short summary, and the last update.\n2. Let each row open the related conversation or change.\n3. Add a project filter and an empty state that explains what appears here.\n\nUse semantic buttons, a clear focus ring, and a timestamp that screen readers can understand. Keep the first page small and load older entries only when requested.\n\nThis gives people a useful way back into their work without adding charts or a second navigation system.'),
    ('docs', 'Improve the getting-started guide', 'claude', 'notebook',
     'Rewrite the getting-started guide around the first five minutes. Use a neutral example project and clear next steps.', [],
     'The guide now follows the first five minutes: open a project, choose an agent, ask for a small change, and review the result.\n\nEach step has one action and a visible outcome. The example uses a fictional notes app, and the final section explains where to find files, changes, and conversation history.\n\nI checked the links and removed the setup details that belong in the reference guide.'),
]
CHATS, EVENTS = [], {}
for index, (identifier, title, backend, workspace, prompt, tools, answer) in enumerate(EXAMPLES):
    at = NOW - index * 3600000
    CHATS.append(dict(id=identifier, workspaceId=workspace, title=title, backend=backend,
                      systemPrompt='Read the relevant code, preserve existing work, and validate the result.',
                      mode='execute', autonomy='standard', allowedTools=[], allowedShellPrefixes=[],
                      budgetSeconds=0, createdAtMs=at - 600000, updatedAtMs=at,
                      lastMessageAtMs=at, lastMessageAuthor='agent', sendRevision=1,
                      running=False, model=None, effort='medium', branch='feature/search'))
    rows = [{'kind': 'user', 'text': prompt, 'atMs': at - 90000}]
    for number, (verb, name, output) in enumerate(tools):
        tool_id = f'{identifier}-tool-{number}'
        rows += [{'kind': 'agent', 'backend': backend, 'atMs': at - 60000 + number * 1000,
                  'event': {'kind': 'toolStart', 'callId': tool_id, 'verb': verb,
                            'target': name}},
                 {'kind': 'agent', 'backend': backend, 'atMs': at - 59000 + number * 1000,
                  'event': {'kind': 'toolEnd', 'callId': tool_id, 'verb': verb,
                            'target': name, 'detail': output, 'ok': True}}]
    rows += [{'kind': 'agent', 'backend': backend, 'atMs': at,
              'event': {'kind': 'text', 'delta': answer}},
             {'kind': 'agent', 'backend': backend, 'atMs': at,
              'event': {'kind': 'usage', 'input': 18420, 'output': 2160, 'cacheRead': 42000, 'cacheWrite': 0, 'costUsd': 0.13}},
             {'kind': 'agent', 'backend': backend, 'atMs': at,
              'event': {'kind': 'done', 'status': 'completed'}}]
    for seq, row in enumerate(rows): row['seq'] = seq + 1
    EVENTS[identifier] = rows

# A deterministic long transcript exercises paging and scroll restoration.
CHATS.append(dict(CHATS[0], id='history', title='Search implementation history', updatedAtMs=NOW - 14400000))
history = []
for turn in range(450):
    history += [dict(kind='user', text=f'Iteration {turn + 1}: check the next search edge case.', atMs=NOW - (450 - turn) * 10000),
                dict(kind='agent', backend='codex', atMs=NOW - (450 - turn) * 10000 + 1000,
                     event=dict(kind='text', delta=f'Iteration **{turn + 1}** is verified. The change preserves query normalization and stable ordering.\n\n```ts\nexpect(search("query")).toEqual(expected);\n```')),
                dict(kind='agent', backend='codex', atMs=NOW - (450 - turn) * 10000 + 2000,
                     event=dict(kind='done', status='completed'))]
for seq, row in enumerate(history): row['seq'] = seq + 1
EVENTS['history'] = history

def result(method, p):
    if method == 'protocol': return {'protocolVersion': '34', 'version': '1.6.1'}
    if method == 'info': return dict(protocolVersion='34', coreVersion='1.6.1', hasArchive=True,
                                     timezone='UTC', priceBookEffectiveFrom='2026-10-13', hasPrices=True)
    if method == 'app.updateCheck': return dict(current='1.6.1', latest='1.6.1', newer=False,
                                                htmlUrl='https://tokenstat.ai/download')
    if method == 'ping': return {'pong': True}
    if method == 'machine.identity': return {'key': 'ab' * 32, 'label': 'Demo Mac', 'fingerprint': 'DEMO-MAC'}
    if method == 'account.status': return {'signedIn': False, 'host': 'https://example.invalid', 'machines': []}
    if method == 'workspace.list': return PROJECTS
    if method == 'workspace.status': return next(row for row in PROJECTS if row['id'] == p.get('id'))
    if method == 'workspace.summary': return []
    if method == 'chat.list': return [row for row in CHATS if row['workspaceId'] == p.get('workspaceId')]
    if method == 'chat.recent': return CHATS
    if method == 'chat.get': return next(row for row in CHATS if row['id'] == p['id'])
    if method == 'chat.backends': return [dict(id=id, label=label, command=id, models=[], efforts=['low', 'medium', 'high'], installed=True, readiness='ready') for id, label in [('codex', 'Codex'), ('claude', 'Claude Code')]]
    if method == 'chat.personas': return {'personas': [], 'defaultId': ''}
    if method == 'chat.instructions': return {'brief': 'Read the relevant code, preserve existing work, and validate the result.', 'added': '', 'channel': 'turnPrefix'}
    if method == 'chat.eventPage':
        rows = EVENTS[p['id']]
        end = int(p.get('cursor') or len(rows))
        start = max(0, end - min(p.get('limit', 300), 120))
        return dict(events=rows[start:end], nextOffset=len(rows), tailCursor=str(len(rows)),
                    cursor=str(start) if start else None, hasEarlier=start > 0, start=start,
                    historyTrimmed=False, reset=False,
                    usage=dict(input=18420, output=2160, cacheRead=42000, cacheWrite=0, cost=0.13, turns=1) if p.get('includeUsage', True) else None)
    if method == 'chat.events':
        rows = EVENTS[p['id']]; start = min(int(p.get('offset', 0)), len(rows))
        return dict(events=rows[start:], nextOffset=len(rows), tailCursor=str(len(rows)), reset=False)
    if method in ['chat.approvals', 'pty.list', 'automation.list', 'workflow.list', 'launcher.catalog',
                  'usage.limits', 'peers.list', 'workspace.log', 'workspace.branches', 'automation.runs',
                  'automation.queue', 'automation.backends', 'workflow.runs', 'todo.list', 'local.models',
                  'ssh.host.list', 'ssh.key.list', 'ssh.folder.list', 'ssh.snippet.list', 'ssh.session.list']: return []
    if method == 'pulls.branch': return {'branch': 'feature/search', 'connected': False, 'pull': None}
    if method == 'host.policy': return {'alwaysOn': False, 'installed': False}
    if method == 'cache.get': return None
    if method == 'cache.list': return {'items': [], 'repaired': False}
    if method in ['chat.watching', 'cache.put']: return {'saved': True}
    raise ValueError('Demo fixture does not implement ' + method)

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            request = json.loads(line)
            try:
                response = {'ok': True, 'id': request.get('id'), 'result': result(request['method'], request.get('params') or {})}
            except Exception as error:
                print(request['method'], str(error), flush=True)
                response = {'ok': False, 'id': request.get('id'), 'error': {'code': 'demo_unavailable', 'message': str(error)}}
            self.wfile.write((json.dumps(response) + '\n').encode()); self.wfile.flush()

class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

if __name__ == '__main__':
    if SOCKET.exists():
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            try:
                probe.connect(str(SOCKET))
            except (ConnectionRefusedError, FileNotFoundError):
                SOCKET.unlink(missing_ok=True)
            else:
                raise SystemExit('The desktop fixture is already running.')
    with Server(str(SOCKET), Handler) as server:
        (OUT / 'fixture.json').write_text(json.dumps({'socket': str(SOCKET)}))
        print('Synthetic desktop fixture:', SOCKET, flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            SOCKET.unlink(missing_ok=True)
