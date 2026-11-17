#!/usr/bin/env python3
"""
GitHistoryMigrator: move a PowerBuilder 2025 repository from Workspace mode
(PBL files, with source exported to ws_objects) to Solution mode (source kept
as text files in .pbl folders), without losing the git history.

Two modes:

  inplace  Adds two commits on a new branch of the repository:
             1. a pure rename commit: every ws_objects/<path>/<lib>.pbl.src/<obj>
                moves to <path>/<lib>.pbl/<obj> with its content unchanged, so
                git sees each move as a 100% rename;
             2. a conversion commit: the export headers are rewritten, the
                .pbw/.pbt files become .pbsln/.pbproj files, each library gets a
                .pblmeta file, and a .gitignore pattern such as *.pbl gets a
                !*.pbl/ negation so the new .pbl folders aren't ignored.
           Existing commits, branches and hashes are untouched.

  rewrite  Builds a NEW repository in which every commit of the source
           repository is rewritten as if the project had always been in
           Solution mode. The source repository is only read. Commit hashes
           change; a map of old to new hashes is written.

Both modes accept --ide-output: the folder PowerBuilder's own migration wrote.
Its .pbsln, .pbproj and .pbl folder contents are then committed on top, so the
final tree is exactly what the IDE produced (including .bin files for objects
with OLE binary data, which this tool cannot generate itself).

Requires Python 3.8+ and git 2.21+.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from collections import Counter

BOM = b"\xef\xbb\xbf"
SOURCE_EXTS = {".sra", ".srd", ".srf", ".srj", ".srm", ".srp", ".srq",
               ".srs", ".sru", ".srw", ".srx"}
PBL_VERSION = "250"   # PowerBuilder 2025
# What PowerBuilder writes into a .pblmeta file when it migrates a workspace.
PBL_COMMENT = "Created from Source Control Refresh Operation"


# --------------------------------------------------------------------------
# Format conversion (pure functions, shared by both modes)
# --------------------------------------------------------------------------

def map_path(path):
    """ws_objects/<dirs>/<lib>.pbl.src/<rest>  ->  <dirs>/<lib>.pbl/<rest>.

    The ws_objects folder may sit below the repository root (next to a .pbw
    that is not at the root); whatever precedes it is kept. Returns None for
    paths that are not inside a .pbl.src folder of a ws_objects folder."""
    parts = path.split("/")
    if "ws_objects" not in parts:
        return None
    i = parts.index("ws_objects")
    rest = parts[i + 1:]
    for k, p in enumerate(rest[:-1]):
        if p.lower().endswith(".pbl.src"):
            rest[k] = p[:-4]
            return "/".join(parts[:i] + rest)
    return None


def library_dir(new_path):
    """The .pbl folder a mapped path lives in."""
    parts = new_path.split("/")
    for k, p in enumerate(parts[:-1]):
        if p.lower().endswith(".pbl"):
            return "/".join(parts[:k + 1])
    return None


def _take_line(b):
    n = b.find(b"\n")
    return (b, b"") if n < 0 else (b[:n + 1], b[n + 1:])


def convert_source(data, path):
    """Workspace export -> Solution source.

    $PBExportHeader$<name>      is dropped
    $PBExportComments$<text>    becomes //objectcomments <text>
    Everything else is kept byte for byte, as PowerBuilder 2025 R2's own
    conversion does. Returns (bytes, notes)."""
    notes = []
    if data.startswith(b"\xff\xfe"):        # UTF-16LE export -> UTF-8 with BOM
        data = BOM + data[2:].decode("utf-16-le").encode("utf-8")
        notes.append("utf16")
    bom = data.startswith(BOM)
    body = data[3:] if bom else data
    line, rest = _take_line(body)
    if line.startswith(b"$PBExportHeader$"):
        body = rest
        line, rest = _take_line(body)
    if line.startswith(b"$PBExportComments$"):
        body = b"//objectcomments " + line[len(b"$PBExportComments$"):] + rest
    if b"Start of PowerBuilder Binary Data Section" in body:
        notes.append("binary")
    return (BOM if bom else b"") + body, notes


def _decode(data):
    if data.startswith(BOM):
        data = data[3:]
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp1252")


def _eol(data):
    return "\r\n" if b"\r\n" in data else "\n"


def _pb_unescape(s):
    return s.replace("\\\\", "\\")


def parse_pb_save(data):
    """Parse a .pbw/.pbt ("Save Format v3.0") file into (values, sections).
    Values are unescaped (\\\\ -> \\); section entries are kept raw, because
    PowerBuilder copies some of them into the .pbproj exactly as written."""
    values, sections, current = {}, {}, None
    for raw in _decode(data).splitlines():
        line = raw.strip()
        m = re.match(r"@begin\s+(\w+)", line)
        if m:
            current = sections.setdefault(m.group(1), [])
            continue
        if line.startswith("@end"):
            current = None
            continue
        if current is not None:
            m = re.match(r'\d+\s+"(.*)";?$', line)
            if m:
                current.append(m.group(1))
            continue
        m = re.match(r'(\w+)\s+"(.*)";?$', line)
        if m:
            values[m.group(1)] = _pb_unescape(m.group(2))
    return values, sections


def _xml_attr(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


def _swap_ext(path, new_ext):
    return os.path.splitext(path)[0] + new_ext


def convert_pbw(data):
    values, sections = parse_pb_save(data)
    nl = _eol(data)
    targets = [_pb_unescape(t).replace("/", "\\") for t in sections.get("Targets", [])]
    default = values.get("DefaultTarget")
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="no" ?>', "<Solution>"]
    if default:
        out.append('  <Projects Default="%s">' % _xml_attr(_swap_ext(default, ".pbproj")))
    else:
        out.append("  <Projects>")
    for t in targets:
        out.append('    <Project Path="%s"/>' % _xml_attr(_swap_ext(t, ".pbproj")))
    out += ["  </Projects>", "</Solution>"]
    return BOM + (nl.join(out) + nl).encode("utf-8")


def convert_pbt(data):
    """.pbt -> .pbproj, in the layout PowerBuilder 2025 R2's conversion writes.
    Each entry of the target's Projects list ("<deploy>&<name>&<library>")
    becomes a <Deploying> element, copied as written in the .pbt (its library
    path keeps the doubled backslashes, as R2 leaves it)."""
    values, sections = parse_pb_save(data)
    nl = _eol(data)
    libs = [l for l in values.get("LibList", "").split(";") if l]
    applib = values.get("applib", libs[0] if libs else "")
    out = ['<?xml version="1.0" encoding="UTF-8" standalone="no" ?>', "<Project>",
           '  <Type Name="%s"/>' % _xml_attr(values.get("type", "pb")),
           '  <Application Name="%s"/>' % _xml_attr(values.get("appname", "")),
           '  <Libraries AppEntry="%s">' % _xml_attr(applib)]
    for l in libs:
        out.append('    <Library Path="%s"/>' % _xml_attr(l))
    out.append("  </Libraries>")
    deploys = [item.split("&", 2) for item in sections.get("Projects", [])]
    deploys = [d for d in deploys if len(d) == 3]
    if deploys:
        out.append("  <Deployings>")
        for deploy, name, lib in deploys:
            out.append('    <Deploying Deploy="%s" Library="%s" Name="%s"/>'
                       % (_xml_attr(deploy), _xml_attr(lib), _xml_attr(name)))
        out.append("  </Deployings>")
    out.append("</Project>")
    return BOM + (nl.join(out) + nl).encode("utf-8")


def make_pblmeta(nl="\r\n"):
    text = ("{" + nl + '    "version": "%s",' % PBL_VERSION + nl
            + '    "comment": "%s"' % PBL_COMMENT + nl + "}")   # no final newline, as the IDE writes it
    return BOM + text.encode("utf-8")


def pblmeta_path(libdir):
    name = libdir.split("/")[-1]
    return libdir + "/" + name[:-4] + ".pblmeta"


def is_pbl_file(path):
    return path.lower().endswith(".pbl")


def is_gitignore(path):
    return path.split("/")[-1] == ".gitignore"


GITIGNORE_NOTE = "# Solution mode: .pbl entries are source folders, not binary libraries"


def fix_gitignore(data):
    """A Workspace-mode .gitignore usually ignores the binary libraries with a
    pattern such as *.pbl. In Solution mode that pattern matches the .pbl
    source folders, so git would ignore every object added to them. For each
    such pattern, add a negation that re-includes the folders (a trailing /
    matches only directories): *.pbl  ->  !*.pbl/
    Returns the new content, or the same bytes if nothing needed changing.
    Works on bytes, so the existing content is never re-encoded."""
    body = data[3:] if data.startswith(BOM) else data
    lines = [l.strip(b" \t\r\n\v\f") for l in body.split(b"\n")]
    have = set(lines)
    add = []
    for p in lines:
        if not p or p.startswith((b"#", b"!")) or p.endswith(b"/"):
            continue
        if p.lower().endswith(b".pbl"):
            neg = b"!" + p + b"/"
            if neg not in have and neg not in add:
                add.append(neg)
    if not add:
        return data
    note = GITIGNORE_NOTE.encode("utf-8")
    if note not in have:
        add.insert(0, note)
    nl = b"\r\n" if b"\r\n" in data else b"\n"
    sep = nl if body and not data.endswith((b"\n", b"\r")) else b""
    return data + sep + nl.join(add) + nl


# --------------------------------------------------------------------------
# git helpers
# --------------------------------------------------------------------------

def git(repo, *args, input=None, check=True):
    r = subprocess.run(["git", "-C", repo, *args], input=input,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and r.returncode != 0:
        sys.exit("git %s failed:\n%s" % (" ".join(args),
                                          r.stderr.decode(errors="replace")))
    return r.stdout


def git_text(repo, *args, **kw):
    return git(repo, *args, **kw).decode("utf-8", errors="replace").strip()


def repo_root(path):
    return git_text(path, "rev-parse", "--show-toplevel")


def commit(repo, message):
    git(repo, "commit", "-q", "-m", message)
    return git_text(repo, "rev-parse", "HEAD")


# --------------------------------------------------------------------------
# --ide-output overlay
# --------------------------------------------------------------------------

def _rel(p):
    return os.path.normpath(p).replace(os.sep, "/")


def resolve_case(root, rel):
    """Spell a relative path the way it exists below root. PowerBuilder paths
    are case-insensitive (a .pbsln may say pbl\\x.pbproj for a PBL folder),
    but git pathspecs and non-Windows file systems are not. Components that
    don't exist are kept as given."""
    out, cur = [], root
    for part in rel.split("/"):
        hit = part
        names = os.listdir(cur) if os.path.isdir(cur) else []
        if part not in names:
            hit = next((n for n in names if n.lower() == part.lower()), part)
        out.append(hit)
        cur = os.path.join(cur, hit)
    return "/".join(out)


