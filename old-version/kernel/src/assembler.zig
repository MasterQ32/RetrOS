const std = @import("std");

const warn = if (std.builtin.os.tag == .freestanding)
    @import("text-terminal.zig").print
else
    std.debug.warn;

const Operand = union(enum) {
    direct: Direct,
    indirect: Indirect,

    fn print(this: Operand) void {
        switch (this) {
            .direct => |o| o.print(),
            .indirect => |o| o.print(),
        }
    }

    const Direct = union(enum) {
        register: u4,
        label: []const u8,
        immediate: u32,

        // fn print(this: Direct) void {
        //     switch (this) {
        //         .register => |r| std.debug.warn("r{}", r),
        //         .label => |r| std.debug.warn("{}", r),
        //         .immediate => |r| std.debug.warn("{}", r),
        //     }
        // }
    };

    const Indirect = struct {
        source: Direct,
        offset: ?i32,

        // fn print(this: Indirect) void {
        //     std.debug.warn("[");
        //     this.source.print();
        //     if (this.offset) |offset| {
        //         if (offset < 0) {
        //             std.debug.warn("{}", offset);
        //         } else {
        //             std.debug.warn("+{}", offset);
        //         }
        //     }
        //     std.debug.warn("]");
        // }
    };
};

const Instruction = struct {
    mnemonic: []const u8,
    operands: [3]Operand,
    operandCount: usize,

    fn new(mn: []const u8) Instruction {
        return Instruction{
            .mnemonic = mn,
            .operandCount = 0,
            .operands = undefined,
        };
    }

    fn addOperand(this: *Instruction, oper: Operand) !void {
        if (this.operandCount >= this.operands.len)
            return error.TooManyOperands;
        this.operands[this.operandCount] = oper;
        this.operandCount += 1;
    }
};

const Element = union(enum) {
    instruction: Instruction,
    label: []const u8,
    data8: u8,
    data16: u16,
    data32: u32,
    alignment: u32,
};

