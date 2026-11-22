/// Debugger state on the UI thread: a fake program, breakpoints, registers, memory and the log.
module debugger.model;

import dentrite.signals;
import std.algorithm.iteration : filter;
import std.algorithm.searching : any, canFind;
import std.array : array;
import std.format : format;
import std.random : Mt19937, uniform;

/// One instruction of the fake program.
struct Instr
{
    ulong addr;      /// address
    ubyte len;       /// length in bytes
    string mnemonic; /// operation
    string operands; /// operands
    string bytes;    /// encoded bytes as hex
}

/// Source location of an instruction.
struct SourceLoc
{
    string file; /// source file
    uint line;   /// line
}

/// Deterministic fake machine code with a source mapping.
final class Program
{
    Instr[] code;    /// instructions, sorted by address
    static immutable string[] files = ["main.d", "parser.d", "lexer.d", "codegen.d", "symbols.d", "util.d"];

    /// Generates `count` instructions from `base`.
    this(size_t count, ulong base = 0x401000)
    {
        static immutable string[2][] forms = [
            ["push", "rbp"], ["mov", "rbp, rsp"], ["sub", "rsp, 0x%02x"], ["mov", "rax, qword ptr [rbp-0x%02x]"],
            ["add", "rax, %d"], ["cmp", "rax, rdx"], ["jne", "0x%x"], ["call", "%s"], ["ret", ""],
            ["lea", "rdi, [rip+0x%x]"], ["xor", "eax, eax"], ["test", "rax, rax"], ["jmp", "0x%x"],
            ["nop", ""], ["pop", "rbp"], ["movzx", "ecx, byte ptr [rsi+%d]"], ["inc", "rcx"],
            ["imul", "rax, rcx"], ["mov", "dword ptr [rbp-0x%02x], eax"], ["shr", "rdx, %d"],
        ];
        static immutable ubyte[] lens = [1, 3, 4, 4, 4, 3, 2, 5, 1, 7, 2, 3, 5, 1, 1, 4, 3, 4, 3, 4];
        static immutable string[] callees = ["parser.next", "lexer.peek", "symbols.lookup", "util.hash",
            "codegen.emit", "gc_malloc", "_d_arraybounds"];
        Mt19937 rng = Mt19937(42);
        ulong a = base;
        code.reserve(count);
        foreach (size_t i; 0 .. count)
        {
            size_t k = uniform(0, forms.length, rng);
            string ops = forms[k][1];
            if (canFind(ops, "%s"))
            {
                ops = format(ops, callees[uniform(0, callees.length, rng)]);
            }
            else if (canFind(ops, "%x"))
            {
                ops = format(ops, a + uniform(-0x400, 0x400, rng) & ~0xfUL);
            }
            else if (canFind(ops, "%02x"))
            {
                ops = format(ops, uniform(1, 0x40, rng) * 8);
            }
            else if (canFind(ops, "%d"))
            {
                ops = format(ops, uniform(1, 32, rng));
            }
            string hex;
            foreach (ubyte j; 0 .. lens[k])
            {
                hex ~= format(j == 0 ? "%02X" : " %02X", uniform(0, 256, rng));
            }
            code ~= Instr(a, lens[k], forms[k][0], ops, hex);
            a += lens[k];
        }
    }

    /// Index of the instruction at or before `addr`.
    size_t indexOf(ulong addr) const
    {
        size_t lo = 0;
        size_t hi = code.length;
        while (hi - lo > 1)
        {
            size_t mid = (lo + hi) / 2;
            if (code[mid].addr <= addr)
            {
                lo = mid;
            }
            else
            {
                hi = mid;
            }
        }
        return lo;
    }

    /// Source location of instruction `index`.
    SourceLoc locate(size_t index) const
    {
        return SourceLoc(files[(index / 4000) % files.length], cast(uint)((index % 4000) / 3 + 1));
    }
}

/// Breakpoint. Identity fields are fixed, the rest are signals.
final class Breakpoint
{
    immutable uint id;     /// stable key
    immutable string file; /// source file
    immutable uint line;   /// source line
    immutable ulong addr;  /// code address
    Signal!bool enabled;   /// checkbox state
    Signal!uint hits;      /// hit count, written by the backend

    /// Creates an enabled breakpoint with no hits.
    this(uint id, SourceLoc loc, ulong addr)
    {
        this.id = id;
        this.file = loc.file;
        this.line = loc.line;
        this.addr = addr;
        enabled = signal(true);
        hits = signal(0u);
    }
}

/// Log severity.
enum Level : ubyte
{
    info,  /// normal
    warn,  /// warning
    error, /// failure
}

