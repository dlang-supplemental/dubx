/// `dubx search <query>`: DUB registry search grouped into status buckets.
///
/// Data: code.dlang.org API (search, package info, stats) plus the GitHub /
/// GitLab API for the package repository. HTTP goes through the system
/// `curl` binary (ships with Windows 10+, macOS and Linux) so dubx needs no
/// libcurl. Responses are cached briefly on disk. Heuristics live in
/// `search_heuristics`.
module search;

import core.atomic : atomicLoad, atomicStore;
import std.algorithm : canFind, filter, map, max, sort;
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
import std.string : indexOf, lastIndexOf, startsWith, strip, toLower;
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
	auto stars = num(j, "star_count");
	if (stars >= 0)
		f.stars = stars;
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
			try applyGitLab(f, r.body_); catch (Exception) {}
		else if (r.status == 404)
			f.repo = RepoState.gone;
		break;
	default:
		f.repo = RepoState.notChecked;
	}
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

	auto resultNames = hits.map!(h => parentName(h.name)).array;
	auto now = Clock.currTime(UTC());
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

private void printHuman(const SearchOptions o, Row[] rows)
{
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
				if (r.facts.openIssues >= 0) d ~= format("open issues+PRs %s", r.facts.openIssues);
				if (r.facts.stars >= 0) d ~= format("stars %s", r.facts.stars);
				if (r.facts.downloadsTotal >= 0) d ~= format("downloads %s total, %s/month", r.facts.downloadsTotal, r.facts.downloadsMonthly);
				d ~= r.facts.hasReadme ? "readme yes" : "readme no";
				if (r.facts.description.length) d ~= r.facts.description;
				writeln("  ", ' '.repeatChar(nameW), "  ", d.join(" | "));
			}
		}
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
	th["wrapperDescriptionPattern"] = wrapperDescriptionPattern;
	j["thresholds"] = th;
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
		p["dependents"] = r.facts.dependents;
		pk ~= p;
	}
	j["packages"] = JSONValue(pk);
	return j;
}
