#!/bin/bash
# Go project: _ = doThing() discard error should be intercepted
tmp=$(mktemp -d)
# Note: There is no trap, the runner is responsible for cleaning up CWD
git -C "$tmp" init -q
mkdir -p "$tmp/bin" "$tmp/cmd"

cat >"$tmp/go.mod" <<'EOF'
module vg-precommit-go-test

go 1.22
EOF

cat >"$tmp/cmd/main.go" <<'EOF'
package main

func doThing() error { return nil }

func main() {
	_ = doThing()
}
EOF

cat >"$tmp/bin/go" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmp/bin/go"
git -C "$tmp" add go.mod cmd/main.go

echo "CWD=$tmp"
echo "EXTRA_PATH=$tmp/bin"