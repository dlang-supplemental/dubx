Not filed yet. Draft for haskell/cabal.

# `-f-foo` (disable flag `foo`) is visually ambiguous; consider a clearer spelling and deprecate the old one

## Summary

Cabal turns a package flag off on the command line with `-f-foo`: `-f` is the short form of `--flags`, and the leading `-` on the flag name means "false". The syntax works, but it is hard to read. I'd like to suggest a clearer spelling, and keep `-f-foo` working with a deprecation notice rather than removing it.

## Current behaviour (from the docs)

[Setup commands, 6.3.3 "Controlling Flag Assignments"](https://cabal.readthedocs.io/en/stable/setup-commands.html#controlling-flag-assignments):

> `-f flagname` or `-f -flagname`: Force the specified flag to true or false (if preceded with a `-`). ... specifying `-fdebug -f-debug` is equivalent to `-f-debug`
>
> `--flags=flagspecs`: Same as `-f`, but allows specifying multiple flag assignments at once. ... `--flags="debug -feature1 feature2"` is equivalent to `-fdebug -f-feature1 -ffeature2`.

In `cabal.project` the `flags:` field uses `+foo` / `-foo`, so the `+`/`-` prefix already exists. Only the CLI short form looks odd.

## Why it reads badly

- **It looks like one hyphenated option.** `-f-feature1` reads as an option named `f-feature1`, not as "`-f`, value `-feature1`".
- **It looks like bundled short flags.** In getopt-style tools, `-xvz` means `-x -v -z`. `tar -xvz` is the usual example, and it's an unintuitive hack: at a glance it reads like a command called "xvz" (are we x-vizzing it?). `-f-foo` has the same problem. Readers who know bundling have to stop and work out what goes with what.
- **It looks like GHC's negation but isn't.** GHC turns off its `-f` options with `-fno-<flag>`, e.g. `-fno-specialise` ([GHC User's Guide, "Using GHC"](https://downloads.haskell.org/ghc/latest/docs/users_guide/using.html)). It never uses `-f-<flag>`. Since Cabal and GHC commands often appear next to each other, two different `-f` conventions are easy to mix up.

## Suggested alternatives (any one would help)

1. **Recommend `--flags=-foo` / `--flags=+foo` in docs and `--help`.** This already works (the `--flags` form). The docs could lead with it and use `+` for "on", matching `cabal.project`.
2. **Accept an explicit, separated value:** `-f '+foo'` / `-f '-foo'` (with a space, the value is clearly an argument), or a non-dash negation such as `-f !foo` (note: `!` needs quoting in some shells).
3. **Long-form-only negation:** only treat a leading `-` as negation inside `--flags=...`, and make `+foo`/`-foo` the documented spelling there.

## Compatibility

Please don't break existing scripts. I'd suggest:

- keep `-f-foo` working;
- print a short deprecation notice pointing to the preferred form (e.g. `-f-foo is deprecated; use --flags=-foo`);
- update the docs and `--help` examples to use the preferred form.

## Motivation / context

This came up while working on CLI-consistency guidance for [OpenShellOrg](https://docs.opensh.org/open-shell-org/), an emerging CLI standard. Its rule on flag-value syntax isn't published yet, so I'm not citing it as a requirement, just as the reason I noticed this.

## Related issues

I searched haskell/cabal and found no duplicate. Nearby but different:

- #937 "let `cabal configure -fSomeFlag` produce error for undeclared flags"
- #12180 "Show default when flags toggle feature"
- #7437 "`--upgrade-dependencies` should be marked as deprecated in v2- commands" (deprecation precedent)

Thanks for considering it.