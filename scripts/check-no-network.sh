#!/usr/bin/env bash
#
# Fail if a crate that must not reach the network has grown a way to.
#
# This is the mechanism behind the product's central claim: the code that reads
# your session logs has no way to send them anywhere. That is a structural
# guarantee rather than a promise about behaviour, and it is only structural if
# something checks. Until this script existed, CLAUDE.md said CI enforced the
# rule and CI did not.
#
# Checks the whole dependency tree, not just direct dependencies, because a
# transitive HTTP client is exactly as capable as a direct one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Crates the guarantee covers. `tokenstat-sync` is deliberately absent: it is
# the one crate allowed to link a network stack. `tokenstat-ffi` is absent too,
# because the app needs account and sync, and it depends on `tokenstat-sync`
# on purpose.
# tokenstat-identity is here because it decides *who may connect*. A crate that
# could also open the connection would be a place for that decision to leak out
# of, and the remote transport that does open one lives above it.
GUARDED=(tokenstat-core tokenstat-mcp tokenstat-highlight tokenstat-identity)

# Anything that can open a socket or speak HTTP. Matched against crate names in
# the resolved tree.
FORBIDDEN='^(reqwest|hyper|hyper-util|h2|tokio|async-std|smol|mio|socket2|curl|curl-sys|ureq|attohttpc|isahc|surf|native-tls|openssl|rustls|tokio-rustls|quinn|tonic|ws|tungstenite|reqwest-middleware)$'

failed=0

for crate in "${GUARDED[@]}"; do
    # `--edges normal` drops dev-dependencies and build-dependencies. A test
    # helper that downloads a fixture cannot leak a user's logs from a shipped
    # binary, and build scripts do not end up in one either.
    tree="$(cargo tree --package "$crate" --edges normal --prefix none --no-dedupe 2>/dev/null \
        | awk '{print $1}' | sort -u)"

    if [ -z "$tree" ]; then
        echo "error: could not resolve the dependency tree for $crate" >&2
        exit 2
    fi

    hits="$(printf '%s\n' "$tree" | grep -E "$FORBIDDEN" || true)"
    if [ -n "$hits" ]; then
        echo "error: $crate can reach the network through:" >&2
        printf '  %s\n' $hits >&2
        failed=1
    else
        echo "ok: $crate has no network dependency"
    fi
done

if [ "$failed" -ne 0 ]; then
    cat >&2 <<'MSG'

This is not a lint. A crate on this list reading your logs must have no way to
send them anywhere, which is what makes the privacy claim structural rather
than a promise.

Anything that makes a request belongs in `tokenstat-sync`. If a guarded crate
needs a result that only the network can provide, pass it in from a caller that
is allowed to fetch it.
MSG
    exit 1
fi
