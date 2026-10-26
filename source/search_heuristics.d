/// Status buckets for `dubx search`: pure heuristics, no I/O.
///
/// Every threshold and keyword list lives in this module so the CLI, the
/// docs (docs/search.adoc) and the upstream proposal
/// (docs/upstream/dub-registry-grouped-search.md) share one definition.
module search_heuristics;

import std.algorithm : canFind, filter, map, maxElement, sort;
import std.array : array, join;
import std.datetime : SysTime, days;
import std.format : format;
import std.regex : matchFirst, regex;
import std.string : indexOf, startsWith, toLower;
import std.typecons : Nullable;

// ---------------------------------------------------------------------------
// Tunables (the only place thresholds are defined)
// ---------------------------------------------------------------------------

/// Bucket thresholds, in days since the newest activity signal.
struct Thresholds
{
	/// Release or commit within this many days => Active (~12 months).
	int activeDays = 365;
	/// No release or commit within this many days => Quiet (3 years).
	/// Between activeDays and quietDays => Slow but alive. Quiet is a
	/// neutral fact (old dates), never a verdict: finished code is quiet too.
	int quietDays = 3 * 365;
	/// Recent issues sampled for responsiveness.
	int issueSample = 10;
	/// Share of sampled issues that are closed or have a comment for the
	/// project to count as "answers issues" (0..100).
	int answeredPercent = 50;
	/// Minimum sampled issues before the share means anything.
	int minIssues = 3;
	/// A repo must keep answering 404/451 this long (first seen -> now)
	/// before it overrides a maintainer-declared status. Until then the
	/// declared bucket stays and the reason warns "repo unreachable since".
	int goneGraceDays = 30;
}

/// Maintainer-declared statuses (proposed recipe key `x:status`).
/// A declared status always beats the age heuristics.
immutable string[] declaredStatuses = ["experimental", "alpha", "beta", "stable",
	"complete", "maintenance-only", "deprecated", "unmaintained"];

/// Defaults used by the CLI.
enum Thresholds defaultThresholds = Thresholds.init;

/// Description words that mark a package as a wrapper/binding of something else.
enum wrapperDescriptionPattern = `\b(bindings?|wrappers?|wraps|port of|interface to|binding for)\b`;

// ---------------------------------------------------------------------------

/// Status bucket. Declaration order is display order.
enum Bucket
{
	active,
	slow,
	finished,
	quiet,
	unmaintained,
	gone,
	wrapper,
	unknown,
}

/// Human label for a bucket.
string bucketLabel(Bucket b)
{
	final switch (b)
	{
	case Bucket.active: return "Active";
	case Bucket.slow: return "Slow but alive";
	case Bucket.finished: return "Finished or maintenance-only";
	case Bucket.quiet: return "Quiet";
	case Bucket.unmaintained: return "Declared deprecated or unmaintained";
	case Bucket.gone: return "Repo gone or archived";
	case Bucket.wrapper: return "Wrapper or subpackage";
	case Bucket.unknown: return "Unknown";
	}
}

/// Stable machine key for a bucket (JSON field values; public interface).
string bucketKey(Bucket b)
{
	final switch (b)
	{
	case Bucket.active: return "active";
	case Bucket.slow: return "slow";
	case Bucket.finished: return "finished";
	case Bucket.quiet: return "quiet";
	case Bucket.unmaintained: return "unmaintained";
	case Bucket.gone: return "gone";
	case Bucket.wrapper: return "wrapper";
	case Bucket.unknown: return "unknown";
	}
}

/// What the source host said about the repository.
enum RepoState
{
	unknown,    /// not checked yet, rate-limited, or network error
	ok,
	moved,      /// redirected to another owner/name (still alive)
	gone,       /// 404 / 451
	archived,
	notChecked, /// host we do not query (e.g. bitbucket)
}

/// Everything the classifier looks at for one package.
struct Facts
{
	string name;
	string description;
	string latestVersion;

