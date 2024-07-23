//  RenderMutex.h
//
//  Runtime
//
//  Created by Jean-Francois Perusse on 2022-02-15.
//  Copyright © 2022 Two Lives Left. All rights reserved.
//

#import <Foundation/Foundation.h>

// This class wraps a mutex used to prevent deadlocks between the non-render and render threads
// which could happen because of the Objective-C bridge with callbacks that can be forwarded
// back to Lua.
//
// The non-render threads locks the mutex from native callbacks, before processing the Lua callback
// code, or in special cases like closing where we want to make sure that willClose will execute.
//
// When the Render Thread is executing, it locks the mutex to prevent native callbacks from
// synchronizing with the Render Thread.
//
// If the Render Thread must synchronize with the main thread (e.g. readImage), it first
// unlocks the mutex before synchronizing. This will let the main thread process a pending
// callback if needed, running the Lua code on the main thread itself, and then executing
// what the Render Thread requested.
@interface RenderMutex : NSObject

/**
 * The RenderMutex lock sleep duration in nanoseconds.
 */
@property (class) long sleepDuration;

/**
 * Returns true if the mutex was locked by the current thread.
 */
- (BOOL)isLockedOnCurrentThread;

/**
 * Locks the render mutex for the render thread, runs the block synchronously, and unlocks the mutex.
 */
- (void)runSyncFromRenderThread:(dispatch_block_t)block;

/**
 * If the mutex is locked, unlock the mutex and execute the block on
 * the target queue.
 *
 * This function should only be called from the render thread, except
 * for "re-entry" (e.g. lua -> objc -> lua -> objc)
 *
 * In case of re-entry, the block is executed on the current thread.
 *
 * @param[in] block The block to execute if the mutex can be locked.
 */
- (void)runSyncFromRenderThreadOnQueue:(dispatch_queue_t)queue block:(dispatch_block_t)block;

/**
 * Unlock the mutex and execute the block on the main thread.
 *
 * This function should only be called from the render thread, except
 * for "re-entry" (e.g. render -> main -> run lua code -> main)
 *
 * In case of re-entry, the block is executed on the current thread.
 *
 * @param[in] block The block to execute if the mutex can be locked.
 */
- (void)runSyncFromRenderThreadOnMain:(dispatch_block_t)block;

/**
 * Get the RenderMutex lock, execute the block, and unlock if we did lock
 * the mutex.
 *
 * This function should only be called from non-render threads.
 *
 * @param[in] block The block to execute if the mutex can be locked.
 */
- (void)runSyncFromNonRenderThread:(dispatch_block_t)block;

/**
 * Try to get the RenderMutex lock, execute the block, and unlock if we did lock
 * the mutex.
 *
 * If the mutex cannot be locked before the timeout, the block is not executed.
 *
 * This function should only be called from non-render threads.
 *
 * @param[in] block The block to execute if the mutex can be locked.
 * @param[in] timeout The timeout in milliseconds.
 */
- (void)runSyncFromNonRenderThread:(dispatch_block_t)block withTimeout:(int)timeout;

/**
 * If the mutex is locked on the current thread, unlock it, execute the block,
 * and lock it again considering the render thread properly.
 *
 * Use this with care! If the block dispatches to another thread which then
 * requires the current thread, a deadlock will occur.
 *
 * Typical use-cases:
 *   - Semaphore wait (e.g. waiting for a native-to-lua callback signal)
 */
- (void)unsafeRunSyncWithoutMutex:(dispatch_block_t)block;

@end
