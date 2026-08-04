# The remote transport: how one machine reaches another

Status: **decided, not built**. This document is the thing M8 was blocked on.
`docs/desktop-app.md` lists it under open risks; this replaces that entry.

M8 puts a second machine's workspaces in the same sidebar. That means a client
on one machine calling `tokenstat-host::dispatch` on another, and a terminal on
an iPad driving a process on a Mac. Everything below exists to answer one
question: what carries those bytes, and who can read them on the way.

## Why this needed a document and not a commit

The privacy claim is the product, and it is a specific claim:

> Everything happens on your machine. tokenstat reads your local logs, extracts
> counters, and discards the rest. Only aggregate numbers are eligible for sync.

Sync moves aggregate counts. The remote transport moves something else
entirely: terminal output, file contents, diffs, commit messages, the text of
whatever an agent is writing. That is the whole of somebody's work, not a row
of integers. If it goes through tokenstat.ai in a form tokenstat.ai can read,
the sentence above stops being true, and no amount of "we don't look" repairs
it, because the guarantee was a boundary rather than a promise.

So the decision is not a networking preference. It sets the outer limit of what
the hosted service is ever able to see.

## The decision

**Direct machine to machine, end to end encrypted, with the account acting only
as a key directory. No relay in the first version. If a relay is added later it
forwards ciphertext it cannot decrypt, and it is opt in per machine.**

Concretely, five parts.

### 1. Identity is a per-machine keypair, not an account token

The daemon generates an X25519 identity on first start and keeps the private
half in the data directory at mode 0600, beside the account token and stored
the same way. It never leaves the machine, is never synced, and is not derived
from the account.

The macOS Keychain was the obvious home for it and is deliberately not used, for
the reason `tokenstat-sync::keychain` already records: reaching the Keychain
from a command line puts the secret on argv, where the process table shows it to
everything running.

This matters because the account token already exists and reusing it would be
easier. It is the wrong shape: a token is a bearer credential the server issues
and can therefore mint, so a server that can mint tokens can impersonate a
machine to another machine. A keypair the server never sees cannot be forged by
the server, which is exactly the property being bought.

The public half is registered with the account as one more field on the machine
record the Machines screen already lists.

### 2. The account is a directory, and trust is pinned on first use

Machine A asks the account for machine B's public key. That is the only role
the hosted service plays in a connection, and it is the same role a phone book
plays.

A directory that hands out keys can hand out the wrong key, so the directory is
not trusted alone. The key is pinned the first time a pair connects, and the
Machines screen shows a short fingerprint for both ends so it can be compared
out of band. A changed key is refused with a message saying so, never
transparently accepted. The failure mode of a hostile or compromised directory
is therefore "it stopped working and said why", not "someone is reading your
terminal".

Machines can also be paired with no directory at all, by typing the other
machine's fingerprint. That path stays supported because it is what makes the
claim checkable: the product works with the hosted service switched off.

### 3. The wire is a Noise handshake with both ends authenticated by those keys

`Noise_XX_25519_ChaChaPoly_BLAKE2s`, via `snow`. Both ends present their static
key during the handshake and each checks the other against what it pinned.

This paragraph originally said TLS 1.3 with self-signed certificates, and the
change is worth recording rather than quietly making. X.509 exists to bind a
*name* to a key through a third party. There is no name here and no third party
by design, so a certificate would carry a key we already have, signed by nobody
we consult, wrapped in ASN.1 we would then have to parse back out to compare the
key we started with. Every one of those steps is somewhere to get it wrong, and
none of them adds a check. Noise authenticates raw static keys, which is exactly
what pinning means, and the handshake is the part of TLS 1.3 the rest of that
ceremony surrounds. Mechanism changed, guarantee unchanged.

A certificate authority stays out of it for the original reason: it is a third
party that can issue for a name it does not own, which is the thing being
designed out.

Because the static key *is* the identity, the machine key from part 1 is an
X25519 key. One key, pinned once, doing one job. A separate signing key
alongside it would mean two keys to compare and a way for them to disagree
about who a machine is.