	Nullable!SysTime lastRelease;   /// newest non-branch version date
	string lastReleaseVersion;
	size_t releaseCount;            /// non-branch versions
	Nullable!SysTime lastBranchCommit; /// newest ~branch version date (registry)
	bool hasReadme;
	string[] dependencies;          /// of the newest release (or branch if none)
	bool registryError;

	string repoKind;                /// github / gitlab / bitbucket
	string repoSlug;                /// owner/project
	RepoState repo;
	string repoMovedTo;
	Nullable!SysTime repoPushed;    /// GitHub pushed_at / GitLab last_activity_at
	long stars = -1;
	long downloadsTotal = -1;
	long downloadsMonthly = -1;

	/// Maintainer-declared status (`x:status`), lowercased; empty if none.
	string declaredStatus;
	long openIssues = -1;        /// GitHub open_issues_count (includes PRs)
	int issuesSampled = -1;      /// recent issues looked at (-1 = not checked)
	int issuesAnswered;          /// of those, closed or commented
	/// Builds with current DMD/LDC: -1 unknown (hook; no source yet), 0 no, 1 yes.
	int buildsWithCurrent = -1;

	/// Default branch reported by the repo host.
	string defaultBranch;
	/// When dubx first saw the repo answer 404/451 (from the dubx state file).
	Nullable!SysTime repoGoneSince;

	/// CI result the package's own CI reported for `ciRef`:
	/// "" unknown, "passing", "failing", "pending".
	string ciState;
	string ciSource;   /// github-checks, github-status, gitlab-pipeline
	string ciRef;      /// e.g. "tag v0.10.0" or "branch master"
	string ciUrl;
	Nullable!SysTime ciDate;

	/// Packages in the same search results that depend on this one.
	/// Not registry-wide: code.dlang.org has no reverse-dependency API.
	string[] dependentsInResults;
}

/// Fill `dependentsInResults` for every package from the others' dependencies.
/// A package's own subpackages do not count.
void computeDependents(Facts[] all)
{
	foreach (ref f; all)
	{
		f.dependentsInResults = null;
		auto top = parentName(f.name).toLower;
		auto isTop = f.name.indexOf(':') < 0;
		foreach (ref o; all)
		{
			if (parentName(o.name).toLower == top)
				continue;
			foreach (d; o.dependencies)
			{
				auto dl = d.toLower;
				if (dl == f.name.toLower || (isTop && parentName(dl) == top))
				{
					f.dependentsInResults ~= o.name;
					break;
				}
			}
		}
	}
}

private string ymd(SysTime t)
{
	return format("%04d-%02d-%02d", t.year, cast(int) t.month, t.day);
}

/// True once a 404/451 repo has been unreachable for `goneGraceDays`.
bool goneSustained(const ref Facts f, SysTime now, Thresholds t = defaultThresholds)
{
	return f.repo == RepoState.gone && !f.repoGoneSince.isNull
		&& (now - f.repoGoneSince.get).total!"days" >= t.goneGraceDays;
}

/// True when sampled recent issues mostly got a reply or were closed.
/// Null-ish (-1) when there is not enough data.
int answersIssues(const ref Facts f, Thresholds t = defaultThresholds)
{
	if (f.issuesSampled < t.minIssues)
		return -1;
	return f.issuesAnswered * 100 >= t.answeredPercent * f.issuesSampled ? 1 : 0;
}

/// Classifier output.
struct Verdict
{
	Bucket bucket;
	string reason;
}

/// Newest of release date, branch commit date and repo push date.
Nullable!SysTime lastActivity(const ref Facts f)
{
	SysTime[] ts;
	if (!f.lastRelease.isNull) ts ~= f.lastRelease.get;
	if (!f.lastBranchCommit.isNull) ts ~= f.lastBranchCommit.get;
	if (!f.repoPushed.isNull) ts ~= f.repoPushed.get;
	Nullable!SysTime r;
	if (ts.length)
		r = ts.maxElement;
	return r;
}

private string ym(SysTime t)
{
	return format("%04d-%02d", t.year, cast(int) t.month);
}

