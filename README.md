# GitHistoryMigrator

Moves a PowerBuilder 2025 repository from **Workspace mode** (PBL files, with
the source exported to `ws_objects`) to **Solution mode** (the source kept as
text files in `.pbl` folders) without losing its git history. `git log`,
`git blame` and GitHub's file history keep working for every object.

The tool comes in two versions that produce identical results:

- **`Migrate.ps1`** needs only Windows PowerShell 5.1, which ships with
  Windows, or PowerShell 7.
- **`migrate.py`** needs Python 3.8 or later, on any platform.

Both need git 2.23 or later. The examples below use `Migrate.ps1`. The
Python options are the same in lowercase with dashes: `--ide-output`,
`--move-pbls-to`, `--output`.

## Why this works

Each object maps one to one, and only its first lines change:

| Workspace | Solution |
|---|---|
| `ws_objects/pfc libs/pfcdwsrv.pbl.src/pfc_n_cst_dwsrv.sru` | `pfc libs/pfcdwsrv.pbl/pfc_n_cst_dwsrv.sru` |
| `$PBExportHeader$pfc_n_cst_dwsrv.sru` | *(removed)* |
| `$PBExportComments$PFC DataWindow service` | `//objectcomments PFC DataWindow service` |

The comment line is dropped altogether for `.srj` project objects. The rest
of each file is identical, byte for byte.

Git records no renames. It detects them by comparing content. So the tool
moves the files in one commit, with no content changes (every move is an
exact rename), and converts them in the next commit (same paths). Even the
smallest objects, where the header is a large part of the file, keep their
history.

## Choosing a mode

| | `inplace` | `rewrite` |
|---|---|---|
| What it changes | Adds commits on a new branch of your repository | Writes a **new** repository. The source is only read |
| Existing commit hashes | Kept. Branches, tags and PR links stay valid | All change. A map of old to new hashes is written |
| `git log` of an object | Needs `--follow` to see the commits before the move | Works without `--follow` |
| `git blame` | Follows the move. Only the `//objectcomments` line is credited to the migration | No migration commits at all |
| Old commits | Check out in Workspace format | Check out in Solution format |
| Team impact | Merge the branch like any other | Everyone re-clones, and you force-push or create a new remote |

Use `inplace` unless you specifically want the history to look as if the
project had always been a solution.

## Usage

Before you start, merge or close the branches that are still in Workspace
format. Work in a fresh clone, and push only when you're happy with the
result.

```bash
git clone https://github.com/you/your-repo.git your-repo-migration
```

**In place** (adds commits on a new branch, `migrate-to-solution`):

```powershell
.\Migrate.ps1 inplace your-repo-migration
```

**Rewrite** into a new repository:

```powershell
.\Migrate.ps1 rewrite your-repo-migration -Output your-repo-solution
```

If PowerShell refuses to run the script because of the execution policy,
run it as `powershell -ExecutionPolicy Bypass -File .\Migrate.ps1 ...`.

### Recommended: commit the IDE's own migration output on top

PowerBuilder's migration knows things this tool can't recover from
`ws_objects`: library comments, which live only in the binary PBL, and the
`.bin` files for objects with OLE binary data. Migrate a copy of the
workspace in the IDE, then pass the folder it wrote:

```powershell
.\Migrate.ps1 inplace your-repo-migration -IdeOutput "C:\path\to\ide-migrated-solution"
```

This adds one more commit, which makes the tree exactly match what the IDE
produced. The tool takes the `.pbsln` at that folder's root, the `.pbproj`
files it lists, and the library folders those projects use. Build output and
anything your `.gitignore` excludes are skipped. Since the renames are already
in commit 1, the history still follows.

## What each commit contains (inplace)

1. **Renames.** Every `ws_objects/<path>/<lib>.pbl.src/<object>` moves to
   `<path>/<lib>.pbl/<object>`. Tracked binary `.pbl` files are removed in
   this commit because the new `.pbl` folders take their place.
2. **Conversion.** The export headers are rewritten. Each `.pbw` becomes a
   `.pbsln` and each `.pbt` a `.pbproj`, with the default target, application,
   library list and deploy projects carried over. Each library folder gets a
   `.pblmeta` file.
3. *(With `-IdeOutput` only.)* The IDE's files.

The tool stops without changing anything if the repository has uncommitted
changes or the branch already exists. It also stops if an untracked `.pbl`
file sits where a new `.pbl` folder must go. Pass
`-MovePblsTo <folder outside the repository>` to move those files aside.

## Limitations

- **Binary data sections.** Objects with OLE controls (such as `u_oc`)
  carry their data inline in Workspace exports. In Solution mode the IDE
  writes it to a separate `.bin` file in a format this tool doesn't
  generate. The tool lists these objects. Use `-IdeOutput`, or open and
  save each one in the IDE.
- **Library comments.** These are stored only in the binary PBL, so a
  generated `.pblmeta` gets the IDE's default comment ("Created from Source
  Control Refresh Operation"). `-IdeOutput` brings in the real ones.
- **Generated `.pbproj` deploy configurations** are best effort. A project
  is included when its `.srj` can be found in a library on the target's
  library list. In rewrite mode this is decided from the library list alone.
- **Rewrite mode** writes `.pblmeta` files in each commit that touches a
  library. It doesn't remove them when a library is later deleted.
- After the migration, the first IDE save of some objects may still change
  them slightly. For example, a newer PowerBuilder version omits default
  application properties. That is the IDE normalizing the source, not a
  migration step, and it shows up as an ordinary small commit.

## Tested on

`pfc2025 - Workspace` (185 commits, 863 objects), using scratch clones; the
source repositories were not modified. Results:

- **Renames.** All 863 moves were detected as exact (100%) renames.
- **Matches the IDE.** After conversion, 875 of 886 files in the `.pbl`
  folders were identical to `PFC2025 - Solution`. The other 11 are 9
  objects that were edited separately in each repository and 2 `.pblmeta`
  files whose real library comments exist only in the binary PBL.
- **With `-IdeOutput`.** The final tree matched the Solution repository's
  971 files exactly.
- **Rewrite.** The tip tree is identical to the in-place result. The 185
  commits and 3 tags are kept. `git blame` credits no line to the migration,
  and `git fsck` passes.
- **PowerShell and Python agree.** `Migrate.ps1`, run on Windows PowerShell
  5.1 and on PowerShell 7, produced the same trees as `migrate.py` in every
  mode. In rewrite mode it also produced the same commit hashes for all 185
  commits.
- **Safety checks.** Each one stopped the tool before it created a branch:
  uncommitted changes, an existing branch, an untracked `.pbl` file in the
  way, a non-empty `-Output` folder, and a repository that isn't in
  Workspace mode. `-MovePblsTo` moved the `.pbl` file aside and the
  migration then completed.
