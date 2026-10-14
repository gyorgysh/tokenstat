#!/usr/bin/env python3
"""Prepare local marketing conversations; preserve real transcripts and back up titles.

Run explicitly to rename existing chats and add inert, synthetic examples.
Never sends a prompt to a provider or changes workspace source files.
"""
import json
import socket
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = Path.home() / 'Library/Application Support/ai.tokenstat.tokenstat'
OUT = ROOT / 'target/product-photos'
OUT.mkdir(parents=True, exist_ok=True)

def call(method, params):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(30)
        connection.connect(str(DATA / 'host.sock'))
        connection.sendall((json.dumps(dict(id='product-photos', method=method, params=params)) + '\n').encode())
        response = json.loads(connection.makefile().readline())
        if not response.get('ok'):
            raise RuntimeError(response)
        return response['result']

TITLES = '''Explore the project
Plan the next release
Review agent workflows
Fix the website status page
Explore the demo workspace
Review the desktop architecture
Review recent website changes
Explore the website
Plan website improvements
Check file and shell tools
Verify file editing
Check workspace tools
Verify read and write operations
Test the editing workflow
Check file operations
Verify temporary workspace tools
Explore the website design
Check agent tool support
Verify shell and file tools
Check the edit workflow
Verify repeated edits
Research gaming news
Explore image attachments
Review the latest commits
Explore image generation
Review the 0.8.3 release
Update the iOS app
Plan desktop improvements
Review the codebase
Prepare the 0.9.1 release
Plan the iPad experience
Expand iPhone and iPad support
Fix the agent running state
Investigate account plan status
Polish the macOS experience
Improve onboarding
Review the latest website commit
Improve the product website
Review desktop changes
Redesign Git history
Explore the website project
Verify workspace tools
Check shell and image tools
Test the file editing flow
Improve the account experience
Review workspace changes
Plan the next desktop feature
Explore agent collaboration
Draft a desktop task
Plan a code review
Prepare repository changes
Migrate the website to Bun
Add Android scroll following
Explore desktop navigation
Plan an agent session
Check agent connectivity
Plan workspace improvements
Draft a feature request
Explore the chat experience
Review uncommitted changes
Check the chat connection
Explore the desktop project
Fix the mobile homepage
Refresh the model catalog
Plan the next release
Plan website maintenance
Update project dependencies
Check agent availability
Review hub verification
Explore the workspace
Draft an implementation task
Plan a review session
Explore the game project
Try agent questions
Plan a desktop feature
Draft a code review
Explore chat settings
Plan the next task
Draft a project question
Plan UI improvements
Explore workspace navigation
Check conversation delivery
Verify agent steering
Check Codex steering
Draft a feature plan
Plan implementation steps
Check active agent sessions
Check the agent connection
Design desktop and mobile motion
Plan the desktop roadmap
Add sign-in options
Explore multiple-choice questions
Plan a tool workflow
Draft a desktop review
Verify shell and editing tools
Test multi-step file editing
Check file tool support
Review software licensing
Verify the complete tool workflow
Plan the next desktop release
Add Haiku to the model catalog
Upgrade Bun and review changes
Draft a project plan
Plan release validation
Validate the 1.5.0 release
Verify automatic agent routing
Check conversation connectivity
Plan the next implementation'''.splitlines()

