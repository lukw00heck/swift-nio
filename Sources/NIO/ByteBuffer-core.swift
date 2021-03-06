//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

let sysMalloc = malloc
let sysRealloc = realloc
let sysFree = free

#if !swift(>=4.1)
    public extension UnsafeMutableRawPointer {
        public func copyMemory(from src: UnsafeRawPointer, byteCount: Int) {
            self.copyBytes(from: src, count: byteCount)
        }
    }
    public extension UnsafeMutableRawBufferPointer {
        public func copyMemory(from src: UnsafeRawBufferPointer) {
            self.copyBytes(from: src)
        }
    }
#endif

/// The preferred allocator for `ByteBuffer` values. The allocation strategy is opaque but is currently libc's
/// `malloc`, `realloc` and `free`.
///
/// - note: `ByteBufferAllocator` is thread-safe.
public struct ByteBufferAllocator {

    /// Create a fresh `ByteBufferAllocator`. In the future the allocator might use for example allocation pools and
    /// therefore it's recommended to reuse `ByteBufferAllocators` where possible instead of creating fresh ones in
    /// many places.
    public init() {
        self.init(hookedMalloc: { sysMalloc($0) },
                  hookedRealloc: { sysRealloc($0, $1) },
                  hookedFree: { sysFree($0) },
                  hookedMemcpy: { $0.copyMemory(from: $1, byteCount: $2) })
    }

    internal init(hookedMalloc: @escaping @convention(c) (Int) -> UnsafeMutableRawPointer,
                  hookedRealloc: @escaping @convention(c) (UnsafeMutableRawPointer, Int) -> UnsafeMutableRawPointer,
                  hookedFree: @escaping @convention(c) (UnsafeMutableRawPointer) -> Void,
                  hookedMemcpy: @escaping @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, Int) -> Void) {
        assert(MemoryLayout<ByteBuffer>.size <= 3 * MemoryLayout<Int>.size,
               "ByteBuffer has size \(MemoryLayout<ByteBuffer>.size) which is larger than the built-in storage of the existential containers.")
        self.malloc = hookedMalloc
        self.realloc = hookedRealloc
        self.free = hookedFree
        self.memcpy = hookedMemcpy
    }

    /// Request a freshly allocated `ByteBuffer` of size `capacity` or larger.
    ///
    /// - parameters:
    ///     - capacity: The capacity of the returned `ByteBuffer`.
    public func buffer(capacity: Int) -> ByteBuffer {
        return ByteBuffer(allocator: self, startingCapacity: capacity)
    }

    internal let malloc: @convention(c) (Int) -> UnsafeMutableRawPointer
    internal let realloc: @convention(c) (UnsafeMutableRawPointer, Int) -> UnsafeMutableRawPointer
    internal let free: @convention(c) (UnsafeMutableRawPointer) -> Void
    internal let memcpy: @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, Int) -> Void

}

private typealias Index = UInt32
private typealias Capacity = UInt32

private func toCapacity(_ value: Int) -> Capacity {
    return Capacity(truncatingIfNeeded: value)
}

private func toIndex(_ value: Int) -> Index {
    return Index(truncatingIfNeeded: value)
}

