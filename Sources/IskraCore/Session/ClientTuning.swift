import MatrixRustSDK

extension ClientBuilder {
    /// How hard the client works, and for whom — the app, or the notification extension.
    ///
    /// - **Retries.** Without a request config the SDK does not retry a request the server turned
    ///   away with "too many requests": it fails, and the user sees a message that did not send.
    ///   Three, as element-x does; one in the extension, which has seconds to live, not minutes. No
    ///   timeout and no concurrency cap are set — sliding sync holds its requests open on purpose,
    ///   and a fixed timeout would cut the long poll short.
    /// - **The extension's size.** Told the process it lives in is small — 24 MB, killed past it —
    ///   so the SDK sizes its caches for that, as element-x's extension does. Backups and
    ///   cross-signing are not set up from there either (see `makeClientBuilder`): that is the
    ///   app's work, and starting it from a process with seconds to live is how it gets half done.
    func tuned(forPush: Bool) -> ClientBuilder {
        let retrying = requestConfig(config: RequestConfig(retryLimit: forPush ? 1 : 3, timeout: nil,
                                                           maxConcurrentRequests: nil, maxRetryTime: nil))
        // Threads, client-side: the room's timeline can leave thread answers out and summarise them
        // under their root, and a thread can be opened as a timeline of its own. See
        // `TimelineStore.threadRootID`. Subscriptions (MSC4306) are left off — no server speaks it.
        let threaded = retrying.threadsEnabled(enabled: true, threadSubscriptions: false)
        return forPush ? threaded.systemIsMemoryConstrained() : threaded
    }
}