const Parser = struct {
    allocator: *std.mem.Allocator,
    source: []const u8,
    offset: usize,
    lineNumber: u32 = 0,

    constants: std.StringHashMap(Token),

    state: State = .default,

    fn init(allocator: *std.mem.Allocator, source: []const u8) Parser {
        return Parser{
            .allocator = allocator,
            .source = source,
            .offset = 0,
            .constants = std.StringHashMap(Token).init(allocator),
        };
    }

    fn deinit(this: *Parser) void {
        this.constants.deinit();
    }

    const TokenType = enum {
        hexnum, // 0x10
        decnum, // 10
        registerName, // r0 … r15
        label, // either 'bla:' or '.bla:'
        comma, // ,
        beginIndirection, // [
        endIndirection, // ]
        identifier, // [A-Za-z][A-Za-z0-9]+
        directiveOrLabel, // .foo
        lineBreak, // '\n'
        positiveOffset, // '+'
        negativeOffset, // '-'
        endOfText,
    };

    const Token = struct {
        type: TokenType,
        value: []const u8,
    };

    fn isWordCharacter(c: u8) bool {
        return switch (c) {
            '0'...'9' => true,
            'a'...'z' => true,
            'A'...'Z' => true,
            '_' => true,
            else => false,
        };
    }

    fn isDigit(c: u8) bool {
        return switch (c) {
            '0'...'9' => true,
            else => false,
        };
    }

    fn isHexDigit(c: u8) bool {
        return switch (c) {
            '0'...'9' => true,
            'a'...'f' => true,
            'A'...'F' => true,
            else => false,
        };
    }

    fn readToken(this: *Parser) !?Token {
        //     const token = this.readTokenNoDebug();
        //     std.debug.warn("token: {}\n", token);
        //     return token;
        // }

        // fn readTokenNoDebug(this: *Parser) !?Token {
        if (this.offset >= this.source.len)
            return null;

        // skip to next start of "meaningful"
        while (true) {
            const c = this.source[this.offset];
            if (c == '#') { // read line comment
                this.offset += 1;
                if (this.offset >= this.source.len)
                    return null;
                while (this.source[this.offset] != '\n') {
                    this.offset += 1;
                    if (this.offset >= this.source.len)
                        return null;
                }

                // don't eat the delimiting newline, otherwise trailing comments will fail
            } else if (c == ' ' or c == '\t') {
                this.offset += 1;
            } else {
                break;
            }
        }

        if (this.source[this.offset] == '\n') {
            this.lineNumber += 1;
        }

        switch (this.source[this.offset]) {
            // is single-char item
            '\n', ',', '[', ']', '-', '+' => {
                this.offset += 1;
                return Token{
                    .type = switch (this.source[this.offset - 1]) {
                        '\n' => .lineBreak,
                        ',' => .comma,
                        '[' => .beginIndirection,
                        ']' => .endIndirection,
                        '-' => .negativeOffset,
                        '+' => .positiveOffset,
                        else => unreachable,
                    },
                    .value = this.source[this.offset - 1 .. this.offset],
                };
            },

            // is either .label or .directiveOrLabel
            '.' => {
                const start = this.offset;
                var end = start + 1;
                if (end >= this.source.len)
                    return error.UnexpectedEndOfText;
                while (isWordCharacter(this.source[end])) {
                    end += 1;
                    if (end >= this.source.len)
                        return error.UnexpectedEndOfText;
                }
                this.offset = end;
                if (this.source[end] == ':') {
                    this.offset += 1;
                    return Token{
                        .type = .label,
                        .value = this.source[start..end],
                    };
                } else {
                    return Token{
                        .type = .directiveOrLabel,
                        .value = this.source[start..end],
                    };
                }
            },

            // identifier:
            'A'...'Z', 'a'...'z', '_' => {
                const start = this.offset;
                var end = start + 1;
                if (end >= this.source.len)
                    return error.UnexpectedEndOfText;
                while (isWordCharacter(this.source[end])) {
                    end += 1;
                    if (end >= this.source.len)
                        return error.UnexpectedEndOfText;
                }
                this.offset = end;

                if (this.source[end] == ':') {
                    this.offset += 1;
                    return Token{
                        .type = .label,
                        .value = this.source[start..end],
                    };
                } else {
                    const text = this.source[start..end];

                    comptime var i = 0;
                    inline while (i < 16) : (i += 1) {
                        comptime var registerName: [3]u8 = "r??".*;
                        comptime var len = std.fmt.formatIntBuf(registerName[1..], @as(usize, i), 10, false, std.fmt.FormatOptions{});
                        // @compileLog(i, registerName[0 .. 1 + len]);
                        if (std.mem.eql(u8, text, registerName[0 .. 1 + len])) {
                            return Token{
                                .type = .registerName,
                                .value = text,
                            };
                        }
                    }

                    if (this.constants.get(text)) |kv| {
                        // return stored token from .def
                        return kv;
                    }

                    return Token{
                        .type = .identifier,
                        .value = text,
                    };
                }
            },

            // numbers:
            '0'...'9' => {
                const start = this.offset;
                var end = start + 1;
                if (end >= this.source.len)
                    return error.UnexpectedEndOfText;
                while (isHexDigit(this.source[end]) or this.source[end] == 'x') {
                    end += 1;
                    if (end >= this.source.len)
                        return error.UnexpectedEndOfText;
                }
                this.offset = end;

                const text = this.source[start..end];

                if (text.len >= 2 and text[0] == '0' and text[1] == 'x') {
                    if (text.len == 2)
                        return error.InvalidHexLiteral;

                    return Token{
                        .type = .hexnum,
                        .value = this.source[start..end],
                    };
                }
                return Token{
                    .type = .decnum,
                    .value = this.source[start..end],
                };
            },
            else => return error.UnexpectedCharacter,
        }

        return null;
    }

    fn readExpectedToken(this: *Parser, comptime _type: TokenType) ![]const u8 {
        const token = (try this.readToken()) orelse return error.UnexpectedEndOfText;
        if (token.type != _type)
            return error.UnexpectedToken;
        return token.value;
    }

    fn readAnyExpectedToken(this: *Parser, allowedTypes: []const TokenType) !Token {
        const token = (try this.readToken()) orelse return error.UnexpectedEndOfText;
        for (allowedTypes) |val| {
            if (token.type == val)
                return token;
        }
        return error.UnexpectedToken;
    }

    fn convertTokenToNumber(token: Token) !u32 {
        return switch (token.type) {
            .hexnum => try std.fmt.parseInt(u32, token.value[2..], 16),
            .decnum => try std.fmt.parseInt(u32, token.value, 10),
            else => return error.UnexpectedToken,
        };
    }

    fn convertTokenToDirectOperand(token: Token) !Operand.Direct {
        return switch (token.type) {
            .registerName => Operand.Direct{
                .register = try std.fmt.parseInt(u4, token.value[1..], 10),
            },
            .identifier, .directiveOrLabel => Operand.Direct{
                .label = token.value,
            },
            .hexnum, .decnum => Operand.Direct{
                .immediate = try convertTokenToNumber(token),
            },
            else => return error.UnexpectedToken,
        };
    }

    fn readNumberToken(this: *Parser) !u32 {
        return try convertTokenToNumber(try this.readAnyExpectedToken(([_]TokenType{ .decnum, .hexnum })[0..]));
    }

    const TokenizeError = error{
        UnexpectedEndOfText,
        InvalidHexLiteral,
        UnexpectedCharacter,
        UnexpectedToken,
        OutOfMemory,
        Overflow,
        InvalidCharacter,
        UnknownDirective,
        TooManyOperands,
        NotImplementedYet,
    };
    fn readNext(this: *Parser) TokenizeError!?Element {
        // loop until we return
        while (true) {
            var token = (try this.readToken()) orelse return null;

            if (token.type == .lineBreak) {
                // line breaks will stop any special processing from directives
                this.state = .default;
                continue;
            }

            switch (this.state) {
                .default => {
                    switch (token.type) {
                        .directiveOrLabel => {
                            if (std.mem.eql(u8, token.value, ".def")) {
                                const name = try this.readExpectedToken(.identifier);
                                _ = try this.readExpectedToken(.comma);
                                const value = (try this.readToken()) orelse return error.UnexpectedEndOfText;

                                switch (value.type) {
                                    .identifier, .hexnum, .decnum, .registerName => {
                                        _ = try this.constants.put(name, value);
                                    },
                                    else => return error.UnexpectedToken,
                                }
                            } else if (std.mem.eql(u8, token.value, ".undef")) {
                                const name = try this.readExpectedToken(.identifier);

                                _ = this.constants.remove(name);
                            } else if (std.mem.eql(u8, token.value, ".d8")) {
                                this.state = .readsD8;
                            } else if (std.mem.eql(u8, token.value, ".d16")) {
                                this.state = .readsD16;
                            } else if (std.mem.eql(u8, token.value, ".d32") or std.mem.eql(u8, token.value, ".dw")) {
                                this.state = .readsD32;
                            } else if (std.mem.eql(u8, token.value, ".align")) {
                                const al = try this.readNumberToken();
                                return @as(?Element, Element{
                                    .alignment = al,
                                });
                            } else {
                                return error.UnknownDirective;
                            }
                        },
                        .label => {
                            return Element{
                                .label = token.value,
                            };
                        },

                        // is a mnemonic/instruction
                        .identifier => {
                            var instruction = Instruction.new(token.value);

                            // read operands
                            var readDelimiterNext = false;
                            var isFirst = true;
                            while (true) {
                                const subtok = (try this.readToken()) orelse return error.UnexpectedEndOfText;

                                if (isFirst and subtok.type == .lineBreak)
                                    break;
                                isFirst = false;

                                if (readDelimiterNext) {
                                    // is either comma for another operand or lineBreak for "end of operands"
                                    switch (subtok.type) {
                                        .lineBreak => break,
                                        .comma => {},
                                        else => return error.UnexpectedToken,
                                    }
                                    readDelimiterNext = false;
                                } else {
                                    // is an operand value
                                    switch (subtok.type) {
                                        .identifier, .hexnum, .decnum, .directiveOrLabel, .registerName => {
                                            try instruction.addOperand(Operand{
                                                .direct = try convertTokenToDirectOperand(subtok),
                                            });
                                        },
                                        .beginIndirection => {
                                            const directOperand = try convertTokenToDirectOperand((try this.readToken()) orelse return error.UnexpectedEndOfText);

                                            const something = try this.readAnyExpectedToken(([_]TokenType{ .endIndirection, .positiveOffset, .negativeOffset })[0..]);
                                            const result = switch (something.type) {
                                                .endIndirection => Operand.Indirect{
                                                    .source = directOperand,
                                                    .offset = null,
                                                },
                                                .positiveOffset => blk: {
                                                    const num = try this.readNumberToken();
                                                    _ = try this.readExpectedToken(.endIndirection);
                                                    break :blk Operand.Indirect{
                                                        .source = directOperand,
                                                        .offset = @intCast(i32, num),
                                                    };
                                                },
                                                .negativeOffset => blk: {
                                                    const num = try this.readNumberToken();
                                                    _ = try this.readExpectedToken(.endIndirection);
                                                    break :blk Operand.Indirect{
                                                        .source = directOperand,
                                                        .offset = -@intCast(i32, num),
                                                    };
                                                },
                                                else => return error.UnexpectedToken,
                                            };

                                            try instruction.addOperand(Operand{
                                                .indirect = result,
                                            });
                                        },
                                        else => return error.UnexpectedToken,
                                    }
                                    readDelimiterNext = true;
                                }
                            }
                            return Element{ .instruction = instruction };
                        },

                        else => return error.UnexpectedToken,
                    }
                },
                .readsD8, .readsD16, .readsD32 => {
                    switch (token.type) {
                        .decnum, .hexnum => {
                            const num = try convertTokenToNumber(token);
                            return switch (this.state) {
                                .readsD8 => Element{
                                    .data8 = @intCast(u8, num),
                                },
                                .readsD16 => Element{
                                    .data16 = @intCast(u16, num),
                                },
                                .readsD32 => Element{
                                    .data32 = num,
                                },

                                else => unreachable,
                            };
                        },
                        .identifier => {
                            // TODO: Support definitions and labels here
                            return error.NotImplementedYet;
                        },
                        .comma => {},
                        else => return error.UnexpectedToken,
                    }
                },
            }
        }
    }

    const State = enum {
        default,
        readsD8,
        readsD16,
        readsD32,
    };
};