Above the handshake the framing is the one that already exists: line-delimited
JSON,
`{"id", "method", "params"}` in, the same envelope back. `dispatch` is a
function over a request, so the remote transport is a third caller of it
alongside the C ABI and the unix socket. **No method is added to a transport.**

### 4. Discovery is the local network first, an address second

`_tokenstat._tcp` over Bonjour on the LAN, plus a manually entered host and
port for everything else. No hole punching, no UPnP, no rendezvous server in
version one. On the same network, which is where a Mac and an iPad usually are,
this needs no infrastructure at all and no packet leaves the building.

Off network, the honest answer for now is a VPN the user already runs. That is
a smaller product than "works anywhere" and it is a much smaller promise to
break.

### 5. Serving is off by default and every new peer is approved by a person

A daemon does not accept remote connections until the user turns that on for
that machine. The first connection from an unknown machine raises a prompt on
the serving side naming the machine and its fingerprint, and is refused until
someone accepts. Approval is per machine and revocable from the Machines
screen.

This follows the rule already written down for `gitwrite`: nothing happens that
the user did not ask for, and nothing happens on a timer. A remote client can
spawn processes and write files, so it is not a lesser permission than the
commit button, it is a larger one.

## What was rejected, and why

**A relay through tokenstat.ai as the primary path.** It is the easiest thing to
build and it works from anywhere, which is why it is tempting. It also puts
every keystroke and every file through servers pueev operates. Even done
honestly it converts a structural guarantee into a policy one, and policies
change with funding. It would also make the service a subpoena target for the
contents of people's work, which the current design simply is not.

**A relay that terminates the encryption.** Same objection, plus it reads worse in a
security review than no encryption at all, because it looks end to end and is
not.

**Reusing the account bearer token for machine authentication.** Covered above:
it makes the server able to impersonate any machine to any other, which is the
one thing the keypair exists to prevent.

**libp2p, or any general peer-to-peer stack.** A large dependency tree entering
what `apps/` links, straight into `check-app-licences.sh`, to solve a problem
that is two machines on one LAN.

**Waiting for a NAT traversal story before shipping M8.** The common case is a
Mac and an iPad on the same Wi-Fi. Shipping that is worth more than not
shipping the general case.

## What a later relay would have to be

Not ruled out, but constrained in advance so the constraint is not renegotiated
under deadline:

- It forwards an already-established end-to-end encrypted stream. Keys are
  never sent to it and it holds none.
- It is off unless the user turns it on, per machine, with the trade stated in
  the interface: connection metadata (which machines talked, when, how much)
  becomes visible to the service, contents do not.
- It stores nothing. A stream buffer in memory, no disk.
- The privacy wording gains a sentence about metadata on the day it ships, and
  not later.

## Where the code goes

```
crates/tokenstat-identity/ NEW  the machine key and the peer store. Decides
                                who may connect, so it is ON the
                                check-no-network guarded list: a crate that
                                could also open a connection is a place for
                                that decision to leak out of.
crates/tokenstat-remote/   NEW  the client and server halves of the transport.
                                Links snow. Allowed a network stack, so it is
                                deliberately NOT guarded.
crates/tokenstat-host/          gains a third transport over dispatch.
```

`tokenstat-core` gains nothing, directly or transitively, and
`scripts/check-no-network.sh` keeps saying so. That guard is the mechanism
behind the claim and this milestone is the one most likely to erode it, so the
rule stands unchanged: anything that makes a request lives above core.

## The order of work

1. The unix socket as the app's transport, with an in-process fast path. No
   network yet, and it is independent of everything above. This is what makes
   the client transport-agnostic, and it is the step where "local or remote" 
   stops being a branch in the UI layer.
2. Machine identity: keypair, a mode-0600 file, fingerprint, the public key on
   the account's machine record.
3. `tokenstat-remote` server and client, Noise with pinned keys, over the same
   dispatch.
4. Approval and the peer registry, plus the Machines screen showing peers,
   fingerprints, and revocation.
5. Bonjour discovery.
6. A second machine's workspaces in the sidebar, which is the milestone as
   `desktop-app.md` states it, and is mostly a matter of the workspace id
   carrying a machine with it.
