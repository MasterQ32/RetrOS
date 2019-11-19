const std = @import("std");
const builtin = @import("builtin");

const Terminal = @import("text-terminal.zig");
const Multiboot = @import("multiboot.zig");
const VGA = @import("vga.zig");
const GDT = @import("gdt.zig");
const Interrupts = @import("interrupts.zig");
const Keyboard = @import("keyboard.zig");
const SerialPort = @import("serial-port.zig");
const CodeEditor = @import("code-editor.zig");
const Timer = @import("timer.zig");
const SplashScreen = @import("splashscreen.zig");
const Assembler = @import("assembler.zig");

const EnumArray = @import("enum-array.zig").EnumArray;

const PCI = @import("pci.zig");
const CMOS = @import("cmos.zig");
const FDC = @import("floppy-disk-controller.zig");

const Heap = @import("heap.zig");

const PMM = @import("pmm.zig");
const VMM = @import("vmm.zig");

export var multibootHeader align(4) linksection(".multiboot") = Multiboot.Header.init();

var usercodeValid: bool = false;

var registers: [16]u32 = [_]u32{0} ** 16;

pub fn getRegisterAddress(register: u4) u32 {
    return @ptrToInt(&registers[register]);
}

var enable_live_tracing = false;

pub const assembler_api = struct {
    pub extern fn flushpix() void {
        switch (vgaApi) {
            .buffered => VGA.swapBuffers(),
            else => {},
        }
    }

    pub extern fn trace(value: u32) void {
        switch (value) {
            0, 1 => {
                enable_live_tracing = (value != 0);
            },
            2 => vgaApi = .immediate,
            3 => vgaApi = .buffered,
            else => {
                Terminal.println("trace({})", value);
            },
        }
    }

    pub extern fn setpix(x: u32, y: u32, col: u32) void {
        // Terminal.println("setpix({},{},{})", x, y, col);
        if (vgaApi == .immediate) {
            VGA.setPixelDirect(x, y, @truncate(u4, col));
        }
        VGA.setPixel(x, y, @truncate(u4, col));
    }

    pub extern fn getpix(x: u32, y: u32) u32 {
        // Terminal.println("getpix({},{})", x, y);
        return VGA.getPixel(x, y);
    }

    pub extern fn gettime() u32 {
        // systemTicks is in 0.1 sec steps, but we want ms
        const time = Timer.ticks;
        // Terminal.println("gettime() = {}", time);
        return time;
    }

    pub extern fn getkey() u32 {
        const keycode = if (Keyboard.getKey()) |key|
            key.scancode | switch (key.set) {
                .default => @as(u32, 0),
                .extended0 => @as(u32, 0x10000),
                .extended1 => @as(u32, 0x20000),
            }
        else
            @as(u32, 0);

        // Terminal.println("getkey() = 0x{X:0>5}", keycode);
        return keycode;
    }
};

const VgaApi = enum {
    buffered,
    immediate,
};
var vgaApi: VgaApi = .immediate;

pub const enable_assembler_tracing = false;

pub var currentAssemblerLine: ?usize = null;

pub fn debugCall(cpu: *Interrupts.CpuState) void {
    if (!enable_live_tracing)
        return;

    currentAssemblerLine = @intToPtr(*u32, cpu.eip).*;

    // Terminal.println("-----------------------------");
    // Terminal.println("Line: {}", currentAssemblerLine);
    // Terminal.println("CPU:\r\n{}", cpu);
    // Terminal.println("Registers:");
    // for (registers) |reg, i| {
    //     Terminal.println("r{} = {}", i, reg);
    // }

    // skip 4 bytes after interrupt. this is the assembler line number!
    cpu.eip += 4;
}

const developSource = @embedFile("../../gasm/concept.asm");

const Task = struct {
    entryPoint: extern fn () noreturn = undefined,
};

