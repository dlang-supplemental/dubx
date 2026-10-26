<!--
Draft only. Not filed. Target: https://github.com/dlang/dub-registry (issue first, then PR).
Prepared against dub-registry commit a7671f8 (2026-10-26). Reference implementation:
dubx `search` (source/search_heuristics.d) in https://github.com/dlang-supplemental/dubx.
-->

# Proposal: group code.dlang.org search results by status, and a declared `x:status` recipe field

## Problem

Searching code.dlang.org for a common topic returns a flat list where live, finished, wrapped and dead packages look alike. For `yaml` today:

- `yaml-d` (LLC-CERERIS) has a single `0.0.1` release from 2017 and its GitHub repo returns 404, yet it sits next to `dyaml`.
- `mir-yaml` is archived on GitHub.
- Six of the hits are subpackages (`dyaml:yaml_gen`, `uniconf:yaml`, ...) and several more are thin layers over `dyaml`.

People new to D read this as "the ecosystem is full of abandoned code", and people looking for a library have to open every repo to find out which one to use.

## What not to do

From the outside you cannot tell a stale package from a finished one, and version numbers mean different things to different authors (`1.0` = "stable API" for one, "first upload" for another). So the registry should **not** label anything "stale" or "abandoned" just because it is old. Only these are hard facts:

- the repository is gone (404/451 from the host), or
- the repository is archived, or
- the maintainer *declared* a status.

Everything age-based should be neutral ("Quiet") and show the facts behind it (last release date, last commit date).

## Proposal

### 1. Group search results into buckets

Shared definitions (same as dubx; thresholds in one place):

| Threshold | Default | Meaning |
| --- | --- | --- |
| `activeDays` | 365 | newest release / branch commit / repo push within this → **Active** |
| `quietDays` | 1095 | between `activeDays` and this → **Slow but alive**; older → **Quiet** (or **Finished**) |
| `issueSample` | 10 | recent issues (PRs excluded) sampled |
| `answeredPercent` | 50 | share closed or commented to count as "answers issues" |
| `minIssues` | 3 | fewer sampled issues → no responsiveness verdict |
| `wrapperDescriptionPattern` | `\b(bindings?\|wrappers?\|wraps\|port of\|interface to\|binding for)\b` | description marks a wrapper |

Rules, first match wins:

1. **Repo gone or archived** – host returns 404/451, or repo is archived.
2. **Declared status** (see section 2) – always beats the heuristics and is shown first:
   `complete`, `maintenance-only` → **Finished or maintenance-only**; `deprecated`, `unmaintained` → **Declared deprecated or unmaintained**; `experimental`, `alpha`, `beta`, `stable` → **Active** (with the declared label as a badge).
3. **Wrapper or subpackage** – name contains `:`; or the newest release depends on another package in the same result set (own subpackages ignored); or the description matches the pattern.
4. **Active** – newest activity ≤ `activeDays`.
5. **Slow but alive** – newest activity ≤ `quietDays`.
6. **Finished** – older, but answers issues and does not fail to build with current compilers.
7. **Quiet** – older, nothing else known. A fact, not a verdict.

"Newest activity" = latest of: newest tagged release date, newest `~branch` version date, repo push date.

Each row gets a one-line reason, e.g. `single release 0.0.1 (2017-05), repo 404` or `last release 0.2.2 (2020-04), pushed 2021-04`.

Liveness signals that do not depend on release cadence, strongest first:

1. **Still builds with current DMD/LDC.** Not available today. A periodic build job (the registry already walks every package in `DubRegistry.updatePackages`) or an opt-in CI badge URL in the recipe would supply it. Until then, treat it as unknown, never as failing.
2. **Answers issues**: share of the last N issues closed or commented on.
3. **Dependents**: count of packages whose newest release depends on this one, and how recent those releases are. The registry has every recipe in Mongo, so this is one aggregation.

### 2. Declared status: new optional recipe field `x:status`

dub has nothing usable today. `PackageRecipe` (dub: `source/dub/recipe/packagerecipe.d`) has no status/maturity field, and both recipe parsers silently drop unknown keys (`default: break;` in `source/dub/recipe/sdl.d` and `json.d`). Because the registry stores `parsePackageRecipe(...).toJson()` (see below), an `x:status` written by a maintainer today never reaches the registry.

Proposed values:

| Value | Meaning |
| --- | --- |
| `experimental` | API may change any time; not for production |
| `alpha` / `beta` | pre-release maturity |
| `stable` | maintained, API stable |
| `complete` | **finished**: works, no new features planned, bug reports still read |
| `maintenance-only` | fixes only, no new features |
| `deprecated` | use something else (optionally with a successor) |
| `unmaintained` | nobody is looking after it |

`complete` is the value that tells *finished* apart from *quiet*. Without it the registry can only say "quiet".

Syntax:

```sdl
x:status "complete"
```

```json
{ "x:status": "complete" }
```

Badge: show the declared status as a badge on the search row and on the package page, and offer `https://code.dlang.org/packages/<name>/status.svg` for READMEs.

## Where to change dub-registry

All paths at `a7671f8`.

**Status data**

