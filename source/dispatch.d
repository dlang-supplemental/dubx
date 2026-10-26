module dispatch;

/// Pure first-argument routing for dubx (no I/O, unit-tested).
///
/// Order: help -> built-in dubx commands -> registry aliases -> build verbs
/// -> unknown. Built-ins always win, and an unknown first word is never
/// forwarded to a backend: redub treats an unknown first word as a package
/// to fetch and run, which is how `dubx search` (0.3.x) ended up fetching a
/// package called "search".

import std.algorithm : among, canFind, levenshteinDistance, startsWith;
import std.uni : toLower;

enum Target
{
	help,
	version_,
	which,
	search,
	publish,
	local,
	registry,   /// dub-publish
	build,      /// redub (if it knows the verb) else dub
	dub,
	redub,
	dubPublish,
	unknown,
}

struct Route
{
	Target target;
	string verb;      /// lower-cased first word
	string[] args;    /// args for the backend / subcommand
	string hint;      /// usage message for Target.unknown
}

/// dubx's own commands. They always take priority.
immutable string[] builtinCommands = [
	"help", "version", "which", "search", "publish", "local",
	"dub", "redub", "dub-publish",
];

/// Short aliases forwarded to dub-publish.
immutable string[] registryAliases = [
	"register", "login", "logout", "update", "status",
	"remove", "logo", "logo-delete", "docs-url", "categories",
	"hooks", "hooks-disable", "repo", "perms-add", "leave",
];

/// Build / package verbs forwarded to redub or dub.
immutable string[] buildVerbs = [
	"build", "run", "test", "describe", "lint", "clean", "fetch",
	"upgrade", "add", "remove-dep", "dustmite", "generate", "init",
	"convert", "add-path", "remove-path", "add-local",
	"remove-local", "list", "list-overrides", "add-override",
	"remove-override", "clean-caches",
];

/// Commands redub itself implements (redub source/app.d entryPoints).
/// Any other first word makes redub fetch/run a package of that name,
/// so every other build verb goes straight to dub.
immutable string[] redubVerbs = [
	"build", "build-universal", "update", "setup", "clean", "describe",
	"deps", "test", "init", "install", "configure", "use", "run", "watch",
];

bool redubHandles(string verb)
{
	return redubVerbs.canFind(verb);
}

bool isHelpWord(string t)
{
	return t == "?" || t == "help" || t == "--help" || t == "-h" || t == "--?"
		|| t.startsWith("?:") || t.startsWith("help:") || t.startsWith("--help:")
		|| t.startsWith("-h:") || t.startsWith("--?:");
}

/// Route `args` (without the program name).
Route route(string[] args)
{
	if (!args.length)
		return Route(Target.help, "", []);
	auto cmd = args[0].toLower;
	auto rest = args[1 .. $];
	if (isHelpWord(cmd))
		return Route(Target.help, cmd, rest);
	if (cmd.among("version", "--version", "-v"))
		return Route(Target.version_, cmd, rest);

	switch (cmd)
	{
	case "which": return Route(Target.which, cmd, rest);
	case "search": return Route(Target.search, cmd, rest);
	case "publish": return Route(Target.publish, cmd, rest);
	case "local": return Route(Target.local, cmd, rest);
	case "dub": return Route(Target.dub, cmd, rest);
	case "redub": return Route(Target.redub, cmd, rest);
	case "dub-publish": return Route(Target.dubPublish, cmd, rest);
	default: break;
	}
	if (registryAliases.canFind(cmd))
		return Route(Target.registry, cmd, cmd ~ rest);
	if (buildVerbs.canFind(cmd))
		return Route(Target.build, cmd, (cmd == "remove-dep" ? "remove" : cmd) ~ rest);
	return Route(Target.unknown, cmd, rest, unknownHint(args[0]));
}

/// Closest known command within edit distance 2, or null.
string suggest(string word)
{
	auto w = word.toLower;
	string best;
	size_t bestD = 3;
	foreach (c; builtinCommands ~ registryAliases ~ buildVerbs)
	{
		auto d = levenshteinDistance(w, c);
		if (d < bestD)
		{
			bestD = d;
			best = c;
		}
	}
	return best;
}

string unknownHint(string word)
{
	string s = "dubx: unknown command '" ~ word ~ "'.";
	auto m = suggest(word);
	if (m.length)
		s ~= " Did you mean 'dubx " ~ m ~ "'?";
	s ~= "\n  dubx does not fetch or run a package from a bare name."
		~ "\n  To run a registry package named '" ~ word ~ "': dubx dub run " ~ word
		~ "\n  To search the registry: dubx search " ~ word
		~ "\n  All commands: dubx ?";
	return s;
}

unittest
{
	// Regression: 0.3.x forwarded "search" to redub, which fetched a package named "search".
	auto r = route(["search", "yaml"]);
	assert(r.target == Target.search && r.args == ["yaml"]);
	assert(route(["SEARCH", "yaml"]).target == Target.search);
	assert(route(["search", "yaml", "--raw"]).target == Target.search);

	// Unknown words never reach a backend.
	auto u = route(["serch", "yaml"]);
	assert(u.target == Target.unknown);
	assert(u.hint.canFind("Did you mean 'dubx search'?"));
	assert(u.hint.canFind("dubx dub run serch"));
	assert(route(["zzzzzzzzzz"]).target == Target.unknown);
	assert(suggest("zzzzzzzzzz") is null);

	// Built-ins beat everything; version flags.
	foreach (v; ["version", "--version", "-v", "-V"])
		assert(route([v]).target == Target.version_);
	assert(route([]).target == Target.help);
	assert(route(["?"]).target == Target.help);

	// Aliases and build verbs.
	assert(route(["login", "--user", "x"]).args == ["login", "--user", "x"]);
	assert(route(["login"]).target == Target.registry);
	assert(route(["remove-dep", "foo"]).args == ["remove", "foo"]);
	assert(route(["build"]).target == Target.build);

	// redub only gets verbs it implements; it would fetch a package for the rest.
	assert(redubHandles("build") && redubHandles("run") && redubHandles("test"));
	foreach (v; ["search", "fetch", "list", "add", "lint", "convert", "add-local"])
		assert(!redubHandles(v));
}