/// Top-level package name (`dyaml:yaml_gen` -> `dyaml`).
string parentName(string name)
{
	auto i = name.indexOf(':');
	return i < 0 ? name : name[0 .. i];
}

/// Short release/activity summary, e.g. "single release 0.0.1 (2017-05), repo 404".
string activitySummary(const ref Facts f)
{
	string[] parts;
	if (f.lastRelease.isNull)
		parts ~= "no tagged release";
	else if (f.releaseCount == 1)
		parts ~= format("single release %s (%s)", f.lastReleaseVersion, ym(f.lastRelease.get));
	else
		parts ~= format("last release %s (%s)", f.lastReleaseVersion, ym(f.lastRelease.get));

	final switch (f.repo)
	{
	case RepoState.gone:
		parts ~= f.repoGoneSince.isNull ? "repo 404" : "repo 404 since " ~ ymd(f.repoGoneSince.get);
		break;
	case RepoState.archived: parts ~= "repo archived"; break;
	case RepoState.moved:
		parts ~= "repo moved to " ~ f.repoMovedTo;
		goto case RepoState.ok;
	case RepoState.ok:
		if (!f.repoPushed.isNull)
			parts ~= "pushed " ~ ym(f.repoPushed.get);
		break;
	case RepoState.unknown:
	case RepoState.notChecked:
		if (!f.lastBranchCommit.isNull && (f.lastRelease.isNull
				|| f.lastBranchCommit.get > f.lastRelease.get))
			parts ~= "branch commit " ~ ym(f.lastBranchCommit.get);
		if (f.repo == RepoState.unknown && f.repoKind.length)
			parts ~= "repo not checked";
		break;
	}
	if (f.issuesSampled > 0)
		parts ~= format("%s/%s recent issues answered", f.issuesAnswered, f.issuesSampled);
	if (f.ciState.length)
		parts ~= format("CI %s on %s%s", f.ciState, f.ciRef,
			f.ciDate.isNull ? "" : " (" ~ ym(f.ciDate.get) ~ ")");
	if (f.dependentsInResults.length)
		parts ~= format("used by %s of these results", f.dependentsInResults.length);
	if (f.buildsWithCurrent == 1) parts ~= "builds with current compilers";
	else if (f.buildsWithCurrent == 0) parts ~= "fails to build with current compilers";
	return parts.join(", ");
}

