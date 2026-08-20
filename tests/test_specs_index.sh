#!/usr/bin/env bash
# Regression tests for the archived specs-index policy.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
validator="$repo_dir/scripts/ci/validate-specs-index.sh"
tmp_dir="$(mktemp -d)"
pass=0
fail=0
total=0

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

green() { printf '\033[32m  PASS: %s\033[0m\n' "$1"; }
red() { printf '\033[31m  FAIL: %s\033[0m\n' "$1"; }

assert_exit() {
  local description="$1" expected="$2"
  shift 2
  local actual=0
  total=$((total + 1))
  "$@" >/dev/null 2>&1 || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    green "$description"
    pass=$((pass + 1))
  else
    red "$description (expected $expected, got $actual)"
    fail=$((fail + 1))
  fi
}

assert_stderr_contains() {
  local description="$1" expected="$2"
  shift 2
  local output
  total=$((total + 1))
  output="$("$@" 2>&1 >/dev/null || true)"
  if [[ "$output" == *"$expected"* ]]; then
    green "$description"
    pass=$((pass + 1))
  else
    red "$description (missing: $expected)"
    fail=$((fail + 1))
  fi
}

make_fixture() {
  local name="$1"
  local fixture="$tmp_dir/$name"
  mkdir -p "$fixture"
  printf '%s' "$fixture"
}

write_valid_index() {
  local destination="$1"
  printf '%s\n' \
    '# Specs' \
    '' \
    '## Archived GitHub Packet Index' \
    '' \
    '| Issue | Outcome |' \
    '|---|---|' \
    '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Fixture outcome |' \
    > "$destination/README.md"
  printf '%s\n' 'GH100' > "$destination/archived-issues.txt"
}

printf '\n=== specs-index archive policy ===\n'

valid="$(make_fixture valid)"
write_valid_index "$valid"
assert_exit "archive index without packet directories passes" 0 bash "$validator" "$valid"

missing_table="$(make_fixture missing-table)"
printf '%s\n' \
  '# Specs' \
  '' \
  '## Archived GitHub Packet Index' \
  '' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Fixture outcome |' \
  > "$missing_table/README.md"
printf '%s\n' 'GH100' > "$missing_table/archived-issues.txt"
assert_exit "archive outcomes without a GFM table fail" 1 bash "$validator" "$missing_table"
assert_stderr_contains "missing table structure is explicit" "must be inside a GFM table" bash "$validator" "$missing_table"

over_indented_table="$(make_fixture over-indented-table)"
printf '%s\n' \
  '# Specs' \
  '' \
  '## Archived GitHub Packet Index' \
  '' \
  '    | Issue | Outcome |' \
  '    |---|---|' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Fixture outcome |' \
  > "$over_indented_table/README.md"
printf '%s\n' 'GH100' > "$over_indented_table/archived-issues.txt"
assert_exit "four-space-indented archive table fails" 1 bash "$validator" "$over_indented_table"
assert_stderr_contains "over-indented table structure is explicit" "must be inside a GFM table" bash "$validator" "$over_indented_table"

restored="$(make_fixture restored)"
write_valid_index "$restored"
mkdir -p "$restored/GH100"
assert_exit "restored packet directory fails" 1 bash "$validator" "$restored"
assert_stderr_contains "restored packet failure names path" "docs/specs/GH100" bash "$validator" "$restored"

symlinked="$(make_fixture symlinked)"
write_valid_index "$symlinked"
mkdir -p "$symlinked/packet-content"
ln -s packet-content "$symlinked/GH100"
assert_exit "symlinked packet path fails" 1 bash "$validator" "$symlinked"
assert_stderr_contains "symlinked packet failure names path" "docs/specs/GH100" bash "$validator" "$symlinked"

legacy="$(make_fixture legacy)"
write_valid_index "$legacy"
printf '%s\n' '| `GH101/` | Implemented reference | Legacy path row |' >> "$legacy/README.md"
assert_exit "legacy live-directory row fails" 1 bash "$validator" "$legacy"
assert_stderr_contains "legacy row explains issue-link format" "must be issue links" bash "$validator" "$legacy"

