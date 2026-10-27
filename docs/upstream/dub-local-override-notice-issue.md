# Issue for dlang/dub

Filed as https://github.com/dlang/dub/issues/3174 (2026-10-26).

**Title:** Report locally substituted dependencies: a notice in interactive use, an error in CI, and a list in `dub describe`

---

## Problem

`dub add-override` is deprecated. The only output it produces is the deprecation message itself, and it doesn't say which package was swapped out. The replacements the deprecation recommends, `dub add-local`/`add-path` and path entries in `dub.selections.json`, resolve with no output at the default log level. A build can therefore run against a local working copy, while the user, a reviewer, or an agent reading the log can't tell that the registry package was replaced.

Checked against dlang/dub master at `122f66fd474e1cba0f25ff073eb789f74f9fd7ae`:

- `source/dub/packagemanager.d:1830-1831`: `OverrideDepMsg = "Overrides are deprecated as they are redundant with more fine-grained approaches"`.
- `source/dub/packagemanager.d:1517-1519`: when a `local-overrides.json` exists, dub runs `logWarn("Found local override file: %s", ovrfilepath)`, then `OverrideDepMsg`, then "Replace with a path-based dependency…". It names the file. It doesn't name the package, the requested version, or the replacement path when an override actually applies.
- `source/dub/project.d:551-556`: a path selection in `dub.selections.json` (`(NativePath path_) { ... m_packageManager.getOrLoadPackage(path, ...) }`) is loaded with no log call of any kind.
- `source/dub/project.d:585-588`: a `path=` dependency from the recipe logs only `logDiagnostic("%sAdding local %s in %s", ...)`, which is hidden unless `-v` is passed.
- `source/dub/packagemanager.d:235-248` (`lookup`) and `:711-722` (package iterator): packages registered with `add-local`/`add-path` (`m_internal.localPackages`, `repo.localPackages`, `fromPath`) are searched before the cached registry packages and returned with no log line. When an `add-local` registration matches the selected version, it wins without any notice.
- `source/dub/description.d:21-30` (`ProjectDescription`): nothing records whether a package came from the registry cache, a local registration, or a path, so `dub describe` can't be used to detect this either.

## Proposal

### 1. Interactive use: an informational notice, not a warning

Overriding a dependency on purpose is a normal workflow, so a warning is the wrong signal. Print a notice at the default (info) level, once per build, with one line per substituted dependency:

```
Notice: local dependency override: <name> requested <version-spec> -> <absolute path> (via add-local|add-path|selections-path|recipe-path|override)
```

The line should include the dependency name, the requested version or spec, the resolved path, and the mechanism that caused the substitution.

### 2. CI: a local substitution is an error

CI must build what the registry serves. In CI, a dependency that resolves to a local registration (`add-local`, `add-path`, `local-overrides.json`) or to a path selection should fail the build with the same per-dependency line, reported at error level.

- Detect CI from `CI=true` and common provider variables (`GITHUB_ACTIONS`, `GITLAB_CI`, `BUILDKITE`, `TF_BUILD`, `JENKINS_URL`, `TEAMCITY_VERSION`, `CIRCLECI`, `APPVEYOR`, `TRAVIS`, ...), plus an explicit switch such as `--ci` or `DUB_CI=1`.
- Offer an explicit opt-in, for example `--allow-local-overrides` or `DUB_ALLOW_LOCAL_OVERRIDES=1`. With it the build continues, but each substitution is still logged.
- `path=` dependencies that point inside the project's own repository (submodules, vendored folders, sub-packages via `path=".."`) are exempt from the CI error: they are part of the project, not a substitution. They are still listed in `dub describe` (source `recipe-path`) but not reported as overrides. Only overrides (`local-overrides.json`), `add-local`/`add-path` registrations, path selections in `dub.selections.json`, and `path=` dependencies that resolve outside the repository root count. The repository root is the nearest enclosing VCS root (e.g. `.git`), falling back to the root package directory.

### 3. Machine-readable output

- Keep the notice line in a fixed, documented format, so tools and agents can grep for it reliably.
- Add the same data to `dub describe` JSON, for example:

```json
"localOverrides": [
  { "name": "foo", "requested": "~>1.2.0", "path": "/home/u/src/foo/", "source": "add-local" }
]
```

`source` would be one of `add-local`, `add-path`, `selections-path`, `recipe-path`, `override`. An empty array means everything resolved from the registry or SCM.

## Related

- #2475 New implementation for `add-local` / `add-path` (open)
- #1120 Add Package-Local versions (open)
- #2506 Fix #2425: Do not select path / repository based dependency (open)
- #2956 `dub add <packagename>` ignores local packages (open)
- #3002 "dub add-local" doesn't work for Git dependencies (open)
- #937 Command to list dependency paths being used (closed)
- #772 dub.selections.json not updated if dependency with path is used (closed)
- #50 Support non-repo packages (closed)

None of these asks for the substitution to be reported. I found no duplicate.