/// `ByteBuffer` stores contiguously allocated raw bytes. It is a random and sequential accessible sequence of zero or
/// more bytes (octets).
///
/// ### Allocation
/// Use `allocator.buffer(capacity: desiredCapacity)` to allocate a new `ByteBuffer`.
///
/// ### Supported types
/// A variety of types can be read/written from/to a `ByteBuffer`. Using Swift's `extension` mechanism you can easily
/// create `ByteBuffer` support for your own data types. Out of the box, `ByteBuffer` supports for example the following
/// types (non-exhaustive list):
///
///  - `String`/`StaticString`
///  - Swift's various (unsigned) integer types
///  - `Foundation`'s `Data`
///  - `[UInt8]` and generally any `Collection` (& `ContiguousCollection`) of `UInt8`
///
/// ### Random Access
/// For every supported type `ByteBuffer` usually contains two methods for random access:
///
///  1. `get<type>(at: Int, length: Int)` where `<type>` is for example `String`, `Data`, `Bytes` (for `[UInt8]`)
///  2. `set(<type>: Type, at: Int)`
///
/// Example:
///
///     var buf = ...
///     buf.set(string: "Hello World", at: 0)
///     let helloWorld = buf.getString(at: 0, length: 11)
///
///     buf.set(integer: 17 as Int, at: 11)
///     let seventeen: Int = buf.getInteger(at: 11)
///
/// If needed, `ByteBuffer` will automatically resize its storage to accommodate your `set` request.
///
/// ### Sequential Access
/// `ByteBuffer` provides two properties which are indices into the `ByteBuffer` to support sequential access:
///  - `readerIndex`, the index of the next readable byte
///  - `writerIndex`, the index of the next byte to write
///
/// For every supported type `ByteBuffer` usually contains two methods for sequential access:
///
///  1. `read<type>(length: Int)` to read `length` bytes from the current `readerIndex` (and then advance the reader index by `length` bytes)
///  2. `write(<type>: Type)` to write, advancing the `writerIndex` by the appropriate amount
///
/// Example:
///
///      var buf = ...
///      buf.write(string: "Hello World")
///      buf.write(integer: 17 as Int)
///      let helloWorld = buf.readString(length: 11)
///      let seventeen: Int = buf.readInteger()
///
/// ### Layout
///     +-------------------+------------------+------------------+
///     | discardable bytes |  readable bytes  |  writable bytes  |
///     |                   |     (CONTENT)    |                  |
///     +-------------------+------------------+------------------+
///     |                   |                  |                  |
///     0      <=      readerIndex   <=   writerIndex    <=    capacity
///
/// The 'discardable bytes' are usually bytes that have already been read, they can however still be accessed using
/// the random access methods. 'Readable bytes' are the bytes currently available to be read using the sequential
/// access interface (`read<Type>`/`write<Type>`). Getting `writableBytes` (bytes beyond the writer index) is undefined
/// behaviour and might yield aribitrary bytes (_not_ `0` initialised).
///
/// ### Slicing
/// `ByteBuffer` supports slicing a `ByteBuffer` without copying the underlying storage.
///
/// Example:
///
///     var buf = ...
///     let dataBytes: [UInt8] = [0xca, 0xfe, 0xba, 0xbe]
///     let dataBytesLength = UInt32(dataBytes.count)
///     buf.write(integer: dataBytesLength) /* the header */
///     buf.write(bytes: dataBytes) /* the data */
///     let bufDataBytesOnly = buf.getSlice(at: 4, length: dataBytes.count)
///     /* `bufDataByteOnly` and `buf` will share their storage */
///
/// ### Important usage notes
/// Each method that is prefixed with `get` is considered "unsafe" as it allows the user to read uninitialized memory if the `index` or `index + length` points outside of the previous written
/// range of the `ByteBuffer`. Because of this it's strongly advised to prefer the usage of methods that start with the `read` prefix and only use the `get` prefixed methods if there is a strong reason
/// for doing so. In any case, if you use the `get` prefixed methods you are responsible for ensuring that you do not reach into uninitialized memory by taking the `readableBytes` and `readerIndex` into
/// account, and ensuring that you have previously written into the area covered by the `index itself.
public struct ByteBuffer {
    private typealias Slice = Range<Index>
    private typealias Allocator = ByteBufferAllocator

    private var _readerIndex: Index = 0
    private var _writerIndex: Index = 0
    private var _slice: Slice
    private var _storage: _Storage

    // MARK: Internal _Storage for CoW
    private final class _Storage {
        private(set) var capacity: Capacity
        private(set) var bytes: UnsafeMutableRawPointer
        private(set) var fullSlice: Slice
        private let allocator: ByteBufferAllocator

