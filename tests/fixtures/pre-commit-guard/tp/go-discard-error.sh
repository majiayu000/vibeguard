#!/bin/bash
# Go 项目：_ = doThing() 丢弃 error 应被拦截
tmp=$(mktemp -d)
# 注意：不设 trap，runner 负责清理 CWD
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