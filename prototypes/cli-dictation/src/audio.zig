//! CoreAudio Capture via AudioQueue, asking the queue for 24 kHz mono s16le
//! directly (its internal converter resamples from the device rate). Portable
//! half of the prototype: knows nothing about the websocket or OpenAI. Chunks
//! are handed to a caller-supplied sink.
//!
//! Extern decls + design per docs/research/coreaudio-capture-zig.md §8.
//! (@cImport is gone on this nightly; hand-written externs instead.)

const std = @import("std");

const OSStatus = i32;

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

const kAudioFormatLinearPCM: u32 = 0x6C70636D; // 'lpcm'
const kAudioFormatFlagIsSignedInteger: u32 = 1 << 2;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;

const AudioQueueRef = ?*opaque {};
const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: *anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?*anyopaque,
    mPacketDescriptionCount: u32,
};
const AudioQueueBufferRef = ?*AudioQueueBuffer;
const AudioTimeStamp = opaque {};
const AudioStreamPacketDescription = extern struct {
    mStartOffset: i64,
    mVariableFramesInPacket: u32,
    mDataByteSize: u32,
};

const AudioQueueInputCallback = *const fn (
    ?*anyopaque,
    AudioQueueRef,
    AudioQueueBufferRef,
    *const AudioTimeStamp,
    u32,
    ?[*]const AudioStreamPacketDescription,
) callconv(.c) void;

extern "c" fn AudioQueueNewInput(
    inFormat: *const AudioStreamBasicDescription,
    inCallbackProc: AudioQueueInputCallback,
    inUserData: ?*anyopaque,
    inCallbackRunLoop: ?*anyopaque,
    inCallbackRunLoopMode: ?*anyopaque,
    inFlags: u32,
    outAQ: *AudioQueueRef,
) OSStatus;
extern "c" fn AudioQueueAllocateBuffer(inAQ: AudioQueueRef, inBufferByteSize: u32, outBuffer: *AudioQueueBufferRef) OSStatus;
extern "c" fn AudioQueueEnqueueBuffer(inAQ: AudioQueueRef, inBuffer: AudioQueueBufferRef, inNumPacketDescs: u32, inPacketDescs: ?[*]const AudioStreamPacketDescription) OSStatus;
extern "c" fn AudioQueueStart(inAQ: AudioQueueRef, inStartTime: ?*const AudioTimeStamp) OSStatus;
extern "c" fn AudioQueueStop(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;
extern "c" fn AudioQueueDispose(inAQ: AudioQueueRef, inImmediate: u8) OSStatus;

/// 24 kHz * 2 B * 50 ms = one buffer == one append-event's worth (crib sheet §4).
pub const buffer_bytes: u32 = 2400;
const buffer_count = 3;

pub const ChunkSink = *const fn (ctx: ?*anyopaque, pcm: []const u8) void;

pub const Capture = struct {
    queue: AudioQueueRef = null,
    ctx: ?*anyopaque = null,
    on_chunk: ?ChunkSink = null,

    /// Set once a nonzero sample is seen — the denial/silence detector, since
    /// mic-TCC denial yields zeros with noErr rather than an error (crib sheet §5.3).
    nonzero_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Runs on the audio queue's internal thread (run-loop arg = null).
    fn onBuffer(
        user_data: ?*anyopaque,
        queue: AudioQueueRef,
        buffer: AudioQueueBufferRef,
        _: *const AudioTimeStamp,
        _: u32,
        _: ?[*]const AudioStreamPacketDescription,
    ) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(user_data.?));
        const b = buffer.?;
        const bytes: [*]const u8 = @ptrCast(b.mAudioData);
        const slice = bytes[0..b.mAudioDataByteSize];

        if (!self.nonzero_seen.load(.monotonic)) {
            for (slice) |x| {
                if (x != 0) {
                    self.nonzero_seen.store(true, .monotonic);
                    break;
                }
            }
        }
        if (self.on_chunk) |cb| cb(self.ctx, slice);
        _ = AudioQueueEnqueueBuffer(queue, buffer, 0, null); // hand the buffer back
    }

    /// Create the queue and enqueue buffers. Fires a TCC preflight but no prompt.
    pub fn init(self: *Capture) !void {
        const format = AudioStreamBasicDescription{
            .mSampleRate = 24000, // the queue's converter resamples from the device rate
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = 16,
        };
        if (AudioQueueNewInput(&format, onBuffer, self, null, null, 0, &self.queue) != 0)
            return error.AudioQueueNewInput;
        errdefer _ = AudioQueueDispose(self.queue, 1);

        var i: usize = 0;
        while (i < buffer_count) : (i += 1) {
            var buf: AudioQueueBufferRef = null;
            if (AudioQueueAllocateBuffer(self.queue, buffer_bytes, &buf) != 0)
                return error.AudioQueueAllocateBuffer;
            if (AudioQueueEnqueueBuffer(self.queue, buf, 0, null) != 0)
                return error.AudioQueueEnqueueBuffer;
        }
    }

    /// First call performs input IO for real => microphone prompt (attributed to
    /// the terminal for a CLI, crib sheet §5.1).
    pub fn start(self: *Capture) !void {
        self.nonzero_seen.store(false, .monotonic);
        if (AudioQueueStart(self.queue, null) != 0) return error.AudioQueueStart;
    }

    pub fn stop(self: *Capture) void {
        _ = AudioQueueStop(self.queue, 1); // synchronous; pending callbacks fire during this call
    }

    pub fn heardSound(self: *Capture) bool {
        return self.nonzero_seen.load(.monotonic);
    }

    pub fn deinit(self: *Capture) void {
        if (self.queue != null) _ = AudioQueueDispose(self.queue, 1);
    }
};