fn getRegisterAddress(register: u4) u32 {
    const root = @import("root");
    if (@hasDecl(root, "getRegisterAddress")) {
        return root.getRegisterAddress(register);
    } else {
        // label addresses are hardcoded on page 0, address 0x00 … 0x40
        return 4 * u32(register);
    }
}

fn convertOperandToArg(comptime T: type, operand: Operand, labels: Labels) error{InvalidOperand}!T {
    switch (operand) {
        .direct => |opdir| switch (opdir) {
            .register => |reg| return T{
                .indirection = Indirection{
                    .address = ImmediateOrLabel.initImm(getRegisterAddress(reg)),
                    .offset = 0,
                },
            },
            .label => |lbl| if (comptime T == InstrInput) {
                return T{
                    .immediate = ImmediateOrLabel.initLbl(labels.get(lbl)),
                };
            } else {
                return error.InvalidOperand;
            },
            .immediate => |imm| if (comptime T == InstrInput) {
                return T{
                    .immediate = ImmediateOrLabel.initImm(imm),
                };
            } else {
                return error.InvalidOperand;
            },
        },
        .indirect => |indirect| {
            switch (indirect.source) {
                .register => |reg| return T{
                    .doubleIndirection = Indirection{
                        .address = ImmediateOrLabel.initImm(getRegisterAddress(reg)),
                        .offset = indirect.offset orelse 0,
                    },
                },
                .label => |lbl| return T{
                    .indirection = Indirection{
                        .address = ImmediateOrLabel.initLbl(labels.get(lbl)),
                        .offset = indirect.offset orelse 0,
                    },
                },
                .immediate => |imm| return T{
                    .indirection = Indirection{
                        .address = ImmediateOrLabel.initImm(imm),
                        .offset = indirect.offset orelse 0,
                    },
                },
            }
        },
    }
}

