const std = @import("std");

const AtomicQueueCount = @import("atomic-queue-count.zig");
const Thread = std.Thread;
const Semaphore = std.Thread.Semaphore;
const Condition = std.Thread.Condition;
const Mutex = std.Thread.Mutex;

usingnamespace @import("av-common.zig");

threadlocal var scaler: ?*SwsContext = null;

pub fn StrideRescalePool(comptime ThreadCount: usize) type {
    return struct {
        const Self = @This();
        const QueueType = std.atomic.Stack(*StrideTask);

        const alloc = std.heap.c_allocator;

        width: u16,
        height: u16,

        queueSema: Semaphore = .{},
        queue: QueueType,

        threads: [ThreadCount]Thread = undefined,

        // other threads waiting for us to complete
        waiting: AtomicQueueCount = .{},

        pub fn init(self: *Self, targetWidth: u16, targetHeight: u16) !void {
            self.width = targetWidth;
            self.height = targetHeight;

            // spawn our threads
            for (self.threads) |*thread| {
                thread.* = try Thread.spawn(.{}, takeTask, .{self});
            }
        }

        pub fn submitTask(self: *Self, task: StrideTask) !void {
            // note to self: don't be naive and append stack variables, expecting them
            // to work when... you know, we leave the stack.

            // create a copy of our task
            var taskCopy = try alloc.create(StrideTask);
            taskCopy.*.in = task.in;
            taskCopy.*.out = task.out;
            taskCopy.*.y = task.y;
            taskCopy.*.h = task.h;

            // create a node to prepend
            var node = try alloc.create(QueueType.Node);
            node.*.next = null;
            node.*.data = taskCopy;

            // prepend and notify of new task
            self.queue.push(node);
            self.waiting.inc();

            // post to threads saying we have a task
            self.queueSema.post();
        }

        pub fn waitUntilEmpty(self: *Self) !void {
            try self.waiting.waitUntil(0);
        }

        pub fn takeTask(self: *Self) !void {
            while (true) {
                // wait for task to come in
                self.queueSema.wait();

                // pop task from our queue and extract in and out
                const taskNode = self.queue.pop().?;
                const task = taskNode.*.data;

                if (task.in == 0) {
                    std.debug.print("Got null in, dying...\n", .{});
                    return;
                }

                const in = task.in.*;
                var out = task.out.*;

                // init scaler if we don't have one already
                if (scaler == null) {
                    scaler = sws_getContext(
                        // source parameters
                        in.width,
                        in.height,
                        in.format,

                        // target parameters
                        self.width,
                        self.height,
                        AV_PIX_FMT_RGB444LE,

                        // scaling algorithm - use a crappy scaling algorithm because of performance
                        SWS_POINT,
                        null,
                        null,
                        null,
                    ) orelse return AVError.FailedSwrContextAlloc;

                    // std.debug.print("Scaling Thread {d}: Created new scaler\n", .{Thread.getCurrentId()});
                    // std.debug.print("Source: width = {d}, height = {d}\n", .{ in.width, in.height });
                    // std.debug.print("Target: width = {d}, height = {d}\n", .{ self.width, self.height });
                }

                var inSlicedPlanes: [8][*c]u8 = undefined;

                // populate inSlicedPlanes with... planes that are sliced
                // we can't just add offsets and be done with it because of formats like YUV,
                // where U and V has half the amount of Y's.
                var plane: usize = 0;
                while (plane < av_pix_fmt_count_planes(in.format)) : (plane += 1) {
                    var vsub: u5 = undefined;

                    if ((plane + 1) & 2 > 0) {
                        const fmt = av_pix_fmt_desc_get(in.format);
                        vsub = @truncate(u5, fmt.*.log2_chroma_h);
                    } else {
                        vsub = 0;
                    }

                    const inOffset = (task.y >> vsub) * in.linesize[plane];
                    inSlicedPlanes[plane] = addDataOffset(in.data[plane], @intCast(usize, inOffset));
                }

                // finally do the scaling with our y and h slice offsets
                if (sws_scale(
                    scaler,
                    @ptrCast([*c]const [*c]const u8, &inSlicedPlanes[0]),
                    @ptrCast([*c]const c_int, &in.linesize[0]),
                    task.y,
                    task.h,
                    @ptrCast([*c]const [*c]u8, &out.data[0]),
                    @ptrCast([*c]c_int, &out.linesize[0]),
                ) < 0) {
                    return AVError.FailedSwrConvert;
                }

                // destroy the old task and task node that we had to allocate earlier
                alloc.destroy(task);
                alloc.destroy(taskNode);

                // decrement saying the task is complete
                self.waiting.dec();
            }
        }

        pub fn shutdown(self: *Self) void {
            {
                for (self.threads) |_| {
                    self.submitTask(.{
                        .in = 0,
                        .out = 0,
                        .y = 0,
                        .h = 0,
                    }) catch @panic("Failed to shutdown threads!");
                }
            }

            {
                for (self.threads) |thread| {
                    thread.join();
                }
                std.debug.print("Stride pool shutdown, waking everyone up...\n", .{});
                self.waiting.forceWake();
            }
        }
    };
}

inline fn addDataOffset(src: [*c]u8, offset: usize) [*c]u8 {
    return @intToPtr([*c]u8, @ptrToInt(src) + offset);
}

pub const StrideTask = struct {
    in: [*c]AVFrame,
    out: [*c]AVFrame,
    y: c_int,
    h: c_int,
};
