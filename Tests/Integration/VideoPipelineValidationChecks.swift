import Foundation
import CryptoKit
import PlayerCore

@main struct VideoPipelineValidationChecks {
    static let paths = ["/owned/" + String(repeating: "a", count: 64) + ".glsl",
                        "/owned/" + String(repeating: "b", count: 64) + ".glsl"]
    static let names = ["First", "Second"]
    static func hooks() -> [[String: Any]] {
        zip(paths, names).map { ["path": $0.0, "desc": $0.1, "hook": "MAIN", "submitted": true] }
    }
    static func render(sequence: Int, processed: Bool, hooks: [[String: Any]]) -> [String: Any] {
        ["generation": 3, "sequence": sequence, "frame-id": "18446744073709551615",
         "completed": true, "has-frame": true, "processed-frame": processed,
         "offscreen": false, "success": true, "broken-frame": false, "shader-error": false,
         "resource-error": false, "overflow": false, "hooks": hooks]
    }
    static func fixture() -> [String: Any] {
        ["version": 1, "generation": 3, "sequence": 12, "last-failure-sequence": 0,
         "overflow": false, "configured-shaders": paths,
         "current": render(sequence: 12, processed: false, hooks: []),
         "last-successful-processed": render(sequence: 10, processed: true, hooks: hooks())]
    }
    static func positive(_ raw: [String: Any], before: Int64 = 9) -> Bool {
        guard let proof = try? VideoPipelineValidation.parse(raw) else { return false }
        return proof.confirmed(sequenceAfter: before, paths: paths, descriptions: names)?.count == 2
    }
    static func main() throws {
        var raw = fixture()
        raw["current"] = render(sequence: 12, processed: true, hooks: hooks())
        raw["last-successful-processed"] = raw["current"]
        precondition(positive(raw), "actual processed receipt accepted independently of decoded-frame counter")
        print("PASS native-proof-processed-same-frame")

        precondition(positive(fixture()), "same-generation cache retains real earlier processed receipt")
        print("PASS native-proof-cached-success-requires-real-processing")

        precondition(!positive(fixture(), before: 12), "old native sequence cannot satisfy a new display request")
        raw = fixture(); raw["generation"] = 4
        precondition(!positive(raw), "prior pipeline generation rejected")
        raw = fixture(); var current = raw["current"] as! [String: Any]; current["sequence"] = 11; raw["current"] = current
        precondition(!positive(raw), "outer/current native sequence mismatch rejected")
        print("PASS native-proof-sequence-and-generation")

        raw = fixture(); raw["last-failure-sequence"] = 11
        precondition(!positive(raw), "failure newer than processed success cannot be hidden by cache")
        raw["last-failure-sequence"] = 10
        precondition(!positive(raw), "equal failure/success boundary is not a later success")
        print("PASS native-proof-failure-after-success")

        for key in ["shader-error", "resource-error", "broken-frame"] {
            raw = fixture(); current = raw["current"] as! [String: Any]; current[key] = true; raw["current"] = current
            precondition(!positive(raw), "failed native state rejected even if API return and DESC are positive")
        }
        print("PASS native-proof-cached-compile-and-resource-failure")

        for mutation in 0..<5 {
            raw = fixture(); var processed = raw["last-successful-processed"] as! [String: Any]; var rows = hooks()
            if mutation == 0 { rows.reverse() }
            if mutation == 1 { rows[0]["path"] = "/foreign/source.glsl" }
            if mutation == 2 { rows[0]["desc"] = "same label, wrong shader" }
            if mutation == 3 { rows[0]["hook"] = "OUTPUT" }
            if mutation == 4 { rows[0]["submitted"] = false }
            processed["hooks"] = rows; raw["last-successful-processed"] = processed
            precondition(!positive(raw), "exact managed path/DESC/MAIN/ordered submission required")
        }
        raw = fixture(); raw["configured-shaders"] = paths.reversed().map { $0 }
        precondition(!positive(raw), "readback list must equal exact ordered managed paths")
        print("PASS native-proof-exact-path-description-hook-order")

        for key in ["offscreen", "overflow"] {
            raw = fixture(); current = raw["current"] as! [String: Any]; current[key] = true; raw["current"] = current
            precondition(!positive(raw), "offscreen/overflow current is not display proof")
        }
        for key in ["has-frame", "completed", "success"] {
            raw = fixture(); current = raw["current"] as! [String: Any]; current[key] = false; raw["current"] = current
            precondition(!positive(raw), "blank/incomplete/unsuccessful output rejected")
        }
        raw = fixture(); var processed = raw["last-successful-processed"] as! [String: Any]; processed["offscreen"] = true; raw["last-successful-processed"] = processed
        precondition(!positive(raw), "offscreen history cannot certify actual processed display")
        print("PASS native-proof-offscreen-empty-and-overflow")

        let invalidSequences: [Any] = [true, 12.0, -1, "12"]
        for value in invalidSequences {
            raw = fixture(); raw["sequence"] = value
            precondition(!positive(raw), "native integer type is strict")
        }
        raw = fixture(); raw["version"] = 2; precondition(!positive(raw), "unknown protocol version rejected")
        raw = fixture(); raw["extra"] = true; precondition(!positive(raw), "unknown shape rejected")
        raw = fixture(); current = raw["current"] as! [String: Any]; current["frame-id"] = "18446744073709551616"; raw["current"] = current
        precondition(!positive(raw), "unsigned frame identity cannot overflow")
        raw = fixture(); processed = raw["last-successful-processed"] as! [String: Any]; var longHooks = hooks(); longHooks[0]["desc"] = String(repeating: "x", count: 129); processed["hooks"] = longHooks; raw["last-successful-processed"] = processed
        precondition(!positive(raw), "truncated descriptor is not complete identity")
        print("PASS native-proof-strict-types-shape-and-bounds")

        let capturedURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CachedShaderFailureSource31.json")
        let capturedData = try Data(contentsOf: capturedURL)
        precondition(capturedData.count == 4344 && SHA256.hash(data: capturedData).map { String(format: "%02x", $0) }.joined()
            == "cff4b07f05a991c03503f749bd0fc91a8193dc2822aed10a194dfbabedac6f12", "actual cached failure fixture remains pinned")
        let captures = try JSONSerialization.jsonObject(with: capturedData) as! [[String: Any]]
        precondition(captures.count == 2)
        for capture in captures {
            let actual = capture["nativeObject"] as! [String: Any]
            let before = (capture["beforeNativeSequence"] as! NSNumber).int64Value
            let expectedPaths = capture["expectedPaths"] as! [String]
            let proof = try VideoPipelineValidation.parse(actual)
            precondition(proof.hasCurrentRenderFailure(sequenceAfter: before, paths: expectedPaths),
                         "actual cached H264/MKV errors are explicit native failures without fresh compiler logs")
            precondition(proof.confirmed(sequenceAfter: before, paths: expectedPaths, descriptions: ["SP Root Invert 25", "SP Root Bad 25"]) == nil)
        }
        print("PASS native-proof-cached-failure-actual-archived-records")
        for capture in captures {
            let actual = capture["nativeObject"] as! [String: Any]
            let before = (capture["beforeNativeSequence"] as! NSNumber).int64Value
            let expectedPaths = capture["expectedPaths"] as! [String]
            let proof = try VideoPipelineValidation.parse(actual)
            precondition(!proof.hasCurrentRenderFailure(sequenceAfter: proof.sequence, paths: expectedPaths), "old failure cannot reject a new request")
            precondition(!proof.hasCurrentRenderFailure(sequenceAfter: before, paths: Array(expectedPaths.reversed())), "foreign ordered pipeline cannot reject this request")
            for key in ["offscreen", "completed", "generation"] {
                var changed = actual, row = actual["current"] as! [String: Any]
                if key == "offscreen" { row[key] = true }
                if key == "completed" { row[key] = false }
                if key == "generation" { row[key] = proof.generation + 1 }
                changed["current"] = row
                let changedProof = try VideoPipelineValidation.parse(changed)
                precondition(!changedProof.hasCurrentRenderFailure(sequenceAfter: before, paths: expectedPaths),
                             "offscreen, incomplete and foreign generation failures do not reject a current display request")
            }
        }
        let successfulProof = try VideoPipelineValidation.parse(fixture())
        precondition(!successfulProof.hasCurrentRenderFailure(sequenceAfter: 9, paths: paths), "real cached success remains successful")
        print("PASS native-proof-failure-rejects-only-current-owned-display")

        let progress = RenderProgress(), first = UUID(), second = UUID(), renderer = UUID()
        progress.completedDrawable(status: 0, flags: 0, forced: true, width: 640, height: 360,
            rendererID: renderer, configurationTicket: first)
        precondition(progress.frames == 0 && progress.configurationDrawable(ticket: first)?.rendererID == renderer,
                     "real forced draw has its own receipt, never creates an update-frame count")
        precondition(progress.configurationDrawable(ticket: second) == nil, "foreign ticket rejected")
        progress.completedDrawable(status: -1, flags: 0, forced: true, width: 640, height: 360,
            rendererID: renderer, configurationTicket: second)
        progress.retireConfigurationDrawable(ticket: first)
        precondition(progress.configurationDrawable(ticket: second)?.status == -1, "old cleanup cannot retire a newer request")
        progress.retireConfigurationDrawable(ticket: second)
        precondition(progress.configurationDrawable(ticket: second) == nil, "exact retirement clears receipt")
        progress.didRenderFrame(); precondition(progress.frames == 1, "existing actual update-frame counter retained")
        print("PASS drawable-receipt-exact-ticket-and-retirement")
        print("MODULE CONTRACT ONLY; no actual Surface/GPU/pixel certificate")
    }
}