        public init(bytesNoCopy: UnsafeMutableRawPointer, capacity: Capacity, allocator: ByteBufferAllocator) {
            self.bytes = bytesNoCopy
            self.capacity = capacity
            self.allocator = allocator
            self.fullSlice = 0..<self.capacity
        }

        deinit {
            self.deallocate()
        }

        private static func allocateAndPrepareRawMemory(bytes: Capacity, allocator: Allocator) -> UnsafeMutableRawPointer {
            let bytes = Int(bytes)
            let ptr = allocator.malloc(bytes)
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: bytes)
            return ptr
        }

        public func allocateStorage() -> _Storage {
            return self.allocateStorage(capacity: self.capacity)
        }

        private func allocateStorage(capacity: Capacity) -> _Storage {
            let newCapacity = capacity == 0 ? 0 : capacity.nextPowerOf2ClampedToMax()
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity, allocator: self.allocator),
                            capacity: newCapacity,
                            allocator: self.allocator)
        }

        public func reallocSlice(_ slice: Slice, capacity: Capacity) -> _Storage {
            assert(slice.count <= capacity)
            let new = self.allocateStorage(capacity: capacity)
            self.allocator.memcpy(new.bytes, self.bytes.advanced(by: Int(slice.lowerBound)), slice.count)
            return new
        }

        public func reallocStorage(capacity: Capacity) {
            let ptr = self.allocator.realloc(self.bytes, Int(capacity))
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: Int(capacity))
            self.bytes = ptr
            self.capacity = capacity
            self.fullSlice = 0..<self.capacity
        }

        private func deallocate() {
            self.allocator.free(self.bytes)
        }

        public static func reallocated(minimumCapacity: Capacity, allocator: Allocator) -> _Storage {
            let newCapacity = minimumCapacity == 0 ? 0 : minimumCapacity.nextPowerOf2ClampedToMax()
            // TODO: Use realloc if possible
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity, allocator: allocator),
                            capacity: newCapacity,
                            allocator: allocator)
        }

        public func dumpBytes(slice: Slice, offset: Int, length: Int) -> String {
            var desc = "["
            for i in Int(slice.lowerBound) + offset ..< Int(slice.lowerBound) + offset + length {
                let byte = self.bytes.advanced(by: i).assumingMemoryBound(to: UInt8.self).pointee
                let hexByte = String(byte, radix: 16)
                desc += " \(hexByte.count == 1 ? " " : "")\(hexByte)"
            }
            desc += " ]"
            return desc
        }
    }

    private mutating func copyStorageAndRebase(capacity: Capacity, resetIndices: Bool = false) {
        let indexRebaseAmount = resetIndices ? self._readerIndex : 0
        let storageRebaseAmount = self._slice.lowerBound + indexRebaseAmount
        let newSlice = Range(storageRebaseAmount ..< min(storageRebaseAmount + toCapacity(self._slice.count), self._slice.upperBound, storageRebaseAmount + capacity))
        self._storage = self._storage.reallocSlice(newSlice, capacity: capacity)
        self.moveReaderIndex(to: self._readerIndex - indexRebaseAmount)
        self.moveWriterIndex(to: self._writerIndex - indexRebaseAmount)
        self._slice = self._storage.fullSlice
    }

    private mutating func copyStorageAndRebase(extraCapacity: Capacity = 0, resetIndices: Bool = false) {
        self.copyStorageAndRebase(capacity: toCapacity(self._slice.count) + extraCapacity, resetIndices: resetIndices)
    }

    private mutating func ensureAvailableCapacity(_ capacity: Capacity, at index: Index) {
        assert(isKnownUniquelyReferenced(&self._storage))

        if self._slice.lowerBound + index + capacity > self._slice.upperBound {
            // double the capacity, we may want to use different strategies depending on the actual current capacity later on.
            var newCapacity = max(1, toCapacity(self.capacity))

            // double the capacity until the requested capacity can be full-filled
            repeat {
                precondition(newCapacity != Capacity.max, "cannot make ByteBuffers larger than \(newCapacity)")
                if newCapacity < (Capacity.max >> 1) {
                    newCapacity = newCapacity << 1
                } else {
                    newCapacity = Capacity.max
                }
            } while newCapacity < index || newCapacity - index < capacity

            self._storage.reallocStorage(capacity: newCapacity)
            self._slice = _slice.lowerBound..<_slice.lowerBound + newCapacity
        }
    }

    // MARK: Internal API

    private mutating func moveReaderIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= writerIndex)
        self._readerIndex = newIndex
    }

    private mutating func moveWriterIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= toCapacity(self._slice.count))
        self._writerIndex = newIndex
    }

    private mutating func set<S: ContiguousCollection>(bytes: S, at index: Index) -> Capacity where S.Element == UInt8 {
        let newEndIndex: Index = index + toIndex(Int(bytes.count))
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newEndIndex > self._slice.upperBound ? newEndIndex - self._slice.upperBound : 0
            self.copyStorageAndRebase(extraCapacity: extraCapacity)
        }

        self.ensureAvailableCapacity(Capacity(bytes.count), at: index)
        let base = self._storage.bytes.advanced(by: Int(self._slice.lowerBound + index)).assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBytes { srcPtr in
            base.assign(from: srcPtr.baseAddress!.assumingMemoryBound(to: S.Element.self), count: srcPtr.count)
        }
        return toCapacity(Int(bytes.count))
    }

    private mutating func set<S: Sequence>(bytes: S, at index: Index) -> Capacity where S.Element == UInt8 {
        assert(!([Array<S.Element>.self, StaticString.self, ContiguousArray<S.Element>.self, UnsafeRawBufferPointer.self, UnsafeBufferPointer<UInt8>.self].contains(where: { (t: Any.Type) -> Bool in t == type(of: bytes) })),
               "called the slower set<S: Sequence> function even though \(S.self) is a ContiguousCollection")
        func ensureCapacityAndReturnStorageBase(capacity: Int) -> UnsafeMutablePointer<UInt8> {
            self.ensureAvailableCapacity(Capacity(capacity), at: index)
            return self._storage.bytes.advanced(by: Int(self._slice.lowerBound + index)).assumingMemoryBound(to: UInt8.self)
        }
        let underestimatedByteCount = bytes.underestimatedCount
        let newPastEndIndex: Index = index + toIndex(underestimatedByteCount)
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newPastEndIndex > self._slice.upperBound ? newPastEndIndex - self._slice.upperBound : 0
            self.copyStorageAndRebase(extraCapacity: extraCapacity)
        }

        var base = ensureCapacityAndReturnStorageBase(capacity: underestimatedByteCount)
        var idx = 0
        for b in bytes {
            if idx >= underestimatedByteCount {
                base = ensureCapacityAndReturnStorageBase(capacity: idx + 1)
            }
            base[idx] = b
            idx += 1
        }
        return toCapacity(idx)
    }

    // MARK: Public Core API

    fileprivate init(allocator: ByteBufferAllocator, startingCapacity: Int) {
        let startingCapacity = toCapacity(startingCapacity)
        self._storage = _Storage.reallocated(minimumCapacity: startingCapacity, allocator: allocator)
        self._slice = self._storage.fullSlice
    }

    /// The number of bytes writable until `ByteBuffer` will need to grow its underlying storage which will likely
    /// trigger a copy of the bytes.
    public var writableBytes: Int { return Int(toCapacity(self._slice.count) - self._writerIndex) }

    /// The number of bytes readable (`readableBytes` = `writerIndex` - `readerIndex`).
    public var readableBytes: Int { return Int(self._writerIndex - self._readerIndex) }

    /// The current capacity of the storage of this `ByteBuffer`, this is not constant and does _not_ signify the number
    /// of bytes that have been written to this `ByteBuffer`.
    public var capacity: Int {
        return self._slice.count
    }

    /// Change the capacity to at least `to` bytes.
    ///
    /// - parameters:
    ///     - to: The desired minimum capacity.
    public mutating func changeCapacity(to newCapacity: Int) {
        precondition(newCapacity >= self.writerIndex,
                     "new capacity \(newCapacity) less than the writer index (\(self.writerIndex))")

        if newCapacity == self._storage.capacity && self._slice == self._storage.fullSlice {
            return
        }

        self.copyStorageAndRebase(capacity: toCapacity(newCapacity))
    }

    private mutating func copyStorageAndRebaseIfNeeded() {
        if !isKnownUniquelyReferenced(&self._storage) {
            self.copyStorageAndRebase()
        }
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify those bytes.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes.
    /// - returns: The value returned by `fn`.
    public mutating func withUnsafeMutableReadableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self.copyStorageAndRebaseIfNeeded()
        return try body(UnsafeMutableRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                                                    count: self.readableBytes))
    }

    /// Yields the bytes currently writable (`bytesWritable` = `capacity` - `writerIndex`). Before reading those bytes you must first
    /// write to them otherwise you will trigger undefined behaviour. The writer index will remain unchanged.
    ///
    /// - note: In almost all cases you should use `writeWithUnsafeMutableBytes` which will move the write pointer instead of this method
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and return the number of bytes written.
    /// - returns: The number of bytes written.
    public mutating func withUnsafeMutableWritableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self.copyStorageAndRebaseIfNeeded()
        return try body(UnsafeMutableRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._writerIndex)),
                                                    count: self.writableBytes))
    }

    @discardableResult
    public mutating func writeWithUnsafeMutableBytes(_ body: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesWritten = try withUnsafeMutableWritableBytes(body)
        self.moveWriterIndex(to: self._writerIndex + toIndex(bytesWritten))
        return bytesWritten
    }

    /// This vends a pointer to the storage of the `ByteBuffer`. It's marked as _very unsafe_ because it might contain
    /// uninitialised memory and it's undefined behaviour to read it. In most cases you should use `withUnsafeReadableBytes`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    public func withVeryUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try body(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound)),
                                             count: self._slice.count))
    }

    /// Yields a buffer pointer containing this `ByteBuffer`'s readable bytes.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes.
    /// - returns: The value returned by `fn`.
    public func withUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try body(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                                             count: self.readableBytes))
    }

    /// Yields a buffer pointer containing this `ByteBuffer`'s readable bytes. You may hold a pointer to those bytes
    /// even after the closure returned iff you model the lifetime of those bytes correctly using the `Unmanaged`
    /// instance. If you don't require the pointer after the closure returns, use `withUnsafeReadableBytes`.
    ///
    /// If you escape the pointer from the closure, you _must_ call `storageManagement.retain()` to get ownership to
    /// the bytes and you also must call `storageManagement.release()` if you no longer require those bytes. Calls to
    /// `retain` and `release` must be balanced.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and the `storageManagement`.
    /// - returns: The value returned by `fn`.
    public func withUnsafeReadableBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        return try body(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                                             count: self.readableBytes), storageReference)
    }

    /// See `withUnsafeReadableBytesWithStorageManagement` and `withVeryUnsafeBytes`.
    public func withVeryUnsafeBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        return try body(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound)),
                                             count: self._slice.count), storageReference)
    }

    /// Returns a slice of size `length` bytes, starting at `index`. The `ByteBuffer` this is invoked on and the
    /// `ByteBuffer` returned will share the same underlying storage. However, the byte at `index` in this `ByteBuffer`
    /// will correspond to index `0` in the returned `ByteBuffer`.
    /// The `readerIndex` of the returned `ByteBuffer` will be `0`, the `writerIndex` will be `length`.
    ///
    /// - parameters:
    ///     - index: The index the requested slice starts at.
    ///     - length: The length of the requested slice.
    public func getSlice(at index: Int, length: Int) -> ByteBuffer? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        guard index <= self.capacity - length else {
            return nil
        }
        let index = toIndex(index)
        let length = toCapacity(length)
        var new = self
        new._slice = self._slice.lowerBound + index ..< self._slice.lowerBound + index+length
        new.moveReaderIndex(to: 0)
        new.moveWriterIndex(to: length)
        return new
    }

    /// Discard the bytes before the reader index. The byte at index `readerIndex` before calling this method will be
    /// at index `0` after the call returns.
    ///
    /// - returns: `true` if one or more bytes have been discarded, `false` if there are no bytes to discard.
    @discardableResult public mutating func discardReadBytes() -> Bool {
        guard self._readerIndex > 0 else {
            return false
        }

        if isKnownUniquelyReferenced(&self._storage) {
            self._storage.bytes.advanced(by: Int(self._slice.lowerBound))
                .copyMemory(from: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                            byteCount: self.readableBytes)
            let indexShift = self._readerIndex
            self.moveReaderIndex(to: 0)
            self.moveWriterIndex(to: self._writerIndex - indexShift)
        } else {
            self.copyStorageAndRebase(extraCapacity: 0, resetIndices: true)
        }
        return true
    }

    /// The reader index or the number of bytes previously read from this `ByteBuffer`. `readerIndex` is `0` for a
    /// newly allocated `ByteBuffer`.
    public var readerIndex: Int {
        return Int(self._readerIndex)
    }

    /// The write index or the number of bytes previously written to this `ByteBuffer`. `writerIndex` is `0` for a
    /// newly allocated `ByteBuffer`.
    public var writerIndex: Int {
        return Int(self._writerIndex)
    }

    /// Set both reader index and writer index to `0`. This will reset the state of this `ByteBuffer` to the state
    /// of a freshly allocated one, if possible without allocations. This is the cheapest way to recycle a `ByteBuffer`
    /// for a new use-case.
    ///
    /// - note: This method will allocate if the underlying storage is referenced by another `ByteBuffer`. Even if an
    ///         allocation is necessary this will be cheaper as the copy of the storage is elided.
    public mutating func clear() {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.allocateStorage()
        }
        self.moveWriterIndex(to: 0)
        self.moveReaderIndex(to: 0)
    }
}

