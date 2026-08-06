module app;

import std.algorithm : among, startsWith;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment, spawnProcess, wait;
import std.stdio;
import std.string : toLower;

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
	if (args.length < 2)
	{
		showHelp([args[0], "?"]);
		return 2;
	}

	{
		auto t = args[1].toLower;
		if (t == "?" || t == "help" || t == "--help" || t == "-h" || t == "--?"
			|| t.startsWith("?:") || t.startsWith("help:") || t.startsWith("--help:")
			|| t.startsWith("-h:") || t.startsWith("--?:"))
		{
			showHelp(args);
			return 0;
		}
	}

	auto cmd = args[1].toLower;
	auto rest = args[2 .. $];

	switch (cmd)
	{
	case "version", "--version", "-V":
		writeln("dubx ", dubxVersion);
		return 0;

	case "which":
		return cmdWhich(rest);

	// Registry owner ops → dub-publish
	case "publish", "register", "login", "logout", "update", "status",
		"remove", "logo", "logo-delete", "docs-url", "categories",
		"hooks", "hooks-disable", "repo", "perms-add", "leave":
		return runTool("dub-publish", [cmd] ~ rest, ToolKind.registry);

	// Build / package workflow → redub, fallback dub
	case "build", "run", "test", "describe", "lint", "clean", "fetch",
		"upgrade", "add", "remove-dep", "dustmite", "generate", "init",
		"convert", "search", "add-path", "remove-path", "add-local",
		"remove-local", "list", "list-overrides", "add-override",
		"remove-override", "clean-caches":
		// Map dubx alias to actual tool args
		if (cmd == "remove-dep")
			return runBuild(["remove"] ~ rest);
		return runBuild([cmd] ~ rest);
	case "dub":
		return runTool("dub", rest, ToolKind.build);

	case "redub":
		return runTool("redub", rest, ToolKind.buildForced);

	case "dub-publish":
		return runTool("dub-publish", rest, ToolKind.registry);

	default:
		// Unknown verb: prefer redub, then dub (passthrough)
		return runBuild([cmd] ~ rest);
	}
}

enum ToolKind
{
	build,       /// redub with dub fallback
	buildForced, /// redub only
	registry,    /// dub-publish only
}

int runBuild(string[] toolArgs)
{
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
			stderr.writeln("  install: https://github.com/dlang-supplemental/dub-publish");
			stderr.writeln("  then: dub build && put dub-publish on PATH");
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
	string[] names = rest.length ? rest : ["redub", "dub", "dub-publish"];
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

