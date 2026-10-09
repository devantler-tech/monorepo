#!/usr/bin/env bash
# monorepo#4057: resolve Project 5's native planning bindings, never a same-named local copy.
# Read-only classifier: no GitHub calls or mutations. Input is the complete GraphQL envelope
# data.organization.projectV2 { id fields { nodes { ... } pageInfo { hasNextPage } } }.
# Request isIssueField on ProjectV2FieldCommon and issueField { id name visibility } on BOTH
# ProjectV2Field and ProjectV2SingleSelectField. Native select attachments have empty options;
# option identities are read separately from the linked organization issue field.
set -euo pipefail

unknown() { echo "project-planning-fields: UNKNOWN $*" >&2; exit 2; }
[ "$#" -eq 2 ] && [ "$1" = --input ] || unknown 'usage: --input <JSON-file|->'
command -v jq >/dev/null 2>&1 || unknown 'jq is required'
if [ "$2" = - ]; then
  payload="$(cat)" || unknown 'cannot read stdin'
else
  payload="$(cat -- "$2")" || unknown 'cannot read input'
fi
[ -n "$payload" ] || unknown 'empty read; refresh the complete field query'

result="$(jq -sce '
  if length != 1 then error("expected one complete GraphQL envelope") else .[0] end
  | if type != "object" or ((.errors // []) | length) != 0 then
    error("failed or partial GraphQL read")
  else .data.organization.projectV2 end
  | if .id != "PVT_kwDOCqQQO84AyVu7" then error("wrong or missing project identity") else . end
  | if (.fields.nodes | type) != "array" or (.fields.nodes | length) == 0
       or .fields.pageInfo.hasNextPage != false then
      error("missing or incomplete field census")
    else .fields.nodes end
  | if all(.[]; type == "object" and (.id | type) == "string" and (.id | length) > 0)
       and ([.[].id] | length) == ([.[].id] | unique | length) then .
    else error("malformed or repeated project field identity") end
  | . as $fields
  | [
      {name:"Priority", id:"IFSS_kgDOAck10g", type:"ProjectV2SingleSelectField", dataType:"SINGLE_SELECT"},
      {name:"Effort", id:"IFSS_kgDOAck11Q", type:"ProjectV2SingleSelectField", dataType:"SINGLE_SELECT"},
      {name:"Start date", id:"IFD_kgDOAck10w", type:"ProjectV2Field", dataType:"DATE"},
      {name:"Target date", id:"IFD_kgDOAck11A", type:"ProjectV2Field", dataType:"DATE"}
    ]
  | reduce .[] as $want ({};
      [$fields[] | select(.issueField.id == $want.id)] as $matches
      | (if ($matches | length) != 1 then error("missing or ambiguous native " + $want.name)
        else $matches[0] end) as $field
      | if $field.isIssueField != true or $field.name != $want.name
           or $field.issueField.name != $want.name or $field.issueField.visibility != "ALL"
           or $field.__typename != $want.type or $field.dataType != $want.dataType then
          error("unverified native binding for " + $want.name)
        else . + {($want.name): {projectFieldId:$field.id, issueFieldId:$want.id}} end)
' <<<"$payload")" || unknown 'native planning bindings unverified; re-read, never create a fallback copy'
printf '%s\n' "$result"
