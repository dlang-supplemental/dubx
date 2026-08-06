module version_;

/// SemVer from VERSION at repo root (stringImportPaths).
enum string dubxVersion = {
	import std.string : strip;
	return import("VERSION").strip;
}();