duplicate="$(make_fixture duplicate)"
write_valid_index "$duplicate"
printf '%s\n' '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Duplicate |' >> "$duplicate/README.md"
assert_exit "duplicate issue row fails" 1 bash "$validator" "$duplicate"
assert_stderr_contains "duplicate failure names issue" "GH100" bash "$validator" "$duplicate"

mismatch="$(make_fixture mismatch)"
write_valid_index "$mismatch"
printf '%s\n' '| [GH101](https://github.com/majiayu000/vibeguard/issues/102) | Mismatch |' >> "$mismatch/README.md"
assert_exit "issue label and URL mismatch fails" 1 bash "$validator" "$mismatch"
assert_stderr_contains "mismatch failure is explicit" "label/URL mismatch" bash "$validator" "$mismatch"

blank_outcome="$(make_fixture blank-outcome)"
write_valid_index "$blank_outcome"
sed -i.bak 's/Fixture outcome/   /' "$blank_outcome/README.md"
rm "$blank_outcome/README.md.bak"
assert_exit "blank archived outcome fails" 1 bash "$validator" "$blank_outcome"
assert_stderr_contains "blank outcome is reported as malformed" "malformed archived packet row" bash "$validator" "$blank_outcome"

extra_cell_outcome="$(make_fixture extra-cell-outcome)"
write_valid_index "$extra_cell_outcome"
sed -i.bak 's/Fixture outcome/   | Hidden evidence/' "$extra_cell_outcome/README.md"
rm "$extra_cell_outcome/README.md.bak"
assert_exit "third cell cannot hide a blank archived outcome" 1 bash "$validator" "$extra_cell_outcome"
assert_stderr_contains "extra-cell outcome is reported as malformed" "malformed archived packet row" bash "$validator" "$extra_cell_outcome"

even_backslash_pipe="$(make_fixture even-backslash-pipe)"
write_valid_index "$even_backslash_pipe"
sed -i.bak 's/Fixture outcome/\\\\| Hidden evidence/' "$even_backslash_pipe/README.md"
rm "$even_backslash_pipe/README.md.bak"
assert_exit "pipe after paired backslashes remains a cell delimiter" 1 bash "$validator" "$even_backslash_pipe"
assert_stderr_contains "paired-backslash extra cell is malformed" "malformed archived packet row" bash "$validator" "$even_backslash_pipe"

compact_spacing="$(make_fixture compact-spacing)"
write_valid_index "$compact_spacing"
printf '%s\n' '|[GH999](https://github.com/majiayu000/vibeguard/issues/999)| Unexpected |' >> "$compact_spacing/README.md"
assert_exit "GH row without canonical pipe spacing fails" 1 bash "$validator" "$compact_spacing"
assert_stderr_contains "compact-spacing row is reported as malformed" "malformed archived packet row" bash "$validator" "$compact_spacing"

formatted_label="$(make_fixture formatted-label)"
write_valid_index "$formatted_label"
printf '%s\n' '| [**GH999**](https://github.com/majiayu000/vibeguard/issues/999) | Unexpected |' >> "$formatted_label/README.md"
assert_exit "formatted GH label cannot bypass archive validation" 1 bash "$validator" "$formatted_label"
assert_stderr_contains "formatted GH label is reported as malformed" "malformed archived packet row" bash "$validator" "$formatted_label"

entity_relative_link="$(make_fixture entity-relative-link)"
write_valid_index "$entity_relative_link"
printf '%s\n' '| [&#71;&#72;999](/majiayu000/vibeguard/issues/999) | Unexpected |' >> "$entity_relative_link/README.md"
assert_exit "entity-encoded relative issue row cannot bypass validation" 1 bash "$validator" "$entity_relative_link"
assert_stderr_contains "entity-relative row is reported as malformed" "malformed archived packet row" bash "$validator" "$entity_relative_link"

