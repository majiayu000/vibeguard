# Safe Bash Guard Pack

Safe Bash is the first Guard Pack adoption slice. It packages the existing
`pre-bash-guard` source of truth into a small, target-oriented contract for
dangerous Bash command interception.

This pack does not change VibeGuard Core. It only declares which existing hook,
rule, manifest, and runtime files a selective installer would use.

## Commands

```bash
bash setup.sh packs explain safe-bash
bash setup.sh packs receipt safe-bash --target claude-code
bash setup.sh packs audit safe-bash --target claude-code
bash setup.sh install --target claude-code --pack safe-bash --dry-run
bash setup.sh install --target claude-code --pack safe-bash
bash setup.sh packs uninstall safe-bash --target claude-code
bash setup.sh demo safe-bash
```

Non-dry-run install is a registration step only. It first requires audit READY,
then writes `~/.vibeguard/guard-packs/safe-bash/<target>/receipt.json`; it
does not edit agent hook/config files.

The demo is side-effect free. It prints a deterministic transcript and never
executes the blocked example command.
