#!/usr/bin/env bash
# monorepo#4057: same-named project fields must never shadow native issue fields.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/project-planning-fields.sh"

fail() { echo "project-planning-fields.test: FAIL $*" >&2; exit 1; }

# Native single-select attachments are not ProjectV2Field, and their project options are empty.
# Literals are independently derived from the four existing organization field identities.
fixture='{"data":{"organization":{"projectV2":{"id":"PVT_kwDOCqQQO84AyVu7","fields":{"pageInfo":{"hasNextPage":false},"nodes":[
{"__typename":"ProjectV2SingleSelectField","id":"old-priority","name":"Priority","dataType":"SINGLE_SELECT","isIssueField":false,"issueField":null},
{"__typename":"ProjectV2Field","id":"old-start","name":"Start date","dataType":"DATE","isIssueField":false,"issueField":null},
{"__typename":"ProjectV2SingleSelectField","id":"native-priority","name":"Priority","dataType":"SINGLE_SELECT","isIssueField":true,"options":[],"issueField":{"id":"IFSS_kgDOAck10g","name":"Priority","visibility":"ALL"}},
{"__typename":"ProjectV2SingleSelectField","id":"native-effort","name":"Effort","dataType":"SINGLE_SELECT","isIssueField":true,"options":[],"issueField":{"id":"IFSS_kgDOAck11Q","name":"Effort","visibility":"ALL"}},
{"__typename":"ProjectV2Field","id":"native-start","name":"Start date","dataType":"DATE","isIssueField":true,"issueField":{"id":"IFD_kgDOAck10w","name":"Start date","visibility":"ALL"}},
{"__typename":"ProjectV2Field","id":"native-target","name":"Target date","dataType":"DATE","isIssueField":true,"issueField":{"id":"IFD_kgDOAck11A","name":"Target date","visibility":"ALL"}}
]}}}}}'

result="$(bash "$helper" --input - <<<"$fixture")" || fail "native fields were not resolved"
expected='{"Priority":{"projectFieldId":"native-priority","issueFieldId":"IFSS_kgDOAck10g"},"Effort":{"projectFieldId":"native-effort","issueFieldId":"IFSS_kgDOAck11Q"},"Start date":{"projectFieldId":"native-start","issueFieldId":"IFD_kgDOAck10w"},"Target date":{"projectFieldId":"native-target","issueFieldId":"IFD_kgDOAck11A"}}'
[ "$result" = "$expected" ] || fail "a project-local duplicate shadowed a native field: $result"

reject() {
  local input="$1" reason="$2" expected_rc="$3" label="$4" output rc=0
  output="$(bash "$helper" --input - <<<"$input" 2>&1)" || rc=$?
  [ "$rc" -eq "$expected_rc" ] || fail "$reason returned $rc, expected $label"
  case "$output" in *"$label"*) ;; *) fail "$reason has no actionable $label diagnostic" ;; esac
}
unknown() { reject "$1" "$2" 2 UNKNOWN; }
finding() { reject "$1" "$2" 1 FINDING; }

unknown '' 'empty read'
unknown '{' 'malformed JSON'
unknown "$fixture $fixture" 'multiple GraphQL envelopes'
unknown '{"data":null,"errors":[{"message":"refused"}]}' 'GraphQL failure'
unknown "$(jq -c '.errors=[{"message":"partial"}]' <<<"$fixture")" 'partial data with errors'
unknown "$(jq -c '.data.organization.projectV2.fields.pageInfo.hasNextPage=true' <<<"$fixture")" 'truncated fields'
unknown "$(jq -c 'del(.data.organization.projectV2.fields.pageInfo)' <<<"$fixture")" 'missing completeness evidence'
unknown "$(jq -c '.data.organization.projectV2.id="another-project"' <<<"$fixture")" 'wrong board'
unknown "$(jq -c '.data.organization.projectV2.fields.nodes=[]' <<<"$fixture")" 'empty field list'
unknown "$(jq -c 'del(.data.organization.projectV2.fields.nodes[2].issueField)' <<<"$fixture")" 'omitted union selection'
unknown "$(jq -c 'del(.data.organization.projectV2.fields.nodes[2].issueField.visibility)' <<<"$fixture")" 'omitted native visibility'
unknown "$(jq -c 'del(.data.organization.projectV2.fields.nodes[2].isIssueField)' <<<"$fixture")" 'omitted native flag'
finding "$(jq -c '.data.organization.projectV2.fields.nodes |= map(select(.id!="native-priority"))' <<<"$fixture")" 'project-local field only'
finding "$(jq -c '.data.organization.projectV2.fields.nodes[2].issueField.id="lookalike"' <<<"$fixture")" 'wrong issue-field identity'
finding "$(jq -c '.data.organization.projectV2.fields.nodes[2].isIssueField=false' <<<"$fixture")" 'unbound native lookalike'
finding "$(jq -c '.data.organization.projectV2.fields.nodes[2].issueField.visibility="PRIVATE"' <<<"$fixture")" 'private field on public board'
finding "$(jq -c '.data.organization.projectV2.fields.nodes[2].__typename="ProjectV2Field"' <<<"$fixture")" 'wrong native select type'
finding "$(jq -c '.data.organization.projectV2.fields.nodes[4].dataType="TEXT"' <<<"$fixture")" 'wrong date type'
unknown "$(jq -c '.data.organization.projectV2.fields.nodes[2].id=""' <<<"$fixture")" 'missing mutation identity'
unknown "$(jq -c '.data.organization.projectV2.fields.nodes += [.data.organization.projectV2.fields.nodes[2]]' <<<"$fixture")" 'ambiguous native binding'
unknown "$(jq -c '.data.organization.projectV2.fields.nodes += [.data.organization.projectV2.fields.nodes[2] | .id="second-native-priority"]' <<<"$fixture")" 'two distinct attachments for one native field'

echo 'project-planning-fields.test: all assertions passed'