secondary_entity_table="$(make_fixture secondary-entity-table)"
write_valid_index "$secondary_entity_table"
printf '%s\n' \
  '' \
  '| Label | Outcome |' \
  '|---|---|' \
  '| [&#71;&#72;999](/majiayu000/vibeguard/issues/999) | Unexpected |' \
  >> "$secondary_entity_table/README.md"
assert_exit "secondary archive-section table cannot hide encoded issue rows" 1 bash "$validator" "$secondary_entity_table"
assert_stderr_contains "secondary table is rejected structurally" "expected exactly one GFM table" bash "$validator" "$secondary_entity_table"

zero_padded_row="$(make_fixture zero-padded-row)"
write_valid_index "$zero_padded_row"
printf '%s\n' '| [GH0100](https://github.com/majiayu000/vibeguard/issues/0100) | Duplicate identity |' >> "$zero_padded_row/README.md"
printf '%s\n' 'GH100' 'GH0100' > "$zero_padded_row/archived-issues.txt"
assert_exit "zero-padded issue row is not canonical" 1 bash "$validator" "$zero_padded_row"
assert_stderr_contains "zero-padded issue row is reported as malformed" "malformed archived packet row" bash "$validator" "$zero_padded_row"

zero_padded_inventory="$(make_fixture zero-padded-inventory)"
write_valid_index "$zero_padded_inventory"
printf '%s\n' 'GH0100' > "$zero_padded_inventory/archived-issues.txt"
assert_exit "zero-padded inventory ID is not canonical" 1 bash "$validator" "$zero_padded_inventory"
assert_stderr_contains "zero-padded inventory ID is reported as malformed" "malformed archive inventory row" bash "$validator" "$zero_padded_inventory"

blockquoted_row="$(make_fixture blockquoted-row)"
write_valid_index "$blockquoted_row"
printf '%s\n' '> | Issue | Outcome |' '> |---|---|' '> | [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Unexpected |' >> "$blockquoted_row/README.md"
assert_exit "blockquoted GH row cannot bypass archive validation" 1 bash "$validator" "$blockquoted_row"
assert_stderr_contains "blockquoted row failure names archived packet row" "archived packet row" bash "$validator" "$blockquoted_row"

incomplete="$(make_fixture incomplete)"
write_valid_index "$incomplete"
printf '%s\n' 'GH100' 'GH101' > "$incomplete/archived-issues.txt"
assert_exit "archive inventory requires every index row" 1 bash "$validator" "$incomplete"
assert_stderr_contains "incomplete index names omitted issue" "missing index rows: GH101" bash "$validator" "$incomplete"

history_repo="$tmp_dir/history-repo"
history_specs="$history_repo/docs/specs"
mkdir -p "$history_specs/GH100" "$history_specs/GH101"
git -C "$history_repo" init -q
git -C "$history_repo" config user.email fixture@example.com
git -C "$history_repo" config user.name Fixture
printf '%s\n' 'packet' > "$history_specs/GH100/outcome.md"
printf '%s\n' 'packet' > "$history_specs/GH101/outcome.md"
git -C "$history_repo" add docs/specs
git -C "$history_repo" commit -q -m 'Add packet history'
rm -rf "$history_specs/GH100" "$history_specs/GH101"
write_valid_index "$history_specs"
printf '%s\n' \
  '| [GH101](https://github.com/majiayu000/vibeguard/issues/101) | Second outcome |' \
  >> "$history_specs/README.md"
printf '%s\n' 'GH100' 'GH101' > "$history_specs/archived-issues.txt"
git -C "$history_repo" add -A
git -C "$history_repo" commit -q -m 'Archive packets'
sed -i.bak '/GH100/d' "$history_specs/README.md"
rm "$history_specs/README.md.bak"
printf '%s\n' 'GH101' > "$history_specs/archived-issues.txt"
assert_exit "coordinated archive deletion fails against Git history" 1 bash "$validator" "$history_specs"
assert_stderr_contains "history-backed failure names erased issue" "append-only relative to Git history: GH100" bash "$validator" "$history_specs"

