#!/usr/bin/env rdmd
/// Writes the README screenshots into `screenshots/` at 1280x720. Run `rdmd tools/screenshots.d` from any
/// directory. Builds the gallery and the debugger first, runs them under xvfb-run when it is on PATH.
module screenshots;

import std.file : mkdirRecurse;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.path : buildPath, dirName;
import std.process : Config, execute, spawnProcess, wait;
import std.stdio : stderr, writeln;

/// Repository root, from this file's location.
enum string root = dirName(dirName(__FILE_FULL_PATH__));

/// One screenshot: example directory, program in its bin/, PNG name and program arguments.
struct Shot
{
    string dir;
    string program;
    string name;
    string[] args;
}

/// Screenshots in README order.
immutable Shot[] shots = [
    Shot("examples/gallery", "dentrite-gallery", "tables.png", ["--page", "tables"]),
    Shot("examples/gallery", "dentrite-gallery", "menu.png", ["--page", "trees", "--script",
        "click:22,13; wait:2; move:80,88; wait:30"]),
    Shot("examples/debugger", "dentrite-debugger", "debugger.png", ["--frames", "60"]),
];

/// Builds the gallery and the debugger, then writes every screenshot. Returns 0, or 1 on failure.
int main(string[] args)
{
    bool noBuild;
    bool noXvfb;
    GetoptResult help = getopt(args,
        "no-build", "Skip dub build.", &noBuild,
        "no-xvfb", "Run on the current display.", &noXvfb);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Writes the README screenshots into screenshots/.", help.options);
        return 0;
    }

    string[] prefix;
    version (Posix)
    {
        if (noXvfb == false && execute(["which", "xvfb-run"]).status == 0)
            prefix = ["xvfb-run", "-a"];
    }

    if (noBuild == false)
    {
        foreach (string dir; ["examples/gallery", "examples/debugger"])
        {
            if (run(["dub", "build"], dir) == false)
                return 1;
        }
    }

    string outDir = buildPath(root, "screenshots");
    mkdirRecurse(outDir);
    foreach (immutable(Shot) s; shots)
    {
        string[] cmd = prefix ~ buildPath(root, s.dir, "bin", s.program)
            ~ ["--size", "1280x720", "--scale", "1", "--shot", buildPath(outDir, s.name)] ~ s.args;
        if (run(cmd, s.dir) == false)
            return 1;
    }
    return 0;
}

/// Runs `cmd` in `dir` under the repository root, true if it exits with 0.
bool run(string[] cmd, string dir)
{
    string cwd = buildPath(root, dir);
    if (wait(spawnProcess(cmd, null, Config.none, cwd)) == 0)
        return true;
    stderr.writeln("failed in ", dir, ": ", cmd);
    return false;
}
