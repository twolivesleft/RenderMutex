//
//  RenderMutex.m
//  Runtime
//
//  Created by Jean-Francois Perusse on 2022-02-15.
//  Copyright © 2022 Two Lives Left. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "RenderMutex.h"

#include <pthread.h>
#include <time.h>

@implementation RenderMutex
{
    pthread_mutex_t renderMutex_;
    NSThread* renderMutexLockedThread_;
    NSThread* renderThread_;
    BOOL mainQueueLocked_;
}

static long _sleepDuration = 100;

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        pthread_mutex_init(&renderMutex_, NULL);
        renderMutexLockedThread_ = NULL;
        renderThread_ = NULL;
    }
    return self;
}

+ (long) sleepDuration
{
    @synchronized (self) {
        return _sleepDuration;
    }
}

+ (void) setSleepDuration:(long)sleepDuration
{
    @synchronized (self) {
        _sleepDuration = sleepDuration;
    }
}

- (BOOL) isLockedOnCurrentThread
{
    return renderMutexLockedThread_ == [NSThread currentThread];
}

- (BOOL) isLockedOnRenderThread
{
    return renderThread_ != nil && renderMutexLockedThread_ == renderThread_;
}

- (BOOL) lock
{
    if ([self isLockedOnCurrentThread])
    {
        return false;
    }
    
    pthread_mutex_lock(&renderMutex_);

    renderMutexLockedThread_ = [NSThread currentThread];

    return true;
}

- (BOOL) lockWithTimeout:(int)timeout
{
    if ([self isLockedOnCurrentThread])
    {
        return false;
    }
        
    const time_t startNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const int timeoutNs = timeout * 1000 * 1000;
    const struct timespec ts = { 0, RenderMutex.sleepDuration };

    while (true)
    {
        if (pthread_mutex_trylock(&renderMutex_) == 0)
        {
            break;
        }

        if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNs > timeoutNs)
        {
            return false;
        }
        
        nanosleep(&ts, nil);
    }
        
    renderMutexLockedThread_ = [NSThread currentThread];

    return true;
}

- (void) unlock
{
#if DEBUG
    NSAssert([self isLockedOnCurrentThread], @"unlock called from a different thread than the lock");
#endif

    renderMutexLockedThread_ = NULL;
    
    pthread_mutex_unlock(&renderMutex_);
}

- (BOOL)lockFromRenderThread
{
#if DEBUG
    const char* queueLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    NSAssert(strcmp(queueLabel, "com.twolivesleft.codea.threadedgcdqueue") == 0,
             @"lockFromRenderThread called from non-render thread %s", queueLabel);
#endif
    
    renderThread_ = [NSThread currentThread];
    
    return [self lock];
}

- (void) unlockFromRenderThread
{
#if DEBUG
    const char* queueLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    NSAssert(strcmp(queueLabel, "com.twolivesleft.codea.threadedgcdqueue") == 0,
             @"unlockFromRenderThread called from non-render threadm %s", queueLabel);
#endif
    
    renderThread_ = NULL;
    
    [self unlock];
}

- (void)runSyncFromRenderThread:(dispatch_block_t)block {
    BOOL didLockRenderMutex = [self lockFromRenderThread];
    
    if (block)
    {
        block();
    }
    
    if (didLockRenderMutex)
    {
        [self unlockFromRenderThread];
    }
}

- (void)runSyncFromRenderThreadOnQueue:(dispatch_queue_t)queue block:(dispatch_block_t)block
{
    BOOL isMainThread = [NSThread isMainThread];
    BOOL useMainQueue = !isMainThread && queue == dispatch_get_main_queue() && !mainQueueLocked_;
    if (useMainQueue)
    {
        mainQueueLocked_ = true;
    }
    
    if ([self isLockedOnCurrentThread])
    {
        NSThread* currentThread = [NSThread currentThread];
        if (currentThread == renderThread_)
        {
            [self unlockFromRenderThread];
            
            dispatch_sync(queue, ^{
                if(block)
                {
                    block();
                }
            });

            [self lockFromRenderThread];
        }
        else
        {
            if (useMainQueue)
            {
                dispatch_sync(queue, ^{
                    if (block)
                    {
                        block();
                    }
                });
            }
            else
            {
                // If we get here, it should be because of a re-entrant call (lua -> objc -> lua -> objc)
                // and thus we should ignore the queue to keep the current lock and thread.
                if (block)
                {
                    block();
                }
            }
        }
    }
    else
    {
        // If the mutex is not currently locked, the render thread might be requesting to run
        // code on the main thread outside of the Lua execution (e.g. changing view mode).
        // In this case, we do the dispatch to the right queue but don't need to lock the mutex.
        dispatch_sync(queue, ^{
            if(block)
            {
                block();
            }
        });
    }
    
    if (useMainQueue)
    {
        mainQueueLocked_ = false;
    }
}

- (void)runSyncFromRenderThreadOnMain:(dispatch_block_t)block
{
    [self runSyncFromRenderThreadOnQueue:dispatch_get_main_queue() block:block];
}

- (void)runSyncFromNonRenderThread:(dispatch_block_t)block
{
    BOOL didLockRenderMutex = [self lock];
    
    if (block)
    {
        block();
    }
    
    if (didLockRenderMutex)
    {
        [self unlock];
    }
}

- (void)runSyncFromNonRenderThread:(dispatch_block_t)block withTimeout:(int)timeout
{
    BOOL didLockRenderMutex = [self lockWithTimeout:timeout];
    
    if (![self isLockedOnCurrentThread]) {
        NSLog(@"Warning: a block was ignored because of a mutex timeout.");
        return;
    }
    
    if (block)
    {
        block();
    }
    
    if (didLockRenderMutex)
    {
        [self unlock];
    }
}

- (void)unsafeRunSyncWithoutMutex:(dispatch_block_t)block
{
    BOOL wasLockedOnCurrentThread = [self isLockedOnCurrentThread];
    BOOL wasLockedOnRenderThread = [self isLockedOnRenderThread];
    if (wasLockedOnCurrentThread)
    {
        [self unlock];
    }
    
    if (block)
    {
        block();
    }

    if (wasLockedOnCurrentThread)
    {
        if (wasLockedOnRenderThread)
        {
            [self lockFromRenderThread];
        }
        else
        {
            [self lock];
        }
    }
}
@end