scoped="$(make_fixture scoped)"
write_valid_index "$scoped"
printf '%s\n' '## Example Elsewhere' '| [GH999](not-an-issue-link) | Example only |' >> "$scoped/README.md"
assert_exit "GH-like rows outside archive section are ignored" 0 bash "$validator" "$scoped"

h1_boundary="$(make_fixture h1-boundary)"
write_valid_index "$h1_boundary"
printf '%s\n' 'GH100' 'GH101' > "$h1_boundary/archived-issues.txt"
printf '%s\n' '# New Document Section' '| [GH101](https://github.com/majiayu000/vibeguard/issues/101) | Outside |' >> "$h1_boundary/README.md"
assert_exit "visible H1 terminates archive section" 1 bash "$validator" "$h1_boundary"
assert_stderr_contains "H1 boundary keeps outside row out" "missing index rows: GH101" bash "$validator" "$h1_boundary"

setext_boundary="$(make_fixture setext-boundary)"
write_valid_index "$setext_boundary"
printf '%s\n' 'GH100' 'GH101' > "$setext_boundary/archived-issues.txt"
printf '%s\n' 'Other Section' '-------------' '| [GH101](https://github.com/majiayu000/vibeguard/issues/101) | Outside |' >> "$setext_boundary/README.md"
assert_exit "visible Setext H2 terminates archive section" 1 bash "$validator" "$setext_boundary"
assert_stderr_contains "Setext boundary keeps outside row out" "missing index rows: GH101" bash "$validator" "$setext_boundary"

setext_h1_boundary="$(make_fixture setext-h1-boundary)"
write_valid_index "$setext_h1_boundary"
printf '%s\n' 'GH100' 'GH101' > "$setext_h1_boundary/archived-issues.txt"
printf '%s\n' 'Other Section' '=============' '| [GH101](https://github.com/majiayu000/vibeguard/issues/101) | Outside |' >> "$setext_h1_boundary/README.md"
assert_exit "visible Setext H1 terminates archive section" 1 bash "$validator" "$setext_h1_boundary"
assert_stderr_contains "Setext H1 boundary keeps outside row out" "missing index rows: GH101" bash "$validator" "$setext_h1_boundary"

h3_thematic_break="$(make_fixture h3-thematic-break)"
write_valid_index "$h3_thematic_break"
printf '%s\n' '### Minor heading' '---' >> "$h3_thematic_break/README.md"
assert_exit "H3 followed by thematic break is not a Setext boundary" 0 bash "$validator" "$h3_thematic_break"

table_thematic_break="$(make_fixture table-thematic-break)"
write_valid_index "$table_thematic_break"
printf '%s\n' '| Supporting | Table |' '---' >> "$table_thematic_break/README.md"
assert_exit "noncanonical body row in the archive table fails" 1 bash "$validator" "$table_thematic_break"
assert_stderr_contains "noncanonical archive table row is reported" "malformed archived packet row" bash "$validator" "$table_thematic_break"

pipe_setext_boundary="$(make_fixture pipe-setext-boundary)"
write_valid_index "$pipe_setext_boundary"
printf '%s\n' '' 'Other | Section' '---' '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Outside |' >> "$pipe_setext_boundary/README.md"
assert_exit "pipe-containing paragraph can form a Setext boundary" 0 bash "$validator" "$pipe_setext_boundary"

reference_thematic_break="$(make_fixture reference-thematic-break)"
write_valid_index "$reference_thematic_break"
printf '%s\n' '' '[docs]: /docs' '---' '| Issue | Outcome |' '|---|---|' '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Still in archive |' >> "$reference_thematic_break/README.md"
assert_exit "link reference followed by thematic break stays in archive scope" 1 bash "$validator" "$reference_thematic_break"
assert_stderr_contains "second archive issue table is rejected" "expected exactly one GFM table" bash "$validator" "$reference_thematic_break"

multiline_setext_boundary="$(make_fixture multiline-setext-boundary)"
write_valid_index "$multiline_setext_boundary"
printf '%s\n' '' '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Outside heading line |' 'Other Section' '---' >> "$multiline_setext_boundary/README.md"
assert_exit "multiline Setext boundary starts at its first paragraph line" 0 bash "$validator" "$multiline_setext_boundary"