extension ByteBuffer: CustomStringConvertible {
    /// A `String` describing this `ByteBuffer`. Example:
    ///
    ///     ByteBuffer { readerIndex: 0, writerIndex: 4, readableBytes: 4, capacity: 512, slice: 256..<768, storage: 0x0000000103001000 (1024 bytes)}
    ///
    /// The format of the description is not API.
    ///
    /// - returns: A description of this `ByteBuffer`.
    public var description: String {
        return  "ByteBuffer { " +
            /*    this     */ "readerIndex: \(self.readerIndex), " +
            /*     is      */ "writerIndex: \(self.writerIndex), " +
            /*     to      */ "readableBytes: \(self.readableBytes), " +
            /*    help     */ "capacity: \(self.capacity), " +
            /*    Xcode    */ "slice: \(self._slice), " +
            /*   indent    */ "storage: \(self._storage.bytes) (\(self._storage.capacity) bytes)" +
            /*             */ "}"
    }

    /// A `String` describing this `ByteBuffer` with some portion of the readable bytes dumped too. Example:
    ///
    ///     ByteBuffer { readerIndex: 0, writerIndex: 4, readableBytes: 4, capacity: 512, slice: 256..<768, storage: 0x0000000103001000 (1024 bytes)}
    ///     readable bytes (max 1k): [ 00 01 02 03 ]
    ///
    /// The format of the description is not API.
    ///
    /// - returns: A description of this `ByteBuffer` useful for debugging.
    public var debugDescription: String {
        return "\(self.description)\nreadable bytes (max 1k): \(self._storage.dumpBytes(slice: self._slice, offset: self.readerIndex, length: min(1024, self.readableBytes)))"
    }
}

