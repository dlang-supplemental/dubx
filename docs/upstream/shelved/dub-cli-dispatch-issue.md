# Make unknown command tokens an error: deprecate dub's implicit dispatch now, error by default in dub 2.0

## Summary

`dub` still dispatches some first words that are not commands implicitly instead of rejecting them. This should change in two steps, with no opt-out:

1. **Current major (1.x), next minor release:** emit a deprecation warning on every implicit use, naming the exact explicit replacement, and ship a strict opt-in that turns the warning into an error.
2. **Next major (2.0):** the error becomes the default. This is a mandatory, full changeover. There is no legacy flag, setting or environment variable that brings the implicit behaviour back.

Please also publish a documented, fixed list of the command tokens `dub` accepts.

The requirements below cite the OpenShellOrg **CLI Dispatch** standard by rule ID ([standard](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch.adoc), [rationale](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch-rationale.adoc), [implementer notes](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch-implementers.adoc), [conformance](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/certification-cli-dispatch.adoc)).

## Current behaviour (checked against `master` @ 122f66f, `dubVersion = "v1.42.0-beta.1"`)

In `source/dub/commandline.d`, `runDubCommandLine` rewrites `args` *before* command lookup:

- **Unknown word that names a file:** if `handler.getCommand(args[1]) is null` and `./<word>` or `./<word>.d` exists, `dub <word> ...` is rewritten to `dub run -q --temp-build --single <file> -- ...` and the file is built and run. The source comment states the trade-off directly: *"What if the script name is a command name? We have to assume it isn't."*
- **Bare invocation:** `CommandLineHandler.getCommand("")` returns `run` (*"If there is no command in the argument list, the `run` command is returned by default"*), so `dub` with no command builds and runs the current package without saying that it chose `run`.
- **`dub <file>.d`** and **`dub -`** (stdin) are also rewritten to single-file `run`. These are shebang/script forms rather than command tokens.
- **Truly unknown word:** when no such file exists, `dub foo` prints `Unknown command: foo` with Levenshtein suggestions. This is close to CD-1, but it writes the usage line via `logInfoNoTag` and exits `1`, not `2`.

So whether `dub foo` runs code depends on what files happen to be in the working directory. The same word can mean "error" in one directory and "build and run this file" in another.

## Requested change

### Release W (1.x minor), per CD-11, CD-13, CD-14, CD-15

On every implicit use, before any action output, emit one block on stderr that `--quiet` does not suppress:

```text
$ dub foo
warning: 'foo' is not a dub command; running './foo.d' as a single-file package implicitly is deprecated
  use: dub run --single foo.d
  this will be an error in dub 2.0; enable now with --strict or DUB_STRICT=1
```

```text
$ dub
warning: no command given; running default 'run' implicitly is deprecated
  use: dub run
  this will be an error in dub 2.0; enable now with --strict or DUB_STRICT=1
```

Strict opt-in (CD-14): `--strict`, `DUB_STRICT=1`, and a documented settings key. Precedence is flag over environment over config. With strict enabled:

```text
$ dub --strict foo
error: unknown command 'foo'
  to run a single-file package: dub run --single foo.d
  see: dub help
$ echo $?
2
```

The release notes must announce the change and name **dub 2.0** as the version in which strict becomes the default (CD-15).

### dub 2.0, per CD-12 and CD-15

- Strict is the default. An unknown first word is always `unknown command '<X>'` on stderr with exit `2`, a did-you-mean suggestion and a help pointer (CD-1). Nothing is read, fetched, built or run before the token is known to be a command (CD-2). No bare word is treated as a package, file or target (CD-3).
- **No opt-out.** CD-12: *"The full changeover is required, not optional … There is no opt-out: a tool MUST NOT keep implicit behaviour behind a legacy flag, setting or environment variable."* `--strict` stays accepted as a no-op (CD-14).
- Bare `dub` prints help (CD-5). If you want to keep a default, it must be documented and announce itself, e.g. `no command given; running default: run` (CD-6).
- The 2.0 release notes list every implicit form that is now an error, with its replacement (CD-15).
- Shebang use (`#!/usr/bin/env dub`): if you want to keep it, it needs a documented, explicit spelling (for example `#!/usr/bin/env -S dub run --single`), not a catch-all on the first word.

### Documented command-token list, per CD-4 and CD-16

`dub help` / `dub --help` and the reference docs must list every token the dispatcher accepts, including aliases and any bare-invocation default. Please publish the same list as a fixed reference that wrappers and drop-in replacements can track. CD-17 requires tools such as `redub` and `dubx` to document which `dub` commands they implement, forward or reject, and they need a stable upstream list for that.

Other rules that apply: unknown flags, extra positionals and missing arguments are usage errors with exit `2` (CD-7, CD-8). The current `Unknown command line flags` path should use the same format and exit code.

## Why

A first word that silently becomes "run something" is hidden surface. A typo or an unsupported command can run code instead of failing. The [rationale](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/standard-cli-dispatch-rationale.adoc) walks through a real case: `dubx search` reached a catch-all in the dub/redub chain and fetched an unrelated package named `search`, and no tool in the chain reported an unknown command.

## Certification

When the 1.x warning release ships, dub can self-declare **Migrating** conformance. After 2.0 ships with strict as the default, it can self-declare **Strict** conformance. The levels and the self-test (`dub zzqx` → exit 2, `dub biuld` → did-you-mean, no network or file activity, and so on) are in [certification-cli-dispatch.adoc](https://github.com/openshellorg/docs/blob/6480593/docs/modules/ROOT/pages/certification-cli-dispatch.adoc). I'd like to invite the maintainers to run the self-test and certify.

## Related

- #2980: `--single` argument handling without `--` (same single-file dispatch path)
- #3007: `--single` should not require a name
- #1026: `dub run <package>` affected by files in the cwd (cwd-dependent dispatch)
- MrcSnm/redub: companion issue for the same change in redub (link to be added after filing)