multiline_setext_h1_boundary="$(make_fixture multiline-setext-h1-boundary)"
write_valid_index "$multiline_setext_h1_boundary"
printf '%s\n' '' '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Outside heading line |' 'Other Section' '===' >> "$multiline_setext_h1_boundary/README.md"
assert_exit "multiline Setext H1 starts at its first paragraph line" 0 bash "$validator" "$multiline_setext_h1_boundary"

fenced_heading="$(make_fixture fenced-heading)"
printf '%s\n' '```markdown' '## Archived GitHub Packet Index' '```' > "$fenced_heading/README.md"
printf '%s\n' 'GH100' > "$fenced_heading/archived-issues.txt"
assert_exit "archive heading inside code fence is ignored" 1 bash "$validator" "$fenced_heading"
assert_stderr_contains "fenced heading failure requires visible section" "expected exactly one visible" bash "$validator" "$fenced_heading"

commented_heading="$(make_fixture commented-heading)"
printf '%s\n' \
  '# Specs' \
  '<!--' \
  '## Archived GitHub Packet Index' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  '-->' \
  > "$commented_heading/README.md"
printf '%s\n' 'GH100' > "$commented_heading/archived-issues.txt"
assert_exit "archive section inside HTML comment is ignored" 1 bash "$validator" "$commented_heading"
assert_stderr_contains "HTML comments fail closed" "HTML comments are not allowed" bash "$validator" "$commented_heading"

inline_code_comment="$(make_fixture inline-code-comment)"
write_valid_index "$inline_code_comment"
printf '%s\n' \
  'Text `<!--`' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Unexpected |' \
  '-->' \
  >> "$inline_code_comment/README.md"
assert_exit "comment markers inside inline code fail closed" 1 bash "$validator" "$inline_code_comment"
assert_stderr_contains "inline-code comment ambiguity is explicit" "HTML comments are not allowed" bash "$validator" "$inline_code_comment"

for raw_html_tag in script pre; do
  raw_html_heading="$(make_fixture "raw-html-${raw_html_tag}")"
  printf '%s\n' \
    "<${raw_html_tag}>" \
    '## Archived GitHub Packet Index' \
    '| Issue | Outcome |' \
    '|---|---|' \
    '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
    "</${raw_html_tag}>" \
    > "$raw_html_heading/README.md"
  printf '%s\n' 'GH100' > "$raw_html_heading/archived-issues.txt"
  assert_exit "archive section inside ${raw_html_tag} block is ignored" 1 bash "$validator" "$raw_html_heading"
  assert_stderr_contains "${raw_html_tag} block failure requires visible section" "expected exactly one visible" bash "$validator" "$raw_html_heading"
done

block_tag_heading="$(make_fixture raw-html-div)"
printf '%s\n' \
  '<div>' \
  '## Archived GitHub Packet Index' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  '</div>' \
  > "$block_tag_heading/README.md"
printf '%s\n' 'GH100' > "$block_tag_heading/archived-issues.txt"
assert_exit "archive section inside GFM block-tag HTML is ignored" 1 bash "$validator" "$block_tag_heading"
assert_stderr_contains "block-tag HTML failure requires visible section" "expected exactly one visible" bash "$validator" "$block_tag_heading"

declaration_heading="$(make_fixture raw-html-declaration)"
printf '%s\n' \
  '<!ARCHIVE' \
  '## Archived GitHub Packet Index' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  '>' \
  > "$declaration_heading/README.md"
printf '%s\n' 'GH100' > "$declaration_heading/archived-issues.txt"
assert_exit "archive section inside GFM declaration HTML is ignored" 1 bash "$validator" "$declaration_heading"
assert_stderr_contains "declaration HTML failure requires visible section" "expected exactly one visible" bash "$validator" "$declaration_heading"

processing_heading="$(make_fixture raw-html-processing)"
printf '%s\n' \
  '<?archive' \
  '## Archived GitHub Packet Index' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  '?>' \
  > "$processing_heading/README.md"