pub const TaskId = enum {
    splash,
    shell,
    codeEditor,
    spriteEditor,
    tilemapEditor,
    codeRunner,
};

extern fn editorNotImplementedYet() noreturn {
    Terminal.println("This editor is not implemented yet!");
    while (true) {
        // wait for interrupt
        asm volatile ("hlt");
    }
}

extern fn executeUsercode() noreturn {
    Terminal.println("Start assembling code...");

    var arena = std.heap.ArenaAllocator.init(Heap.allocator);

    var buffer = std.Buffer.init(&arena.allocator, "") catch unreachable;

    CodeEditor.saveTo(&buffer) catch |err| {
        arena.deinit();
        Terminal.println("Failed to save user code: {}", err);
        while (true) {
            // wait for interrupt
            asm volatile ("hlt");
        }
    };

    if (Assembler.assemble(&arena.allocator, buffer.toSliceConst(), VMM.getUserSpace(), null)) {
        arena.deinit();

        Terminal.println("Assembled code successfully!");
        // Terminal.println("Memory required: {} bytes!", fba.end_index);

        Terminal.println("Setup graphics...");

        // Load dawnbringers 16 color palette
        // see: https://lospec.com/palette-list/dawnbringer-16
        VGA.loadPalette(comptime [_]VGA.RGB{
            VGA.RGB.parse("#140c1c") catch unreachable, //  0 = black
            VGA.RGB.parse("#442434") catch unreachable, //  1 = dark purple-brown
            VGA.RGB.parse("#30346d") catch unreachable, //  2 = blue
            VGA.RGB.parse("#4e4a4e") catch unreachable, //  3 = gray
            VGA.RGB.parse("#854c30") catch unreachable, //  4 = brown
            VGA.RGB.parse("#346524") catch unreachable, //  5 = green
            VGA.RGB.parse("#d04648") catch unreachable, //  6 = salmon
            VGA.RGB.parse("#757161") catch unreachable, //  7 = khaki
            VGA.RGB.parse("#597dce") catch unreachable, //  8 = baby blue
            VGA.RGB.parse("#d27d2c") catch unreachable, //  9 = orange
            VGA.RGB.parse("#8595a1") catch unreachable, // 10 = light gray
            VGA.RGB.parse("#6daa2c") catch unreachable, // 11 = grass green
            VGA.RGB.parse("#d2aa99") catch unreachable, // 12 = skin
            VGA.RGB.parse("#6dc2ca") catch unreachable, // 13 = bright blue
            VGA.RGB.parse("#dad45e") catch unreachable, // 14 = yellow
            VGA.RGB.parse("#deeed6") catch unreachable, // 15 = white
        });

        Terminal.println("Start user code...");
        asm volatile ("jmp 0x40000000");
        unreachable;
    } else |err| {
        arena.deinit();
        buffer.deinit();
        Terminal.println("Failed to assemble user code: {}", err);
        while (true) {
            // wait for interrupt
            asm volatile ("hlt");
        }
    }
}

extern fn executeTilemapEditor() noreturn {
    var time: usize = 0;
    var color: VGA.Color = 1;
    while (true) : (time += 1) {
        if (Keyboard.getKey()) |key| {
            if (key.set == .default and key.scancode == 57) {
                // space
                if (@addWithOverflow(VGA.Color, color, 1, &color)) {
                    color = 1;
                }
            }
        }

        var y: usize = 0;
        while (y < VGA.height) : (y += 1) {
            var x: usize = 0;
            while (x < VGA.width) : (x += 1) {
                // c = @truncate(u4, (x + offset_x + dx) / 32 + (y + offset_y + dy) / 32);
                const c = if (y > ((Timer.ticks / 10) % 200)) color else 0;
                VGA.setPixel(x, y, c);
            }
        }

        VGA.swapBuffers();
    }
}