- `source/dubregistry/dbcontroller.d` – `struct DbPackageStats` (~line 752) gains `@optional` fields, e.g. `repoState` (`ok`/`gone`/`archived`), `lastPush`, `issuesSampled`, `issuesAnswered`, `dependents`, `buildsWithCurrent` (tri-state). `struct DbRepoStatsT` (~line 772) could hold `archived`/`pushedAt` instead.
- `source/dubregistry/repositories/repository.d` – `struct RepositoryInfo` (~line 98) gains `bool archived; SysTime pushedAt;`.
- `source/dubregistry/repositories/github.d` – `GithubRepository.getInfo()` (~line 137) already reads the repo JSON (`fork`, `stargazers_count`, `open_issues_count`); also read `archived` and `pushed_at`. Same for `gitlab.d` (`archived`, `last_activity_at`) and `gitea.d`; `bitbucket.d` can leave them unset.
- `source/dubregistry/registry.d` – `DubRegistry.updatePackageStats()` (~line 170) already catches `FileNotFoundException` as "repo no longer exists" and zero-scores the package (#221). Record `repoState = gone` there instead of only dropping the score; copy `archived`/`pushedAt` from `getRepositoryInfo()`. Stats are cached 24 h by `getPackageStats()`, which is the right cadence.
- Dependents: a new aggregation next to `DbController.searchPackages` over `versions.info.dependencies`, run from the existing `updatePackages()` cycle.

**Declared status**

- dub (separate repo, `dlang/dub`): add `@Optional string status;` (serialized as `x:status`, or plain `status` if the dub team prefers) to `PackageRecipe`, parse it in `sdl.d`/`json.d`, warn on unknown values.
- dub-registry `registry.d` – `getVersionInfo()` (~line 738) stores `recipe.toJson()` as `DbPackageVersion.info`. Once dub keeps the key it flows through with no registry change. Until then, the registry could read the raw recipe text it already has in that callback and copy `x:status` into `ret.info` itself.

**Classification and UI**

- New `source/dubregistry/status.d`: `Thresholds`, `Bucket`, `classify(...)` – a pure port of dubx `search_heuristics.d` (unit-tested, no I/O).
- `source/dubregistry/web.d` – `DubRegistryFullWebFrontend.querySearch()` (~line 544) renders `search_results.dt` with `m_registry.searchPackages(q)`. Classify there and pass grouped results.
- `source/dubregistry/dbcontroller.d` – `searchPackages()` (~line 395) projects only `name`, `stats`, `latestVersion`; that is enough once the new fields live in `stats` (no extra query per row).
- `views/search_results.dt` – one table per bucket (or a bucket column plus filter chips), reason column, declared-status badge first.
- `views/view_package.dt` – same badge and reason on the package page.
- `source/dubregistry/api.d` – `search()` (~line 138) returns `SearchResult`; add `bucket` and `reason` so `dub search` and tools like dubx get the same answer.
- `source/dubregistry/viewutils.d` – a `formatStatusReason()` beside `formatPackageStats()`.

## Rollout

1. Store `repoState`/`archived`/`pushedAt` in stats (no UI change).
2. Add `status.d` + grouped search page behind a `?grouped=1` query flag; collect feedback.
3. Make grouping the default; keep a "flat list" link.
4. Land `x:status` in dub; add badge.
5. Build-check job feeding `buildsWithCurrent`.

## Open questions

1. Field name: `x:status` (namespaced, clearly an extension) or a first-class `status`? Namespaced keys need a dub change either way, because dub drops unknown keys today.
2. Should a declared `stable` with a 404 repo still show as gone? This draft says yes: a missing repo is a fact that beats any declaration.
3. Should `deprecated` carry a successor (`x:status "deprecated" successor="dyaml"`)?
4. Who runs the build check, how often, and against which compiler versions (latest DMD + latest LDC only)? What counts as "builds" for packages that need system libraries?
5. Is "answers issues" fair to projects that track issues elsewhere (GitLab, mailing list)? Should it only ever raise a package (Quiet → Finished), never lower one? (This draft: only raise.)
6. Wrapper detection by "depends on another hit" also catches frameworks that merely use the library (e.g. `uim-framework` → `dyaml`). Keep it, restrict it to small packages, or let maintainers declare `x:kind "binding"`?
7. Thresholds: are 12 months / 3 years right for D's release culture? They are in one struct, so they are easy to tune.
8. Should packages whose repo has been 404 for N months be hidden from default search entirely?

## Reference implementation

`dubx search <query>` in [dlang-supplemental/dubx](https://github.com/dlang-supplemental/dubx) implements the same buckets client-side with the public API (`docs/search.adoc`). Sample output for `yaml`:

```
Active (5)
  dyaml          0.10.0       last release 0.10.0 (2024-06), repo moved to dlang-community/D-YAML, pushed 2026-01
Quiet (3)
  uniconf        0.2.2        last release 0.2.2 (2020-04), pushed 2021-04
Repo gone or archived (3)
  yaml-d         0.0.1        single release 0.0.1 (2017-05), repo 404
  mir-yaml       1.0.0        single release 1.0.0 (2021-07), repo archived
Wrapper or subpackage (13)
  dyaml:yaml_gen 0.10.0       subpackage of dyaml
  configy        2.2.0        depends on dyaml; last release 2.2.0 (2025-10), pushed 2025-10
```