printf '%s\n' 'GH100' > "$processing_heading/archived-issues.txt"
assert_exit "archive section inside GFM processing instruction is ignored" 1 bash "$validator" "$processing_heading"
assert_stderr_contains "processing instruction failure requires visible section" "expected exactly one visible" bash "$validator" "$processing_heading"

cdata_heading="$(make_fixture raw-html-cdata)"
printf '%s\n' \
  '<![CDATA[' \
  '## Archived GitHub Packet Index' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  ']]>' \
  > "$cdata_heading/README.md"
printf '%s\n' 'GH100' > "$cdata_heading/archived-issues.txt"
assert_exit "archive section inside GFM CDATA HTML is ignored" 1 bash "$validator" "$cdata_heading"
assert_stderr_contains "CDATA failure requires visible section" "expected exactly one visible" bash "$validator" "$cdata_heading"

generic_tag_heading="$(make_fixture raw-html-generic-tag)"
printf '%s\n' \
  '<custom-element data-kind="archive">' \
  '## Archived GitHub Packet Index' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Hidden |' \
  '</custom-element>' \
  > "$generic_tag_heading/README.md"
printf '%s\n' 'GH100' > "$generic_tag_heading/archived-issues.txt"
assert_exit "archive section inside generic GFM HTML tag block is ignored" 1 bash "$validator" "$generic_tag_heading"
assert_stderr_contains "generic tag block failure requires visible section" "expected exactly one visible" bash "$validator" "$generic_tag_heading"

paragraph_generic_tag="$(make_fixture paragraph-generic-tag)"
write_valid_index "$paragraph_generic_tag"
printf '%s\n' \
  'Text' \
  '<x-widget>' \
  '### Visible subsection' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Unexpected |' \
  '</x-widget>' \
  >> "$paragraph_generic_tag/README.md"
assert_exit "generic tag cannot interrupt a paragraph to hide rows" 1 bash "$validator" "$paragraph_generic_tag"
assert_stderr_contains "paragraph-context table remains visible" "expected exactly one GFM table" bash "$validator" "$paragraph_generic_tag"

fake_closer="$(make_fixture fake-closer)"
printf '%s\n' \
  '# Specs' \
  '```markdown' \
  '``` trailing text is not a closing fence' \
  '## Archived GitHub Packet Index' \
  '| [GH100](https://github.com/majiayu000/vibeguard/issues/100) | Fenced |' \
  > "$fake_closer/README.md"
printf '%s\n' 'GH100' > "$fake_closer/archived-issues.txt"
assert_exit "fence-like line with trailing text does not close fence" 1 bash "$validator" "$fake_closer"
assert_stderr_contains "fake closer keeps heading fenced" "expected exactly one visible" bash "$validator" "$fake_closer"

backtick_info="$(make_fixture backtick-info)"
write_valid_index "$backtick_info"
printf '%s\n' \
  '```bad`info' \
  '| Issue | Outcome |' \
  '|---|---|' \
  '| [GH999](https://github.com/majiayu000/vibeguard/issues/999) | Unexpected |' \
  '```' \
  >> "$backtick_info/README.md"
assert_exit "backtick in fence info string cannot hide archive rows" 1 bash "$validator" "$backtick_info"
assert_stderr_contains "invalid backtick fence leaves table visible" "expected exactly one GFM table" bash "$validator" "$backtick_info"

missing_section="$(make_fixture missing-section)"
printf '%s\n' '# Specs' > "$missing_section/README.md"
printf '%s\n' 'GH100' > "$missing_section/archived-issues.txt"
assert_exit "missing archive section fails" 1 bash "$validator" "$missing_section"

missing_readme="$(make_fixture missing-readme)"
assert_exit "missing index fails" 1 bash "$validator" "$missing_readme"

assert_exit "live specs index passes" 0 bash "$validator"

printf '\n%d/%d passed\n' "$pass" "$total"
[[ "$fail" -eq 0 ]]
