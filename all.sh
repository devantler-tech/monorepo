#!/bin/bash

set -e

# Commit message
COMMIT_MSG="${1:-'Auto-commit from all.sh'}"

git submodule foreach --recursive "
  echo \"Processing \$name in \$path\"
  cd \"\$toplevel/\$path\"
  git add .
  if ! git diff --cached --quiet; then
    git commit -m \"$COMMIT_MSG\"
    git push
    echo \"Committed and pushed in \$path\"
  else
    echo \"No changes to commit in \$path\"
  fi
"

echo "Done processing all submodules."