EXAMPLES = [
 ('review', 'Review search edge cases', 'codex', 'tokenstat',
  'Review the search changes for edge cases. Check query normalization, result ordering, and the regression tests.',
  [('Read','src/search.ts','Read query normalization and stable result ordering.'),
   ('Read','tests/search.test.ts','Checked empty queries, accents, and equal-score results.'),
   ('Edit','src/search.ts','Moved trimming before the empty-query guard.'),
   ('Shell','bun test tests/search.test.ts','12 passed · 0 failed · 84 ms')],
  'Found and fixed one edge case: a whitespace-only query skipped the empty state.\n\n### Small, focused patch\n```ts\nconst query = input.trim();\nif (!query) return [];\n\nreturn rankResults(query, items);\n```\n\n**12 tests pass**, including the new regression. Accented queries and equal-score ordering still behave correctly.\n\nThe patch is ready to review.'),
 ('feature','Add keyboard navigation','claude','tokenstat',
  'Add keyboard navigation to search: arrow keys to select, Enter to open, and Escape to close. Restore focus when the panel closes.',
  [('Read','src/SearchPanel.tsx','Checked selection state and focus ownership.'),
   ('Edit','src/SearchPanel.tsx','Added ArrowUp, ArrowDown, Enter, and Escape handling.'),
   ('Edit','tests/search-keyboard.test.tsx','Added focus restoration and empty-list coverage.'),
   ('Shell','bun test tests/search-keyboard.test.tsx','18 passed · 0 failed · 126 ms')],
  'Keyboard navigation is ready.\n\n- **↑ / ↓** move through results.\n- **Enter** opens the selected item.\n- **Escape** closes search and restores focus.\n\nThe first result is selected when results arrive. Empty results keep the input focused, and selection stays within the list.\n\n**18 tests pass**, including keyboard selection, pointer interaction, and focus restoration.'),
 ('bug','Fix reconnect after sleep','codex','tokenstat',
  'The project chat occasionally stays disconnected after the Mac wakes. Reproduce it and fix the reconnect path.',
  [('Read','Sources/Bridge/SocketTransport.swift','Traced the connection lifecycle after wake.'),
   ('Edit','Sources/Bridge/SocketTransport.swift','Retry the first request after a stale socket closes.'),
   ('Shell','swift test --filter SocketTransportTests','9 passed · 0 failed')],
  'The reconnect path now recovers after wake. A stale socket is closed before the first request is retried.\n\nThe draft stays in place while reconnecting, and sending resumes once the host responds.\n\n**Verified:** wake/reconnect, a host restart, and a request interrupted during sleep. All **9 transport tests pass**.'),
 ('plan','Plan the activity view','codex','tokenstat',
  'Plan a compact activity view that makes recent work easy to scan. Keep the first version accessible and focused.',[],
  'Start with a short list of recent work, grouped by day.\n\n### First version\n1. Show the project, a one-line summary, and the last update.\n2. Open the related conversation or change from each row.\n3. Add a project filter and a useful empty state.\n\nUse clear focus rings, semantic buttons, and readable timestamps. Load older entries when requested.\n\nI would ship the list first, then use feedback to decide which filters deserve a place.'),
 ('refactor','Simplify the API client','claude','tokenstat',
  'Consolidate the duplicated retry logic in the API client. Keep the public interface unchanged.',
  [('Read','src/api/client.ts','Compared retry behavior across request methods.'),
   ('Edit','src/api/retry.ts','Extracted one bounded retry helper with cancellation support.'),
   ('Shell','bun test tests/api','24 passed · 0 failed')],
  'The API client now uses one retry helper for all request methods.\n\nRetries use a bounded backoff and stop immediately on cancellation. Authentication and validation errors return without a retry.\n\nThe public methods and response types are unchanged. **24 tests pass**, including timeout and cancellation coverage.'),
 ('tests','Cover offline chat recovery','codex','tokenstat',
  'Add regression coverage for a draft created offline, then sent after the connection recovers.',
  [('Read','tests/chat-recovery.test.ts','Checked the existing recovery fixtures.'),
   ('Edit','tests/chat-recovery.test.ts','Added offline draft and reconnect cases.'),
   ('Shell','bun test tests/chat-recovery.test.ts','7 passed · 0 failed')],
  'Added regression coverage for offline chat recovery.\n\nThe tests verify that the draft survives a connection loss, sends once after recovery, and stays available if the retry fails.\n\nAll **7 recovery tests pass**.'),
 ('docs','Polish the getting-started guide','claude','www',
  'Rewrite the getting-started guide around the first five minutes: open a project, ask for a change, and review the result.',
  [('Read','content/help/getting-started.md','Checked the current setup steps.'),
   ('Edit','content/help/getting-started.md','Reorganized the guide around the first project.'),
   ('Shell','bun run lint-md','Markdown and internal links verified.')],
  'The guide now follows the first five minutes: **open a project → choose an agent → ask for a small change → review the result**.\n\nEach step has one action and a visible outcome. The example uses a small notes app.\n\nChecked the internal links and moved reference details into the setup guide.'),
 ('web','Improve mobile navigation','codex','www',
  'Make the mobile navigation easier to scan. Keep the current links and make keyboard focus visible.',
  [('Read','web/Header.jsx','Reviewed menu structure and focus behavior.'),
   ('Edit','web/Header.jsx','Grouped product links and improved keyboard focus.'),
   ('Shell','bun run check-action-icons','Navigation icons and labels verified.')],
  'Mobile navigation now groups product links together and shows a clear focus ring.\n\nThe menu closes after a selection and returns focus to its trigger on Escape. Existing URLs are preserved.\n\nChecked the narrow layout, keyboard navigation, and action labels.'),
]