/// Classify one package.
///
/// Order: repo gone/archived -> wrapper/subpackage -> activity age.
/// `resultNames` are the top-level names in the same search result set; a
/// dependency on one of them (other than the package's own subpackages)
/// marks the package as a wrapper of it.
Verdict classify(const ref Facts f, const(string)[] resultNames, SysTime now,
	Thresholds t = defaultThresholds)
{
	// 1. Hard facts: repo archived, or 404/451. A 404 overrides a declared
	//    status only once it has lasted goneGraceDays (repos come back).
	auto declared = declaredStatuses.canFind(f.declaredStatus);
	if (f.repo == RepoState.archived
		|| (f.repo == RepoState.gone && (!declared || goneSustained(f, now, t))))
		return Verdict(Bucket.gone, activitySummary(f));

	// 2. Maintainer-declared status beats every heuristic
	if (declared)
	{
		auto why = "declared " ~ f.declaredStatus ~ "; "
			~ (f.repo == RepoState.gone ? "repo unreachable since "
				~ (f.repoGoneSince.isNull ? ymd(now) : ymd(f.repoGoneSince.get)) ~ "; " : "")
			~ activitySummary(f);
		switch (f.declaredStatus)
		{
		case "complete", "maintenance-only": return Verdict(Bucket.finished, why);
		case "deprecated", "unmaintained": return Verdict(Bucket.unmaintained, why);
		case "experimental", "alpha", "beta", "stable": return Verdict(Bucket.active, why);
		default: break; // unknown value: fall through to heuristics
		}
	}

	// 3. Wrapper or subpackage
	if (f.name.indexOf(':') >= 0)
		return Verdict(Bucket.wrapper, "subpackage of " ~ parentName(f.name));

	auto own = f.name.toLower;
	string[] wrapped;
	foreach (d; f.dependencies)
	{
		auto top = parentName(d).toLower;
		if (top == own)
			continue;
		if (resultNames.canFind!(n => n.toLower == top) && !wrapped.canFind(top))
			wrapped ~= top;
	}
	if (wrapped.length)
		return Verdict(Bucket.wrapper, "depends on " ~ wrapped.join(", ") ~ "; " ~ activitySummary(f));

	auto m = matchFirst(f.description.toLower, regex(wrapperDescriptionPattern));
	if (!m.empty)
		return Verdict(Bucket.wrapper, "description says '" ~ m[1] ~ "'; " ~ activitySummary(f));

	// 4. Activity age (facts, not verdicts)
	auto last = lastActivity(f);
	if (last.isNull)
		return Verdict(Bucket.unknown, f.registryError ? "registry info unavailable" : activitySummary(f));

	auto age = (now - last.get).total!"days";
	if (age <= t.activeDays)
		return Verdict(Bucket.active, activitySummary(f));
	if (age <= t.quietDays)
		return Verdict(Bucket.slow, activitySummary(f));
	// Quiet + (answers issues or its CI passes) + not known to be broken
	// => reads as finished.
	if ((answersIssues(f, t) == 1 || f.ciState == "passing")
		&& f.ciState != "failing" && f.buildsWithCurrent != 0)
		return Verdict(Bucket.finished, "quiet but " ~ activitySummary(f)
			~ (!f.ciState.length && f.buildsWithCurrent == -1 ? ", build check n/a" : ""));
	return Verdict(Bucket.quiet, activitySummary(f));
}

