const std = @import("std");
const mc = @import("mc.zig");
const color = @import("color.zig");

const AtomicQueueCount = @import("atomic-queue-count.zig");
const Thread = std.Thread;
const Semaphore = std.Thread.Semaphore;

// i'm lazy, if this looks similar to stride-pool, it's becuase it's a copy-paste with
// color matching specific changes
// TODO: abstract stride-pool and color-match-pool so we can just implement in a clean manner
pub fn ColorMatchPool(comptime ThreadCount: usize, writeOntoSrc: bool) type {
    return struct {
        const Self = @This();
        const QueueType = std.atomic.Stack(*ColorMatchTask);

        const alloc = std.heap.c_allocator;

        queueSema: Semaphore = .{},
        queue: QueueType = .{},

        threads: [ThreadCount]Thread,

        // other threads waiting for us to complete
        waiting: AtomicQueueCount = .{},

        pub fn init(self: *Self) !void {
            // spawn our threads
            for (self.threads) |*thread| {
                thread.* = try Thread.spawn(.{}, takeTask, .{self});
            }
        }

        pub fn takeTask(self: *Self) !void {
            while (true) {
                // wait for task to come in
                self.queueSema.wait();

                // pop task from our queue and extract in and out
                const taskNode = self.queue.pop().?;
                const task = taskNode.*.data;

                if (task.src == null) {
                    std.debug.print("Got null src, dying...\n", .{});
                    return;
                }

                const src = task.src.?;

                // let's avoid having toa second pass to translate it back to U16... this looks ugly
                if (writeOntoSrc) {
                    for (src[task.srcOff .. task.srcOff + task.len]) |*pixel| {
                        pixel.* = color.toU16RGB(mc.ColorLookupTable[pixel.*]);
                    }
                } else {
                    const dst = task.dst.?;
                    var index: usize = 0;
                    while (index < task.len) : (index += 1) {
                        dst[task.dstOff + index] = mc.ColorLookupTable[src[task.srcOffset + index]];
                    }
                }

                // destroy the old task and task node that we had to allocate earlier
                alloc.destroy(task);
                alloc.destroy(taskNode);

                // decrement saying the task is complete
                self.waiting.dec();
            }
        }

        pub fn waitUntilEmpty(self: *Self) !void {
            try self.waiting.waitUntil(0);
        }

        pub fn shutdown(self: *Self) void {
            {
                for (self.threads) |_| {
                    self.submitTask(.{
                        .src = null,
                        .dst = null,
                        .srcOff = 0,
                        .dstOff = 0,
                        .len = 0,
                    }) catch @panic("Failed to shutdown threads!");
                }
            }

            {
                for (self.threads) |thread| {
                    thread.join();
                }
                std.debug.print("Color pool shutdown, waking everyone up...\n", .{});
                self.waiting.forceWake();
            }
        }

        pub fn submitTask(self: *Self, task: ColorMatchTask) !void {
            // note to self: don't be naive and append stack variables, expecting them
            // to work when... you know, we leave the stack.

            // create a copy of our task
            var taskCopy = try alloc.create(ColorMatchTask);
            taskCopy.src = task.src;
            taskCopy.dst = task.dst;
            taskCopy.srcOff = task.srcOff;
            taskCopy.dstOff = task.dstOff;
            taskCopy.len = task.len;

            // create a node to prepend
            var node = try alloc.create(QueueType.Node);
            node.*.next = null;
            node.*.data = taskCopy;

            // prepend task and increment the amount of tasks we have
            self.queue.push(node);
            self.waiting.inc();

            // post to threads saying we have a task
            self.queueSema.post();
        }
    };
}

pub const ColorMatchTask = struct {
    src: ?[*]u16,
    dst: ?[*]u8,
    srcOff: usize,
    dstOff: usize,
    len: usize,
};
