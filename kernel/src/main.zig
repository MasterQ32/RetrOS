const std = @import("std");
const builtin = @import("builtin");

const Terminal = @import("text-terminal.zig");
const Multiboot = @import("multiboot.zig");
const VGA = @import("vga.zig");
const GDT = @import("gdt.zig");
const Interrupts = @import("interrupts.zig");
const Keyboard = @import("keyboard.zig");

const Assembler = @import("assembler.zig");

export var multibootHeader align(4) linksection(".multiboot") = Multiboot.Header.init();

var systemTicks: u64 = 0;

fn handleTimerIRQ(cpu: *Interrupts.CpuState) *Interrupts.CpuState {
    systemTicks += 1;

    return cpu;
}

pub fn main() anyerror!void {
    Terminal.clear();
    {
        Terminal.print("[ ] Initialize gdt...\r");
        GDT.init();
        Terminal.println("[X");
    }
    {
        Terminal.print("[ ] Initialize idt...\r");
        Interrupts.init();
        Terminal.println("[X");

        // Terminal.print("[ ] Fire Test Interrupt\r");
        // Interrupts.trigger_isr(45);
        // Terminal.println("[X");

        Interrupts.setIRQHandler(0, handleTimerIRQ);

        Terminal.print("[ ] Enable IRQs...\r");
        Interrupts.enableExternalInterrupts();
        Interrupts.enableAllIRQs();
        Terminal.println("[X");
    }
    {
        Terminal.print("[ ] Enable Keyboard...\r");
        Keyboard.init();
        Terminal.println("[X");
    }

    const flags = @ptrCast(*Multiboot.Structure.Flags, &multiboot.flags).*;

    Terminal.print("Multiboot Structure: {*}\r\n", multiboot);
    inline for (@typeInfo(Multiboot.Structure).Struct.fields) |fld| {
        if (comptime !std.mem.eql(u8, comptime fld.name, "flags")) {
            if (@field(flags, fld.name)) {
                Terminal.print("\t{}\t= {}\r\n", fld.name, @field(multiboot, fld.name));
            }
        }
    }

    Terminal.print("VGA init...\r\n");

    // prevent the terminal to write data into the video memory
    Terminal.enable_video = false;

    VGA.init();

    var rng_engine = std.rand.DefaultPrng.init(0);
    var rng = &rng_engine.random;

    var time: usize = 0;
    var color: u4 = 1;
    while (true) : (time += 1) {
        if (Keyboard.getKey()) |key| {
            if (key.set == .default and key.scancode == 57) {
                // space
                if (@addWithOverflow(u4, color, 1, &color)) {
                    color = 1;
                }
            }
        }

        var y: usize = 0;
        while (y < 480) : (y += 1) {
            var x: usize = 0;
            while (x < 640) : (x += 1) {
                // c = @truncate(u4, (x + offset_x + dx) / 32 + (y + offset_y + dy) / 32);
                const c = if (y > (systemTicks % 480)) color else 0;
                VGA.setPixel(x, y, c);
            }
        }

        VGA.swapBuffers();
    }
}

fn kmain() noreturn {
    if (multibootMagic != 0x2BADB002) {
        @panic("System was not bootet with multiboot!");
    }

    main() catch |err| {
        Terminal.setColors(.white, .red);
        Terminal.print("\r\n\r\nmain() returned {}!", err);
    };

    Terminal.println("system haltet, shut down now!");
    while (true) {
        asm volatile ("hlt");
    }
}

var kernelStack: [1 << 16]u8 align(16) = undefined;

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

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    Terminal.setColors(.white, .red);
    Terminal.print("\r\n\r\nKERNEL PANIC:\r\n{}", msg);
    while (true) {}
}
