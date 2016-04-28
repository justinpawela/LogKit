// Loggers.swift
//
// Copyright (c) 2015 - 2016, Justin Pawela & The LogKit Project
// http://www.logkit.info/
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

import Foundation


// ======================================================================== //
// MARK: Logger
// ======================================================================== //

/// The main logging API for application code. An instance of this class distributes Log Entries to Endpoints
/// for writing.
///
/// Initiating a Logger as a global constant (for example, in the ApplicationDelegate file), allows a developer to log
/// from all files in their project. For example, this simple initialization creates a Logger with a _ConsoleEndpoint_:
///
/// ````
/// let log = Logger()
/// ````
///
/// Then, from any file in the project, a developer can create a Log Entry by using one of the instance's methods,
/// such as:
///
/// ````
/// log.debug("This is a debug message.")
/// ````
///
/// A Logger instance has methods for `debug`, `info`, `notice`, `warning`, `error`, and `critical` Log Entries.
///
/// When initialized, a _WriteMode_ is supplied to the Logger instance. This option determines the Logger's
/// synchronicity and concurrency behaviors. The available options are:
///
/// - `.Asynchronous`: Write Log Entries to Endpoints asynchronously.
/// - `.Synchronous`:  Write Log Entries to Endpoints synchronously.
/// - `.Serial`:       Write Log Entries to Endpoints synchronously, and to each Endpoint serially.
///
/// In all cases, Log Entries are written in order, and each Log Entry is written to each of its target Endpoints
/// before the next Entry begins writing.
public final class Logger {

    /// These options determine how the Logger writes Entries to its Endpoints.
    public enum WriteMode {
        /// Tells the Logger to write Log Entries to Endpoints asynchronously. Returns immediately after writes
        /// are scheduled, and very possibly before said writes have completed.
        ///
        /// Log Entries will be written asynchronously, and may be written to multiple Endpoints concurrently.
        /// However, each Log Entry will be written to every target Endpoint before the next Log Entry is begun. In
        /// other words, Log Entries are written in order.
        ///
        /// Recommended for production builds. Provides the best speed, but is less useful for debugging, as
        /// critical Log Entries may not be written to Endpoints before the application crashes.
        case Asynchronous
        /// Tells the Logger to write Log Entries to Endpoints synchronously. Only returns once the Log Entry has
        /// been written to each target Endpoint.
        ///
        /// Log Entries will be written synchronously, but may be written to multiple Endpoints concurrently.
        /// However, each Log Entry will be written to every target Endpoint before the next Log Entry is begun. In
        /// other words, Log Entries are written in order.
        ///
        /// Recommended for debug builds. Slower than asynchronous writing, but each Log Entry is guaranteed to
        /// be written before the logging call returns, ensuring critical Log Entries are not lost.
        case Synchronous
        /// Tells the Logger to write Log Entries to Endpoints synchronously and serially. Only returns once the
        /// Log Entry has been written to each target Endpoint.
        ///
        /// Log Entries will be written synchronously, and will be written to multiple Endpoints
        /// serially (one-at-a-time). Log Entries are written in order.
        ///
        /// Only recommended for debugging serious issues. This is the slowest mode, as no concurrency is used.
        /// However, this mode may make diagnosing issues with custom Endpoints easier.
        case Serial
    }

    /// The collection of Endpoints that successfully initialized.
    private let endpoints: [LXEndpoint]
    /// The queue used to write Log Entries.
    private let writeQueue: dispatch_queue_t
    /// The barrier function used to keep Log Entry writes in order.
    ///
    /// - requires: A reference to either `dispatch_barrier_async` or `dispatch_barrier_sync`.
    private let writeBarrier: (dispatch_queue_t, dispatch_block_t) -> Void

