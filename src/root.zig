const std = @import("std");
const testing = std.testing;

// Definitions from the 
pub const Cmnd_STK_GET_SYNC = 0x30;
pub const Cmnd_STK_GET_SIGN_ON = 0x31;
pub const Cmnd_STK_READ_SIGN = 0x75;
pub const Cmnd_STK_GET_PARAMETER = 0x41;
pub const Sync_CRC_EOP = 0x20;
pub const Cmnd_STK_SET_DEVICE = 0x42;
pub const Cmnd_STK_SET_DEVICE_EXT = 0x45;
pub const Cmnd_STK_ENTER_PROGMODE = 0x50;
pub const Cmnd_STK_LEAVE_PROGMODE = 0x51;
pub const Cmnd_STK_LOAD_ADDRESS = 0x55;
pub const Cmnd_STK_PROG_PAGE = 0x64;
pub const Cmnd_STK_READ_PAGE = 0x74;
pub const Cmnd_STK_READ_OSCCAL = 0x38;
pub const Cmnd_STK_READ_FUSE = 0x50;
pub const Cmnd_STK_READ_LOCK = 0x58;
pub const Cmnd_STK_READ_SIGNATURE = 0x30;
pub const Cmnd_STK_READ_OSCCAL_EXT = 0x38;
pub const Cmnd_STK_READ_FUSE_EXT = 0x50;

pub const Resp_STK_OK               = 0x10;
pub const Resp_STK_FAILED            = 0x11;
pub const Resp_STK_UNKNOWN           = 0x12;
pub const Resp_STK_NODEVICE          = 0x13;
pub const Resp_STK_INSYNC            = 0x14;
pub const Resp_STK_NOSYNC            = 0x15;

pub const Parm_STK_SW_MAJOR = 0x80;
pub const Parm_STK_SW_MINOR = 0x81;
pub const Parm_STK_LEDS = 0x83;
pub const Parm_STK_VTARGET = 0x84;
pub const Parm_STK_VADJUST = 0x85;
pub const Parm_STK_OSC_PSCALE = 0x86;
pub const Parm_STK_OSC_CMATCH = 0x87;
pub const Parm_STK_RESET_DURATION = 0x88;
pub const Parm_STK_SCK_DURATION = 0x89;
pub const Parm_STK_BUFSIZEL = 0x90;
pub const Parm_STK_BUFSIZEH = 0x91;
pub const Parm_STK_DEVICE = 0x92;
pub const Parm_STK_PROGMODE = 0x93;
pub const Parm_STK_PARAMODE = 0x94;
pub const Parm_STK_POLLING = 0x95;
pub const Parm_STK_SELFTIMED = 0x96;
pub const Parm_STK500_TOPCARD_DETECT = 0x98;
pub const Parm_STK_500P_PDI = 0x9A;
pub const Parm_STK_STATUS = 0x9C;

const LOST_SYNC = error.BrokenPipe;

pub const ArduinoUnoStkConnection = struct {
    pub const OpenError = error {
        // Drawn from std.fs.File.OpenError.NoDevice
        NoDevice,
    } || std.fs.File.ReadError;
    port: std.fs.File,
    pub fn open(port: std.fs.File) OpenError!ArduinoUnoStkConnection {
        var conn = ArduinoUnoStkConnection { .port = port, };
        conn.getsync() catch |err| switch(err) {
            error.BrokenPipe => return error.NoDevice,
            else => return err
        };
        return conn;
    }
    pub fn getsync(this: *@This()) std.fs.File.ReadError!void {
        try set_timeout(this.port, 0);

        for (0..6) |_| {
            // Reboot the bootloader to put it in a listening state.

            // Ported from https://github.com/avrdudes/avrdude/blob/a336e47a6e1fe069c45096edaeda1b4841ad7ce5/src/stk500.c#L118
            // "This code assumes a negative-logic USB to TTL serial adapter
            //  Pull the RTS/DTR line low to reset AVR: it is still high from open()/last attempt"
            // FIXME: Error handling for EscapeCommFunction.
            if (0 == windows.EscapeCommFunction(this.port.handle, windows.SETDTR)) std.debug.panic("unexpected error", .{});
            std.time.sleep(1000 * 100); // Wait for capacitor to discharge: we're bringing the RESET line on the board low.

            // Release RESET and allow the bootloader to start. Wait 20ms for it to initialize.
            if (0 == windows.EscapeCommFunction(this.port.handle, windows.CLRRTS)) std.debug.panic("unexpected error", .{});
            if (0 == windows.EscapeCommFunction(this.port.handle, windows.CLRDTR)) std.debug.panic("unexpected error", .{});
            std.time.sleep(1000 * 1000 * 20);
            
            // Discharge line noise.
            try this.drain();
            this.command(&.{Cmnd_STK_GET_SYNC, Sync_CRC_EOP}) catch continue;
            return;
        }
        return LOST_SYNC;
    }
    pub fn command(this: *@This(), msg: []const u8) !void {
        try this.send(msg);
        var resp: [2]u8 = undefined;
        try this.recv(&resp);
    }
    pub fn send(this: *@This(), msg: []const u8) std.fs.File.WriteError!void {
        try set_timeout(this.port, 500);
        if (this.port.write(msg) catch @panic("unexpected error") != msg.len) return error.BrokenPipe;
    }
    pub fn recv(this: *@This(), msg: []u8) std.fs.File.ReadError!void {
        try set_timeout(this.port, 5000);
        if (this.port.read(msg) catch @panic("unexpected error") != msg.len) return error.ConnectionTimedOut;
    }
    pub fn getparm(this: *@This(), parm: u8) (std.fs.File.ReadError || std.fs.File.WriteError)!u8 {
        var resp: [3]u8 = undefined;
        try this.request(&.{Cmnd_STK_GET_PARAMETER, parm, Sync_CRC_EOP}, &resp);
        return resp[1];
    }
    pub fn request(this: *@This(), msg: []const u8, response: []u8) (std.fs.File.ReadError || std.fs.File.WriteError)!void {
        for (0..3) |_| {
            try this.send(msg);
            try this.recv(response[0..1]);

            if (response[0] == Resp_STK_NOSYNC) try this.getsync();
            break;
        } else return LOST_SYNC;
        if (response[0] != Resp_STK_INSYNC) return error.InputOutput; // Programmer says we're in a bad state.
        
        try this.recv(response[1..]);
        const status = response[response.len - 1];
        if (status == Resp_STK_FAILED) return error.AccessDenied; // Also possible when the device doesn't recognize the parameter.
        if (status != Resp_STK_OK) return error.Unexpected;
    }
    pub fn drain(this: *@This()) !void {
        // This timeout slows down how fast we can connect to the programmer,
        // but the sync takes quite a long time. avrdude uses 250ms, which is
        // probably a good compromise. I'm experimenting with the stability here
        // since 50ms works on my machine.
        try set_timeout(this.port, 50);
        var buf: [512]u8 = undefined;
        while (try this.port.read(&buf) != 0) {}
    }
    pub fn loadaddr(this: *@This(), addr: u16) !void {
        var msg: [4]u8 = .{Cmnd_STK_LOAD_ADDRESS, 0, 0, Sync_CRC_EOP};
        std.mem.writePackedInt(u16, msg[1..3], 0, addr, .little);
        try this.command(&msg);
    }
};