const TaskList = EnumArray(TaskId, Task);
const taskList = TaskList.initMap(([_]TaskList.KV{
    TaskList.KV{
        .key = .splash,
        .value = Task{
            .entryPoint = SplashScreen.run,
        },
    },
    TaskList.KV{
        .key = .shell,
        .value = Task{
            .entryPoint = editorNotImplementedYet,
        },
    },
    TaskList.KV{
        .key = .codeEditor,
        .value = Task{
            .entryPoint = CodeEditor.run,
        },
    },
    TaskList.KV{
        .key = .spriteEditor,
        .value = Task{
            .entryPoint = editorNotImplementedYet,
        },
    },
    TaskList.KV{
        .key = .tilemapEditor,
        .value = Task{
            .entryPoint = executeTilemapEditor,
        },
    },
    TaskList.KV{
        .key = .codeRunner,
        .value = Task{
            .entryPoint = executeUsercode,
        },
    },
}));

var userStack: [8192]u8 align(16) = undefined;

pub fn handleFKey(cpu: *Interrupts.CpuState, key: Keyboard.FKey) *Interrupts.CpuState {
    return switch (key) {
        .F1 => switchTask(.shell),
        .F2 => switchTask(.codeEditor),
        .F3 => switchTask(.spriteEditor),
        .F4 => switchTask(.tilemapEditor),
        .F5 => switchTask(.codeRunner),
        .F12 => blk: {
            if (Terminal.enable_serial) {
                Terminal.println("Disable serial... Press F12 to enable serial again!");
                Terminal.enable_serial = false;
            } else {
                Terminal.enable_serial = true;
                Terminal.println("Serial output enabled!");
            }
            break :blk cpu;
        },
        else => cpu,
    };
}

pub fn switchTask(task: TaskId) *Interrupts.CpuState {
    const Helper = struct {
        fn createTask(stack: []u8, id: TaskId) *Interrupts.CpuState {
            var newCpu = @ptrCast(*Interrupts.CpuState, stack.ptr + stack.len - @sizeOf(Interrupts.CpuState));
            newCpu.* = Interrupts.CpuState{
                .eax = 0,
                .ebx = 0,
                .ecx = 0,
                .edx = 0,
                .esi = 0,
                .edi = 0,
                .ebp = 0,

                .eip = @ptrToInt(taskList.at(id).entryPoint),
                .cs = 0x08,
                .eflags = 0x202,

                .interrupt = 0,
                .errorcode = 0,
                .esp = 0,
                .ss = 0,
            };
            return newCpu;
        }
    };

    var stack = userStack[0..];
    return Helper.createTask(stack, task);
}

extern const __start: u8;
extern const __end: u8;