const Labels = struct {
    local: std.StringHashMap(u32),
    global: std.StringHashMap(u32),

    fn get(this: Labels, name: []const u8) LabelRef {
        var ref = if (name[0] == '.') this.local.getEntry(name) else this.global.getEntry(name);
        if (ref) |lbl| {
            return LabelRef{
                .label = lbl.key,
                .offset = lbl.value,
            };
        } else {
            return LabelRef{
                .label = name,
                .offset = null,
            };
        }
    }
};

pub fn assemble(allocator: *std.mem.Allocator, source: []const u8, target: []u8, offset: ?u32) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(&arena.allocator, source);
    defer parser.deinit();

    var labels = Labels{
        .local = std.StringHashMap(u32).init(&arena.allocator),
        .global = std.StringHashMap(u32).init(&arena.allocator),
    };
    defer labels.local.deinit();
    defer labels.global.deinit();

    var writer = Writer.init(allocator, target);
    writer.deinit();

    // used for offsetting labels to "link" the code to the
    // right position
    const absoffset = offset orelse @intCast(u32, @ptrToInt(target.ptr));

    // std.debug.warn("offset = {} ({})\n", offset, absoffset);

    var i: usize = 0;

    warn("start parsing...\r\n", .{});

    while (try parser.readNext()) |label_or_instruction| {
        i += 1;

        switch (label_or_instruction) {
            .label => |lbl| {
                // std.debug.warn("{}: # 0x{X:0>8}\n", lbl, writer.offset);
                if (lbl[0] == '.') {
                    // is local
                    _ = try labels.local.put(lbl, absoffset + writer.offset);
                } else {
                    // we need to patch all previous code here as
                    // we will lose all local label references in this step.
                    try writer.applyPatches(labels, .onlyLocals);

                    // erase all local labels as soon as we encounter a global label
                    labels.local.clearAndFree();
                    _ = try labels.global.put(lbl, absoffset + writer.offset);
                }
            },
            .instruction => |instr| {

                // insert debug tracers
                // CD30              int 0x30
                // enable this for line callback :)
                if (@hasDecl(@import("root"), "enable_assembler_tracing")) {
                    if (@import("root").enable_assembler_tracing) {
                        try writer.write(@as(u8, 0xCD));
                        try writer.write(@as(u8, 0x30));
                        try writer.write(parser.lineNumber);
                    }
                }

                // std.debug.warn("\t{}", instr.mnemonic);
                // var i: usize = 0;
                // while (i < instr.operandCount) : (i += 1) {
                //     if (i > 0) {
                //         std.debug.warn(", ");
                //     } else {
                //         std.debug.warn(" ");
                //     }
                //     instr.operands[i].print();
                // }
                // std.debug.warn("\n");
                var foundAny = false;
                inline for (@typeInfo(InstructionCore).Struct.decls) |executor| {
                    comptime std.debug.assert(executor.data == .Fn);
                    if (std.mem.eql(u8, executor.name, instr.mnemonic)) {
                        const FunType = @typeInfo(executor.data.Fn.fn_type).Fn;

                        if (FunType.args.len != instr.operandCount + 1) {
                            // ("operand count mismatch for {}. Expected {}, got {}!\n", instr.mnemonic, FunType.args.len - 1, instr.operandCount);
                            return error.OperandMismatch;
                        }

                        inline for (FunType.args) |arg| {
                            comptime std.debug.assert(arg.arg_type != null);
                        }

                        switch (FunType.args.len) {
                            1 => {
                                try @field(InstructionCore, executor.name)(&writer);
                            },
                            2 => {
                                var arg0 = try convertOperandToArg(FunType.args[1].arg_type.?, instr.operands[0], labels);
                                try @field(InstructionCore, executor.name)(&writer, arg0);
                            },
                            3 => {
                                var arg0 = try convertOperandToArg(FunType.args[1].arg_type.?, instr.operands[0], labels);
                                var arg1 = try convertOperandToArg(FunType.args[2].arg_type.?, instr.operands[1], labels);
                                try @field(InstructionCore, executor.name)(&writer, arg0, arg1);
                            },
                            4 => {
                                // warn("assemble {}\r\n", executor.name);
                                var arg0 = try convertOperandToArg(FunType.args[1].arg_type.?, instr.operands[0], labels);
                                var arg1 = try convertOperandToArg(FunType.args[2].arg_type.?, instr.operands[1], labels);
                                var arg2 = try convertOperandToArg(FunType.args[3].arg_type.?, instr.operands[2], labels);
                                try @field(InstructionCore, executor.name)(&writer, arg0, arg1, arg2);
                            },

                            else => @panic("unsupported operand count!"),
                        }

                        // std.debug.warn("found instruction: {}\n", instr.mnemonic);
                        foundAny = true;
                        break;
                    }
                }

                if (!foundAny) {
                    // std.debug.warn("unknown instruction: {}\n", instr.mnemonic);
                    return error.UnknownMnemonic;
                }
            },
            .data8 => |data| {
                // std.debug.warn(".d8 0x{X:0>2}\n", data);
                try writer.write(data);
            },
            .data16 => |data| {
                // std.debug.warn(".d16 0x{X:0>4}\n", data);
                try writer.write(data);
            },
            .data32 => |data| {
                // std.debug.warn(".d32 0x{X:0>8}\n", data);
                try writer.write(data);
            },
            .alignment => |al| {
                // std.debug.warn(".align {}\n", al);
                std.debug.assert((al & (al - 1)) == 0);
                writer.offset = (writer.offset + al - 1) & ~(al - 1);
            },
        }
    }

    try InstructionCore.exit(&writer);

    // debug output:
    // {
    //     std.debug.warn("Labels:\n");
    //     var iter = labels.global.iterator();
    //     while (iter.next()) |lbl| {
    //         std.debug.warn("\t{}\n", lbl);
    //     }
    // }
    // {
    //     std.debug.warn("Constants:\n");
    //     var iter = parser.constants.iterator();
    //     while (iter.next()) |lbl| {
    //         std.debug.warn("\t{}\n", lbl);
    //     }
    // }
    // {
    //     std.debug.warn("Global Patches:\n");
    //     var iter = writer.globalPatchlist.iterator();
    //     while (iter.next()) |lbl| {
    //         std.debug.warn("\t{}\n", lbl);
    //     }
    // }

    try writer.applyPatches(labels, .all);
}