/// Log line.
struct LogLine
{
    double time;  /// seconds since start
    Level level;  /// severity
    string text;  /// message
}

/// Register names, in display order.
immutable string[] registerNames = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10",
    "r11", "r12", "r13", "r14", "r15", "rip", "rflags"];

/// UI-side debugger state.
final class Session
{
    Program program;                  /// code
    Signal!(Breakpoint[]) breakpoints; /// every breakpoint
    Signal!uint selected;             /// selected breakpoint ID, 0 for none
    Signal!bool running;              /// target running
    Signal!ulong pc;                  /// current instruction address
    Signal!ulong[] registers;         /// register values
    Signal!(immutable(ubyte)[]) memory; /// memory snapshot
    ulong memoryBase = 0x7ffe_0000;   /// address of `memory[0]`
    Signal!uint hitRate;              /// hits per second
    LogLine[] log;                    /// every log line
    Signal!size_t logCount;           /// `log.length`, for views to depend on
    private uint nextId = 1;          /// next breakpoint ID
    private Mt19937 rng;              /// for added breakpoints

    /// Creates a session over a fresh fake program with a few breakpoints.
    this()
    {
        program = new Program(60_000);
        rng = Mt19937(7);
        breakpoints = signal(cast(Breakpoint[]) null);
        selected = signal(0u);
        running = signal(true);
        pc = signal(program.code[0].addr);
        foreach (size_t i; 0 .. registerNames.length)
        {
            registers ~= signal(0UL);
        }
        memory = signal(cast(immutable(ubyte)[]) new ubyte[0x4000]);
        hitRate = signal(0u);
        logCount = signal(cast(size_t) 0);
        Breakpoint[] initial;
        foreach (int i; 0 .. 14)
        {
            initial ~= make(uniform(0, program.code.length, rng));
        }
        breakpoints.set(initial);
    }

    /// New breakpoint at instruction `index`.
    private Breakpoint make(size_t index)
    {
        return new Breakpoint(nextId++, program.locate(index), program.code[index].addr);
    }

    /// Adds `n` breakpoints at random instructions.
    void addRandom(size_t n = 1)
    {
        Breakpoint[] more = breakpoints.peek.dup;
        foreach (size_t i; 0 .. n)
        {
            more ~= make(uniform(0, program.code.length, rng));
        }
        breakpoints.set(more);
    }

    /// Breakpoint at `addr`, or null.
    Breakpoint at(ulong addr)
    {
        foreach (Breakpoint b; breakpoints.peek)
        {
            if (b.addr == addr)
            {
                return b;
            }
        }
        return null;
    }

    /// Drops breakpoint `b`.
    void remove(Breakpoint b)
    {
        breakpoints.set(breakpoints.peek.filter!(x => x !is b).array);
    }

    /// Adds a breakpoint at `addr`, or removes the one there.
    void toggleAt(ulong addr)
    {
        if (Breakpoint b = at(addr))
        {
            remove(b);
            return;
        }
        Breakpoint[] more = breakpoints.peek.dup;
        more ~= make(program.indexOf(addr));
        breakpoints.set(more);
        selected.set(more[$ - 1].id);
    }

    /// Drops every disabled breakpoint.
    void removeDisabled()
    {
        breakpoints.set(breakpoints.peek.filter!(b => b.enabled.peek).array);
    }

    /// True if any breakpoint is disabled.
    bool anyDisabled()
    {
        return breakpoints.get.any!(b => b.enabled.get == false);
    }

    /// Appends log lines.
    void append(LogLine[] lines)
    {
        if (lines.length == 0)
        {
            return;
        }
        log ~= lines;
        logCount.set(log.length);
    }
}

/// Instructions are contiguous, and lookups find the instruction containing an address.
unittest
{
    Program p = new Program(1000);
    assert(p.code[1].addr == p.code[0].addr + p.code[0].len);
    assert(p.indexOf(p.code[500].addr) == 500);
    assert(p.indexOf(p.code[500].addr + p.code[500].len - 1) == 500 || p.code[500].len == 1);
    assert(p.code[0].bytes.length == p.code[0].len * 3 - 1);
}

/// Toggling adds and removes, and the new breakpoint is selected.
unittest
{
    Session s = new Session;
    size_t n = s.breakpoints.peek.length;
    ulong a = s.program.code[123].addr;
    s.toggleAt(a);
    assert(s.breakpoints.peek.length == n + 1 && s.at(a) !is null);
    assert(s.selected.peek == s.at(a).id);
    s.toggleAt(a);
    assert(s.breakpoints.peek.length == n && s.at(a) is null);
}