unittest
{
	import std.datetime : DateTime, UTC;

	auto now = SysTime(DateTime(2026, 10, 26), UTC());
	SysTime at(int y, int m) { return SysTime(DateTime(y, m, 1), UTC()); }
	string[] names = ["dyaml", "uniconf", "yaml-d", "configy"];

	// yaml-d: single 0.0.1 release from 2017, repo 404 -> Abandoned
	Facts yamld = { name: "yaml-d", lastReleaseVersion: "0.0.1", releaseCount: 1,
		repo: RepoState.gone, repoKind: "github", dependencies: ["tinyendian"] };
	yamld.lastRelease = at(2017, 5);
	auto v = classify(yamld, names, now);
	assert(v.bucket == Bucket.gone, v.reason);
	assert(v.reason == "single release 0.0.1 (2017-05), repo 404", v.reason);

	// uniconf: last release 2020, pushed 2021 -> Quiet (own subpackages are not wrapping)
	Facts uni = { name: "uniconf", lastReleaseVersion: "0.2.2", releaseCount: 9,
		repo: RepoState.ok, dependencies: ["uniconf:yaml", "uniconf:core"] };
	uni.lastRelease = at(2020, 4);
	uni.repoPushed = at(2021, 4);
	assert(classify(uni, names, now).bucket == Bucket.quiet);
	// ... and Finished when it still answers issues
	uni.issuesSampled = 4;
	uni.issuesAnswered = 3;
	assert(classify(uni, names, now).bucket == Bucket.finished);
	// ... unless it is known not to build
	uni.buildsWithCurrent = 0;
	assert(classify(uni, names, now).bucket == Bucket.quiet);
	// Declared status beats heuristics
	uni.declaredStatus = "complete";
	auto dv = classify(uni, names, now);
	assert(dv.bucket == Bucket.finished && dv.reason.startsWith("declared complete"), dv.reason);
	uni.declaredStatus = "unmaintained";
	assert(classify(uni, names, now).bucket == Bucket.unmaintained);

	// dyaml: release 2024-06, pushed 2026-01 -> Active
	Facts dy = { name: "dyaml", lastReleaseVersion: "0.10.0", releaseCount: 40,
		repo: RepoState.moved, repoMovedTo: "dlang-community/D-YAML", dependencies: ["tinyendian"] };
	dy.lastRelease = at(2024, 6);
	dy.repoPushed = at(2026, 1);
	assert(classify(dy, names, now).bucket == Bucket.active);

	// Without the repo push date dyaml is Slow but alive
	dy.repoPushed.nullify();
	dy.repo = RepoState.unknown;
	assert(classify(dy, names, now).bucket == Bucket.slow);

	// Subpackage and dependency wrappers
	Facts sub = { name: "dyaml:yaml_gen" };
	assert(classify(sub, names, now) == Verdict(Bucket.wrapper, "subpackage of dyaml"));
	Facts cfg = { name: "configy", dependencies: ["dyaml"], repo: RepoState.ok };
	cfg.lastRelease = at(2025, 1);
	assert(classify(cfg, names, now).bucket == Bucket.wrapper);

	// Description wrapper
	Facts b = { name: "libfoo-d", description: "D bindings for libfoo" };
	b.lastRelease = at(2026, 1);
	assert(classify(b, names, now).bucket == Bucket.wrapper);

	// Archived wins over everything
	Facts ar = { name: "x", repo: RepoState.archived };
	ar.lastRelease = at(2026, 9);
	assert(classify(ar, names, now).bucket == Bucket.gone);

	// Nothing known
	Facts none = { name: "y", registryError: true };
	assert(classify(none, names, now).bucket == Bucket.unknown);

	// CI passing is evidence for Finished; failing keeps Quiet
	Facts q = { name: "q", repo: RepoState.ok, ciState: "passing", ciRef: "tag v1.0.0" };
	q.lastRelease = at(2019, 3);
	q.ciDate = at(2019, 3);
	auto qv = classify(q, names, now);
	assert(qv.bucket == Bucket.finished, qv.reason);
	assert(qv.reason.canFind("CI passing on tag v1.0.0 (2019-03)"), qv.reason);
	q.ciState = "failing";
	q.issuesSampled = 5; q.issuesAnswered = 5;
	assert(classify(q, names, now).bucket == Bucket.quiet);

	// 404 vs declared status: grace period, then gone
	Facts g = { name: "g", repo: RepoState.gone, declaredStatus: "complete" };
	g.lastRelease = at(2018, 1);
	auto gv = classify(g, names, now); // first seen now
	assert(gv.bucket == Bucket.finished && gv.reason.canFind("repo unreachable since 2026-10-26"), gv.reason);
	g.repoGoneSince = now - 29.days;
	assert(classify(g, names, now).bucket == Bucket.finished);
	g.repoGoneSince = now - 30.days;
	auto gg = classify(g, names, now);
	assert(gg.bucket == Bucket.gone && gg.reason.canFind("repo 404 since 2026-09-26"), gg.reason);
	// Without a declaration a 404 is gone at once
	g.declaredStatus = null;
	g.repoGoneSince.nullify();
	assert(classify(g, names, now).bucket == Bucket.gone);

	// Dependents among the results
	Facts[] fs = [Facts("dyaml"), Facts("configy"), Facts("dyaml:yaml_gen"), Facts("uniconf")];
	fs[1].dependencies = ["dyaml"];
	fs[3].dependencies = ["uniconf:yaml", "dyaml:yaml_gen"];
	computeDependents(fs);
	assert(fs[0].dependentsInResults == ["configy", "uniconf"], fs[0].dependentsInResults.join(","));
	assert(fs[2].dependentsInResults == ["uniconf"]);
	assert(fs[3].dependentsInResults.length == 0);

	// Threshold edges
	Facts e = { name: "e", repo: RepoState.ok };
	e.repoPushed = now - 365.days;
	assert(classify(e, names, now).bucket == Bucket.active);
	e.repoPushed = now - 366.days;
	assert(classify(e, names, now).bucket == Bucket.slow);
	e.repoPushed = now - (3 * 365 + 1).days;
	assert(classify(e, names, now).bucket == Bucket.quiet);
}