fn set_timeout(port: std.fs.File, timeout: u32) error {}!void {
    if (0 == windows.SetCommTimeouts(port.handle, &.{
        .ReadIntervalTimeout = 0,
        .ReadTotalTimeoutMultiplier = 0,
        .ReadTotalTimeoutConstant = timeout,
        .WriteTotalTimeoutMultiplier = 0,
        .WriteTotalTimeoutConstant = 0,
    })) std.debug.panic("unexpected error {any}", .{std.os.windows.kernel32.GetLastError()}); // FIXME
}


const windows = struct {
    extern "kernel32" fn SetupComm(
        hFile: std.os.windows.HANDLE,
        dwInQueue: std.os.windows.DWORD,
        dwOutQueue: std.os.windows.DWORD  
    ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
    extern "kernel32" fn CreateFileA(
        lpFileName: [*]const u8,
        dwDesiredAccess: std.os.windows.DWORD,
        dwShareMode: std.os.windows.DWORD,
        lpSecurityAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: std.os.windows.DWORD,
        dwFlagsAndAttributes: std.os.windows.DWORD,
        hTemplateFile: ?std.os.windows.HANDLE
    ) callconv(std.os.windows.WINAPI) std.os.windows.HANDLE;
    // BOOL SetCommTimeouts(
    //   [in] HANDLE         hFile,
    //   [in] LPCOMMTIMEOUTS lpCommTimeouts
    // );
    extern "kernel32" fn SetCommTimeouts(
        hFile: std.os.windows.HANDLE,
        lpCommTimeouts: ?*const COMMTIMEOUTS
    ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
    // typedef struct _COMMTIMEOUTS {
    //   DWORD ReadIntervalTimeout;
    //   DWORD ReadTotalTimeoutMultiplier;
    //   DWORD ReadTotalTimeoutConstant;
    //   DWORD WriteTotalTimeoutMultiplier;
    //   DWORD WriteTotalTimeoutConstant;
    // } COMMTIMEOUTS, *LPCOMMTIMEOUTS;
    pub const COMMTIMEOUTS = struct {
        ReadIntervalTimeout: std.os.windows.DWORD,
        ReadTotalTimeoutMultiplier: std.os.windows.DWORD,
        ReadTotalTimeoutConstant: std.os.windows.DWORD,
        WriteTotalTimeoutMultiplier: std.os.windows.DWORD,
        WriteTotalTimeoutConstant: std.os.windows.DWORD,
    };

    extern "kernel32" fn EscapeCommFunction(
        hFile: std.os.windows.HANDLE,
        dwFunc: std.os.windows.DWORD
    ) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
    const SETXOFF = 1;
    const SETXON = 2;
    const SETRTS = 3;
    const CLRRTS = 4;
    const SETDTR = 5;
    const CLRDTR = 6;
    const SETBREAK = 8;
    const CLRBREAK = 9;

};

test {
    testing.refAllDecls(@This());
}