def solution_files(ide_dir):
    """The files that make up the solution in the IDE's output folder: the
    .pbsln at its root, the .pbproj files it lists, and every file in the
    library folders those projects use. Build output (which also contains
    .pbl folders) is not part of it. Paths are spelled as they exist on disk."""
    slns = [f for f in os.listdir(ide_dir) if f.lower().endswith(".pbsln")]
    if not slns:
        sys.exit("--ide-output %s has no .pbsln file at its root." % ide_dir)
    files, libdirs = set(), set()

    for sln in slns:
        files.add(sln)
        text = _decode(open(os.path.join(ide_dir, sln), "rb").read())
        for proj in re.findall(r'<Project\s+Path="([^"]+)"', text):
            proj = resolve_case(ide_dir, _rel(proj.replace("\\", "/")))
            full = os.path.join(ide_dir, proj)
            if not os.path.isfile(full):
                continue
            files.add(proj)
            ptext = _decode(open(full, "rb").read())
            base = os.path.dirname(proj)
            for lib in re.findall(r'(?:Library Path|AppEntry)="([^"]+)"', ptext):
                libdirs.add(resolve_case(ide_dir, _rel(os.path.join(base, lib.replace("\\", "/")))))
    for d in libdirs:
        for root, _dirs, fs in os.walk(os.path.join(ide_dir, d)):
            for f in fs:
                files.add(_rel(os.path.relpath(os.path.join(root, f), ide_dir)))
    return sorted(files)