/// A `Collection` that is contiguously layed out in memory and can therefore be duplicated using `memcpy`.
public protocol ContiguousCollection: Collection {
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

extension StaticString: Collection {
    public typealias Element = UInt8
    public typealias SubSequence = ArraySlice<UInt8>

    public typealias Index = Int

    public var startIndex: Index { return 0 }
    public var endIndex: Index { return self.utf8CodeUnitCount }
    public func index(after i: Index) -> Index { return i + 1 }

    public subscript(position: Int) -> StaticString.Element {
        get {
            return self[position]
        }
    }
}

extension Array: ContiguousCollection {}
extension ContiguousArray: ContiguousCollection {}
extension StaticString: ContiguousCollection {
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(UnsafeRawBufferPointer(start: self.utf8Start, count: self.utf8CodeUnitCount))
    }
}
extension UnsafeRawBufferPointer: ContiguousCollection {
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(self)
    }
}
extension UnsafeBufferPointer: ContiguousCollection {
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(UnsafeRawBufferPointer(self))
    }
}

/* change types to the user visible `Int` */
extension ByteBuffer {
    /// Copy the collection of `bytes` into the `ByteBuffer` at `index`.
    @discardableResult
    public mutating func set<S: Sequence>(bytes: S, at index: Int) -> Int where S.Element == UInt8 {
        return Int(self.set(bytes: bytes, at: toIndex(index)))
    }

