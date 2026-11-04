package main

import (
	"strings"
)

// Rate-limit diagnosis.
//
// Every failed gh call is reported through dieGH, which names a rate limit AS a rate limit and
// keeps the caller's original wording for everything else. The fallback matters as much as the
// detection: a classifier that called every failure a rate limit would be exactly as misleading
// as the guess it replaces.
//
// stderr is NOT sufficient on its own: `gh` does not reliably say when it was refused for budget
// reasons. Measured 2026-07-27 with GraphQL at 0/5000, `gh project view 5 --owner devantler-tech`
// printed only "unknown owner type". So the budget the failed call spends is also asked for.
//
// GraphQL is read IN-QUERY, never from `GET /rate_limit`. Measured 2026-09-15 at the same moment
// (monorepo#2507): the REST endpoint reported GraphQL used=0, remaining=5000, while `rateLimit`
// inside a GraphQL query reported used=1182, remaining=3818, with a different reset time. REST
// (core) is read from `GET /rate_limit`, which is unmetered and authoritative for REST calls.

// probe is the outcome of the in-query GraphQL budget probe.
type probe int

const (
	probeRead    probe = iota // a numeric reading was taken
	probeNone                 // no reading could be taken
	probeRefused              // the probe itself was refused on a PRIMARY rate limit
)

// graphqlRateLimit reads "<remaining> <limit> <resetAt>" for the GraphQL budget this command
// spends. The probe spends the same pool, so an empty pool can refuse it, and that refusal is the
// answer. A SECONDARY refusal of the probe says nothing about the primary budget, so it is no
// reading. The probe's stderr is its own and never replaces the failed call's evidence.
func (a *adder) graphqlRateLimit() (string, probe) {
	out, errText, err := a.gh("api", "graphql", "-f", "query="+rateLimitQuery,
		"--jq", `.data.rateLimit | "\(.remaining) \(.limit) \(.resetAt)"`)
	if err == nil {
		reading := strings.TrimRight(out, "\n")
		if !allDigits(firstField(reading)) {
			return "", probeNone // a response without a numeric figure is no reading
		}
		return reading, probeRead
	}
	if primaryLimit.MatchString(errText) && !secondaryLimit.MatchString(errText) {
		return "", probeRefused
	}
	return "", probeNone
}

// budgetExhausted is true only when the budget is provably gone. Anything unreadable is "not
// proven", so the caller keeps its original wording rather than guessing.
func (a *adder) budgetExhausted(resource string) bool {
	var remaining string
	if resource == "graphql" {
		reading, outcome := a.graphqlRateLimit()
		switch outcome {
		case probeRefused:
			return true
		case probeNone:
			return false
		}
		remaining = firstField(reading)
	} else {
		out, _, err := a.gh("api", "rate_limit", "--jq", ".resources."+resource+".remaining")
		if err != nil {
			return false
		}
		remaining = strings.TrimRight(out, "\n")
	}
	if !allDigits(remaining) {
		return false // unparseable: do not guess
	}
	return strings.Trim(remaining, "0") == ""
}

// dieGH reports a failed gh call. resource must name the budget the FAILED call actually spends:
// REST and GraphQL are metered separately, so reading the GraphQL counter after a REST refusal
// could print a healthy allowance as "exhausted" with an unrelated reset time. state says what is
// true of the board now, per call site.
func (a *adder) dieGH(resource, context, state, other string) *exit {
	label := resource
	switch resource {
	case "graphql":
		label = "GraphQL"
	case "core":
		label = "REST (core)"
	}

	if secondaryLimit.MatchString(a.lastErr) {
		return die(context + " — GitHub applied a SECONDARY rate limit (a short-term burst guard)." + ind +
			state + ind +
			"Neither primary counter reflects this, so no allowance is quoted. Slow the" + ind +
			"calls down and retry shortly. This is NOT an auth, scope, or network problem.")
	}

	// Either signal is enough: GitHub said so, OR the budget is provably gone.
	if primaryLimit.MatchString(a.lastErr) || a.budgetExhausted(resource) {
		// Quote the figure from the same pool the probe read. Never fatal: a missing figure must
		// not turn a clear diagnosis into a crash.
		budget := "figure unavailable"
		if resource == "graphql" {
			if reading, outcome := a.graphqlRateLimit(); outcome == probeRead {
				rest := afterFirstSpace(reading)
				budget = firstField(reading) + "/" + firstField(rest) + ", resets " + afterFirstSpace(rest)
			}
		} else {
			out, _, err := a.gh("api", "rate_limit", "--jq",
				`"\(.resources.`+resource+`.remaining)/\(.resources.`+resource+`.limit), resets \(.resources.`+resource+`.reset|todate)"`)
			if err == nil {
				budget = strings.TrimRight(out, "\n")
			}
		}
		return die(context + " — GitHub " + label + " RATE LIMIT is exhausted (" + budget + ")." + ind +
			state + ind +
			"This is NOT an auth, scope, or network problem — the credential is fine." + ind +
			"The budget is shared across every agent lane and session, so a survey or" + ind +
			"bulk sweep in the same hour is the usual cause.")
	}
	return die(other)
}

// firstField is the shell's ${s%% *}: everything before the first space, or all of s.
func firstField(s string) string {
	field, _, _ := strings.Cut(s, " ")
	return field
}

// afterFirstSpace is the shell's ${s#* }: everything after the first space, or all of s.
func afterFirstSpace(s string) string {
	if _, rest, found := strings.Cut(s, " "); found {
		return rest
	}
	return s
}
