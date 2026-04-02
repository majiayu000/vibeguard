# Inspect mode context

> Activation method: load this profile at the beginning of the session, or use `/vibeguard:review`

## Behavior adjustment

- Read thoroughly before commenting, do not comment while reading.
- Severity first: Security > Logic > Quality > Performance
- Each finding must be accompanied by specific recommendations for remediation
- No modifications are made, only the review report is output

## Maintained constraints

- All seven levels of VibeGuard constraints are in effect
- All review criteria are referenced in the `rules/` directory

## Review Depth

- Read each file in full without skipping
- Track data flow across files
- Check boundary conditions and error paths
- Verify that tests cover critical paths
