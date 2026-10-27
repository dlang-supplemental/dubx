<!--
Filed as https://github.com/dlang/dub-registry/issues/629 (2026-10-26). PR to follow.
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
| `goneGraceDays` | 30 | sustained 404/451 needed before it overrides a declared status |
| `wrapperDescriptionPattern` | `\b(bindings?\|wrappers?\|wraps\|port of\|interface to\|binding for)\b` | description marks a wrapper |

Rules, first match wins:

1. **Repo gone or archived** – repo is archived, or the host returns 404/451. With no declared status a 404 counts at once. With a declared status the 404 must be *sustained*: repeated checks (the 24 h stats refresh) keep failing for `goneGraceDays` (default 30, configurable) since the first failure. Until then the package keeps its declared bucket and shows *repo unreachable since <date>*; after that the 404 overrides the declaration. Repos get renamed, briefly made private, or restored, so one failed fetch is not enough to bury a package whose maintainer said it is finished.
2. **Declared status** (see section 2) – always beats the heuristics and is shown first:
   `complete`, `maintenance-only` → **Finished or maintenance-only**; `deprecated`, `unmaintained` → **Declared deprecated or unmaintained**; `experimental`, `alpha`, `beta`, `stable` → **Active** (with the declared label as a badge).
3. **Wrapper or subpackage** – name contains `:`; or the newest release depends on another package in the same result set (own subpackages ignored); or the description matches the pattern.
4. **Active** – newest activity ≤ `activeDays`.
5. **Slow but alive** – newest activity ≤ `quietDays`.
6. **Finished** – older, but answers issues *or* its CI passes (see Build status), and no build is known to fail.
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

## Dependency graph

The registry should compute and show, for every package **and every version**:

- **Dependencies**, direct and transitive (the resolved tree, depth-limited for display).
- **Dependents** ("used by"), direct and transitive, with the version ranges they ask for.

### The data is already there

`getVersionInfo()` (registry.d ~line 738) stores each version's `recipe.toJson()` as `DbPackageVersion.info`, so `versions.info.dependencies` (and `configurations[].dependencies`, `subPackages[]`) is in Mongo for every version of every package. Dependencies are a read of that field. **Dependents are the reverse index of the same field**: no new data source, only an aggregation.

### Prior art: registry.antora-supplemental.org