def overlay_ide_output(repo, ide_dir, mapped_libdirs):
    """Copy the IDE's solution files (see solution_files) into the repo, each
    at the spelling the repository already uses for it.
    Returns (changed paths, repo files in .pbl folders the IDE did not write,
    IDE files skipped because the repository's .gitignore excludes them)."""
    targets = [(src, resolve_case(repo, src)) for src in solution_files(ide_dir)]
    ignored = set(git(repo, "check-ignore", "--no-index", "-z", "--stdin",
                      input=b"\0".join(d.encode("utf-8") for _s, d in targets) + b"\0",
                      check=False).decode("utf-8").split("\0"))
    changed, skipped, seen = [], [], set()
    for src, rel in targets:
        if rel in ignored:
            skipped.append(rel)
            continue
        seen.add(rel.lower())
        dst = os.path.join(repo, rel)
        new = open(os.path.join(ide_dir, src), "rb").read()
        if os.path.isfile(dst) and open(dst, "rb").read() == new:
            continue
        os.makedirs(os.path.dirname(dst) or repo, exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(new)
        changed.append(rel)
    leftovers = []
    for libdir in sorted(mapped_libdirs):
        d = os.path.join(repo, libdir)
        if os.path.isdir(d):
            for f in os.listdir(d):
                rel = libdir + "/" + f
                if rel.lower() not in seen:
                    leftovers.append(rel)
    return changed, leftovers, skipped


def stage_paths(repo, paths):
    if paths:
        git(repo, "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul",
            input=b"\0".join(p.encode("utf-8") for p in paths) + b"\0")


# --------------------------------------------------------------------------
# inplace mode
# --------------------------------------------------------------------------

def run_inplace(args):
    repo = repo_root(args.repo)
    if git_text(repo, "status", "--porcelain", "--untracked-files=no"):
        sys.exit("The repository has uncommitted changes. Commit or stash them first.")
    if git(repo, "rev-parse", "--verify", "-q", "refs/heads/" + args.branch,
           check=False).strip():
        sys.exit("Branch %s already exists." % args.branch)

    # Index entries: mode, sha, path
    entries = {}
    for rec in git(repo, "ls-files", "-s", "-z").split(b"\0"):
        if rec:
            meta, path = rec.split(b"\t", 1)
            mode, sha, _stage = meta.decode().split()
            entries[path.decode("utf-8")] = (mode, sha)

    mapping, unmapped = {}, []
    for p in entries:
        n = map_path(p)
        if n:
            mapping[p] = n
        elif "/ws_objects/" in "/" + p:
            unmapped.append(p)
    if not mapping:
        sys.exit("No ws_objects/<lib>.pbl.src files found: is this a Workspace-mode repository?")
    libdirs = sorted({library_dir(n) for n in mapping.values()})
    lower_entries = {p.lower(): p for p in entries}

    # Things that would block the new paths
    clash = [n for n in mapping.values() if n.lower() in lower_entries]
    if clash:
        sys.exit("These target paths are already tracked:\n  " + "\n  ".join(clash[:20]))
    tracked_pbls = [lower_entries[d.lower()] for d in libdirs if d.lower() in lower_entries]
    local_pbls = [d for d in libdirs
                  if os.path.isfile(os.path.join(repo, d)) and d.lower() not in lower_entries]
    if local_pbls and not args.move_pbls_to:
        sys.exit("These untracked .pbl files sit where the new .pbl folders go:\n  "
                 + "\n  ".join(local_pbls)
                 + "\nPass --move-pbls-to <folder outside the repository> to move them aside.")

    print("Branch %s from %s" % (args.branch, git_text(repo, "rev-parse", "--short", "HEAD")))
    git(repo, "switch", "-q", "-c", args.branch)

    # ---- commit 1: pure renames ------------------------------------------
    for d in local_pbls:
        dst = os.path.join(args.move_pbls_to, d)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(os.path.join(repo, d), dst)
        print("Moved local %s to %s" % (d, dst))
    if tracked_pbls:
        git(repo, "rm", "-q", "--", *tracked_pbls)

    index_info = []
    for old, new in sorted(mapping.items()):
        mode, sha = entries[old]
        src, dst = os.path.join(repo, old), os.path.join(repo, new)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(src, dst)
        index_info.append("0 %s\t%s" % ("0" * len(sha), old))
        index_info.append("%s %s\t%s" % (mode, sha, new))
    git(repo, "update-index", "--index-info", input=("\n".join(index_info) + "\n").encode("utf-8"))
    _prune_empty_dirs(repo, {os.path.dirname(o) for o in mapping})
    sha1 = commit(repo, args.message_rename or
                  "Move the source from ws_objects into .pbl folders (Solution mode)\n\n"
                  "A pure rename: no file content changes, so git follows each file's\n"
                  "history across the move. The next commit converts the formats.")

    # ---- commit 2: conversion --------------------------------------------
    notes, touched = Counter(), []
    binary_objs, utf16_objs = [], []
    for new in sorted(mapping.values()):
        if os.path.splitext(new)[1].lower() not in SOURCE_EXTS:
            continue
        full = os.path.join(repo, new)
        data = open(full, "rb").read()
        conv, n = convert_source(data, new)
        if "binary" in n:
            binary_objs.append(new)
        if "utf16" in n:
            utf16_objs.append(new)
        if conv != data:
            with open(full, "wb") as fh:
                fh.write(conv)
            touched.append(new)

    sample_eol = "\r\n"
    for p in sorted(entries):
        low = p.lower()
        if low.endswith(".pbw"):
            data = open(os.path.join(repo, p), "rb").read()
            sample_eol = _eol(data)
            out = _swap_ext(p, ".pbsln")
            _write(repo, out, convert_pbw(data))
            git(repo, "rm", "-q", "--", p)
            touched.append(out)
        elif low.endswith(".pbt"):
            data = open(os.path.join(repo, p), "rb").read()
            out = _swap_ext(p, ".pbproj")
            _write(repo, out, convert_pbt(data))
            git(repo, "rm", "-q", "--", p)
            touched.append(out)
        elif is_gitignore(p):
            data = open(os.path.join(repo, p), "rb").read()
            fixed = fix_gitignore(data)
            if fixed != data:
                _write(repo, p, fixed)
                touched.append(p)
    for d in libdirs:
        meta = pblmeta_path(d)
        if not os.path.exists(os.path.join(repo, meta)):
            _write(repo, meta, make_pblmeta(sample_eol))
            touched.append(meta)
    stage_paths(repo, touched)
    sha2 = commit(repo, args.message_convert or
                  "Convert to PowerBuilder Solution format\n\n"
                  "Export headers become //objectcomments lines, the workspace and\n"
                  "target files become a .pbsln and .pbproj files, and each library\n"
                  "folder gets a .pblmeta file.")

    # ---- optional commit 3: the IDE's own output -------------------------
    sha3, leftovers, skipped = None, [], []
    if args.ide_output:
        changed, leftovers, skipped = overlay_ide_output(repo, args.ide_output, libdirs)
        stage_paths(repo, changed)
        if git_text(repo, "diff", "--cached", "--name-only"):
            sha3 = commit(repo, "Apply PowerBuilder's own Solution migration output")

    # ---- report ------------------------------------------------------------
    renames = git_text(repo, "diff", "--name-status", "-M", "--find-renames=100%",
                       sha1 + "~1", sha1).splitlines()
    exact = sum(1 for l in renames if l.startswith("R100"))
    print()
    print("Commit 1 (renames):    %s  %d files moved, %d detected by git as exact renames"
          % (sha1[:10], len(mapping), exact))
    print("Commit 2 (conversion): %s  %d files written" % (sha2[:10], len(touched)))
    if sha3:
        print("Commit 3 (IDE output): %s" % sha3[:10])
    _report(unmapped, binary_objs if not args.ide_output else [], utf16_objs, leftovers, skipped)
    print("\nNothing was pushed. Review with:  git log --stat -3   and, for any object,"
          "\n  git log --follow -- \"%s\"" % sorted(mapping.values())[0])


def _write(repo, rel, data):
    full = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(full) or repo, exist_ok=True)
    with open(full, "wb") as fh:
        fh.write(data)