/// A reference to a named label.
/// May contain the offset of the label for faster assembly.
const LabelRef = struct {
    label: []const u8,
    offset: ?u32,
};

/// A literal value that is noted by either a label reference or an immediate (written) number.
const ImmediateOrLabel = union(enum) {
    immediate: u32,
    label: LabelRef,

    fn initImm(val: u32) ImmediateOrLabel {
        return ImmediateOrLabel{
            .immediate = val,
        };
    }

    fn initLbl(val: LabelRef) ImmediateOrLabel {
        return ImmediateOrLabel{
            .label = val,
        };
    }

    pub fn format(value: ImmediateOrLabel, comptime fmt: []const u8, options: std.fmt.FormatOptions, context: anytype, comptime Errors: type, output: fn (@typeOf(context), []const u8) Errors!void) Errors!void {
        switch (value) {
            .immediate => |imm| try std.fmt.format(context, Errors, output, "0x{X:0>8}", imm),
            .label => |ref| {
                if (ref.offset) |off| {
                    try std.fmt.format(context, Errors, output, "0x{X:0>8}", off);
                } else {
                    try std.fmt.format(context, Errors, output, "{}", ref.label);
                }
            },
        }
    }
};

const WriterError = error{
    NotEnoughSpace,
    OutOfMemory,
};

/// simple wrapper around a slice that allows
/// sequential writing to that slice
const Writer = struct {
    target: []u8,
    offset: u32,

    localPatchlist: std.ArrayList(Patch),
    globalPatchlist: std.ArrayList(Patch),

    const PatchBatch = enum {
        all,
        onlyLocals,
    };

    /// a patch that will be applied later.
    /// Patches are required when labels are referenced but the offset of
    /// the label is not yet known.
    const Patch = struct {
        /// Offset in the `target` field of the `Writer` struct.
        offset_to_binary: u32,

        /// Required when the label is referenced in an indirectoin via `[label+offset]`.
        offset_to_value: i32,

        /// The name of the label.
        label: []const u8,
    };

    fn init(allocator: *std.mem.Allocator, target: []u8) Writer {
        return Writer{
            .target = target,
            .offset = 0,
            .localPatchlist = std.ArrayList(Patch).init(allocator),
            .globalPatchlist = std.ArrayList(Patch).init(allocator),
        };
    }

    fn deinit(this: Writer) void {
        this.localPatchlist.deinit();
        this.globalPatchlist.deinit();
    }

    fn applyPatchesTo(this: *Writer, labels: Labels, patchlist: *std.ArrayList(Patch)) !void {

        // on deinit, we will flush our patchlist and apply all patches:
        for (patchlist.items) |patch| {
            const lbl = labels.get(patch.label);
            // std.debug.warn("Patching {} to {}\n", patch, lbl);
            if (lbl.offset) |local_offset| {
                const off = local_offset + @bitCast(u32, patch.offset_to_value);
                std.mem.copy(u8, this.target[patch.offset_to_binary .. patch.offset_to_binary + 4], std.mem.asBytes(&off));
            } else {
                return error.UnknownLabel;
            }
        }

        patchlist.shrink(0);
    }

    fn applyPatches(this: *Writer, labels: Labels, batchMode: PatchBatch) !void {
        if (batchMode == .all) {
            try this.applyPatchesTo(labels, &this.globalPatchlist);
        }
        try this.applyPatchesTo(labels, &this.localPatchlist);
    }

    fn ensureSpace(this: *Writer, size: usize) WriterError!void {
        if (this.offset + size > this.target.len)
            return error.NotEnoughSpace;
    }

    /// emits `count` undefined bytes to the stream.
    /// these must be patched by hand!
    fn emit(this: *Writer, count: u32) WriterError!usize {
        try this.ensureSpace(count);
        std.mem.set(u8, this.target[this.offset .. this.offset + count], 0x90);

        const off = this.offset;
        this.offset += count;
        return @as(usize, off);
    }

    /// writes a value.
    /// if the value is a LabelRef and the ref is not valid yet, it will
    /// be added to the patchlist.
    fn write(this: *Writer, value: anytype) WriterError!void {
        try this.writeWithOffset(value, 0);
    }

    /// writes a value with a certain offset added to it.
    /// if the value is a LabelRef and the ref is not valid yet, it will
    /// be added to the patchlist.
    fn writeWithOffset(this: *Writer, value: anytype, offset: i32) WriterError!void {
        const T = @TypeOf(value);
        switch (T) {
            u8, u16, u32, u64, i8, i16, i32, i64 => {
                var val = value + @intCast(T, offset);
                try this.ensureSpace(@sizeOf(T));
                std.mem.copy(u8, this.target[this.offset .. this.offset + @sizeOf(T)], std.mem.asBytes(&val));
                this.offset += @sizeOf(T);
            },
            LabelRef => {
                try this.ensureSpace(4);
                if (value.offset) |local_offset| {
                    //  this assumes twos complement
                    const off = local_offset + @bitCast(u32, offset);
                    std.mem.copy(u8, this.target[this.offset .. this.offset + 4], std.mem.asBytes(&off));
                } else {
                    const patch = Patch{
                        .label = value.label,
                        .offset_to_binary = this.offset,
                        .offset_to_value = offset,
                    };
                    if (value.label[0] == '.') {
                        try this.localPatchlist.append(patch);
                    } else {
                        try this.globalPatchlist.append(patch);
                    }
                }
                this.offset += 4;
            },
            ImmediateOrLabel => switch (value) {
                .immediate => |v| try this.writeWithOffset(v, offset),
                .label => |v| try this.writeWithOffset(v, offset),
            },
            else => @compileError(@typeName(@TypeOf(value)) ++ " is not supported by writer!"),
        }
    }
};

