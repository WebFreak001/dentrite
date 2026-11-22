/// Fake debug target on its own thread, talking to the UI through mailboxes.
///
/// The thread never touches signals. It posts latest values (hit counts, PC,
/// registers, memory) and an ordered log stream, then wakes the UI. The UI drains
/// everything once per frame in one batch. Commands go the other way through
/// atomics and a mailbox the thread polls.
module debugger.backend;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs, usecs;
import debugger.model;
import dentrite.mailbox;
import dentrite.signals : batch;
import std.format : format;
import std.random : Mt19937, uniform, uniform01;

/// Breakpoint as the target sees it.
struct TargetBreakpoint
{
    uint id;   /// key
    ulong addr; /// address
}

/// Target thread and the boxes between it and the UI.
final class Backend
{
    Mailbox!(uint, uint) hits;          /// hit count per breakpoint ID
    Mailbox!(uint, ulong) regs;         /// register values by index, PC under `pcKey`
    Mailbox!(uint, immutable(ubyte)[]) memory; /// memory snapshot under key 0
    Mailbox!(uint, uint) rate;          /// hits per second under key 0
    Queue!LogLine log;                  /// log lines in order
    Mailbox!(uint, immutable(TargetBreakpoint)[]) armed; /// enabled breakpoints, UI to target
    enum uint pcKey = uint.max;         /// `regs` key of the PC

    private shared bool running = true; /// target runs freely
    private shared int steps;           /// single steps requested while paused
    private shared bool quit;           /// thread should stop
    private Thread thread;              /// the target
    private const Program program;      /// code to walk

    /// Creates the boxes for `program`. Call `start` to run.
    this(const Program program)
    {
        this.program = program;
        hits = new Mailbox!(uint, uint);
        regs = new Mailbox!(uint, ulong);
        memory = new Mailbox!(uint, immutable(ubyte)[]);
        rate = new Mailbox!(uint, uint);
        log = new Queue!LogLine;
        armed = new Mailbox!(uint, immutable(TargetBreakpoint)[])(() nothrow {});
    }

    /// Starts the thread.
    void start()
    {
        thread = new Thread(&loop);
        thread.isDaemon = true;
        thread.start();
    }

    /// Stops the thread and waits for it.
    void stop()
    {
        atomicStore(quit, true);
        if (thread !is null)
        {
            thread.join();
        }
    }

    /// Runs or pauses the target.
    void setRunning(bool on)
    {
        atomicStore(running, on);
    }

    /// Executes one instruction while paused.
    void step()
    {
        atomicOp!"+="(steps, 1);
    }

    /// Sends the enabled breakpoints to the target.
    void arm(Breakpoint[] bps)
    {
        immutable(TargetBreakpoint)[] list;
        foreach (Breakpoint b; bps)
        {
            if (b.enabled.peek)
            {
                list ~= TargetBreakpoint(b.id, b.addr);
            }
        }
        armed.post(0, list);
    }

    /// Applies everything posted since the last drain to `s`, in one batch. UI thread.
    void drain(Session s)
    {
        uint[uint] h = hits.drain();
        ulong[uint] r = regs.drain();
        immutable(ubyte)[][uint] m = memory.drain();
        uint[uint] hr = rate.drain();
        LogLine[] lines = log.drain();
        if (h.length == 0 && r.length == 0 && m.length == 0 && hr.length == 0 && lines.length == 0)
        {
            return;
        }
        batch(() {
            if (h.length > 0)
            {
                foreach (Breakpoint b; s.breakpoints.peek)
                {
                    if (uint* n = b.id in h)
                    {
                        b.hits.set(*n);
                    }
                }
            }
            foreach (uint k, ulong v; r)
            {
                if (k == pcKey)
                {
                    s.pc.set(v);
                }
                else if (k < s.registers.length)
                {
                    s.registers[k].set(v);
                }
            }
            if (immutable(ubyte)[]* snap = 0 in m)
            {
                s.memory.set(*snap);
            }
            if (uint* n = 0 in hr)
            {
                s.hitRate.set(*n);
            }
            s.append(lines);
        });
    }

    /// Target thread body: walks the code, counts hits, mutates registers and memory.
    private void loop()
    {
        Mt19937 rng = Mt19937(1234);
        immutable(TargetBreakpoint)[] bps;
        uint[uint] counts;
        ulong[registerNames.length] reg;
        foreach (ref ulong v; reg)
        {
            v = uniform!ulong(rng) >> 16;
        }
        ubyte[] mem = new ubyte[0x4000];
        foreach (ref ubyte b; mem)
        {
            b = cast(ubyte) uniform(0, 256, rng);
        }
        size_t pc;
        MonoTime start = MonoTime.currTime;
        MonoTime lastMem;
        MonoTime lastRate = start;
        uint hitsSince;
        while (atomicLoad(quit) == false)
        {
            immutable(TargetBreakpoint)[][uint] a = armed.drain();
            if (immutable(TargetBreakpoint)[]* got = 0 in a)
            {
                bps = *got;
            }
            bool run = atomicLoad(running);
            int stepping = atomicLoad(steps);
            if (run == false && stepping == 0)
            {
                Thread.sleep(2.msecs);
                continue;
            }
            int instructions = run ? 50 : 1;
            if (run == false)
            {
                atomicOp!"-="(steps, 1);
            }
            foreach (int i; 0 .. instructions)
            {
                if (bps.length > 0 && uniform01(rng) < 0.02)
                {
                    pc = program.indexOf(bps[uniform(0, bps.length, rng)].addr);
                }
                else if (uniform01(rng) < 0.05)
                {
                    pc = uniform(0, program.code.length, rng);
                }
                else
                {
                    pc = (pc + 1) % program.code.length;
                }
                ulong addr = program.code[pc].addr;
                foreach (ref const TargetBreakpoint b; bps)
                {
                    if (b.addr == addr)
                    {
                        uint n = ++counts.require(b.id, 0);
                        hits.post(b.id, n);
                        ++hitsSince;
                        if (n % 500 == 1)
                        {
                            SourceLoc loc = program.locate(pc);
                            double t = (MonoTime.currTime - start).total!"usecs" / 1e6;
                            Level lv = n > 5000 ? Level.warn : Level.info;
                            log.post(LogLine(t, lv, format("breakpoint %d hit at %s:%d (0x%X), count %d",
                                b.id, loc.file, loc.line, addr, n)));
                        }
                    }
                }
                size_t r = uniform(0, 16, rng);
                reg[r] += uniform(-64, 64, rng);
                mem[uniform(0, mem.length, rng)] = cast(ubyte) uniform(0, 256, rng);
            }
            reg[16] = program.code[pc].addr;
            reg[17] = 0x246 ^ (reg[0] & 0x41);
            foreach (uint k; 0 .. cast(uint) reg.length)
            {
                regs.post(k, reg[k]);
            }
            regs.post(pcKey, program.code[pc].addr);
            MonoTime now = MonoTime.currTime;
            if (now - lastMem >= 50.msecs || run == false)
            {
                memory.post(0, mem.idup);
                lastMem = now;
            }
            if (now - lastRate >= 500.msecs)
            {
                rate.post(0, cast(uint)(hitsSince * 1e6 / (now - lastRate).total!"usecs"));
                hitsSince = 0;
                lastRate = now;
            }
            if (uniform01(rng) < 0.002)
            {
                double t = (now - start).total!"usecs" / 1e6;
                log.post(LogLine(t, Level.error, format("access violation reading 0x%X, handled", uniform!uint(rng))));
            }
            if (run)
            {
                Thread.sleep(1.msecs);
            }
        }
    }
}
