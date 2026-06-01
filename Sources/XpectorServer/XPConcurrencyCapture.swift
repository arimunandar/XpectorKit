import Foundation
import XpectorKit

final class XPConcurrencyCapture {

    static func captureSnapshot(activeNetworkTasks: Int = 0) -> XPThreadSnapshot {
        var threads: [XPThreadInfo] = []
        var queueLabelCounts: [String: Int] = [:]

        let mainMachThread = pthread_mach_thread_np(pthread_self())
        let isCalledFromMain = Thread.isMainThread
        let mainThreadStack = isCalledFromMain ? Thread.callStackSymbols : nil

        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)

        guard kr == KERN_SUCCESS, let list = threadList else {
            return XPThreadSnapshot(threads: [], gcdQueues: [], activeNetworkTasks: activeNetworkTasks)
        }

        defer {
            let listSize = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), listSize)
        }

        for i in 0..<Int(threadCount) {
            let thread = list[i]

            // --- Thread identifier info ---
            var identInfo = thread_identifier_info_data_t()
            var identInfoCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let identKR = withUnsafeMutablePointer(to: &identInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(identInfoCount)) { intPtr in
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), intPtr, &identInfoCount)
                }
            }

            let threadID: UInt32
            if identKR == KERN_SUCCESS {
                threadID = UInt32(truncatingIfNeeded: identInfo.thread_id)
            } else {
                threadID = UInt32(i)
            }

            // --- Thread name via pthread ---
            let threadName = Self.threadName(for: thread, fallbackIndex: i)

            // --- Main thread detection ---
            let isMain: Bool
            if i == 0 {
                // Thread 0 is conventionally the main thread on Apple platforms
                isMain = true
            } else {
                isMain = (thread == mainMachThread) && isCalledFromMain
            }

            // --- QoS class ---
            let qos = Self.qosClass(for: thread)

            // --- Stack trace ---
            // We can only reliably get stack symbols for the current thread.
            let stackTrace: [String]?
            if thread == mainMachThread && isCalledFromMain {
                stackTrace = mainThreadStack
            } else if isMain && !isCalledFromMain {
                // We are not on the main thread; cannot capture main thread stack in v1
                stackTrace = nil
            } else {
                stackTrace = nil
            }

            // --- GCD queue label parsing ---
            if let name = threadName {
                let label = Self.extractQueueLabel(from: name)
                if let label {
                    queueLabelCounts[label, default: 0] += 1
                }
            }

            threads.append(XPThreadInfo(
                id: threadID,
                name: threadName,
                isMainThread: isMain,
                qosClass: qos,
                stackTrace: stackTrace
            ))
        }

        let gcdQueues = queueLabelCounts.map { label, count in
            XPGCDQueueInfo(label: label, pendingCount: count)
        }.sorted { $0.label < $1.label }

        return XPThreadSnapshot(
            threads: threads,
            gcdQueues: gcdQueues,
            activeNetworkTasks: activeNetworkTasks
        )
    }

    // MARK: - Thread Name

    private static func threadName(for machThread: thread_act_t, fallbackIndex: Int) -> String? {
        // Convert the Mach thread port to a pthread handle, then read the name.
        let handle = pthread_from_mach_thread_np(machThread)
        if handle != nil {
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
            defer { buf.deallocate() }
            buf[0] = 0
            if pthread_getname_np(handle!, buf, 256) == 0 && buf[0] != 0 {
                return String(cString: buf)
            }
        }

        // For the main thread (index 0), provide a well-known name
        if fallbackIndex == 0 {
            return "main"
        }

        return nil
    }

    // MARK: - QoS Class

    private static func qosClass(for thread: thread_act_t) -> String? {
        // Use thread_extended_info to get the thread priority, then map to QoS class.
        // THREAD_QOS_POLICY is not in the public SDK headers, so we infer QoS
        // from the Mach scheduling priority ranges.
        var extInfo = thread_extended_info_data_t()
        var extCount = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &extInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(extCount)) { intPtr in
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), intPtr, &extCount)
            }
        }

        guard kr == KERN_SUCCESS else { return nil }

        return Self.qosFromPriority(extInfo.pth_curpri)
    }

    private static func qosFromPriority(_ priority: Int32) -> String {
        // Mach scheduling priority ranges (from osfmk/kern/sched.h):
        //   47  = user interactive (main thread default)
        //   37  = user initiated
        //   31  = default
        //   20  = utility
        //    4  = background
        //    4  = maintenance (lowest)
        // These are approximate; exact thresholds can shift between OS versions.
        switch priority {
        case 46...:  return "userInteractive"
        case 33...45: return "userInitiated"
        case 25...32: return "default"
        case 17...24: return "utility"
        case 5...16:  return "background"
        case ...4:    return "maintenance"
        default:      return "default"
        }
    }

    // MARK: - GCD Queue Label Extraction

    private static func extractQueueLabel(from threadName: String) -> String? {
        let name = threadName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "main" {
            return nil
        }

        // GCD worker threads often have names like "com.apple.main-thread",
        // "com.apple.root.default-qos", or custom queue labels.
        // Dispatch queue labels are typically set as the thread name.
        // Filter out generic GCD root pool names that are not useful.
        let genericPrefixes = [
            "com.apple.root.",
            "com.apple.libdispatch-manager",
            "com.apple.NSURLSession-work",
        ]

        for prefix in genericPrefixes {
            if name.hasPrefix(prefix) {
                return nil
            }
        }

        // Accept anything that looks like a reverse-DNS label or known queue pattern
        if name.contains(".") || name.contains("-queue") || name.contains("Queue") {
            return name
        }

        return name
    }
}