/// First or second level indirection. second level indirection is required for
/// fake registers as they are implemented by indirection as well.
const Indirection = struct {
    address: ImmediateOrLabel,
    offset: i32,
};

/// An operand to an instruction that may be modified by the instruction.
/// Must must either be a register name or a "regular" indirection.
const InstrOutput = union(enum) {
    indirection: Indirection,
    doubleIndirection: Indirection,

    pub fn format(value: InstrOutput, comptime fmt: []const u8, options: std.fmt.FormatOptions, context: anytype, comptime Errors: type, output: fn (@typeOf(context), []const u8) Errors!void) Errors!void {
        switch (value) {
            .indirection => |ind| if (ind.offset == 0)
                try std.fmt.format(context, Errors, output, "*[{}]", ind.address)
            else
                try std.fmt.format(context, Errors, output, "*[{}+{}]", ind.address, ind.offset),
            .doubleIndirection => |dind| if (dind.offset == 0)
                try std.fmt.format(context, Errors, output, "*[[{}]]", dind.address)
            else
                try std.fmt.format(context, Errors, output, "*[[{}]+{}]", dind.address, dind.offset),
        }
    }

    /// Loads the operands value into EAX.
    /// Does not modify anything except EAX.
    pub fn loadToEAX(this: InstrOutput, writer: *Writer) !void {
        switch (this) {
            .indirection => |ind| {
                // A144332211        mov eax,[0x11223344]
                try writer.write(@as(u8, 0xA1));
                try writer.writeWithOffset(ind.address, ind.offset);
            },
            // actually only required when someone does `[reg]`
            .doubleIndirection => |ind| {
                // A144332211        mov eax,[0x11223344]
                try writer.write(@as(u8, 0xA1));
                try writer.write(ind.address);

                if (ind.offset != 0) {
                    // 8B8044332211      mov eax,[eax+0x11223344]
                    try writer.write(@as(u8, 0x8B));
                    try writer.write(@as(u8, 0x80));
                    try writer.write(ind.offset);
                } else {
                    // 8B00              mov eax,[eax]
                    try writer.write(@as(u8, 0x8B));
                    try writer.write(@as(u8, 0x00));
                }
            },
        }
    }

    /// Saves EAX into the operands location. Clobbers EBX
    pub fn saveFromEAX(this: InstrOutput, writer: *Writer) !void {
        switch (this) {
            .indirection => |ind| {
                // A344332211        mov [0x11223344],eax
                try writer.write(@as(u8, 0xA3));
                try writer.writeWithOffset(ind.address, ind.offset);
            },
            // actually only required when someone does `[reg]`
            .doubleIndirection => |ind| {
                // 8B 1D 44332211      mov ebx,[dword 0x11223344]
                try writer.write(@as(u8, 0x8B));
                try writer.write(@as(u8, 0x1D));
                try writer.write(ind.address);

                if (ind.offset != 0) {
                    // 898344332211      mov [ebx+0x11223344],eax
                    try writer.write(@as(u8, 0x89));
                    try writer.write(@as(u8, 0x83));
                    try writer.write(ind.offset);
                } else {
                    // 8903              mov [ebx],eax
                    try writer.write(@as(u8, 0x89));
                    try writer.write(@as(u8, 0x03));
                }
            },
        }
    }
};