pub fn main() anyerror!void {
    SerialPort.init(SerialPort.COM1, 9600, .none, .eight);

    Terminal.clear();

    // const flags = @ptrCast(*Multiboot.Structure.Flags, &multiboot.flags).*;
    const flags = @bitCast(Multiboot.Structure.Flags, multiboot.flags);

    Terminal.print("Multiboot Structure: {*}\r\n", multiboot);
    inline for (@typeInfo(Multiboot.Structure).Struct.fields) |fld| {
        if (comptime !std.mem.eql(u8, comptime fld.name, "flags")) {
            if (@field(flags, fld.name)) {
                Terminal.print("\t{}\t= {}\r\n", fld.name, @field(multiboot, fld.name));
            }
        }
    }

    // Init PMM

    // mark everything in the "memmap" as free
    if (multiboot.flags != 0) {
        var iter = multiboot.mmap.iterator();
        while (iter.next()) |entry| {
            if (entry.baseAddress + entry.length > 0xFFFFFFFF)
                continue; // out of range

            Terminal.println("mmap = {}", entry);

            var start = std.mem.alignForward(@intCast(usize, entry.baseAddress), 4096); // only allocate full pages
            var length = entry.length - (start - entry.baseAddress); // remove padded bytes
            while (start < entry.baseAddress + length) : (start += 4096) {
                PMM.mark(@intCast(usize, start), switch (entry.type) {
                    .available => PMM.Marker.free,
                    else => PMM.Marker.allocated,
                });
            }
        }
    }

    Terminal.println("total memory: {} pages, {Bi}", PMM.getFreePageCount(), PMM.getFreeMemory());

    // mark "ourself" used
    {
        var pos = @ptrToInt(&__start);
        std.debug.assert(std.mem.isAligned(pos, 4096));
        while (pos < @ptrToInt(&__end)) : (pos += 4096) {
            PMM.mark(pos, .allocated);
        }
    }

    // Mark MMIO area as allocated
    {
        var i: usize = 0x0000;
        while (i < 0x10000) : (i += 0x1000) {
            PMM.mark(i, .allocated);
        }
    }

    {
        Terminal.print("[ ] Initialize gdt...\r");
        GDT.init();
        Terminal.println("[X");
    }

    var pageDirectory = try VMM.init();

    // map ourself into memory
    {
        var pos = @ptrToInt(&__start);
        std.debug.assert(std.mem.isAligned(pos, 4096));
        while (pos < @ptrToInt(&__end)) : (pos += 4096) {
            try pageDirectory.mapPage(pos, pos, .readWrite);
        }
    }

    // map VGA memory
    {
        var i: usize = 0xA0000;
        while (i < 0xC0000) : (i += 0x1000) {
            try pageDirectory.mapPage(i, i, .readWrite);
        }
    }

    Terminal.print("[ ] Map user space memory...\r");
    try VMM.create_userspace(pageDirectory);
    Terminal.println("[X");

    Terminal.print("[ ] Map heap memory...\r");
    try VMM.create_heap(pageDirectory);
    Terminal.println("[X");

    Terminal.println("free memory: {} pages, {Bi}", PMM.getFreePageCount(), PMM.getFreeMemory());

    Terminal.print("[ ] Enable paging...\r");
    VMM.enable_paging();
    Terminal.println("[X");

    Terminal.print("[ ] Initialize heap memory...\r");
    Heap.init();
    Terminal.println("[X");

    {
        Terminal.print("[ ] Initialize idt...\r");
        Interrupts.init();
        Terminal.println("[X");

        Terminal.print("[ ] Enable IRQs...\r");
        Interrupts.disableAllIRQs();
        Interrupts.enableExternalInterrupts();
        Terminal.println("[X");
    }

    Terminal.print("[ ] Enable Keyboard...\r");
    Keyboard.init();
    Terminal.println("[X");

    Terminal.print("[ ] Enable Timer...\r");
    Timer.init();
    Terminal.println("[X");

    Terminal.print("[ ] Initialize CMOS...\r");
    CMOS.init();
    Terminal.println("[X");

    CMOS.printInfo();

    Terminal.print("[ ] Initialize FDC...\r");
    try FDC.init();
    Terminal.println("[X");

    {
        Terminal.println("    read sector 0...");
        var sector0: [512]u8 = [_]u8{0xFF} ** 512;
        try FDC.read(.A, 0, sector0[0..]);
        for (sector0) |b, i| {
            Terminal.print("{X:0>2} ", b);

            if ((i % 16) == 15) {
                Terminal.println("");
            }
        }
        Terminal.println("    write sector 0...");
        for (sector0) |*b, i| {
            b.* = @truncate(u8, i);
        }
        try FDC.write(.A, 0, sector0[0..]);
    }

    Terminal.print("[ ] Initialize PCI...\r");
    PCI.init();
    Terminal.println("[X");

    Terminal.print("Initialize text editor...\r\n");
    CodeEditor.init();
    try CodeEditor.load(developSource[0..]);

    Terminal.print("Press 'space' to start system...\r\n");
    while (true) {
        if (Keyboard.getKey()) |key| {
            if (key.char) |c|
                if (c == ' ')
                    break;
        }
    }

    Terminal.print("[ ] Initialize VGA...\r");
    // prevent the terminal to write data into the video memory
    Terminal.enable_video = false;
    VGA.init();
    Terminal.println("[X");

    Terminal.println("[x] Disable serial debugging for better performance...");
    Terminal.println("    Press F12 to re-enable serial debugging!");
    // Terminal.enable_serial = false;

    asm volatile ("int $0x45");
    unreachable;
}

