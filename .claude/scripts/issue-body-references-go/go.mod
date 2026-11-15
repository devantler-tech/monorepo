module github.com/devantler-tech/monorepo/issue-body-references

go 1.26.11

require (
	github.com/yuin/goldmark v1.7.17
	golang.org/x/net v0.60.0
)

// test-inputs: .claude/scripts/delivered-open-candidates.sh
// test-inputs: .claude/scripts/delivered-open-candidates.test.sh .claude/scripts/go-helper-build.sh
// test-inputs: .github/workflows/ci.yaml
