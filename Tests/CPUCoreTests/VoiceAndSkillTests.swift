@testable import CPUCore
import Foundation
import Testing

struct VoiceAndSkillTests {
    @Test func gzipRoundTrips() throws {
        let text = String(repeating: "豆包语音 streaming ASR · ", count: 200)
        let packed = Gzip.compress(Data(text.utf8))
        #expect(packed.count < text.utf8.count)
        #expect(packed.prefix(2) == Data([0x1F, 0x8B]), "gzip magic")
        let unpacked = try #require(Gzip.decompress(packed))
        #expect(String(decoding: unpacked, as: UTF8.self) == text)
    }

    @Test func parsesServerResultFrames() throws {
        // A server "full response" frame: header, sequence, size, gzip JSON.
        let json = Data(#"{"result":{"text":"给王宁发微信","utterances":[{"definite":true}]}}"#.utf8)
        let payload = Gzip.compress(json)
        var frame = Data([0x11, 0x93, 0x11, 0x00])
        frame.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFE])  // sequence -2: the last frame
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        frame.append(payload)
        let parsed = try #require(OpenSpeechFrame.parse(frame))
        #expect(parsed.final)
        #expect((parsed.json?["result"] as? [String: Any])?["text"] as? String == "给王宁发微信")
    }

    @Test func clientFramesCarryTypeAndGzip() {
        let frame = OpenSpeechFrame.make(type: 0x2, flags: 0x2, json: false, payload: Data([1, 2, 3]))
        #expect(frame[0] == 0x11)
        #expect(frame[1] == 0x22, "audio-only request, last packet")
        #expect(frame[2] == 0x01, "raw serialization, gzip")
    }

    @Test func errorFramesReportTheirCode() throws {
        let message = Gzip.compress(Data(#"{"error":"quota"}"#.utf8))
        var frame = Data([0x11, 0xF0, 0x11, 0x00])
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(45_000_001).bigEndian, Array.init))
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(message.count).bigEndian, Array.init))
        frame.append(message)
        let parsed = try #require(OpenSpeechFrame.parse(frame))
        #expect(parsed.errorCode == 45_000_001)
    }

    @Test func spokenRepliesAreShortAndPlain() {
        let reply = "已在计算器算出 **111**。结果已显示。完整记录：/Users/me/Library/Logs/CPU/runs/a.md 还有更多内容。"
        let spoken = Speaker.speakable(reply)
        #expect(spoken == "已在计算器算出 111。结果已显示。")
    }

    @Test func demonstrationBecomesReplayableCalls() throws {
        let steps = [
            DemoStep(kind: .open, app: "计算器", bundleId: "com.apple.calculator"),
            DemoStep(kind: .click, app: "计算器", bundleId: "com.apple.calculator", target: "7"),
            DemoStep(kind: .key, app: "计算器", bundleId: "com.apple.calculator", key: "return"),
            DemoStep(kind: .type, app: "备忘录", bundleId: "com.apple.Notes", text: "56")
        ]
        let calls = try #require(Agent.replayCalls(for: steps))
        #expect(calls.map { $0["tool"] as? String } == ["open", "act", "open", "act"])
        let actions = (calls[1]["input"] as? [String: Any])?["actions"] as? [[String: Any]]
        #expect(actions?.first?["target"] as? String == "7")
    }

    @Test func unlabeledClicksAreNotReplayed() {
        let steps = [DemoStep(kind: .click, app: "微信", bundleId: "com.tencent.xinWeChat", target: nil)]
        #expect(Agent.replayCalls(for: steps) == nil)
    }
}

struct EndpointingTests {
    @Test func trailingOffWaitsLonger() {
        #expect(Endpointing.looksUnfinished("这里还提到了这个基因现金流的"))
        #expect(Endpointing.looksUnfinished("帮我把这个文件，"))
        #expect(Endpointing.looksUnfinished("先打开微信然后。"))
        #expect(Endpointing.looksUnfinished("send it to Wang and"))
        #expect(!Endpointing.endpointEnds("这里还提到了这个基因现金流的"))
        #expect(Endpointing.pause(after: "那个", base: 1.1) == 1.8)
    }

    @Test func completeRequestsEndAtOnce() {
        #expect(Endpointing.endpointEnds("帮我优化一下这篇文章"))
        #expect(Endpointing.endpointEnds("打开修改后的文章。"))
        #expect(Endpointing.endpointEnds("帮我看看这个是怎么回事啊"))
        #expect(!Endpointing.endpointEnds("用它"))
        #expect(Endpointing.pause(after: "打开微信", base: 1.1) == 1.1)
    }
}
