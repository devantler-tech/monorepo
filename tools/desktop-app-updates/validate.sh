#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
shellcheck -x -P SCRIPTDIR update.sh install.sh test.sh install.test.sh lifecycle.test.sh validate.sh
bash test.sh
(cd helper && go test ./... && go vet .)
bash install.test.sh
bash lifecycle.test.sh