/// An operand to an instruction that is only read by the instruction.
const InstrInput = union(enum) {
    immediate: ImmediateOrLabel,
    indirection: Indirection,
    doubleIndirection: Indirection,

    pub fn format(value: InstrInput, comptime fmt: []const u8, options: std.fmt.FormatOptions, context: anytype, comptime Errors: type, output: fn (@typeOf(context), []const u8) Errors!void) Errors!void {
        switch (value) {
            .immediate => |imm| try std.fmt.format(context, Errors, output, "{}", imm),
            .indirection => |ind| if (ind.offset == 0)
                try std.fmt.format(context, Errors, output, "[{}]", ind.address)
            else
                try std.fmt.format(context, Errors, output, "[{}+{}]", ind.address, ind.offset),
            .doubleIndirection => |dind| if (dind.offset == 0)
                try std.fmt.format(context, Errors, output, "[[{}]]", dind.address)
            else
                try std.fmt.format(context, Errors, output, "[[{}]+{}]", dind.address, dind.offset),
        }
    }

    /// Loads the operands value into EAX.
    /// Does not modify anything except EAX.
    pub fn loadToEAX(this: InstrInput, writer: *Writer) !void {
        switch (this) {
            .immediate => |imm| {
                // B844332211        mov eax,0x11223344
                try writer.write(@as(u8, 0xB8));
                try writer.write(imm);
            },
            .indirection => |ind| {
                // A144332211        mov eax,[0x11223344]
                try writer.write(@as(u8, 0xA1));
                try writer.writeWithOffset(ind.address, ind.offset);
            },
            // actually only required when someone does `[reg]`
            .doubleIndirection => |ind| {
                // A144332211        mov eax,[0x11223344]
                try writer.write(@as(u8, 0xA1));
                try writer.write(ind.address);

                if (ind.offset != 0) {
                    // 8B8044332211      mov eax,[eax+0x11223344]
                    try writer.write(@as(u8, 0x8B));
                    try writer.write(@as(u8, 0x80));
                    try writer.write(ind.offset);
                } else {
                    // 8B00              mov eax,[eax]
                    try writer.write(@as(u8, 0x8B));
                    try writer.write(@as(u8, 0x00));
                }
            },
        }
    }
};

const API = @import("root").assembler_api;

fn emitConditionalJump(writer: *Writer, dst: InstrInput, jumpCode: u8) WriterError!void {

    // make inverse jump mechanic:
    // jump over the unconditional jump as
    // conditional jumps are always short jumps and cannot
    // use indirection
    try writer.write(jumpCode); // emit NOP for debugging reference
    const offset = try writer.emit(1);

    const start = writer.offset;
    try InstructionCore.jmp(writer, dst);
    const end = writer.offset;

    writer.target[offset] = @intCast(u8, end - start);
}

fn emitMovEbxToEax(writer: *Writer) WriterError!void {

    // 89C3              mov ebx,eax
    try writer.write(@as(u8, 0x89));
    try writer.write(@as(u8, 0xC3));
}