def _prune_empty_dirs(repo, dirs):
    for d in sorted(dirs, key=len, reverse=True):
        while d:
            full = os.path.join(repo, d)
            if os.path.isdir(full) and not os.listdir(full):
                os.rmdir(full)
                d = os.path.dirname(d)
            else:
                break


def _report(unmapped, binary_objs, utf16_objs, leftovers, skipped=()):
    if unmapped:
        print("\nFiles under ws_objects outside any .pbl.src folder were left as they are:")
        for p in unmapped[:20]:
            print("  " + p)
    if binary_objs:
        print("\nThese objects carry an inline binary data section (OLE controls). The"
              "\nIDE stores that data in a separate .bin file in Solution mode; run with"
              "\n--ide-output, or open and save each object in the IDE:")
        for p in binary_objs:
            print("  " + p)
    if utf16_objs:
        print("\n%d objects were UTF-16 and are now UTF-8 with a BOM." % len(utf16_objs))
    if leftovers:
        print("\nFiles in .pbl folders that the IDE output does not contain (kept):")
        for p in leftovers[:20]:
            print("  " + p)
        if len(leftovers) > 20:
            print("  ... and %d more" % (len(leftovers) - 20))
    if skipped:
        print("\nIDE output files skipped because the repository's .gitignore excludes them:")
        for p in skipped[:20]:
            print("  " + p)
        if len(skipped) > 20:
            print("  ... and %d more" % (len(skipped) - 20))