def main():
    chats = json.loads((DATA / 'chat/conversations.json').read_text())['conversations']
    backup = OUT / 'original-chat-titles.json'
    if not backup.exists():
        backup.write_text(json.dumps([dict(id=x['id'], title=x['title']) for x in chats], indent=2))
    originals = json.loads(backup.read_text())
    if len(originals) != len(TITLES):
        raise SystemExit('Original chat count changed; review title mapping before proceeding.')
    for old, title in zip(originals, TITLES):
        current = next((x for x in chats if x['id'] == old['id']), None)
        if current and current['title'] != title:
            call('chat.update', dict(id=old['id'], title=title))
    manifest = OUT / 'demo-chats.json'
    demos = json.loads(manifest.read_text()) if manifest.exists() else {}
    for key, title, backend, project, prompt, steps, answer in reversed(EXAMPLES):
        if key in demos:
            continue
        workspace = str(ROOT if project == 'tokenstat' else ROOT.parent / project)
        chat = call('chat.create',dict(workspaceId=workspace, backend=backend,
                    title=title, model='gpt-6.1-sol' if backend=='codex' else 'claude-sonnet-4-6',
                    effort='high', personaId='', mode='plan' if key=='plan' else 'execute', autonomy='standard'))
        identifier = chat['id']; at = int(time.time() * 1000)
        rows = [dict(kind='user',text=prompt,at_ms=at-90000)]
        for number, (verb,target,detail) in enumerate(steps):
            call_id = f'demo-{key}-{number}'
            rows += [dict(kind='agent',backend=backend,at_ms=at-70000+number*6000,
                          event=dict(kind='toolStart',call_id=call_id,verb=verb,target=target)),
                     dict(kind='agent',backend=backend,at_ms=at-67000+number*6000,
                          event=dict(kind='toolEnd',call_id=call_id,verb=verb,target=target,detail=detail,ok=True))]
        rows += [dict(kind='agent',backend=backend,at_ms=at-1000,event=dict(kind='text',delta=answer)),
                 dict(kind='agent',backend=backend,at_ms=at,event=dict(kind='usage',input=18420,output=2160,cache_read=42000,cache_write=0,cost_usd=0.13)),
                 dict(kind='agent',backend=backend,at_ms=at,event=dict(kind='done',status='ok',exit_code=0))]
        folder=DATA/'chat'/identifier;folder.mkdir(exist_ok=True)
        offset=0
        with (folder/'events.ndjson').open('wb') as file:
            for row in rows:
                row['seq']=offset;line=(json.dumps(row)+'\n').encode();file.write(line);offset+=len(line)
        # Refreshes the host's index after adding the inert transcript.
        call('chat.update',dict(id=identifier,title=title))
        demos[key]=dict(id=identifier,title=title,workspace=workspace,synthetic=True)
        manifest.write_text(json.dumps(demos,indent=2))
    print(f'Renamed {len(originals)} chats; prepared {len(demos)} synthetic conversations.')
    print(f'Original titles: {backup}')
    print(f'Demo manifest: {manifest}')

if __name__ == '__main__': main()