    /// Initialize a Logger. Any Endpoints that fail initialization are discarded.
    ///
    /// - parameter endpoints: An array of Endpoints to dispatch Log Entries to.
    /// - parameter writeMode: A `WriteMode` case indicating the synchronicity desired. Options are
    ///                        `.Asynchronous`, `Synchronous`, or `Serial`. Defaults to `.Asynchronous`.
    public init(endpoints: [LXEndpoint?], writeMode: Logger.WriteMode = .Asynchronous) {
        switch writeMode {
        case .Asynchronous:
            self.writeBarrier = dispatch_barrier_async
            self.writeQueue = dispatch_queue_create("logger-asynchronous", DISPATCH_QUEUE_CONCURRENT)
            dispatch_set_target_queue(self.writeQueue, shim_dispatchGetQOSUtility())
        case .Synchronous:
            self.writeBarrier = dispatch_barrier_sync
            self.writeQueue = dispatch_queue_create("logger-synchronous", DISPATCH_QUEUE_CONCURRENT)
            dispatch_set_target_queue(self.writeQueue, shim_dispatchGetQOSUserInitiated())
        case .Serial:
            self.writeBarrier = dispatch_barrier_sync
            self.writeQueue = dispatch_queue_create("logger-serial", DISPATCH_QUEUE_SERIAL)
            dispatch_set_target_queue(self.writeQueue, shim_dispatchGetQOSUserInitiated())
        }
        self.endpoints = endpoints.flatMap({ $0 }) // Discards Endpoints that fail initialization.
        assert(!self.endpoints.isEmpty, "A Logger instance has been initialized, but no valid Endpoints were provided.")
    }

    /// Initialize a basic **synchronous** Logger that writes to the console (`stderr`) with default settings.
    public convenience init() {
        self.init(endpoints: [LXConsoleEndpoint()], writeMode: .Synchronous)
    }

    /// Delivers Log Entries to Endpoints.
    ///
    /// This function filters Endpoints based on their `minimumPriorityLevel` property to deliver Entries only to
    /// qualified Endpoints. If no Endpoint qualifies, most of the work is skipped.
    ///
    /// After identifying qualified Endpoints, the Log Entry is serialized to a string based on each Endpoint's
    /// individual settings. Then, it is dispatched to the Endpoint for writing.
    private func log(
        messageBlock: () -> String,
        userInfo: [String: AnyObject],
        level: LXPriorityLevel,
        functionName: String,
        filePath: String,
        lineNumber: Int,
        columnNumber: Int,
        threadID: String = NSString(format: "%p", NSThread.currentThread()) as String,
        threadName: String = NSThread.currentThread().name ?? "",
        isMainThread: Bool = NSThread.currentThread().isMainThread
    ) {
        // Get a timestamp before doing anything else. Relative to Darwin reference epoch 2001-01-01 (not Unix epoch).
        let timestamp = CFAbsoluteTimeGetCurrent()

        // Determine what (if any) Endpoints this Log Entry will target.
        let targetEndpoints = self.endpoints.filter({ $0.minimumPriorityLevel <= level })
        if !targetEndpoints.isEmpty {
            // Resolve the message now, just once
            let message = messageBlock()
            let now = NSDate(timeIntervalSinceReferenceDate: timestamp)

            // Create a group to keep all writes for a particular Log Entry together.
            let writeGroup = dispatch_group_create()
            assert(writeGroup != nil, "The dispatch group writeGroup failed to be created.")

            // Schedule the construction, serialization, and writing of the Log Entry for each of the target Endpoints.
            for endpoint in targetEndpoints {
                dispatch_group_async(writeGroup, self.writeQueue, {
                    // Convert the Entry to a string.
                    let entryString = endpoint.entryFormatter.stringFromEntry(LXLogEntry(
                        message: message,
                        userInfo: userInfo,
                        level: level.description,
                        timestamp: now.timeIntervalSince1970,
                        dateTime: endpoint.dateFormatter.stringFromDate(now),
                        functionName: functionName,
                        filePath: filePath,
                        lineNumber: lineNumber,
                        columnNumber: columnNumber,
                        threadID: threadID,
                        threadName: threadName,
                        isMainThread: isMainThread
                        ), appendNewline: endpoint.requiresNewlines)
                    // Tell the Endpoint to write the string. Should NOT return until write is complete.
                    endpoint.write(entryString)
                })
            }

            // Use a barrier to separate log calls. Might wait here for writes to complete, depending on init writeMode.
            self.writeBarrier(self.writeQueue, {
                //TODO: This call to wait, and thus the waitGroup itself, may be unnecessary because of the barrier.
                //TODO: However, I don't know if the system would optimize away an empty barrier block.
                dispatch_group_wait(writeGroup, DISPATCH_TIME_FOREVER)
            })
        }
    }

    /// Log a `Debug` entry.
    ///
    /// - parameter message:  The message to log.
    /// - parameter userInfo: A dictionary of additional values for Endpoints to consider.
    public func debug(
        @autoclosure(escaping) message: () -> String,
        userInfo: [String: AnyObject] = [:],
        functionName: String = #function,
        filePath: String = #file,
        lineNumber: Int = #line,
        columnNumber: Int = #column
    ) {
        self.log(message, userInfo: userInfo, level: .Debug, functionName: functionName, filePath: filePath, lineNumber: lineNumber, columnNumber: columnNumber)
    }