[registry.antora-supplemental.org](https://registry.antora-supplemental.org) (source: `antora-supplemental/antora-extensions-registry`, SolidStart + Drizzle/Turso) already shows a dependency tree and a "Used by" list for each Antora extension:

- **Data model.** Each module records typed edges: `requires`, `recommends`, and `bundles` (a bundle package lists its members). Packages declare richer relations in `package.json` under `antoraRegistry` (`requires`, `worksWith`, `conflictsWith`, `provides`/`uses` contracts). Compatibility links are computed at catalog sync, stored in a `catalog_compat` table and the catalog snapshot, and shown on *both* packages with a confidence order: declared conflict > platform mismatch > guaranteed > declared/curated > likely (inferred) > alternative.
- **Engine** (`src/lib/extension-deps.ts`). `buildDependencyTree(root, all, maxDepth = 4)` walks requires, recommends and bundle members. It is cycle-safe (a node already on the current branch is shown once and marked `cycle`), dedupes children, and shows unresolved ids as "(not listed)" or, when it has an external URL, "(not in registry)". `resolveModuleId` prefers a module from the same repository when a name is ambiguous. `dependents(target, all)` returns incoming edges with their relation (requires / recommends / bundled in) and a `mutual` flag for two-package cycles.
- **UI.** The package page has a "Dependency tree" card (nested list, version per node, relation badge: requires = warning colour, bundles = primary, recommends = muted; "No dependencies." when empty) and a "Used by" list with the same badges plus "mutual".
- **API.** `/api/extensions/catalog` returns the whole catalog with each module's requires/recommends (cached 300 s); clients build the graph themselves. There is no dedicated dependents endpoint.

### What to copy, what to change for dub

Keep: typed edges (for dub: required, optional, default-optional, per-configuration, subpackage), a depth limit on displayed trees, explicit cycle marks, visible "not in registry" nodes (path/repository dependencies), the mutual flag, and per-relation badges.

Change:

1. **Per version, not latest-only.** The antora registry keeps edges for the newest release only. dub users pin versions, and "who still depends on 1.x" is the question that matters before a breaking release. Store edges per `(package, version)`; show the newest by default with a version picker.
2. **Precompute the reverse index.** The antora registry computes dependents at read time over a few hundred entries. dub has ~2.5k packages and tens of thousands of versions, so build a `dependents` collection (`{target, targetRange, source, sourceVersion, relation, configuration}`) in the existing `updatePackages()` cycle, updated incrementally when a version is added or removed. Transitive dependents are a bounded BFS over that index (cache the counts).
3. **Resolve ranges.** A dependent edge carries a version range, so the UI can say "used by 37 (12 on a range that includes 2.x)". Transitive *dependencies* should be resolved the way dub would (newest matching version) and labelled as such, because a consumer's real lockfile may differ.
4. **Expose it in the API.**
   – `GET /api/packages/<name>/<version>/dependencies?transitive=1&depth=4`: tree with resolved versions, relation, `cycle`, `notInRegistry`.
   – `GET /api/packages/<name>/dependents?version=<v>&transitive=0|1`: source package, source version, range, relation; plus `count` and `countRecent` (dependents whose newest release is within `activeDays`).
   – `dependents` / `dependentsRecent` in `/api/packages/<name>/stats`, so search can use them cheaply.
5. **Feed the heuristics.** "Used by N recently released packages" is a liveness signal independent of the package's own release cadence: a finished library that 40 active packages depend on is not dead.

Where in dub-registry: a `DbController.updateDependents(packageId)` next to `searchPackages` (dbcontroller.d ~line 395), called from `updatePackages()` (registry.d ~line 493) after `getVersionInfo`; new routes in `api.d`; "Dependencies" and "Used by" cards in `views/view_package.dt`.

dubx can only count dependents **among one search's results** (`used by N of these results`), because the public API has no reverse lookup and building one client-side means downloading every package. That limit is the argument for doing it in the registry.

## Build status

"Still builds" is the strongest liveness signal and the one the registry cannot see today. Roll it out in order of cost.

### (a) Read the CI the repo already has (cheap, now)

**Exact release commit only.** A CI result is shown only when it belongs to exactly the code the registry serves. During the 24 h stats refresh, resolve the newest version's tag (`v<ver>`, then `<ver>`) to its commit SHA (peeling annotated tags), then ask for CI results *on that SHA*. There is **no fallback to the default branch**: `main` HEAD may be a different commit, and its result says nothing about the release. A run triggered by a push to `main` on the same SHA does count, because it tested the same code.

- GitHub: `GET /repos/{o}/{r}/git/ref/tags/{tag}` (+ `GET .../git/tags/{sha}` to peel annotated tags), then `GET /repos/{o}/{r}/commits/{sha}/check-runs` and `GET .../commits/{sha}/status`; failing beats pending beats passing.
- GitLab: `GET /projects/:id/repository/tags/{tag}` (commit is already peeled), then `GET /projects/:id/pipelines?sha={sha}&per_page=1`.
- Gitea/Forgejo: `GET /repos/{o}/{r}/tags/{tag}` for the commit, then `GET /repos/{o}/{r}/commits/{sha}/status`.

No tag, or no CI on that commit, means **unknown**, never passing or failing. The unknown badge on code.dlang.org should link to a registry help page for authors (e.g. `/docs/ci-status`) with the same guidance as dubx's [Link your CI to your release](https://github.com/dlang-supplemental/dubx/blob/main/docs/ci-status-for-releases.adoc): why it is unknown (no tag / no CI on the tagged commit); on GitHub add `push: tags: ['v*']` to the workflow or tag a commit `main` CI already ran on; on GitLab allow tag pipelines in `workflow:rules`; annotated and lightweight tags both work (annotated ones are peeled); a minimal DMD + LDC matrix (`dlang-community/setup-dlang`, `dub test`); and how to check the result on the commit page.

Store `ciState` (passing/failing/pending/unknown), `ciTag`, `ciSha`, `ciDate`, `ciUrl` in `DbPackageStats`, and show a badge linking to the run, labelled **"reported by the package's own CI"**. That is one or two extra requests per package per day, on host APIs the registry already calls (`RepositoryInfo` in repository.d ~line 98; github.d ~line 137, gitlab.d ~line 144, gitea.d ~line 146). dubx 0.5.0 implements this client-side.

### (b) Opt-in shared CI (cheap for the registry, run by maintainers)

Publish a reusable GitHub Actions workflow (e.g. `dlang/dub-registry/.github/workflows/package-check.yml`) and a GitLab CI template that build and test against a fixed matrix (latest DMD, latest LDC, oldest supported frontend) on push, on tag and weekly. They report to the registry through the existing repository webhook (or a signed status file the registry fetches), including the compiler versions used. Maintainers opt in with a few lines of YAML, and the registry gets *uniform* results ("builds with DMD 2.111 and LDC 1.42 as of <date>") instead of whatever each project's CI happens to check.

### (c) Registry-run builds (expensive, limited)

Build in a registry-owned sandbox only for a bounded set: the top N by downloads or by dependents (say 200), plus packages whose (a)/(b) result is stale. Rough cost: a median `dub build` + `dub test` takes 1-3 minutes; 200 packages × 2 compilers × weekly is about 400-1200 build-minutes a week. That fits the free Actions quota of a public `dub-registry-builds` repo, or one small VM. Builds run with no network after `dub fetch`, no secrets, CPU/memory/time limits, and only for released versions (never arbitrary branches). Packages that need system libraries are reported as "needs system deps", not as failing.

### Trust, abuse and staleness

- **Label the source.** (a) is self-reported: maintainers control their own CI and can make it green. (b) is self-run but uses the registry's workflow, so the matrix is known. (c) is verified. Show which one produced the badge, and rank verified above self-reported in any scoring.
- **CI never demotes on its own.** No CI is *unknown*, not failing. A failing self-reported run may block *Finished* but never marks a package dead.
- **Staleness.** Always show the date and ref: "passing on v0.10.0, 2024-06" is a different claim from "passing on master, today". An old green result describes old compilers. After `quietDays`, or after a new DMD/LDC frontend release, show it as *last known green* and stop counting it as evidence for *Finished*. Only the newest release's tagged commit counts; never substitute a branch result.
- **Abuse.** For (b), webhook reports must be signed per package (the existing webhook secret) and must point at a run URL the registry can fetch back; ignore reports for refs that do not exist. For (c), rate-limit rebuild requests and never build on unauthenticated triggers.

## Where to change dub-registry

All paths at `a7671f8`.

**Status data**

- `source/dubregistry/dbcontroller.d` – `struct DbPackageStats` (~line 752) gains `@optional` fields, e.g. `repoState` (`ok`/`gone`/`archived`), `lastPush`, `issuesSampled`, `issuesAnswered`, `dependents`, `buildsWithCurrent` (tri-state). `struct DbRepoStatsT` (~line 772) could hold `archived`/`pushedAt` instead.
- `source/dubregistry/repositories/repository.d` – `struct RepositoryInfo` (~line 98) gains `bool archived; SysTime pushedAt;`.
- `source/dubregistry/repositories/github.d` – `GithubRepository.getInfo()` (~line 137) already reads the repo JSON (`fork`, `stargazers_count`, `open_issues_count`); also read `archived` and `pushed_at`. Same for `gitlab.d` (`archived`, `last_activity_at`) and `gitea.d`; `bitbucket.d` can leave them unset.
- `source/dubregistry/registry.d` – `DubRegistry.updatePackageStats()` (~line 172) already catches `FileNotFoundException` (~line 182) as "repo no longer exists" and zero-scores the package (#221). Record `repoState = gone` and keep the first failure date (`repoGoneSince`, cleared on the next success) there instead of only dropping the score; copy `archived`/`pushedAt` from `getRepositoryInfo()`. Stats are cached 24 h by `getPackageStats()`, which is the right cadence.
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
5. Read existing CI status (Build status (a)); store `repoGoneSince` and apply the 30-day rule.
6. Dependents reverse index + API endpoints + package-page cards (Dependency graph).
7. Opt-in shared workflow (b), then a limited registry build job (c) feeding `buildsWithCurrent`.

## Open questions

1. Field name: `x:status` (namespaced, clearly an extension) or a first-class `status`? Namespaced keys need a dub change either way, because dub drops unknown keys today.
2. Should `deprecated` carry a successor (`x:status "deprecated" successor="dyaml"`)?
3. For Build status (c): which compiler versions (latest DMD + latest LDC only, or also the oldest supported frontend)? How should packages that need system libraries be reported?
4. Is "answers issues" fair to projects that track issues elsewhere (GitLab, mailing list)? Should it only ever raise a package (Quiet → Finished), never lower one? (This draft: only raise.)
5. Wrapper detection by "depends on another hit" also catches frameworks that merely use the library (e.g. `uim-framework` → `dyaml`). Keep it, restrict it to small packages, or let maintainers declare `x:kind "binding"`?
6. Thresholds: are 12 months / 3 years right for D's release culture? They are in one struct, so they are easy to tune.
7. Should packages past the 30-day 404 rule be hidden from default search entirely, or only sorted last?
8. Dependency graph: should transitive dependents count optional dependencies, and should dependents that are themselves *Repo gone* be excluded from counts?

Resolved: a declared status with a 404 repo keeps its bucket, with a *repo unreachable since <date>* warning, until the 404 has been sustained for `goneGraceDays` (30, configurable) over repeated checks; then the repo counts as gone. A 404 without a declared status counts at once.

## Reference implementation

`dubx search <query>` in [dlang-supplemental/dubx](https://github.com/dlang-supplemental/dubx) implements the same buckets client-side with the public API (`docs/search.adoc`). Sample output for `yaml`:

```
Active (5)
  dyaml          0.10.0       last release 0.10.0 (2024-06), repo moved to dlang-community/D-YAML, pushed 2026-01, used by 4 of these results
  mir-ion        2.3.5        last release 2.3.5 (2025-11), pushed 2025-11, CI failing on v2.3.5 (2025-11)
Quiet (3)
  uniconf        0.2.2        last release 0.2.2 (2020-04), pushed 2021-04
Repo gone or archived (3)
  yaml-d         0.0.1        single release 0.0.1 (2017-05), repo 404 since 2026-10-26
  mir-yaml       1.0.0        single release 1.0.0 (2021-07), repo archived
Wrapper or subpackage (13)
  dyaml:yaml_gen 0.10.0       subpackage of dyaml
  configy        2.2.0        depends on dyaml; last release 2.2.0 (2025-10), pushed 2025-10
```
