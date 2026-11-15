module github.com/devantler-tech/monorepo/memory-backup

go 1.26.11

require golang.org/x/sys v0.37.0

require github.com/yuin/goldmark v1.8.7

// test-inputs: .claude/scripts/go-helper-build.sh .claude/scripts/memory-archive.sh
// test-inputs: .claude/scripts/memory-archive.test.sh .claude/scripts/memory-backup.sh
// test-inputs: .claude/scripts/memory-backup.test.sh .claude/scripts/memory-rewrite.sh
// test-inputs: .github/workflows/ci.yaml