    /// Copy the collection of `bytes` into the `ByteBuffer` at `index`.
    @discardableResult
    public mutating func set<S: ContiguousCollection>(bytes: S, at index: Int) -> Int where S.Element == UInt8 {
        return Int(self.set(bytes: bytes, at: toIndex(index)))
    }

    /// Move the reader index forward by `offset` bytes.
    public mutating func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= writerIndex, "new readerIndex: \(newIndex), expected: range(0, \(writerIndex))")
        self.moveReaderIndex(to: newIndex)
    }

    /// Set the reader index to `offset`.
    public mutating func moveReaderIndex(to offset: Int) {
        let newIndex = toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= writerIndex, "new readerIndex: \(newIndex), expected: range(0, \(writerIndex))")
        self.moveReaderIndex(to: newIndex)
    }

    /// Move the writer index forward by `offset` bytes.
    public mutating func moveWriterIndex(forwardBy offset: Int) {
        let newIndex = self._writerIndex + toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= toCapacity(self._slice.count),"new writerIndex: \(newIndex), expected: range(0, \(toCapacity(self._slice.count)))")
        self.moveWriterIndex(to: newIndex)
    }

    /// Set the writer index to `offset`.
    public mutating func moveWriterIndex(to offset: Int) {
        let newIndex = toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= toCapacity(self._slice.count),"new writerIndex: \(newIndex), expected: range(0, \(toCapacity(self._slice.count)))")
        self.moveWriterIndex(to: newIndex)
    }
}

extension ByteBuffer: Equatable {
    // TODO: I don't think this makes sense. This should compare bytes 0..<writerIndex instead.

    /// Compare two `ByteBuffer` values. Two `ByteBuffer` values are considered equal if the readable bytes are equal.
    public static func ==(lhs: ByteBuffer, rhs: ByteBuffer) -> Bool {
        guard lhs.readableBytes == rhs.readableBytes else {
            return false
        }

        if lhs._slice == rhs._slice && lhs._storage === rhs._storage {
            return true
        }

        return lhs.withUnsafeReadableBytes { lPtr in
            rhs.withUnsafeReadableBytes { rPtr in
                // Shouldn't get here otherwise because of readableBytes check
                assert(lPtr.count == rPtr.count)
                return memcmp(lPtr.baseAddress!, rPtr.baseAddress!, lPtr.count) == 0
            }
        }
    }
}