# --------------------------------------------------------------------------
# rewrite mode
# --------------------------------------------------------------------------

def _unquote(p):
    """Undo git's C-style path quoting."""
    if not p.startswith(b'"'):
        return p
    s, out, i = p[1:-1], bytearray(), 0
    esc = {b"n": 10, b"t": 9, b'"': 34, b"\\": 92, b"a": 7, b"b": 8,
           b"f": 12, b"r": 13, b"v": 11}
    while i < len(s):
        c = s[i:i + 1]
        if c == b"\\":
            n = s[i + 1:i + 2]
            if n in esc:
                out.append(esc[n]); i += 2
            else:
                out.append(int(s[i + 1:i + 4], 8)); i += 4
        else:
            out += c; i += 1
    return bytes(out)


def _quote(p):
    if any(c in p for c in (b'"', b"\n", b"\\")) or p.startswith(b" "):
        return b'"' + p.replace(b"\\", b"\\\\").replace(b'"', b'\\"').replace(b"\n", b"\\n") + b'"'
    return p


class BlobReader:
    def __init__(self, repo):
        self.p = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def read(self, sha):
        self.p.stdin.write(sha + b"\n")
        self.p.stdin.flush()
        header = self.p.stdout.readline().split()
        size = int(header[2])
        data = self.p.stdout.read(size)
        self.p.stdout.read(1)
        return data

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def run_rewrite(args):
    src = repo_root(args.repo)
    out = os.path.abspath(args.output)
    if os.path.exists(out) and os.listdir(out):
        sys.exit("%s exists and is not empty." % out)
    os.makedirs(out, exist_ok=True)
    subprocess.run(["git", "init", "-q", out], check=True)
    objects = git_text(src, "rev-parse", "--path-format=absolute", "--git-common-dir")
    alt = os.path.join(out, ".git", "objects", "info", "alternates")
    with open(alt, "w", newline="\n") as fh:
        fh.write(os.path.join(objects, "objects").replace("\\", "/") + "\n")

    marks = os.path.join(out, ".git", "migrator-marks")
    exp = subprocess.Popen(["git", "-C", src, "fast-export", "--branches", "--tags",
                            "--no-data", "--signed-tags=strip",
                            "--tag-of-filtered-object=rewrite", "--reencode=no",
                            "--show-original-ids"],
                           stdout=subprocess.PIPE)
    imp = subprocess.Popen(["git", "-C", out, "fast-import", "--quiet",
                            "--export-marks=" + marks], stdin=subprocess.PIPE)
    blobs = BlobReader(src)
    stats = Counter()
    binary_objs, orig_ids = set(), {}

    r, w = exp.stdout, imp.stdin

    def copy_data(line):
        w.write(line)
        n = int(line[5:])
        w.write(r.read(n))

    while True:
        line = r.readline()
        if not line:
            break
        if line.startswith(b"commit "):
            head, ops, mark = [line], [], None
            while True:
                line = r.readline()
                if line.startswith(b"data "):
                    n = int(line[5:])
                    head.append(line + r.read(n))
                elif line.startswith(b"mark "):
                    mark = line[5:].strip()
                    head.append(line)
                elif line.startswith(b"original-oid "):
                    if mark:
                        orig_ids[mark] = line[13:].strip()
                    head.append(line)
                elif line.startswith((b"author ", b"committer ", b"encoding ",
                                      b"from ", b"merge ")):
                    head.append(line)
                else:
                    break
            # file operations until a blank line
            libdirs = {}     # library folder -> line ending of its sources
            while line not in (b"\n", b""):
                ops.extend(_rewrite_op(line, blobs, stats, binary_objs, libdirs))
                line = r.readline()
            for d, nl in sorted(libdirs.items()):
                meta = make_pblmeta(nl)
                ops.append(b"M 100644 inline " + _quote(pblmeta_path(d).encode("utf-8"))
                           + b"\ndata %d\n" % len(meta) + meta + b"\n")
            w.write(b"".join(head) + b"".join(ops) + b"\n")
            stats["commits"] += 1
        elif line.startswith(b"data "):
            copy_data(line)
        else:
            w.write(line)
    blobs.close()
    w.close()
    if exp.wait() or imp.wait():
        sys.exit("fast-export / fast-import failed.")

    # Make the new repository self-contained, then drop the alternates link.
    subprocess.run(["git", "-C", out, "repack", "-a", "-d", "-q"], check=True)
    os.remove(alt)

    # Commit map: old sha -> new sha
    new_ids = {}
    for l in open(marks, "rb"):
        m, sha = l.split()
        new_ids[m] = sha
    mapfile = os.path.join(out, ".git", "migrator-commit-map.txt")
    with open(mapfile, "wb") as fh:
        for m, old in orig_ids.items():
            if m in new_ids:
                fh.write(old + b" " + new_ids[m] + b"\n")
    os.remove(marks)

    # Check out the branch the source repository had checked out.
    head = git_text(src, "symbolic-ref", "-q", "HEAD", check=False) or "refs/heads/main"
    if git(out, "rev-parse", "--verify", "-q", head, check=False).strip():
        git(out, "symbolic-ref", "HEAD", head)
        git(out, "reset", "-q", "--hard")
    git(out, "fsck", "--connectivity-only", "--no-progress")

    print("Rewrote %d commits into %s (checked out %s)" % (stats["commits"], out, head))
    print("  %d object versions converted, %d renamed only, %d .pbl binaries dropped,"
          " %d .pbt and %d .pbw converted"
          % (stats["converted"], stats["renamed"], stats["pbl"], stats["pbt"], stats["pbw"]))
    if stats["gitignore"]:
        print("  %d .gitignore versions now re-include the .pbl folders" % stats["gitignore"])
    print("  Old -> new commit hashes: %s" % mapfile)

    if args.ide_output:
        libdirs = {library_dir(p) for p in
                   git_text(out, "ls-files").splitlines() if library_dir(p)}
        changed, leftovers, skipped = overlay_ide_output(out, args.ide_output, libdirs)
        stage_paths(out, changed)
        if git_text(out, "diff", "--cached", "--name-only"):
            sha = commit(out, "Apply PowerBuilder's own Solution migration output")
            print("  Added the IDE output as %s" % sha[:10])
        _report([], [], [], leftovers, skipped)
    else:
        cur = {p for p in binary_objs
               if os.path.exists(os.path.join(out, p.decode("utf-8")))}
        _report([], sorted(p.decode("utf-8") for p in cur), [], [])
    print("\nThe source repository was only read. Nothing was pushed.")