/// Contains emitter functions for every possible instructions.
const InstructionCore = struct {
    /// moves src to dst.
    fn mov(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);
        try dst.saveFromEAX(writer);
    }

    /// adds src to dst
    fn add(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // 01D8              add eax,ebx
        try writer.write(@as(u8, 0x01));
        try writer.write(@as(u8, 0xD8));

        try dst.saveFromEAX(writer);
    }

    // subtracts src from dst
    fn sub(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // 29D8              sub eax,ebx
        try writer.write(@as(u8, 0x29));
        try writer.write(@as(u8, 0xD8));

        try dst.saveFromEAX(writer);
    }
    fn cmp(writer: *Writer, lhs: InstrInput, rhs: InstrInput) WriterError!void {
        try rhs.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try lhs.loadToEAX(writer);

        // 39D8              cmp eax,ebx
        try writer.write(@as(u8, 0x39));
        try writer.write(@as(u8, 0xD8));
    }
    fn jmp(writer: *Writer, pos: InstrInput) WriterError!void {
        switch (pos) {
            .immediate => |imm| {
                // B844332211        mov eax,0x11223344
                try writer.write(@as(u8, 0xB8));
                try writer.write(imm);

                // FFE0              jmp eax
                try writer.write(@as(u8, 0xFF));
                try writer.write(@as(u8, 0xE0));
            },
            .indirection => |ind| {
                // FF2544332211      jmp [dword 0x11223344]
                try writer.write(@as(u8, 0xFF));
                try writer.write(@as(u8, 0x25));
                try writer.writeWithOffset(ind.address, ind.offset);
            },
            // actually only required when someone does `[reg]`
            .doubleIndirection => |ind| {
                // A144332211        mov eax,[0x11223344]
                try writer.write(@as(u8, 0xA1));
                try writer.write(ind.address);

                if (ind.offset != 0) {
                    // FFA044332211      jmp [eax+0x11223344]
                    try writer.write(@as(u8, 0xFF));
                    try writer.write(@as(u8, 0xA0));
                    try writer.write(ind.offset);
                } else {
                    // FF20              jmp [eax]
                    try writer.write(@as(u8, 0xFF));
                    try writer.write(@as(u8, 0x20));
                }
            },
        }
    }
    fn jnz(writer: *Writer, pos: InstrInput) WriterError!void {
        // 7404              jz +4
        try emitConditionalJump(writer, pos, 0x74);
    }
    fn jiz(writer: *Writer, pos: InstrInput) WriterError!void {
        // 7504              jnz +4
        try emitConditionalJump(writer, pos, 0x75);
    }
    fn jlz(writer: *Writer, pos: InstrInput) WriterError!void {
        // 7D06              jnl 0x4d # jump not less
        try emitConditionalJump(writer, pos, 0x7D);
    }
    fn jgz(writer: *Writer, pos: InstrInput) WriterError!void {
        // 7E04              jng 0x4d # jump not greater
        try emitConditionalJump(writer, pos, 0x7E);
    }
    fn mul(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // F7E3              mul ebx
        // clobbers EDX with higher part
        try writer.write(@as(u8, 0xF7));
        try writer.write(@as(u8, 0xE3));

        try dst.saveFromEAX(writer);
    }
    fn div(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // F7F3              div ebx
        // clobbers EDX with remainder part
        try writer.write(@as(u8, 0xF7));
        try writer.write(@as(u8, 0xF3));

        try dst.saveFromEAX(writer);
    }
    fn mod(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // F7F3              div ebx
        // clobbers EDX with remainder part
        try writer.write(@as(u8, 0xF7));
        try writer.write(@as(u8, 0xF3));

        // 89D0              mov eax,edx
        try writer.write(@as(u8, 0x89));
        try writer.write(@as(u8, 0xD0));

        try dst.saveFromEAX(writer);
    }
    fn gettime(writer: *Writer, dst: InstrOutput) WriterError!void {
        // extern fn () u32

        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.gettime)));

        // FFD0              call eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xD0));

        try dst.saveFromEAX(writer);
    }
    fn getkey(writer: *Writer, dst: InstrOutput) WriterError!void {
        // extern fn () u32

        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.getkey)));

        // FFD0              call eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xD0));

        try dst.saveFromEAX(writer);
    }

    fn @"and"(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        //  21D8              and eax,ebx
        try writer.write(@as(u8, 0x21));
        try writer.write(@as(u8, 0xD8));

        try dst.saveFromEAX(writer);
    }

    fn @"or"(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // 09D8              or eax,ebx
        try writer.write(@as(u8, 0x09));
        try writer.write(@as(u8, 0xD8));

        try dst.saveFromEAX(writer);
    }

    fn @"xor"(writer: *Writer, dst: InstrOutput, src: InstrInput) WriterError!void {
        try src.loadToEAX(writer);

        try emitMovEbxToEax(writer);

        try dst.loadToEAX(writer);

        // 31D8              xor eax,ebx
        try writer.write(@as(u8, 0x31));
        try writer.write(@as(u8, 0xD8));

        try dst.saveFromEAX(writer);
    }

    fn @"not"(writer: *Writer, dst: InstrOutput) WriterError!void {
        try dst.loadToEAX(writer);

        // F7D0              not eax
        try writer.write(@as(u8, 0xF7));
        try writer.write(@as(u8, 0xD0));

        try dst.saveFromEAX(writer);
    }

    fn @"neg"(writer: *Writer, dst: InstrOutput) WriterError!void {
        try dst.loadToEAX(writer);

        // F7D8              neg eax
        try writer.write(@as(u8, 0xF7));
        try writer.write(@as(u8, 0xD8));

        try dst.saveFromEAX(writer);
    }

    fn setpix(writer: *Writer, x: InstrInput, y: InstrInput, col: InstrInput) WriterError!void {
        // extern fn (x: u32, y: u32, col: u32) void
        try col.loadToEAX(writer);
        // 50                push eax
        try writer.write(@as(u8, 0x50));

        try y.loadToEAX(writer);
        // 50                push eax
        try writer.write(@as(u8, 0x50));

        try x.loadToEAX(writer);
        // 50                push eax
        try writer.write(@as(u8, 0x50));

        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.setpix)));

        // FFD0              call eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xD0));

        // 83C444            add esp,byte +0x44
        // pop*3
        try writer.write(@as(u8, 0x83));
        try writer.write(@as(u8, 0xC4));
        try writer.write(@as(u8, 0x0C)); // pop 3 args
    }

    fn getpix(writer: *Writer, col: InstrOutput, x: InstrInput, y: InstrInput) WriterError!void {
        // extern fn (x: u32, y: u32) u32
        try y.loadToEAX(writer);
        // 50                push eax
        try writer.write(@as(u8, 0x50));

        try x.loadToEAX(writer);
        // 50                push eax
        try writer.write(@as(u8, 0x50));

        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.getpix)));

        // FFD0              call eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xD0));

        // 83C455            add esp,byte +0x55
        try writer.write(@as(u8, 0x83));
        try writer.write(@as(u8, 0xC4));
        try writer.write(@as(u8, 0x08)); // pop 2 args

        try col.saveFromEAX(writer);
    }
    fn flushpix(writer: *Writer) WriterError!void {
        // extern fn () void

        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.flushpix)));

        // FFD0              call eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xD0));
    }
    fn trace(writer: *Writer, on: InstrInput) WriterError!void {
        // extern fn (x: u32, y: u32, col: u32) void
        try on.loadToEAX(writer);
        // 50                push eax
        try writer.write(@as(u8, 0x50));

        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.trace)));

        // FFD0              call eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xD0));

        // 83C444            add esp,byte +0x04
        try writer.write(@as(u8, 0x83));
        try writer.write(@as(u8, 0xC4));
        try writer.write(@as(u8, 0x04)); // pop 1 args
    }

    fn exit(writer: *Writer) WriterError!void {
        // B844332211        mov eax,0x11223344
        try writer.write(@as(u8, 0xB8));
        try writer.write(@intCast(u32, @ptrToInt(API.exit)));

        // FFE0              jmp eax
        try writer.write(@as(u8, 0xFF));
        try writer.write(@as(u8, 0xE0));
    }
};
