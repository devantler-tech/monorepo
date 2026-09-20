#!/usr/bin/awk -f

# Emit each Markdown line after removing container prefixes with the same
# indentation semantics as the PR ownership classifier. Four leading columns
# at any nesting depth are an indented code block, not structural body text.

function expand_leading_tabs(line,    output, column, position, char, width, pad) {
  output = ""
  column = 0
  for (position = 1; position <= length(line); position++) {
    char = substr(line, position, 1)
    if (char == "\t") {
      width = 4 - (column % 4)
      pad = sprintf("%" width "s", "")
      output = output pad
      column += width
    } else if (char == " ") {
      output = output char
      column++
    } else {
      return output substr(line, position)
    }
  }
  return output
}

function structural_line(line,    indent, marker_width, rest) {
  sub(/\r$/, "", line)
  line = expand_leading_tabs(line)

  while (1) {
    indent = 0
    while (substr(line, indent + 1, 1) == " ") {
      indent++
    }
    if (indent >= 4) {
      if (reject_indented_code) {
        found_indented_code = 1
      }
      return ""
    }
    if (indent >= length(line)) {
      return ""
    }

    rest = substr(line, indent + 1)
    if (substr(rest, 1, 1) == ">") {
      rest = expand_leading_tabs(substr(rest, 2))
      if (substr(rest, 1, 1) == " ") {
        rest = substr(rest, 2)
      }
      line = rest
      continue
    }
    marker_width = 0
    # Role routing recognizes only the quote and unordered-list containers
    # documented for routine disclosures. The general structural parser keeps
    # normalizing every supported Markdown list form.
    if (role_routing && rest ~ /^[-*][[:space:]]/) {
      marker_width = 1
    } else if (!role_routing && rest ~ /^[-*+][[:space:]]/) {
      marker_width = 1
    } else if (!role_routing && match(rest, /^[0-9]+[.)][[:space:]]/)) {
      marker_width = RLENGTH - 1
    }
    if (marker_width > 0) {
      rest = expand_leading_tabs(substr(rest, marker_width + 1))
      if (substr(rest, 1, 1) == " ") {
        rest = substr(rest, 2)
      }
      line = rest
      continue
    }
    return rest
  }
}

{
  print structural_line($0)
}

END {
  if (reject_indented_code && found_indented_code) {
    exit 1
  }
}
