import AESCore
import AVFoundation
import Foundation

// Development tool (macOS): inspect vault files made by either platform.
//
//   aescore-tool verify  <file.encv> <password>
//   aescore-tool decrypt <file.enc|file.encv> <password> <output>
//   aescore-tool probe   <file.mp4|file.ts>
//   aescore-tool find    <vault-base-dir> <password>
//   aescore-tool make-ts <out.encv> <password> [seconds] [rotation] [--no-audio]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    fail("usage: aescore-tool verify|decrypt|probe|find …")
}
let rest = Array(arguments.dropFirst())

switch command {
case "verify":
    guard rest.count == 2 else { fail("usage: verify <file.encv> <password>") }
    let url = URL(fileURLWithPath: rest[0])
    let header = try EncvHeader.read(from: url)
    print("header: v\(header.version) container=\(header.container) rotation=\(header.rotationDegrees) " +
        "authenticated=\(header.isAuthenticated) kdf=\(header.kdf.algorithm)/\(header.kdf.iterations)")
    print("verification: \(EncvReader.verify(url: url, secret: Secret(rest[1])))")

case "decrypt":
    guard rest.count == 3 else { fail("usage: decrypt <file> <password> <output>") }
    let url = URL(fileURLWithPath: rest[0])
    let output = URL(fileURLWithPath: rest[2])
    let secret = Secret(rest[1])
    // Sniff the magic: video thumbnails are AESP photos stored under the video's name.
    let magic = try FileHandle(forReadingFrom: url).read(upToCount: 4) ?? Data()
    if magic == Data("AESV".utf8) {
        let reader = try EncvReader(url: url, secret: secret)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        var offset: UInt64 = 0
        while offset < reader.plaintextLength {
            let chunk = try reader.read(at: offset, count: 1 << 20)
            try handle.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
        }
        try handle.close()
        print("wrote \(offset) bytes")
    } else {
        let plaintext = try ImageCrypto.open(Data(contentsOf: url), secret: secret)
        try plaintext.write(to: output)
        print("wrote \(plaintext.count) bytes")
    }

case "probe":
    guard rest.count == 1 else { fail("usage: probe <media file>") }
    let asset = AVURLAsset(url: URL(fileURLWithPath: rest[0]))
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let duration = try await asset.load(.duration)
            print(String(format: "duration: %.2f s", duration.seconds))
            for track in try await asset.load(.tracks) {
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let formats = try await track.load(.formatDescriptions)
                let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }.map { code in
                    String(bytes: withUnsafeBytes(of: code.bigEndian) { Array($0) }, encoding: .ascii) ?? "?"
                } ?? "?"
                let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
                print("track \(track.mediaType.rawValue) codec=\(codec) size=\(Int(size.width))x\(Int(size.height)) rotation=\(degrees)")
            }
        } catch {
            print("probe failed: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()

case "find":
    guard rest.count == 2 else { fail("usage: find <base dir> <password>") }
    let vault = try VaultLocator.find(Secret(rest[1]), in: URL(fileURLWithPath: rest[0]))
    print(vault?.path ?? "no vault for this password")

case "make-ts":
    guard rest.count >= 2 else { fail("usage: make-ts <out.encv> <password> [seconds] [rotation] [--no-audio]") }
    let numbers = rest.dropFirst(2).compactMap { Int($0) }
    try MakeTS.run(
        output: URL(fileURLWithPath: rest[0]), password: rest[1],
        seconds: numbers.first ?? 12, rotation: numbers.dropFirst().first ?? 90,
        audio: !rest.contains("--no-audio")
    )

default:
    fail("unknown command \(command)")
}
