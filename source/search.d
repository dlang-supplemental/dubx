/// `dubx search <query>`: DUB registry search grouped into status buckets.
///
/// Data: code.dlang.org API (search, package info, stats) plus the GitHub /
/// GitLab API for the package repository. HTTP goes through the system
/// `curl` binary (ships with Windows 10+, macOS and Linux) so dubx needs no
/// libcurl. Responses are cached briefly on disk. Heuristics live in
/// `search_heuristics`.
module search;

import core.atomic : atomicLoad, atomicStore;
import std.algorithm : canFind, filter, map, max, min, sort;
import std.array : array, join;
import std.conv : to;
import std.datetime : Clock, SysTime, UTC, hours, minutes;
import std.digest.sha : sha1Of;
import std.digest : toHexString;
import std.file : exists, mkdirRecurse, readText, remove, timeLastModified, write, dirEntries, SpanMode;
import std.format : format;
import std.json;
import std.parallelism : TaskPool;
import std.path : buildPath, baseName;
import std.process : environment, pipeProcess, Redirect, wait, ProcessException;
import std.stdio : File, stderr, stdout, writeln;
import std.string : endsWith, indexOf, lastIndexOf, startsWith, strip, toLower;
import std.typecons : Nullable;
import std.uri : encodeComponent;

import search_heuristics;

// ---------------------------------------------------------------------------
// Tunables (I/O side; classification thresholds are in search_heuristics)
// ---------------------------------------------------------------------------

enum registryBase = "https://code.dlang.org";
enum githubApi = "https://api.github.com";
enum gitlabApi = "https://gitlab.com/api/v4";
/// How long a cached API response stays fresh.
enum cacheTtlMinutes = 60;
/// Parallel HTTP workers.
enum httpWorkers = 8;
/// Per-request timeout (seconds).
enum httpTimeoutSeconds = 20;
/// Run logs kept in the log directory.
enum keepLogs = 20;

/// Exit codes (documented in docs/search.adoc).
enum ExitCode : int
{
	ok = 0,
	failure = 1,
	usage = 2,
	network = 3,
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

struct SearchOptions
{
	string query;
	bool verbose;
	bool json;
	bool raw;
	bool noCache;
	string[] passthrough; /// args for --raw (everything except --raw)
}

/// Parse `dubx search` args. Returns null on success, else a usage error.
string parseSearchArgs(string[] args, out SearchOptions o)
{
	string[] words;
	foreach (a; args)
	{
		switch (a)
		{
		case "--raw": o.raw = true; continue;
		case "--verbose", "-v": o.verbose = true; break;
		case "--json": o.json = true; break;
		case "--no-cache": o.noCache = true; break;
		default:
			if (a.startsWith("-") && !o.raw)
			{
				o.passthrough ~= a;
				continue;
			}
			words ~= a;
		}
		o.passthrough ~= a;
	}
	if (!o.verbose && environment.get("DUBX_VERBOSE", "").length && environment.get("DUBX_VERBOSE") != "0")
		o.verbose = true;
	o.query = words.join(" ");
	if (o.raw)
		return null;
	foreach (a; args)
		if (a.startsWith("-") && !["--verbose", "-v", "--json", "--no-cache"].canFind(a))
			return "unknown option '" ~ a ~ "' (use --raw to pass options to dub search)";
	if (!o.query.length)
		return "missing query: dubx search <query> [--verbose] [--json] [--no-cache] [--raw]";
	return null;
}

unittest
{
	SearchOptions o;
	assert(parseSearchArgs(["yaml", "--json"], o) is null);
	assert(o.query == "yaml" && o.json && !o.verbose);
	SearchOptions o2;
	assert(parseSearchArgs(["--raw", "yaml", "--foo"], o2) is null);
	assert(o2.raw && o2.passthrough == ["yaml", "--foo"]);
	SearchOptions o3;
	assert(parseSearchArgs([], o3) !is null);
	SearchOptions o4;
	assert(parseSearchArgs(["x", "--bogus"], o4) !is null);
}

// ---------------------------------------------------------------------------
// Per-OS paths
// ---------------------------------------------------------------------------

private string homeDir()
{
	version (Windows)
		return environment.get("USERPROFILE", ".");
	else
		return environment.get("HOME", ".");
}

/// Cache directory for API responses.
string cacheDir()
{
	version (Windows)
		return buildPath(environment.get("LOCALAPPDATA", buildPath(homeDir(), "AppData", "Local")), "dubx", "cache", "http");
	else version (OSX)
		return buildPath(homeDir(), "Library", "Caches", "dubx", "http");
	else
		return buildPath(environment.get("XDG_CACHE_HOME", buildPath(homeDir(), ".cache")), "dubx", "http");
}

/// Log directory (CO-14).
string logDir()
{
	version (Windows)
		return buildPath(environment.get("LOCALAPPDATA", buildPath(homeDir(), "AppData", "Local")), "dubx", "logs");
	else version (OSX)
		return buildPath(homeDir(), "Library", "Logs", "dubx");
	else
		return buildPath(environment.get("XDG_STATE_HOME", buildPath(homeDir(), ".local", "state")), "dubx", "logs");
}

// ---------------------------------------------------------------------------
// Run log: JSON Lines, one event per line, `section` field (CO-6, CO-11)
// ---------------------------------------------------------------------------

final class RunLog
{
	string path;
	private File f;
	private bool echo;

	this(bool echoToStderr)
	{
		echo = echoToStderr;
		try
		{
			auto dir = logDir();
			mkdirRecurse(dir);
			auto ts = Clock.currTime(UTC());
			path = buildPath(dir, format("search-%04d-%02d-%02dT%02d-%02d-%02d.jsonl",
				ts.year, cast(int) ts.month, ts.day, ts.hour, ts.minute, ts.second));
			f = File(path, "w");
			rotate(dir);
		}
		catch (Exception)
		{
			path = null;
		}
	}

	private static void rotate(string dir)
	{
		auto logs = dirEntries(dir, "search-*.jsonl", SpanMode.shallow).map!(e => e.name).array;
		logs.sort();
		if (logs.length > keepLogs)
			foreach (old; logs[0 .. $ - keepLogs])
				try remove(old); catch (Exception) {}
	}