def _rewrite_op(line, blobs, stats, binary_objs, libdirs):
    """Rewrite one fast-export file operation; returns a list of byte strings."""
    if line.startswith(b"M "):
        mode, ref, path = line[2:].rstrip(b"\n").split(b" ", 2)
        path = _unquote(path)
        p = path.decode("utf-8")
        new = map_path(p)
        if mode == b"160000":
            return [line]
        if new:
            npath = _quote(new.encode("utf-8"))
            if os.path.splitext(new)[1].lower() in SOURCE_EXTS:
                data, notes = convert_source(blobs.read(ref), new)
                libdirs[library_dir(new)] = _eol(data)
                if "binary" in notes:
                    binary_objs.add(new.encode("utf-8"))
                stats["converted"] += 1
                return [b"M " + mode + b" inline " + npath + b"\ndata %d\n" % len(data)
                        + data + b"\n"]
            stats["renamed"] += 1
            return [b"M " + mode + b" " + ref + b" " + npath + b"\n"]
        low = p.lower()
        if low.endswith(".pbl"):
            stats["pbl"] += 1
            return []
        if low.endswith(".pbt") or low.endswith(".pbw"):
            data = blobs.read(ref)
            if low.endswith(".pbt"):
                stats["pbt"] += 1
                data, ext = convert_pbt(data), ".pbproj"
            else:
                stats["pbw"] += 1
                data, ext = convert_pbw(data), ".pbsln"
            npath = _quote(_swap_ext(p, ext).encode("utf-8"))
            return [b"M 100644 inline " + npath + b"\ndata %d\n" % len(data) + data + b"\n"]
        if is_gitignore(p):
            data = blobs.read(ref)
            fixed = fix_gitignore(data)
            if fixed != data:
                stats["gitignore"] += 1
                return [b"M " + mode + b" inline " + _quote(path)
                        + b"\ndata %d\n" % len(fixed) + fixed + b"\n"]
        return [line]
    if line.startswith(b"D "):
        path = _unquote(line[2:].rstrip(b"\n"))
        p = path.decode("utf-8")
        new = map_path(p)
        if new:
            return [b"D " + _quote(new.encode("utf-8")) + b"\n"]
        low = p.lower()
        if low.endswith(".pbl"):
            return []
        if low.endswith(".pbt"):
            return [b"D " + _quote(_swap_ext(p, ".pbproj").encode("utf-8")) + b"\n"]
        if low.endswith(".pbw"):
            return [b"D " + _quote(_swap_ext(p, ".pbsln").encode("utf-8")) + b"\n"]
        return [line]
    if line.startswith((b"R ", b"C ")):
        sys.exit("Unexpected rename/copy in fast-export output: %r" % line)
    return [line]    # deleteall, N (notes), etc.


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Move a PowerBuilder Workspace-mode git repository to Solution mode, keeping its history.")
    sub = ap.add_subparsers(dest="mode", required=True)

    a = sub.add_parser("inplace", help="add a rename commit and a conversion commit on a new branch")
    a.add_argument("repo", help="the Workspace-mode repository")
    a.add_argument("--branch", default="migrate-to-solution", help="new branch name (default: %(default)s)")
    a.add_argument("--ide-output", help="folder written by PowerBuilder's own migration, committed on top")
    a.add_argument("--move-pbls-to", help="folder to move untracked local .pbl files into")
    a.add_argument("--message-rename", help="message for the rename commit")
    a.add_argument("--message-convert", help="message for the conversion commit")

    b = sub.add_parser("rewrite", help="write a new repository whose whole history is in Solution format")
    b.add_argument("repo", help="the Workspace-mode repository (only read)")
    b.add_argument("--output", required=True, help="new, empty folder for the rewritten repository")
    b.add_argument("--ide-output", help="folder written by PowerBuilder's own migration, committed on top")

    args = ap.parse_args()
    if getattr(args, "ide_output", None) and not os.path.isdir(args.ide_output):
        sys.exit("--ide-output %s is not a folder." % args.ide_output)
    (run_inplace if args.mode == "inplace" else run_rewrite)(args)


if __name__ == "__main__":
    main()
