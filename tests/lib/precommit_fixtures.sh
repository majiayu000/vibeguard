#!/usr/bin/env bash

make_stub_guard_dir() {
  local stub_root
  stub_root=$(mktemp -d)
  mkdir -p "$stub_root/guards/rust" "$stub_root/guards/typescript" "$stub_root/guards/go"

  cat >"$stub_root/guards/rust/check_unwrap_in_prod.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$stub_root/guards/typescript/check_console_residual.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$stub_root/guards/typescript/check_any_abuse.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$stub_root/guards/go/check_error_handling.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$stub_root/guards/go/check_goroutine_leak.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$stub_root/guards/go/check_defer_in_loop.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x \
    "$stub_root/guards/rust/check_unwrap_in_prod.sh" \
    "$stub_root/guards/typescript/check_console_residual.sh" \
    "$stub_root/guards/typescript/check_any_abuse.sh" \
    "$stub_root/guards/go/check_error_handling.sh" \
    "$stub_root/guards/go/check_goroutine_leak.sh" \
    "$stub_root/guards/go/check_defer_in_loop.sh"

  echo "$stub_root"
}