	void event(string section, string level, string msg)
	{
		synchronized (this)
		{
			if (echo)
				stderr.writeln("[", section, "] ", msg);
			if (path is null)
				return;
			JSONValue j = ["ts": Clock.currTime(UTC()).toISOExtString(), "section": section,
				"level": level, "msg": msg];
			f.writeln(j.toString());
			f.flush();
		}
	}
}

// ---------------------------------------------------------------------------
// HTTP via curl, with a small on-disk cache
// ---------------------------------------------------------------------------

struct HttpResult
{
	int status;      /// 0 = transport error
	string body_;
	bool fromCache;
	string error;
}

private string cacheFile(string url)
{
	return buildPath(cacheDir(), toHexString(sha1Of(url)).idup ~ ".txt");
}

HttpResult httpGet(string url, string[] headers, bool useCache, RunLog log)
{
	auto cf = cacheFile(url);
	if (useCache)
	{
		try
		{
			if (exists(cf) && Clock.currTime - timeLastModified(cf) < cacheTtlMinutes.minutes)
			{
				auto raw = readText(cf);
				auto nl = raw.indexOf('\n');
				if (nl > 0)
				{
					log.event("network", "debug", "cache " ~ url);
					return HttpResult(raw[0 .. nl].to!int, raw[nl + 1 .. $], true);
				}
			}
		}
		catch (Exception) {}
	}

	string cfg = "header = \"User-Agent: dubx-search\"\n";
	foreach (h; headers)
		cfg ~= "header = \"" ~ h ~ "\"\n";
	HttpResult r;
	try
	{
		auto p = pipeProcess(["curl", "-sS", "-L", "--max-time", httpTimeoutSeconds.to!string,
			"-K", "-", "-w", "\n%{http_code}", url], Redirect.all);
		p.stdin.write(cfg); // token travels via stdin config, not argv
		p.stdin.close();
		ubyte[] outBytes;
		foreach (chunk; p.stdout.byChunk(64 * 1024))
			outBytes ~= chunk;
		string err;
		foreach (line; p.stderr.byLine)
			err ~= line.idup ~ " ";
		auto rc = wait(p.pid);
		auto s = cast(string) outBytes;
		auto nl = s.lastIndexOf('\n');
		if (rc != 0 || nl < 0)
			r = HttpResult(0, null, false, err.strip.length ? err.strip : "curl exit " ~ rc.to!string);
		else
			r = HttpResult(s[nl + 1 .. $].strip.to!int, s[0 .. nl], false);
	}
	catch (ProcessException e)
	{
		r = HttpResult(0, null, false, "curl not found on PATH: " ~ e.msg);
	}
	catch (Exception e)
	{
		r = HttpResult(0, null, false, e.msg);
	}

	log.event("network", r.status == 200 ? "debug" : "warn",
		format("GET %s -> %s%s", url, r.status, r.error.length ? " (" ~ r.error ~ ")" : ""));

	if (r.status == 200 || r.status == 404)
	{
		try
		{
			mkdirRecurse(cacheDir());
			write(cf, r.status.to!string ~ "\n" ~ r.body_);
		}
		catch (Exception) {}
	}
	return r;
}

// ---------------------------------------------------------------------------
// JSON helpers and parsers (pure; unit-tested)
// ---------------------------------------------------------------------------

private string str(const JSONValue j, string key)
{
	if (j.type != JSONType.object)
		return null;
	if (auto p = key in j.object)
		if (p.type == JSONType.string)
			return p.str;
	return null;
}

private long num(const JSONValue j, string key, long dflt = -1)
{
	if (j.type != JSONType.object)
		return dflt;
	if (auto p = key in j.object)
	{
		if (p.type == JSONType.integer) return p.integer;
		if (p.type == JSONType.uinteger) return cast(long) p.uinteger;
		if (p.type == JSONType.float_) return cast(long) p.floating;
	}
	return dflt;
}

private Nullable!SysTime parseTime(string s)
{
	Nullable!SysTime r;
	if (!s.length)
		return r;
	try
		r = SysTime.fromISOExtString(s.indexOf('Z') < 0 && s.indexOf('+') < 0 ? s ~ "Z" : s);
	catch (Exception) {}
	return r;
}

struct SearchHit
{
	string name, description, version_;
}

SearchHit[] parseSearch(string body_)
{
	SearchHit[] hits;
	auto j = parseJSON(body_);
	if (j.type != JSONType.array)
		return hits;
	foreach (e; j.array)
		hits ~= SearchHit(str(e, "name"), str(e, "description"), str(e, "version"));
	return hits;
}

/// Fill registry facts from `/api/packages/<name>/info`.
void applyInfo(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	if (auto rp = "repository" in j.object)
	{
		f.repoKind = str(*rp, "kind");
		auto owner = str(*rp, "owner"), project = str(*rp, "project");
		if (owner.length && project.length)
			f.repoSlug = owner ~ "/" ~ project;
	}
	if (auto vp = "versions" in j.object)
	{
		const(JSONValue)* newest;     // newest release
		const(JSONValue)* newestAny;  // newest of anything
		SysTime newestAnyT;
		foreach (ref v; vp.array)
		{
			auto ver = str(v, "version");
			auto t = parseTime(str(v, "date"));
			if (ver.startsWith("~"))
			{
				if (!t.isNull && (f.lastBranchCommit.isNull || t.get > f.lastBranchCommit.get))
					f.lastBranchCommit = t;
			}
			else
			{
				f.releaseCount++;
				if (!t.isNull && (f.lastRelease.isNull || t.get > f.lastRelease.get))
				{
					f.lastRelease = t;
					f.lastReleaseVersion = ver;
					newest = &v;
				}
			}
			if (!t.isNull && (newestAny is null || t.get > newestAnyT))
			{
				newestAny = &v;
				newestAnyT = t.get;
			}
		}
		auto pick = newest !is null ? newest : newestAny;
		if (pick !is null)
		{
			f.hasReadme = str(*pick, "readme").strip.length > 0;
			foreach (key; ["x:status", "status"])
			{
				auto st = str(*pick, key).strip.toLower;
				if (st.length && declaredStatuses.canFind(st))
				{
					f.declaredStatus = st;
					break;
				}
			}
			if (auto dp = "dependencies" in pick.object)
				if (dp.type == JSONType.object)
					f.dependencies = dp.object.keys.sort.array;
		}
	}
}

/// Fill download / star counts from `/api/packages/<name>/stats`.
void applyStats(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	if (auto dp = "downloads" in j.object)
	{
		f.downloadsTotal = num(*dp, "total");
		f.downloadsMonthly = num(*dp, "monthly");
	}
	if (f.stars < 0)
		if (auto rp = "repo" in j.object)
			f.stars = num(*rp, "stars");
}

/// Fill repo state from a GitHub `/repos/<owner>/<repo>` 200 response.
void applyGitHub(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	f.repo = RepoState.ok;
	if (auto ap = "archived" in j.object)
		if (ap.type == JSONType.true_)
			f.repo = RepoState.archived;
	f.repoPushed = parseTime(str(j, "pushed_at"));
	auto stars = num(j, "stargazers_count");
	if (stars >= 0)
		f.stars = stars;
	f.openIssues = num(j, "open_issues_count");
	f.defaultBranch = str(j, "default_branch");
	auto full = str(j, "full_name");
	if (f.repo == RepoState.ok && full.length && full.toLower != f.repoSlug.toLower)
	{
		f.repo = RepoState.moved;
		f.repoMovedTo = full;
	}
}

/// Read a maintainer-declared `x:status` from raw dub.sdl / dub.json text.
/// dub drops unknown recipe keys, so the registry never sees this key; dubx
/// reads the recipe file straight from the repository instead.
string declaredStatusFromRecipe(string text, bool json)
{
	import std.regex : matchFirst, regex;
	auto m = json ? matchFirst(text, regex(`"x:status"\s*:\s*"([^"]+)"`))
		: matchFirst(text, regex(`^\s*x:status\s+"([^"]+)"`, "m"));
	if (m.empty)
		return null;
	auto st = m[1].strip.toLower;
	return declaredStatuses.canFind(st) ? st : null;
}

/// Count recent issues (not PRs) that were closed or got a comment.
void applyIssues(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	if (j.type != JSONType.array)
		return;
	f.issuesSampled = 0;
	f.issuesAnswered = 0;
	foreach (e; j.array)
	{
		if (e.type != JSONType.object || ("pull_request" in e.object) !is null)
			continue;
		f.issuesSampled++;
		if (str(e, "state") == "closed" || num(e, "comments", 0) > 0)
			f.issuesAnswered++;
	}
}

/// Fill repo state from a GitLab `/projects/<id>` 200 response.
void applyGitLab(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	f.repo = RepoState.ok;
	if (auto ap = "archived" in j.object)
		if (ap.type == JSONType.true_)
			f.repo = RepoState.archived;
	f.repoPushed = parseTime(str(j, "last_activity_at"));
	f.defaultBranch = str(j, "default_branch");
	auto stars = num(j, "star_count");
	if (stars >= 0)
		f.stars = stars;
}

// --- CI status reported by the package's own CI (build-status step a) ---

private Nullable!SysTime newer(Nullable!SysTime a, Nullable!SysTime b)
{
	if (a.isNull) return b;
	if (b.isNull) return a;
	return a.get > b.get ? a : b;
}

/// GitHub `GET /repos/{o}/{r}/commits/{ref}/check-runs`. Returns false when
/// there are no check runs (caller then tries the commit-status API).
bool applyCheckRuns(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	auto runs = "check_runs" in j.object;
	if (runs is null || runs.type != JSONType.array || !runs.array.length)
		return false;
	bool failing, pending;
	Nullable!SysTime last;
	string url;
	foreach (r; runs.array)
	{
		auto st = str(r, "status"), c = str(r, "conclusion");
		if (st != "completed")
			pending = true;
		else if (["failure", "timed_out", "action_required", "startup_failure"].canFind(c))
		{
			failing = true;
			if (!url.length) url = str(r, "html_url");
		}
		last = newer(last, parseTime(str(r, "completed_at")));
	}
	f.ciState = failing ? "failing" : pending ? "pending" : "passing";
	f.ciSource = "github-checks";
	f.ciDate = last;
	if (url.length) f.ciUrl = url;
	return true;
}

/// GitHub `GET /repos/{o}/{r}/commits/{ref}/status` (combined commit status).
bool applyCombinedStatus(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	if (num(j, "total_count", 0) <= 0)
		return false;
	auto st = str(j, "state");
	f.ciState = st == "success" ? "passing" : st == "pending" ? "pending" : "failing";
	f.ciSource = "github-status";
	if (auto sp = "statuses" in j.object)
		if (sp.type == JSONType.array)
			foreach (e; sp.array)
			{
				f.ciDate = newer(f.ciDate, parseTime(str(e, "updated_at")));
				if (!f.ciUrl.length) f.ciUrl = str(e, "target_url");
			}
	return true;
}

/// GitLab `GET /projects/:id/pipelines?ref=<ref>&per_page=1`.
bool applyGitLabPipelines(ref Facts f, string body_)
{
	auto j = parseJSON(body_);
	if (j.type != JSONType.array || !j.array.length)
		return false;
	auto p = j.array[0];
	auto st = str(p, "status");
	if (st == "success") f.ciState = "passing";
	else if (st == "failed") f.ciState = "failing";
	else if (["running", "pending", "created", "waiting_for_resource", "preparing", "scheduled"].canFind(st)) f.ciState = "pending";
	else return false; // canceled, skipped, manual: says nothing
	f.ciSource = "gitlab-pipeline";
	f.ciDate = parseTime(str(p, "updated_at"));
	f.ciUrl = str(p, "web_url");
	return true;
}

// --- Remembered repo state (dubx cache): when a 404 was first seen ---

/// Key in the repo-state file.
string repoStateKey(const ref Facts f)
{
	return f.repoKind ~ ":" ~ f.repoSlug.toLower;
}

/// Merge one package into the remembered repo state and back.
/// 404/451: keep the first-seen date (record `now` if new) and restore a
/// declared status remembered from when the repo was reachable. Reachable:
/// forget the 404 date and remember the declared status.
void syncRepoState(ref JSONValue state, ref Facts f, SysTime now)
{
	if (!f.repoSlug.length || f.repo == RepoState.unknown || f.repo == RepoState.notChecked)
		return;
	if (state.type != JSONType.object)
		state = JSONValue(string[string].init);
	auto key = repoStateKey(f);
	JSONValue e = (key in state.object) ? state[key] : JSONValue(string[string].init);
	if (f.repo == RepoState.gone)
	{
		auto since = parseTime(str(e, "firstGone"));
		if (since.isNull)
		{
			since = now;
			e["firstGone"] = now.toISOExtString();
		}
		f.repoGoneSince = since;
		if (!f.declaredStatus.length)
		{
			auto d = str(e, "declaredStatus");
			if (declaredStatuses.canFind(d))
				f.declaredStatus = d;
		}
	}
	else
	{
		if ("firstGone" in e.object)
			e.object.remove("firstGone");
		if (f.declaredStatus.length)
			e["declaredStatus"] = f.declaredStatus;
		else if ("declaredStatus" in e.object)
			e.object.remove("declaredStatus");
	}
	if (e.object.length)
		state[key] = e;
	else if (key in state.object)
		state.object.remove(key);
}

unittest
{
	import std.datetime : DateTime;
	auto t0 = SysTime(DateTime(2026, 9, 1), UTC());
	auto t1 = SysTime(DateTime(2026, 10, 26), UTC());
	JSONValue st;
	Facts ok = { name: "p", repoKind: "github", repoSlug: "o/P", repo: RepoState.ok, declaredStatus: "complete" };
	syncRepoState(st, ok, t0);
	assert(st["github:o/p"]["declaredStatus"].str == "complete");
	Facts gone = { name: "p", repoKind: "github", repoSlug: "o/p", repo: RepoState.gone };
	syncRepoState(st, gone, t0);
	assert(gone.repoGoneSince.get == t0 && gone.declaredStatus == "complete");
	Facts again = { name: "p", repoKind: "github", repoSlug: "o/p", repo: RepoState.gone };
	syncRepoState(st, again, t1);
	assert(again.repoGoneSince.get == t0); // first-seen date is kept
	assert(goneSustained(again, t1));
	Facts back = { name: "p", repoKind: "github", repoSlug: "o/p", repo: RepoState.ok };
	syncRepoState(st, back, t1);
	assert(("github:o/p" in st.object) is null); // repo back, nothing declared: forgotten

	Facts c;
	assert(applyCheckRuns(c, `{"total_count":2,"check_runs":[
		{"status":"completed","conclusion":"success","completed_at":"2024-06-20T10:00:00Z"},
		{"status":"completed","conclusion":"skipped","completed_at":"2024-06-21T10:00:00Z"}]}`));
	assert(c.ciState == "passing" && c.ciDate.get.day == 21);
	Facts c2;
	assert(applyCheckRuns(c2, `{"total_count":1,"check_runs":[{"status":"completed","conclusion":"failure","html_url":"u"}]}`));
	assert(c2.ciState == "failing" && c2.ciUrl == "u");
	Facts c3;
	assert(!applyCheckRuns(c3, `{"total_count":0,"check_runs":[]}`) && !c3.ciState.length);
	assert(!applyCombinedStatus(c3, `{"state":"pending","total_count":0,"statuses":[]}`));
	assert(applyCombinedStatus(c3, `{"state":"success","total_count":1,"statuses":[{"updated_at":"2020-01-02T00:00:00Z","target_url":"t"}]}`));
	assert(c3.ciState == "passing" && c3.ciSource == "github-status" && c3.ciUrl == "t");
	Facts c4;
	assert(applyGitLabPipelines(c4, `[{"status":"failed","updated_at":"2021-03-04T00:00:00Z","web_url":"w"}]`));
	assert(c4.ciState == "failing" && c4.ciUrl == "w");
	assert(!applyGitLabPipelines(c4, `[]`));
}

unittest
{
	auto hits = parseSearch(`[{"name":"dyaml","description":"YAML parser and emitter","version":"0.10.0"},
		{"name":"dyaml:yaml_gen","description":"x","version":"0.10.0"}]`);
	assert(hits.length == 2 && hits[1].name == "dyaml:yaml_gen");

	Facts f;
	f.name = "yaml-d";
	applyInfo(f, `{"name":"yaml-d","repository":{"kind":"github","owner":"LLC-CERERIS","project":"yaml-d"},
		"versions":[
		 {"version":"~dev","date":"2017-03-19T18:25:52Z","readme":"x","dependencies":{"tinyendian":"~>0.1.0"}},
		 {"version":"~master","date":"2017-05-16T10:34:15Z","readme":"","dependencies":{}},
		 {"version":"0.0.1","date":"2017-05-16T10:34:15Z","readme":"# yaml-d","dependencies":{"tinyendian":"~>0.1.0"}}]}`);
	assert(f.repoKind == "github" && f.repoSlug == "LLC-CERERIS/yaml-d");
	assert(f.releaseCount == 1 && f.lastReleaseVersion == "0.0.1");
	assert(f.lastRelease.get.year == 2017 && f.hasReadme);
	assert(f.dependencies == ["tinyendian"]);

	applyStats(f, `{"downloads":{"total":1049,"monthly":0},"repo":{"stars":0}}`);
	assert(f.downloadsTotal == 1049 && f.downloadsMonthly == 0 && f.stars == 0);

	Facts g;
	g.repoSlug = "kiith-sa/D-YAML";
	applyGitHub(g, `{"full_name":"dlang-community/D-YAML","archived":false,"pushed_at":"2026-01-24T17:04:19Z","stargazers_count":120}`);
	assert(g.repo == RepoState.moved && g.repoMovedTo == "dlang-community/D-YAML");
	assert(g.repoPushed.get.year == 2026 && g.stars == 120);

	Facts a;
	a.repoSlug = "o/p";
	applyGitHub(a, `{"full_name":"o/p","archived":true,"pushed_at":"2019-01-01T00:00:00Z"}`);
	assert(a.repo == RepoState.archived);

	Facts iss;
	applyIssues(iss, `[{"state":"closed","comments":0},{"state":"open","comments":2},
		{"state":"open","comments":0},{"state":"open","comments":5,"pull_request":{}}]`);
	assert(iss.issuesSampled == 3 && iss.issuesAnswered == 2);

	assert(declaredStatusFromRecipe("name \"a\"\nx:status \"complete\"\n", false) == "complete");
	assert(declaredStatusFromRecipe(`{"name":"a","x:status": "Deprecated"}`, true) == "deprecated");
	assert(declaredStatusFromRecipe(`{"x:status":"bogus"}`, true) is null);

	Facts ds;
	applyInfo(ds, `{"versions":[{"version":"1.0.0","date":"2020-01-01T00:00:00Z","x:status":"Complete"}]}`);
	assert(ds.declaredStatus == "complete");
}

// ---------------------------------------------------------------------------
// Gathering
// ---------------------------------------------------------------------------

private shared bool githubRateLimited;
private shared bool githubAuthed;

private string githubToken()
{
	auto t = environment.get("GH_TOKEN", "");
	if (!t.length)
		t = environment.get("GITHUB_TOKEN", "");
	return t;
}

private bool isRateLimit(const HttpResult r)
{
	return (r.status == 403 || r.status == 429) && r.body_.toLower.indexOf("rate limit") >= 0;
}

private void gather(ref Facts f, bool useCache, RunLog log)
{
	if (f.name.indexOf(':') >= 0)
		return; // subpackage: classified by name, no lookups needed

	auto enc = encodeComponent(f.name);
	auto info = httpGet(registryBase ~ "/api/packages/" ~ enc ~ "/info", null, useCache, log);
	if (info.status == 200)
	{
		try applyInfo(f, info.body_);
		catch (Exception e) { f.registryError = true; log.event("registry", "warn", f.name ~ ": bad info JSON: " ~ e.msg); }
	}
	else
		f.registryError = true;

	auto stats = httpGet(registryBase ~ "/api/packages/" ~ enc ~ "/stats", null, useCache, log);
	if (stats.status == 200)
		try applyStats(f, stats.body_); catch (Exception) {}

	if (!f.repoSlug.length)
		return;
	switch (f.repoKind)
	{
	case "github":
		if (atomicLoad(githubRateLimited))
			return;
		string[] hdr = ["Accept: application/vnd.github+json"];
		auto tok = githubToken();
		if (tok.length)
			hdr ~= "Authorization: Bearer " ~ tok;
		auto r = httpGet(githubApi ~ "/repos/" ~ f.repoSlug, hdr, useCache, log);
		if (r.status == 200)
		{
			try applyGitHub(f, r.body_); catch (Exception) {}
			// Declared status from the recipe on the default branch (raw host: no API quota).
			if (!f.declaredStatus.length && (f.repo == RepoState.ok || f.repo == RepoState.moved))
			{
				auto slug0 = f.repo == RepoState.moved ? f.repoMovedTo : f.repoSlug;
				foreach (file; ["dub.sdl", "dub.json"])
				{
					auto rr = httpGet("https://raw.githubusercontent.com/" ~ slug0 ~ "/HEAD/" ~ file, null, useCache, log);
					if (rr.status == 200)
					{
						f.declaredStatus = declaredStatusFromRecipe(rr.body_, file == "dub.json");
						break;
					}
				}
			}
			// CI status the package's own CI reported (build-status step a).
			if ((f.repo == RepoState.ok || f.repo == RepoState.moved) && !atomicLoad(githubRateLimited))
			{
				auto slug = f.repo == RepoState.moved ? f.repoMovedTo : f.repoSlug;
				if (!resolveGitHubCi(f, slug, (string u) => httpGet(u, hdr, useCache, log)))
					atomicStore(githubRateLimited, true);
			}
			// Issue responsiveness only matters for quiet packages; saves API quota.
			auto last = lastActivity(f);
			if ((f.repo == RepoState.ok || f.repo == RepoState.moved) && !last.isNull
				&& (Clock.currTime(UTC()) - last.get).total!"days" > defaultThresholds.activeDays
				&& !atomicLoad(githubRateLimited))
			{
				auto slug = f.repo == RepoState.moved ? f.repoMovedTo : f.repoSlug;
				auto ir = httpGet(format("%s/repos/%s/issues?state=all&per_page=%s", githubApi, slug,
					defaultThresholds.issueSample), hdr, useCache, log);
				if (ir.status == 200)
					try applyIssues(f, ir.body_); catch (Exception) {}
				else if (isRateLimit(ir))
					atomicStore(githubRateLimited, true);
			}
		}
		else if (r.status == 404 || r.status == 451)
			f.repo = RepoState.gone;
		else if (isRateLimit(r))
		{
			atomicStore(githubRateLimited, true);
			log.event("network", "warn", "GitHub API rate limit hit; remaining repos use registry dates only");
		}
		break;
	case "gitlab":
		auto r = httpGet(gitlabApi ~ "/projects/" ~ encodeComponent(f.repoSlug), null, useCache, log);
		if (r.status == 200)
		{
			try applyGitLab(f, r.body_); catch (Exception) {}
			if (f.repo == RepoState.ok)
				resolveGitLabCi(f, (string u) => httpGet(u, null, useCache, log));
		}
		else if (r.status == 404 || r.status == 451)
			f.repo = RepoState.gone;
		break;
	default:
		f.repo = RepoState.notChecked;
	}
}

/// Release tags to try for the latest registry version, in order.
/// There is deliberately no branch fallback: a CI result is reported only
/// when it belongs to exactly the commit the registry serves.
string[] releaseTags(const ref Facts f)
{
	if (!f.lastReleaseVersion.length)
		return null;
	return ["v" ~ f.lastReleaseVersion, f.lastReleaseVersion];
}

alias Fetch = HttpResult delegate(string url);

/// Parse GitHub `git/ref/tags/<t>` or `git/tags/<sha>` JSON: returns
/// [objectType, sha] of the object it points at.
string[2] gitObject(string body_)
{
	auto j = parseJSON(body_);
	auto o = "object" in j.object;
	if (o is null || o.type != JSONType.object)
		return ["", ""];
	return [str(*o, "type"), str(*o, "sha")];
}

/// Merge two CI readings of the same commit: failing beats pending beats passing.
private void mergeCi(ref Facts f, const ref Facts g)
{
	if (!g.ciState.length) return;
	int rank(string s) { return s == "failing" ? 3 : s == "pending" ? 2 : s == "passing" ? 1 : 0; }
	if (rank(g.ciState) > rank(f.ciState))
	{
		f.ciState = g.ciState;
		f.ciSource = g.ciSource;
		if (g.ciUrl.length) f.ciUrl = g.ciUrl;
	}
	else if (f.ciSource.length && f.ciSource != g.ciSource && rank(g.ciState) == rank(f.ciState))
		f.ciSource ~= "+" ~ g.ciSource;
	f.ciDate = newer(f.ciDate, g.ciDate);
}

/// GitHub: resolve the latest release tag to its commit (peeling annotated
/// tags), then read check runs and the combined status for that SHA.
/// Returns false when GitHub rate-limited us.
bool resolveGitHubCi(ref Facts f, string slug, Fetch get)
{
	auto tags = releaseTags(f);
	if (!tags.length) { f.ciNoneReason = "no release version in the registry"; return true; }
	string tag, sha;
	foreach (t; tags)
	{
		auto r = get(format("%s/repos/%s/git/ref/tags/%s", githubApi, slug, encodeComponent(t)));
		if (isRateLimit(r)) return false;
		if (r.status != 200) continue;
		string[2] o;
		try o = gitObject(r.body_); catch (Exception) { continue; }
		foreach (_; 0 .. 5) // peel annotated (possibly nested) tags
		{
			if (o[0] != "tag") break;
			auto tr = get(format("%s/repos/%s/git/tags/%s", githubApi, slug, o[1]));
			if (isRateLimit(tr)) return false;
			if (tr.status != 200) { o = ["", ""]; break; }
			try o = gitObject(tr.body_); catch (Exception) { o = ["", ""]; break; }
		}
		if (o[0] == "commit" && o[1].length) { tag = t; sha = o[1]; break; }
	}
	if (!sha.length) { f.ciNoneReason = "no tag v" ~ f.lastReleaseVersion ~ " or " ~ f.lastReleaseVersion ~ " in the repo"; return true; }
	f.ciRef = tag;
	f.ciSha = sha;
	auto base = format("%s/repos/%s/commits/%s/", githubApi, slug, sha);
	Facts a, b;
	auto cr = get(base ~ "check-runs?per_page=100");
	if (isRateLimit(cr)) return false;
	if (cr.status == 200) try applyCheckRuns(a, cr.body_); catch (Exception) {}
	auto sr = get(base ~ "status");
	if (isRateLimit(sr)) return false;
	if (sr.status == 200) try applyCombinedStatus(b, sr.body_); catch (Exception) {}
	mergeCi(f, a);
	mergeCi(f, b);
	if (!f.ciState.length)
		f.ciNoneReason = "no CI results on the release commit";
	else if (!f.ciUrl.length || f.ciState == "passing")
		f.ciUrl = format("https://github.com/%s/commit/%s", slug, sha);
	return true;
}

/// GitLab: tag -> commit id (GitLab returns the peeled commit), then the
/// newest pipeline for that SHA.
void resolveGitLabCi(ref Facts f, Fetch get)
{
	auto tags = releaseTags(f);
	if (!tags.length) { f.ciNoneReason = "no release version in the registry"; return; }
	auto proj = gitlabApi ~ "/projects/" ~ encodeComponent(f.repoSlug);
	foreach (t; tags)
	{
		auto r = get(proj ~ "/repository/tags/" ~ encodeComponent(t));
		if (r.status != 200) continue;
		string sha;
		try
		{
			auto j = parseJSON(r.body_);
			if (auto c = "commit" in j.object) sha = str(*c, "id");
		}
		catch (Exception) {}
		if (!sha.length) continue;
		f.ciRef = t;
		f.ciSha = sha;
		auto pr = get(proj ~ "/pipelines?sha=" ~ sha ~ "&per_page=1");
		bool got;
		if (pr.status == 200) try got = applyGitLabPipelines(f, pr.body_); catch (Exception) {}
		if (!got) f.ciNoneReason = "no CI results on the release commit";
		return;
	}
	f.ciNoneReason = "no tag v" ~ f.lastReleaseVersion ~ " or " ~ f.lastReleaseVersion ~ " in the repo";
}

unittest
{
	// Fake host: tag v1.0.0 is annotated and points at commit AAA; main HEAD
	// is a different commit BBB whose CI fails. Only AAA may be reported.
	string[] asked;
	HttpResult fake(string url)
	{
		asked ~= url;
		HttpResult r;
		r.status = 200;
		if (url.endsWith("/git/ref/tags/v1.0.0"))
			r.body_ = `{"object":{"type":"tag","sha":"T1"}}`;
		else if (url.endsWith("/git/tags/T1"))
			r.body_ = `{"object":{"type":"commit","sha":"AAA"}}`;
		else if (url.canFind("/commits/AAA/check-runs"))
			r.body_ = `{"total_count":0,"check_runs":[]}`;
		else if (url.canFind("/commits/AAA/status"))
			r.body_ = `{"state":"pending","total_count":0,"statuses":[]}`;
		else if (url.canFind("/commits/main/") || url.canFind("/commits/BBB/"))
			r.body_ = `{"total_count":1,"check_runs":[{"status":"completed","conclusion":"failure"}]}`;
		else
			r.status = 404;
		return r;
	}
	Facts f = { name: "p", lastReleaseVersion: "1.0.0", defaultBranch: "main" };
	assert(resolveGitHubCi(f, "o/p", &fake));
	assert(f.ciState == "" && f.ciSha == "AAA" && f.ciRef == "v1.0.0", f.ciState);
	assert(f.ciNoneReason == "no CI results on the release commit");
	assert(!asked.canFind!(u => u.canFind("main") || u.canFind("BBB")));

	// A run from a push to main on the *same* commit counts: it tested the same code.
	HttpResult fake2(string url)
	{
		HttpResult r;
		r.status = 200;
		if (url.endsWith("/git/ref/tags/v2.0.0")) r.status = 404;
		else if (url.endsWith("/git/ref/tags/2.0.0")) r.body_ = `{"object":{"type":"commit","sha":"CCC"}}`;
		else if (url.canFind("/commits/CCC/check-runs"))
			r.body_ = `{"total_count":1,"check_runs":[{"status":"completed","conclusion":"success","completed_at":"2025-01-02T00:00:00Z"}]}`;
		else if (url.canFind("/commits/CCC/status"))
			r.body_ = `{"state":"pending","total_count":0,"statuses":[]}`;
		else r.status = 404;
		return r;
	}
	Facts g = { name: "q", lastReleaseVersion: "2.0.0" };
	assert(resolveGitHubCi(g, "o/q", &fake2));
	assert(g.ciState == "passing" && g.ciRef == "2.0.0" && g.ciSha == "CCC");

	// No tag at all: no CI, never passing or failing.
	Facts h = { name: "r", lastReleaseVersion: "3.0.0", defaultBranch: "main" };
	assert(resolveGitHubCi(h, "o/r", &fake));
	assert(h.ciState == "" && h.ciSha == "" && h.ciNoneReason.canFind("no tag"));

	// GitLab: tag -> commit -> pipeline by SHA
	HttpResult gl(string url)
	{
		HttpResult r;
		r.status = 200;
		if (url.endsWith("/repository/tags/v1.0.0")) r.body_ = `{"name":"v1.0.0","commit":{"id":"DDD"}}`;
		else if (url.canFind("pipelines?sha=DDD")) r.body_ = `[{"status":"success","web_url":"w"}]`;
		else r.status = 404;
		return r;
	}
	Facts k = { name: "k", repoSlug: "o/k", lastReleaseVersion: "1.0.0" };
	resolveGitLabCi(k, &gl);
	assert(k.ciState == "passing" && k.ciSha == "DDD" && k.ciUrl == "w");
}

/// Remembered per-repo state (first 404 date, last declared status).
string repoStatePath()
{
	import std.path : dirName;
	return buildPath(dirName(cacheDir()), "repo-state.json");
}

private JSONValue loadRepoState()
{
	try
		if (exists(repoStatePath()))
			return parseJSON(readText(repoStatePath()));
	catch (Exception) {}
	return JSONValue(string[string].init);
}

private void saveRepoState(JSONValue st)
{
	try
	{
		mkdirRecurse(cacheDir());
		write(repoStatePath(), st.toPrettyString());
	}
	catch (Exception) {}
}

struct Row
{
	Facts facts;
	Verdict verdict;
}

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------

int cmdSearch(SearchOptions o)
{
	auto log = new RunLog(o.verbose && !o.json);
	auto useCache = !o.noCache;
	atomicStore(githubAuthed, githubToken().length > 0);
	log.event("search", "info", "query '" ~ o.query ~ "'" ~ (atomicLoad(githubAuthed) ? " (GitHub token set)" : " (no GitHub token)"));

	auto res = httpGet(registryBase ~ "/api/packages/search?q=" ~ encodeComponent(o.query), null, useCache, log);
	SearchHit[] hits;
	string failure;
	if (res.status != 200)
		failure = res.status == 0 ? res.error : format("code.dlang.org search returned HTTP %s", res.status);
	else
	{
		try hits = parseSearch(res.body_);
		catch (Exception e) failure = "could not parse search response: " ~ e.msg;
	}
	if (failure.length)
	{
		if (o.json)
			writeln(resultJson(o, null, ExitCode.network, failure, null, log.path).toPrettyString());
		stderr.writeln("dubx search: ", failure);
		if (log.path.length)
			stderr.writeln("log: ", log.path);
		return ExitCode.network;
	}

	auto rows = new Row[hits.length];
	foreach (i, h; hits)
	{
		rows[i].facts.name = h.name;
		rows[i].facts.description = h.description;
		rows[i].facts.latestVersion = h.version_;
	}

	auto pool = new TaskPool(httpWorkers);
	scope (exit) pool.finish();
	foreach (ref r; pool.parallel(rows, 1))
		gather(r.facts, useCache, log);

	auto now = Clock.currTime(UTC());
	auto state = loadRepoState();
	foreach (ref r; rows)
		syncRepoState(state, r.facts, now);
	saveRepoState(state);

	{
		auto fs = rows.map!(r => r.facts).array;
		computeDependents(fs);
		foreach (i, ref r; rows)
			r.facts.dependentsInResults = fs[i].dependentsInResults;
	}

	auto resultNames = hits.map!(h => parentName(h.name)).array;
	foreach (ref r; rows)
	{
		r.verdict = classify(r.facts, resultNames, now);
		log.event("classify", "info", format("%s -> %s: %s", r.facts.name, bucketKey(r.verdict.bucket), r.verdict.reason));
	}

	string[] attention;
	if (atomicLoad(githubRateLimited))
		attention ~= "GitHub API rate limit hit; some repos judged from registry dates only"
			~ (atomicLoad(githubAuthed) ? "" : " (set GH_TOKEN for 5000 req/h)") ~ " - see log section network";
	auto regErrors = rows.filter!(r => r.facts.registryError).array.length;
	if (regErrors)
		attention ~= format("%s package(s) had no registry info - see log section network", regErrors);

	if (o.json)
		writeln(resultJson(o, rows, ExitCode.ok, null, attention, log.path).toPrettyString());
	else
		printHuman(o, rows);

	foreach (a; attention)
		stderr.writeln("dubx search: ", a);
	if (log.path.length)
		stderr.writeln("log: ", log.path);
	return ExitCode.ok;
}

private string fmtDate(const Nullable!SysTime t)
{
	return t.isNull ? null : t.get.toISOExtString()[0 .. 10];
}

/// Public how-to for package authors: link CI to a release. dubx docs are
/// not published to an Antora site (no antora.yml), so this is the GitHub view.
enum ciHelpUrl = "https://github.com/dlang-supplemental/dubx/blob/main/docs/ci-status-for-releases.adoc";

/// `text` as an OSC 8 hyperlink to `url`, or "text: url" when hyperlinks are off.
string hyperlink(string text, string url, bool osc8)
{
	return osc8 ? "\x1b]8;;" ~ url ~ "\x1b\\" ~ text ~ "\x1b]8;;\x1b\\" : text ~ ": " ~ url;
}

unittest
{
	assert(hyperlink("how to fix", "https://x", true) == "\x1b]8;;https://x\x1b\\how to fix\x1b]8;;\x1b\\");
	assert(hyperlink("how to fix", "https://x", false) == "how to fix: https://x");
	string[string] env;
	assert(!osc8Supported(true, env));
	env["WT_SESSION"] = "1";
	assert(osc8Supported(true, env) && !osc8Supported(false, env));
	env["DUBX_NO_HYPERLINKS"] = "1";
	assert(!osc8Supported(true, env));
	string[string] vte = ["VTE_VERSION": "7200"];
	assert(osc8Supported(true, vte));
}

/// OSC 8 only on a terminal known to render it (unknown terminals would show
/// escape garbage). DUBX_NO_HYPERLINKS=1 turns it off.
bool osc8Supported(bool isTty, const string[string] env)
{
	if (!isTty || "DUBX_NO_HYPERLINKS" in env)
		return false;
	auto get = (string k) => (k in env) ? env[k] : "";
	import std.conv : to;
	if (get("WT_SESSION").length || get("KONSOLE_VERSION").length || get("KITTY_WINDOW_ID").length
		|| get("WEZTERM_EXECUTABLE").length || get("DOMTERM").length)
		return true;
	if (["vscode", "iTerm.app", "WezTerm", "Hyper", "ghostty", "Tabby"].canFind(get("TERM_PROGRAM")))
		return true;
	auto vte = get("VTE_VERSION");
	try if (vte.length && vte.to!int >= 5000) return true; catch (Exception) {}
	auto term = get("TERM");
	return term.canFind("kitty") || term.canFind("foot") || term.canFind("ghostty") || term.canFind("wezterm");
}

private bool stdoutIsTty()
{
	version (Windows)
	{
		import core.sys.windows.windows : GetStdHandle, GetConsoleMode, STD_OUTPUT_HANDLE, DWORD;
		DWORD mode;
		return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
	}
	else
	{
		import core.sys.posix.unistd : isatty;
		return isatty(1) != 0;
	}
}

private void printHuman(const SearchOptions o, Row[] rows)
{
	import std.process : environment;
	auto osc8 = osc8Supported(stdoutIsTty(), environment.toAA);
	size_t nameW = 4, verW = 3;
	foreach (r; rows)
	{
		nameW = max(nameW, r.facts.name.length);
		verW = max(verW, r.facts.latestVersion.length);
	}
	writeln(format("%s package(s) for '%s'", rows.length, o.query));
	foreach (b; [Bucket.active, Bucket.slow, Bucket.finished, Bucket.quiet, Bucket.unmaintained,
		Bucket.gone, Bucket.wrapper, Bucket.unknown])
	{
		auto inB = rows.filter!(r => r.verdict.bucket == b).array;
		if (!inB.length)
			continue;
		writeln();
		writeln(bucketLabel(b), " (", inB.length, ")");
		foreach (r; inB)
		{
			writeln(format("  %-*s  %-*s  %s", nameW, r.facts.name, verW, r.facts.latestVersion, r.verdict.reason));
			if (o.verbose)
			{
				string[] d;
				if (r.facts.repoSlug.length) d ~= r.facts.repoKind ~ ":" ~ r.facts.repoSlug;
				if (r.facts.repo == RepoState.gone && !r.facts.repoGoneSince.isNull)
					d ~= "repo unreachable since " ~ fmtDate(r.facts.repoGoneSince);
				d ~= r.facts.ciState.length
					? format("CI %s (%s, %s @ %s%s, reported by the package's own CI) %s", r.facts.ciState, r.facts.ciSource,
						r.facts.ciRef, r.facts.ciSha[0 .. min(7, $)], r.facts.ciDate.isNull ? "" : ", " ~ fmtDate(r.facts.ciDate), r.facts.ciUrl)
					: "CI: none for release" ~ (r.facts.ciNoneReason.length ? " (" ~ r.facts.ciNoneReason ~ ")" : "")
						~ " – " ~ hyperlink("how to link CI to a release", ciHelpUrl, osc8);
				if (r.facts.dependentsInResults.length)
					d ~= "used by (in these results) " ~ r.facts.dependentsInResults.join(", ");
				if (r.facts.openIssues >= 0) d ~= format("open issues+PRs %s", r.facts.openIssues);
				if (r.facts.stars >= 0) d ~= format("stars %s", r.facts.stars);
				if (r.facts.downloadsTotal >= 0) d ~= format("downloads %s total, %s/month", r.facts.downloadsTotal, r.facts.downloadsMonthly);
				d ~= r.facts.hasReadme ? "readme yes" : "readme no";
				if (r.facts.description.length) d ~= r.facts.description;
				writeln("  ", ' '.repeatChar(nameW), "  ", d.join(" | "));
			}
		}
	}
	if (rows.canFind!(r => r.facts.dependentsInResults.length > 0))
	{
		writeln();
		writeln("\"used by\" counts only packages in these results; code.dlang.org has no reverse-dependency API.");
	}
	auto noCi = rows.filter!(r => !r.facts.ciState.length && r.facts.name.indexOf(':') < 0
		&& r.verdict.bucket != Bucket.gone).array.length;
	if (noCi && !o.verbose)
	{
		writeln();
		writeln(format("%s package(s) have no CI status for their release. %s", noCi,
			hyperlink("How to link CI to a release", ciHelpUrl, osc8)));
	}
}

private string repeatChar(char c, size_t n)
{
	auto s = new char[n];
	s[] = c;
	return cast(string) s;
}

private JSONValue resultJson(const SearchOptions o, Row[] rows, ExitCode code, string error,
	string[] attention, string logPath)
{
	JSONValue j;
	j["outcome"] = code == ExitCode.ok ? "ok" : "error";
	j["exitCode"] = cast(int) code;
	j["query"] = o.query;
	if (error.length)
		j["error"] = error;
	j["changes"] = JSONValue(cast(JSONValue[]) []);
	j["attention"] = JSONValue(attention.map!(a => JSONValue(a)).array);
	j["log"] = logPath.length ? JSONValue(logPath) : JSONValue(null);
	JSONValue th;
	th["activeDays"] = defaultThresholds.activeDays;
	th["quietDays"] = defaultThresholds.quietDays;
	th["issueSample"] = defaultThresholds.issueSample;
	th["answeredPercent"] = defaultThresholds.answeredPercent;
	th["minIssues"] = defaultThresholds.minIssues;
	th["goneGraceDays"] = defaultThresholds.goneGraceDays;
	th["wrapperDescriptionPattern"] = wrapperDescriptionPattern;
	j["thresholds"] = th;
	j["dependentsScope"] = "search-results";
	JSONValue[] pk;
	foreach (r; rows)
	{
		JSONValue p;
		p["name"] = r.facts.name;
		p["version"] = r.facts.latestVersion;
		p["description"] = r.facts.description;
		p["bucket"] = bucketKey(r.verdict.bucket);
		p["bucketLabel"] = bucketLabel(r.verdict.bucket);
		p["reason"] = r.verdict.reason;
		p["lastRelease"] = fmtDate(r.facts.lastRelease).length ? JSONValue(fmtDate(r.facts.lastRelease)) : JSONValue(null);
		p["lastReleaseVersion"] = r.facts.lastReleaseVersion;
		p["releaseCount"] = r.facts.releaseCount;
		p["repoPushed"] = fmtDate(r.facts.repoPushed).length ? JSONValue(fmtDate(r.facts.repoPushed)) : JSONValue(null);
		p["repo"] = r.facts.repoSlug.length ? JSONValue(r.facts.repoKind ~ ":" ~ r.facts.repoSlug) : JSONValue(null);
		p["repoState"] = r.facts.repo.to!string;
		p["stars"] = r.facts.stars;
		p["downloadsTotal"] = r.facts.downloadsTotal;
		p["downloadsMonthly"] = r.facts.downloadsMonthly;
		p["hasReadme"] = r.facts.hasReadme;
		p["declaredStatus"] = r.facts.declaredStatus.length ? JSONValue(r.facts.declaredStatus) : JSONValue(null);
		p["openIssues"] = r.facts.openIssues;
		p["issuesSampled"] = r.facts.issuesSampled;
		p["issuesAnswered"] = r.facts.issuesAnswered;
		p["buildsWithCurrent"] = r.facts.buildsWithCurrent == -1 ? JSONValue(null) : JSONValue(r.facts.buildsWithCurrent == 1);
		if (r.facts.ciState.length)
		{
			JSONValue ci;
			ci["state"] = r.facts.ciState;
			ci["source"] = r.facts.ciSource;
			ci["tag"] = r.facts.ciRef;
			ci["sha"] = r.facts.ciSha;
			ci["date"] = fmtDate(r.facts.ciDate).length ? JSONValue(fmtDate(r.facts.ciDate)) : JSONValue(null);
			ci["url"] = r.facts.ciUrl.length ? JSONValue(r.facts.ciUrl) : JSONValue(null);
			ci["reportedBy"] = "package CI";
			p["ci"] = ci;
			p["ciReason"] = JSONValue(null);
			p["ciHelpUrl"] = JSONValue(null);
		}
		else
		{
			p["ci"] = JSONValue(null);
			p["ciReason"] = r.facts.ciNoneReason.length ? r.facts.ciNoneReason
				: "not checked (subpackage, repo gone, host not supported, or GitHub rate limit)";
			p["ciHelpUrl"] = ciHelpUrl;
		}
		p["repoGoneSince"] = fmtDate(r.facts.repoGoneSince).length ? JSONValue(fmtDate(r.facts.repoGoneSince)) : JSONValue(null);
		JSONValue dep;
		dep["scope"] = "search-results";
		dep["count"] = r.facts.dependentsInResults.length;
		dep["names"] = JSONValue(r.facts.dependentsInResults.map!(n => JSONValue(n)).array);
		p["dependents"] = dep;
		pk ~= p;
	}
	j["packages"] = JSONValue(pk);
	return j;
}
