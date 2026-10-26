# Make unknown command tokens an error: deprecate the runMain catch-all now, error by default in the next major

## Summary

Any first word that `redub` does not recognise is passed to `runMain` as a package to resolve, fetch, build and run. This should change in two steps, with no opt-out:

1. **Current major (1.x), next minor release:** a deprecation warning on every implicit use, plus a strict opt-in that makes it an error.
2. **Next major (2.0):** the error becomes the default. This is a mandatory, full changeover. There is no legacy flag, setting or environment variable that brings the catch-all back.

redub also has **no documented list of the command tokens it accepts**. Please add one, including which `dub` commands redub implements, which it forwards and which it rejects.

The requirements below cite the OpenShellOrg **CLI Dispatch** standard by rule ID ([standard](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch.adoc), [rationale](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch-rationale.adoc), [implementer notes](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch-implementers.adoc), [conformance](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/certification-cli-dispatch.adoc)).

## Current behaviour (checked against `main` @ 7cf2af7, `RedubVersionOnly = "v1.32.1"`)

In `source/app.d`, `main` builds an `entryPoints` table: `build`, `build-universal`, `update`, `setup`, `clean`, `describe`, `deps`, `test`, `init`, `install`, `configure`, `use`, `run`, and `watch` under `version(RedubWatcher)`. It then does:

```d
if(args.length >= 2)
{
    foreach(cmd; entryPoints.byKey)
        if(args[1] == cmd) { ... return entryPoints[cmd](args); }
}
return runMain(args, runArgs);
```

Any other first word falls through to `runMain` → `resolveDependencies` (`source/redub/extensions/cli.d`) → `redub.api.resolveDependencies`. There `getPackageFromCli` takes the word as the target package and, via `shouldFetchPackage` / `findPackage(targetPackage, null, packageVersion, "redub-run")`, **fetches, builds and runs it**. Concretely:

- `redub search json` (`search` is a dub command that redub does not implement) tries to fetch and run a package named `search`. This is how `dubx search` came to fetch an unrelated package. See the worked example in the [standard](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch.adoc).
- A typo such as `redub biuld` does not get a did-you-mean. It becomes a package lookup.
- Bare `redub` runs `runMain` silently (CD-6).

## Requested change

### Release W (1.x minor), per CD-11, CD-13, CD-14, CD-15

On every implicit use, before any action output, emit one block on stderr that `-q` does not suppress:

```text
$ redub foo
warning: 'foo' is not a redub command; running package 'foo' implicitly is deprecated
  use: redub run foo
  this will be an error in redub 2.0; enable now with --strict or REDUB_STRICT=1
```

Strict opt-in (CD-14): `--strict`, `REDUB_STRICT=1`, and a documented config key. Precedence is flag over environment over config.

### Wrapper/drop-in rules apply now, per CD-9, CD-10, CD-17

For `dub` commands that redub does not implement, there must be no forwarding, guessing or fallback, even in 1.x, because there is no implicit use to migrate here:

```text
$ redub search json
error: redub does not implement 'search'
  'search' is implemented by dub: dub search json
  redub implements: build, build-universal, update, setup, clean, describe, deps, test, init, install, configure, use, run
  see: redub --help
$ echo $?
2
```

### redub 2.0, per CD-12 and CD-15

- Strict is the default. An unknown first word gives `unknown command '<X>'` on stderr, a did-you-mean suggestion and a help pointer, and exit `2` (CD-1). Nothing is resolved, fetched, built or run before the token is known (CD-2). No bare word is ever a package (CD-3). Running a package requires `redub run <pkg>`.
- **No opt-out.** CD-12: *"The full changeover is required, not optional … There is no opt-out: a tool MUST NOT keep implicit behaviour behind a legacy flag, setting or environment variable."* `--strict` stays accepted as a no-op (CD-14).
- Bare `redub` prints help (CD-5). If you want to keep a default, it must be documented and announce itself, e.g. `no command given; running default: run` (CD-6).
- The 2.0 release notes list every implicit form that is now an error, with its replacement (CD-15).

### Documented command-token list, per CD-4, CD-16, CD-17

- `redub --help` (and `redub help`) lists every token the dispatcher accepts, including `watch` when built with `RedubWatcher` and any aliases and default.
- The README or docs carry a table of every `dub` command showing whether redub **implements** it, **forwards** it (and to what), or **rejects** it. The table must be kept in step with the dub versions redub supports (CD-17).
- Unknown flags, extra positionals and missing arguments are usage errors with exit `2` (CD-7, CD-8).

## Certification

When the 1.x warning release ships, redub can self-declare **Migrating** conformance. After 2.0 ships with strict as the default, it can self-declare **Strict** conformance. The levels and self-test are in [certification-cli-dispatch.adoc](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/certification-cli-dispatch.adoc). I'd like to invite you to run the self-test and certify.

## Related

- #26: Help CLI flag is missing (closed). `--help` exists now, but there is no command-token list (CD-16).
- #31 / #29: `redub -v test` / `redub -q test` (closed). Earlier cases of tokens in an unexpected position reaching the wrong handler.
- dlang/dub: companion issue for the same change in dub (link to be added after filing)