fn kmain() noreturn {
    if (multibootMagic != 0x2BADB002) {
        @panic("System was not bootet with multiboot!");
    }

    main() catch |err| {
        Terminal.enable_serial = true;
        Terminal.setColors(.white, .red);
        Terminal.println("\r\n\r\nmain() returned {}!", err);
        if (@errorReturnTrace()) |trace| {
            for (trace.instruction_addresses) |addr, i| {
                if (i >= trace.index)
                    break;
                Terminal.println("Stack: {x: >8}", addr);
            }
        }
    };

    Terminal.enable_serial = true;
    Terminal.println("system haltet, shut down now!");
    while (true) {
        Interrupts.disableExternalInterrupts();
        asm volatile ("hlt");
    }
}

var kernelStack: [4096]u8 align(16) = undefined;

var multiboot: *Multiboot.Structure = undefined;
var multibootMagic: u32 = undefined;

export nakedcc fn _start() noreturn {
    // DO NOT INSERT CODE BEFORE HERE
    // WE MUST NOT MODIFY THE REGISTER CONTENTS
    // BEFORE SAVING THEM TO MEMORY
    multiboot = asm volatile (""
        : [_] "={ebx}" (-> *Multiboot.Structure)
    );
    multibootMagic = asm volatile (""
        : [_] "={eax}" (-> u32)
    );
    // FROM HERE ON WE ARE SAVE

    @newStackCall(kernelStack[0..], kmain);
}

const SerialOutStream = struct {
    const This = @This();
    fn print(_: This, comptime fmt: []const u8, args: ...) error{Never}!void {
        Terminal.print(fmt, args);
    }

    fn write(_: This, text: []const u8) error{Never}!void {
        Terminal.print("{}", text);
    }

    fn writeByte(_: This, byte: u8) error{Never}!void {
        Terminal.print("{c}", byte);
    }
};

const serial_out_stream = SerialOutStream{};

fn printLineFromFile(out_stream: var, line_info: std.debug.LineInfo) anyerror!void {
    Terminal.println("TODO print line from the file\n");
}

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    Terminal.enable_serial = true;
    Interrupts.disableExternalInterrupts();
    Terminal.setColors(.white, .red);
    Terminal.println("\r\n\r\nKERNEL PANIC: {}\r\n", msg);

    // Terminal.println("Registers:");
    // for (registers) |reg, i| {
    //     Terminal.println("r{} = {}", i, reg);
    // }

    const first_trace_addr = @returnAddress();

    // const dwarf_info: ?*std.debug.DwarfInfo = getSelfDebugInfo() catch |err| blk: {
    //     Terminal.println("unable to get debug info: {}\n", @errorName(err));
    //     break :blk null;
    // };
    var it = std.debug.StackIterator.init(first_trace_addr);
    while (it.next()) |return_address| {
        Terminal.println("Stack: {x}", return_address);
        // if (dwarf_info) |di| {
        //     std.debug.printSourceAtAddressDwarf(
        //         di,
        //         serial_out_stream,
        //         return_address,
        //         true, // tty color on
        //         printLineFromFile,
        //     ) catch |err| {
        //         Terminal.println("missed a stack frame: {}\n", @errorName(err));
        //         continue;
        //     };
        // }
    }

    haltForever();
}

fn haltForever() noreturn {
    while (true) {
        Interrupts.disableExternalInterrupts();
        asm volatile ("hlt");
    }
}

