@_implementationOnly import CTurboPFor
@_implementationOnly import CHelper
import Foundation

/// Write an om file and write multiple chunks of data
public final class OmFileEncoder {
    /// The scalefactor that is applied to all write data
    public let scalefactor: Float
    
    /// Type of compression and coding. E.g. delta, zigzag coding is then implemented in different compression routines
    public let compression: CompressionType
    
    /// The dimensions of the file
    let dims: [Int]
    
    /// How the dimensions are chunked
    let chunks: [Int]
    
    
    /// Store all byte offsets where our compressed chunks start. Later, we want to decompress chunk 1234 and know it starts at byte offset 5346545
    private var chunkOffsetBytes: [Int]
    
    /// Buffer where chunks are moved to, before compression them. => input for compression call
    private var chunkBuffer: UnsafeMutableRawBufferPointer
    
    /// All data is written to this buffer. The current offset is in `writeBufferPos`. This buffer must be written out before it is full.
    private var writeBuffer: UnsafeMutableBufferPointer<UInt8>
        
    public var writeBufferPos = 0
    
    public var totalBytesWritten = 0
    
    /// Position of last chunk that has been written
    public var chunkIndex: Int = 0

    
    /// Return the total number of chunks in this file
    func number_of_chunks() -> Int {
        var n = 1
        for i in 0..<dims.count {
            n *= dims[i].divideRoundedUp(divisor: chunks[i])
        }
        return n
    }
    
    
    /**
     Write new or overwrite new compressed file. Data must be supplied with a closure which supplies the current position in dimension 0. Typically this is the location offset. The closure must return either an even number of elements of `chunk0 * dim1` elements or all remainig elements at once.
     
     One chunk should be around 2'000 to 16'000 elements. Fewer or more are not usefull!
     
     Note: `chunk0` can be a uneven multiple of `dim0`. E.g. for 10 location, we can use chunks of 3, so the last chunk will only cover 1 location.
     */
    public init(dimensions: [Int], chunkDimensions: [Int], compression: CompressionType, scalefactor: Float) {
        var nChunks = 1
        for i in 0..<dimensions.count {
            nChunks *= dimensions[i].divideRoundedUp(divisor: chunkDimensions[i])
        }
        
        let chunkSizeByte = chunkDimensions.reduce(1, *) * 4
        if chunkSizeByte > 1024 * 1024 * 4 {
            print("WARNING: Chunk size greater than 4 MB (\(Float(chunkSizeByte) / 1024 / 1024) MB)!")
        }
        
        self.chunkOffsetBytes = .init(repeating: 0, count: nChunks)
        self.dims = dimensions
        self.chunks = chunkDimensions
        self.scalefactor = scalefactor
        self.compression = compression
        
        let bufferSize = P4NENC256_BOUND(n: chunkDimensions.reduce(1, *), bytesPerElement: 4)
        
        // Read buffer needs to be a bit larger for AVX 256 bit alignment
        self.chunkBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 4)
        self.writeBuffer = .allocate(capacity: max(1024 * 1024, bufferSize))
    }
    
    public func writeHeader<FileHandle: OmFileWriterBackend>(fn: FileHandle) throws {
        writeHeader()
        try fn.write(contentsOf: writeBuffer[0..<writeBufferPos].map({$0}))
        writeBufferPos = 0
    }
    public func writeTrailer<FileHandle: OmFileWriterBackend>(fn: FileHandle) throws {
        self.writeTrailer()
        try fn.write(contentsOf: writeBuffer[0..<writeBufferPos].map({$0}))
        writeBufferPos = 0
    }
    /// Can be all, a single or multiple chunks
    public func writeData<FileHandle: OmFileWriterBackend>(array: [Float], arrayDimensions: [Int], arrayRead: [Range<Int>], fn: FileHandle) throws {
        // TODO check dimensions of arrayDimensions and arrayRead
        var q: Int? = 0
        while let qIn = q {
            q = writeNextChunks(array: array, arrayDimensions: arrayDimensions, arrayRead: arrayRead, cOffset: qIn)
            try fn.write(contentsOf: writeBuffer[0..<writeBufferPos].map({$0}))
            writeBufferPos = 0
        }
    }
    
    /// Write header, data and trailer
    public func write<FileHandle: OmFileWriterBackend>(array: [Float], arrayDimensions: [Int], arrayRead: [Range<Int>], fn: FileHandle) throws {
        try writeHeader(fn: fn)
        try writeData(array: array, arrayDimensions: arrayDimensions, arrayRead: arrayRead, fn: fn)
        try writeTrailer(fn: fn)
    }
    
    public func writeTrailer() {
        let lutStart = totalBytesWritten
        //print("LUT start \(lutStart), \(chunkOffsetBytes)")
        let len = chunkOffsetBytes.withUnsafeBytes({
            memcpy(writeBuffer.baseAddress!.advanced(by: writeBufferPos), $0.baseAddress!, $0.count)
            return $0.count
        })
        writeBufferPos += len
        totalBytesWritten += len
        
        // TODO: pad to 64 bit
        
        let len2 = dims.withUnsafeBytes({
            memcpy(writeBuffer.baseAddress!.advanced(by: writeBufferPos), $0.baseAddress!, $0.count)
            return $0.count
        })
        writeBufferPos += len2
        totalBytesWritten += len2
        
        let len3 = chunks.withUnsafeBytes({
            memcpy(writeBuffer.baseAddress!.advanced(by: writeBufferPos), $0.baseAddress!, $0.count)
            return $0.count
        })
        writeBufferPos += len3
        totalBytesWritten += len3
        
        // n dimensions
        writeBuffer.baseAddress!.advanced(by: writeBufferPos).assumingMemoryBound(to: Int.self, capacity: 1)[0] = dims.count
        writeBufferPos += 8
        totalBytesWritten += 8
        
        // LUT start offset
        writeBuffer.baseAddress!.advanced(by: writeBufferPos).assumingMemoryBound(to: Int.self, capacity: 1)[0] = lutStart
        writeBufferPos += 8
        totalBytesWritten += 8
        
        // TODO LUT compressed chunk size
    }
    
    /// Data must be exactly of the size of the next chunk or chunks!
    /// Return true if all inpupt data base been processed
    ///
    /// `cOffset=0` if chunks are feed one by one
    /// Otherwise `cOffset` is incremented while looping over a large array
    public func writeNextChunks(array: [Float], arrayDimensions: [Int], arrayRead: [Range<Int>], cOffset: Int) -> Int? {
        assert(array.count == arrayDimensions.reduce(1, *))
        
        var cOffset = cOffset
        
        var number_of_chunks_in_array = 1
        for i in 0..<dims.count {
            number_of_chunks_in_array *= arrayRead[i].count.divideRoundedUp(divisor: chunks[i])
        }
        
        while true {
            // Calculate number of elements in this chunk
            var rollingMultiplty = 1
            var rollingMultiplyChunkLength = 1
            var rollingMultiplyTargetCube = 1
            
            /// Read coordinate from input array
            var q = 0
            
            var d = 0
            
            /// Copy multiple elements from the decoded chunk into the output buffer. For long time-series this drastically improves copy performance.
            var linearReadCount = 1
            
            /// Internal state to keep track if everything is kept linear
            var linearRead = true
            
            /// Used for 2d delta coding
            var lengthLast = 0
            
            /// Count length in chunk and find first buffer offset position
            for i in (0..<dims.count).reversed() {
                let nChunksInThisDimension = dims[i].divideRoundedUp(divisor: chunks[i])
                let c0 = (chunkIndex / rollingMultiplty) % nChunksInThisDimension
                let c0Offset = (cOffset / rollingMultiplty) % nChunksInThisDimension
                let length0 = min((c0+1) * chunks[i], dims[i]) - c0 * chunks[i]
                //let chunkGlobal0 = c0 * chunks[i] ..< c0 * chunks[i] + length0
                //let clampedGlobal0 = chunkGlobal0//.clamped(to: dimRead[i])
                //let clampedLocal0 = clampedGlobal0.substract(c0 * chunks[i])
                
                if i == dims.count-1 {
                    lengthLast = length0
                }

                q = q + rollingMultiplyTargetCube * (c0Offset * chunks[i] + arrayRead[i].lowerBound)
                //print("i", i, "arrayRead[i].count", arrayRead[i].count, "length0", length0, "arrayDimensions[i]", arrayDimensions[i])
                assert(length0 <= arrayRead[i].count)
                assert(length0 <= arrayDimensions[i])
                if i == dims.count-1 && !(arrayRead[i].count == length0 && arrayDimensions[i] == length0) {
                    // if fast dimension and only partially read
                    linearReadCount = length0
                    linearRead = false
                }
                if linearRead && arrayRead[i].count == length0 && arrayDimensions[i] == length0 {
                    // dimension is read entirely
                    // and can be copied linearly into the output buffer
                    linearReadCount *= length0
                } else {
                    // dimension is read partly, cannot merge further reads
                    linearRead = false
                }
           
                rollingMultiplty *= nChunksInThisDimension
                rollingMultiplyTargetCube *= arrayDimensions[i]
                rollingMultiplyChunkLength *= length0
            }
            
            /// How many elements are in this chunk
            let lengthInChunk = rollingMultiplyChunkLength
            
            //print("compress chunk \(chunkIndex) lengthInChunk \(lengthInChunk)")
            
            // loop over elements to read and move to target buffer. Apply scalefactor and convert UInt16
            loopBuffer: while true {
                //print("q=\(q) d=\(d), count=\(linearReadCount)")
                //linearReadCount = 1
                for i in 0..<linearReadCount {
                    assert(q+i < array.count)
                    assert(d+i < lengthInChunk)
                    let val = array[q+i]
                    //print("WRITE ",val)
                    if val.isNaN {
                        // Int16.min is not representable because of zigzag coding
                        chunkBuffer.assumingMemoryBound(to: Int16.self)[d+i] = Int16.max
                    }
                    let scaled = compression == .p4nzdec256logarithmic ? (log10(1+val) * scalefactor) : (val * scalefactor)
                    chunkBuffer.assumingMemoryBound(to: Int16.self)[d+i] = Int16(max(Float(Int16.min), min(Float(Int16.max), round(scaled))))
                }
                q += linearReadCount-1
                d += linearReadCount-1
                d += 1
                
                // Move `q` to next position
                rollingMultiplyTargetCube = 1
                linearRead = true
                linearReadCount = 1
                for i in (0..<dims.count).reversed() {
                    let qPos = ((q / rollingMultiplyTargetCube) % arrayDimensions[i] - arrayRead[i].lowerBound) / chunks[i]
                    let length0 = min((qPos+1) * chunks[i], arrayRead[i].count) - qPos * chunks[i]
                    
                    /// More forward
                    q += rollingMultiplyTargetCube
                    
                    if i == dims.count-1 && !(arrayRead[i].count == length0 && arrayDimensions[i] == length0) {
                        // if fast dimension and only partially read
                        linearReadCount = length0
                        linearRead = false
                    }
                    if linearRead && arrayRead[i].count == length0 && arrayDimensions[i] == length0 {
                        // dimension is read entirely
                        // and can be copied linearly into the output buffer
                        linearReadCount *= length0
                    } else {
                        // dimension is read partly, cannot merge further reads
                        linearRead = false
                    }
                    let q0 = ((q / rollingMultiplyTargetCube) % arrayDimensions[i] - arrayRead[i].lowerBound) % chunks[i]
                    if q0 != 0 && q0 != length0 {
                        break // no overflow in this dimension, break
                    }
                    q -= length0 * rollingMultiplyTargetCube
                    
                    rollingMultiplyTargetCube *= arrayDimensions[i]
                    if i == 0 {
                        // All chunks have been read. End of iteration
                        break loopBuffer
                    }
                }
            }
            
            // 2D encoding
            delta2d_encode(lengthInChunk / lengthLast, lengthLast, chunkBuffer.assumingMemoryBound(to: Int16.self).baseAddress)
            
            // Compress chunk
            let writeLength = p4nzenc128v16(chunkBuffer.assumingMemoryBound(to: UInt16.self).baseAddress!, lengthInChunk, writeBuffer.baseAddress!.advanced(by: writeBufferPos))
            //print("compressed size", writeLength, "lengthInChunk", lengthInChunk, "start offset", totalBytesWritten)
            writeBufferPos += writeLength
            totalBytesWritten += writeLength
            
            // Store chunk offset in LUT
            // TODO: `-3` to remove the header size. Reconsider this impl
            chunkOffsetBytes[chunkIndex] = totalBytesWritten - 3
            chunkIndex += 1
            cOffset += 1
            
            //print("cOffset", cOffset, "number_of_chunks_in_array", number_of_chunks_in_array)
            if cOffset == number_of_chunks_in_array {
                return nil
            }
            
            // TODO: Only return if buffer is getting full
            return cOffset
        }
    }
    
    deinit {
        chunkBuffer.deallocate()
        writeBuffer.deallocate()
    }
    
    /// Write header
    public func writeHeader() {
        writeBuffer[writeBufferPos + 0] = OmHeader.magicNumber1
        writeBuffer[writeBufferPos + 1] = OmHeader.magicNumber2
        writeBuffer[writeBufferPos + 2] = 3
        writeBufferPos += 3
        totalBytesWritten += 3
    }
}
