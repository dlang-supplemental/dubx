module app;

import std.algorithm : among, startsWith;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment, spawnProcess, wait;
import std.stdio;
import std.string : toLower;

import search : cmdSearch, parseSearchArgs, SearchOptions, ExitCode;
import dispatch : route, Target, redubHandles;
import version_;
import prohelp.config;
import prohelp.intercept;

private enum embeddedHelpSdl = import("help.sdl");

private InterceptConfig helpConfig()
{
	return InterceptConfig.fromContent(embeddedHelpSdl, "help.sdl");
}

private void showHelp(string[] args)
{
	auto helpArgs = args.dup;
	if (helpArgs.length < 2)
		helpArgs ~= "?";
	prohelp.intercept.intercept(helpArgs, helpConfig());
}

int main(string[] args)
{
	auto r = route(args[1 .. $]);
	final switch (r.target)
	{
	case Target.help:
		if (args.length < 2)
		{
			showHelp([args[0], "?"]);
			return 2;
		}
		showHelp(args);
		return 0;
	case Target.version_:
		writeln("dubx ", dubxVersion);
		return 0;
	case Target.which:
		return cmdWhich(r.args);
	// Registry search grouped into status buckets (--raw = dub search passthrough)
	case Target.search:
		return runSearch(r.args);
	// Opaque registry namespace: dubx publish <anything> -> dub-publish <anything>
	case Target.publish:
		return runPublish(r.args);
	// Local/private package mirror helper -> dubproxy (when installed)
	case Target.local:
		return runLocal(r.args);
	case Target.registry:
		return runTool("dub-publish", r.args, ToolKind.registry);
	case Target.build:
		return runBuild(r.args);
	case Target.dub:
		return runTool("dub", r.args, ToolKind.build);
	case Target.redub:
		return runTool("redub", r.args, ToolKind.buildForced);
	case Target.dubPublish:
		return runTool("dub-publish", r.args, ToolKind.registry);
	case Target.unknown:
		// Never forward an unknown word: redub would fetch and run a package by that name.
		stderr.writeln(r.hint);
		return 2;
	}
}

/// `dubx search`: grouped registry search, or `--raw` passthrough to dub search
/// (redub has no search command and would fetch a package called "search").
int runSearch(string[] rest)
{
	SearchOptions o;
	auto err = parseSearchArgs(rest, o);
	if (o.raw)
		return runTool("dub", ["search"] ~ o.passthrough, ToolKind.build);
	if (err.length)
	{
		stderr.writeln("dubx search: ", err);
		return ExitCode.usage;
	}
	return cmdSearch(o);
}

/// Forward to dub-publish. Remap only verbs dubx explicitly redesigns.
int runPublish(string[] rest)
{
	if (!rest.length)
		return runTool("dub-publish", [], ToolKind.registry);

	// Explicit dubx redesigns under `publish` go here, e.g.:
	//   if (rest[0].toLower == "auth")
	//       return runTool("dub-publish", ["login"] ~ rest[1 .. $], ToolKind.registry);
	return runTool("dub-publish", rest, ToolKind.registry);
}

/// Forward to dubproxy for private/mirror package injection into the local DUB cache.
int runLocal(string[] rest)
{
	return runTool("dubproxy", rest, ToolKind.local);
}

enum ToolKind
{
	build,       /// redub with dub fallback
	buildForced, /// redub only
	registry,    /// dub-publish only
	local,       /// dubproxy (optional PATH tool)
}

int runBuild(string[] toolArgs)
{
	// redub treats a verb it does not implement as a package name to fetch; send those to dub.
	if (toolArgs.length && !redubHandles(toolArgs[0]))
		return runTool("dub", toolArgs, ToolKind.build);
	if (findOnPath("redub").length)
		return runTool("redub", toolArgs, ToolKind.buildForced);
	stderr.writeln("dubx: redub not found on PATH; falling back to dub");
	return runTool("dub", toolArgs, ToolKind.build);
}

int runTool(string name, string[] toolArgs, ToolKind kind)
{
	auto exe = findOnPath(name);
	if (!exe.length)
	{
		final switch (kind)
		{
		case ToolKind.build:
		case ToolKind.buildForced:
			stderr.writeln("dubx: '", name, "' not found on PATH");
			if (name == "redub")
				stderr.writeln("  install: dub fetch redub && dub run redub -- --help");
			else
				stderr.writeln("  install the DUB package manager (dlang.org)");
			break;
		case ToolKind.registry:
			stderr.writeln("dubx: 'dub-publish' not found on PATH");
			stderr.writeln("  install: https://github.com/dlang-supplemental/dub-publish/releases");
			break;
		case ToolKind.local:
			stderr.writeln("dubx: 'dubproxy' not found on PATH");
			stderr.writeln("  dubx local proxies dubproxy for private/mirrored packages in ~/.dub/packages.");
			stderr.writeln("  Prefer modern alternatives when possible:");
			stderr.writeln("    - path deps in dub.sdl / dub.json");
			stderr.writeln("    - git+https://… repository dependencies");
			stderr.writeln("    - dub add-local / dubx add-local");
			stderr.writeln("  Install dubproxy (optional):");
			stderr.writeln("    dub fetch dubproxy && dub build dubproxy --config=cli");
			stderr.writeln("    then put the binary on PATH");
			stderr.writeln("  Upstream: https://github.com/symmetryinvestments/dubproxy");
			break;
		}
		return 127;
	}

	auto cmdline = exe ~ toolArgs;
	try
	{
		auto pid = spawnProcess(cmdline);
		return wait(pid);
	}
	catch (Exception e)
	{
		stderr.writeln("dubx: failed to run ", name, ": ", e.msg);
		return 1;
	}
}

int cmdWhich(string[] rest)
{
	string[] names = rest.length ? rest : ["redub", "dub", "dub-publish", "dubproxy"];
	int missing;
	foreach (n; names)
	{
		auto p = findOnPath(n);
		if (p.length)
			writeln(n, "=", p);
		else
		{
			writeln(n, "=MISSING");
			missing++;
		}
	}
	return missing ? 1 : 0;
}

/// Locate an executable on PATH (and next to dubx itself).
string findOnPath(string name)
{
	string[] candidates;
	version (Windows)
		candidates = [name, name ~ ".exe", name ~ ".bat", name ~ ".cmd"];
	else
		candidates = [name];

	// Prefer a sibling binary next to dubx (dev installs)
	try
	{
		auto dir = dirName(thisExePath());
		foreach (c; candidates)
		{
			auto p = buildPath(dir, c);
			if (exists(p))
				return p;
		}
	}
	catch (Exception)
	{
	}

	auto path = environment.get("PATH", "");
	char sep;
	version (Windows)
		sep = ';';
	else
		sep = ':';

	import std.algorithm : splitter;
	foreach (dir; path.splitter(sep))
	{
		if (!dir.length)
			continue;
		foreach (c; candidates)
		{
			auto p = buildPath(dir, c);
			if (exists(p))
				return p;
		}
	}
	return null;
}

void printHelp()
{
	showHelp(["dubx", "?"]);
}