    /// Log an `Info` entry.
    ///
    /// - parameter message:  The message to log.
    /// - parameter userInfo: A dictionary of additional values for Endpoints to consider.
    public func info(
        @autoclosure(escaping) message: () -> String,
        userInfo: [String: AnyObject] = [:],
        functionName: String = #function,
        filePath: String = #file,
        lineNumber: Int = #line,
        columnNumber: Int = #column
    ) {
        self.log(message, userInfo: userInfo, level: .Info, functionName: functionName, filePath: filePath, lineNumber: lineNumber, columnNumber: columnNumber)
    }

    /// Log a `Notice` entry.
    ///
    /// - parameter message:  The message to log.
    /// - parameter userInfo: A dictionary of additional values for Endpoints to consider.
    public func notice(
        @autoclosure(escaping) message: () -> String,
        userInfo: [String: AnyObject] = [:],
        functionName: String = #function,
        filePath: String = #file,
        lineNumber: Int = #line,
        columnNumber: Int = #column
    ) {
        self.log(message, userInfo: userInfo, level: .Notice, functionName: functionName, filePath: filePath, lineNumber: lineNumber, columnNumber: columnNumber)
    }

    /// Log a `Warning` entry.
    ///
    /// - parameter message:  The message to log.
    /// - parameter userInfo: A dictionary of additional values for Endpoints to consider.
    public func warning(
        @autoclosure(escaping) message: () -> String,
        userInfo: [String: AnyObject] = [:],
        functionName: String = #function,
        filePath: String = #file,
        lineNumber: Int = #line,
        columnNumber: Int = #column
    ) {
        self.log(message, userInfo: userInfo, level: .Warning, functionName: functionName, filePath: filePath, lineNumber: lineNumber, columnNumber: columnNumber)
    }

    /// Log an `Error` entry.
    ///
    /// - parameter message:  The message to log.
    /// - parameter userInfo: A dictionary of additional values for Endpoints to consider.
    public func error(
        @autoclosure(escaping) message: () -> String,
        userInfo: [String: AnyObject] = [:],
        functionName: String = #function,
        filePath: String = #file,
        lineNumber: Int = #line,
        columnNumber: Int = #column
    ) {
        self.log(message, userInfo: userInfo, level: .Error, functionName: functionName, filePath: filePath, lineNumber: lineNumber, columnNumber: columnNumber)
    }

    /// Log a `Critical` entry.
    ///
    /// - parameter message:  The message to log.
    /// - parameter userInfo: A dictionary of additional values for Endpoints to consider.
    public func critical(
        @autoclosure(escaping) message: () -> String,
        userInfo: [String: AnyObject] = [:],
        functionName: String = #function,
        filePath: String = #file,
        lineNumber: Int = #line,
        columnNumber: Int = #column
    ) {
        self.log(message, userInfo: userInfo, level: .Critical, functionName: functionName, filePath: filePath, lineNumber: lineNumber, columnNumber: columnNumber)
    }

}


// ======================================================================== //
// MARK: Aliases
// ======================================================================== //

@available(*, deprecated, renamed="Logger")
public typealias LXLogger = Logger      //TODO: Remove alias from LogKit 4.0


// ======================================================================== //
// MARK: Shims
// ======================================================================== //
//TODO: Remove once OSX 10.9 support is dropped.

/// Returns the global queue at QOS_CLASS_UTILITY, or DISPATCH_QUEUE_PRIORITY_LOW if QOS classes are not available.
///
/// This shim function exists to support OSX 10.9, because QOS classes are not available until OSX 10.10.
private func shim_dispatchGetQOSUtility(flags flags: UInt = 0) -> dispatch_queue_t {
    if #available(OSX 10.10, OSXApplicationExtension 10.10, *) {
        return dispatch_get_global_queue(QOS_CLASS_UTILITY, flags)
    } else {
        return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, flags)
    }
}

/// Returns the global queue at QOS_CLASS_USER_INITIATED, or DISPATCH_QUEUE_PRIORITY_DEFAULT if QOS classes are not
/// available.
///
/// This shim function exists to support OSX 10.9, because QOS classes are not available until OSX 10.10.
private func shim_dispatchGetQOSUserInitiated(flags flags: UInt = 0) -> dispatch_queue_t {
    if #available(OSX 10.10, OSXApplicationExtension 10.10, *) {
        return dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, flags)
    } else {
        return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, flags)
    }
}