var kernel_panic_allocator_bytes: [4 * 1024 * 1024]u8 = undefined;
var kernel_panic_allocator_state = std.heap.FixedBufferAllocator.init(kernel_panic_allocator_bytes[0..]);
const kernel_panic_allocator = &kernel_panic_allocator_state.allocator;

extern var __debug_info_start: u8;
extern var __debug_info_end: u8;
extern var __debug_abbrev_start: u8;
extern var __debug_abbrev_end: u8;
extern var __debug_str_start: u8;
extern var __debug_str_end: u8;
extern var __debug_line_start: u8;
extern var __debug_line_end: u8;
extern var __debug_ranges_start: u8;
extern var __debug_ranges_end: u8;

fn dwarfSectionFromSymbolAbs(start: *u8, end: *u8) std.debug.DwarfInfo.Section {
    return std.debug.DwarfInfo.Section{
        .offset = 0,
        .size = @ptrToInt(end) - @ptrToInt(start),
    };
}

fn dwarfSectionFromSymbol(start: *u8, end: *u8) std.debug.DwarfInfo.Section {
    return std.debug.DwarfInfo.Section{
        .offset = @ptrToInt(start),
        .size = @ptrToInt(end) - @ptrToInt(start),
    };
}

fn getSelfDebugInfo() !*std.debug.DwarfInfo {
    const S = struct {
        var have_self_debug_info = false;
        var self_debug_info: std.debug.DwarfInfo = undefined;

        var in_stream_state = std.io.InStream(anyerror){ .readFn = readFn };
        var in_stream_pos: usize = 0;
        const in_stream = &in_stream_state;

        fn readFn(self: *std.io.InStream(anyerror), buffer: []u8) anyerror!usize {
            const ptr = @intToPtr([*]const u8, in_stream_pos);
            @memcpy(buffer.ptr, ptr, buffer.len);
            in_stream_pos += buffer.len;
            return buffer.len;
        }

        const SeekableStream = std.io.SeekableStream(anyerror, anyerror);
        var seekable_stream_state = SeekableStream{
            .seekToFn = seekToFn,
            .seekByFn = seekForwardFn,

            .getPosFn = getPosFn,
            .getEndPosFn = getEndPosFn,
        };
        const seekable_stream = &seekable_stream_state;

        fn seekToFn(self: *SeekableStream, pos: u64) anyerror!void {
            in_stream_pos = @intCast(usize, pos);
        }
        fn seekForwardFn(self: *SeekableStream, pos: i64) anyerror!void {
            in_stream_pos = @bitCast(usize, @bitCast(isize, in_stream_pos) +% @intCast(isize, pos));
        }
        fn getPosFn(self: *SeekableStream) anyerror!u64 {
            return in_stream_pos;
        }
        fn getEndPosFn(self: *SeekableStream) anyerror!u64 {
            return @ptrToInt(&__debug_ranges_end);
        }
    };
    if (S.have_self_debug_info)
        return &S.self_debug_info;

    S.self_debug_info = std.debug.DwarfInfo{
        .dwarf_seekable_stream = S.seekable_stream,
        .dwarf_in_stream = S.in_stream,
        .endian = builtin.Endian.Little,
        .debug_info = dwarfSectionFromSymbol(&__debug_info_start, &__debug_info_end),
        .debug_abbrev = dwarfSectionFromSymbolAbs(&__debug_abbrev_start, &__debug_abbrev_end),
        .debug_str = dwarfSectionFromSymbolAbs(&__debug_str_start, &__debug_str_end),
        .debug_line = dwarfSectionFromSymbol(&__debug_line_start, &__debug_line_end),
        .debug_ranges = dwarfSectionFromSymbolAbs(&__debug_ranges_start, &__debug_ranges_end),
        .abbrev_table_list = undefined,
        .compile_unit_list = undefined,
        .func_list = undefined,
    };
    try std.debug.openDwarfDebugInfo(&S.self_debug_info, kernel_panic_allocator);
    return &S.self_debug_info;
}
