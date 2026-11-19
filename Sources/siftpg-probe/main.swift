import Foundation
import SiftCore
import SiftPG

guard let url = ProcessInfo.processInfo.environment["SIFT_PG_URL"], !url.isEmpty else {
    FileHandle.standardError.write(Data("siftpg-probe: SIFT_PG_URL is not set\n".utf8))
    exit(2)
}

do {
    let pg = try PGConnection(conninfo: url)
    let outcome = try PGSelfCheck.run(pg)
    print("server version: \(outcome.serverVersion)")
    for (i, column) in outcome.page.columns.enumerated() {
        print("\(column.name) (\(column.typeName), oid \(column.typeOID)) = \(outcome.page.rows[0][i])")
    }
    if outcome.mismatches.isEmpty {
        print("OK: all \(outcome.page.columns.count) values match")
        exit(0)
    }
    for m in outcome.mismatches { print("MISMATCH \(m)") }
    exit(1)
} catch {
    FileHandle.standardError.write(Data("siftpg-probe: \(error)\n".utf8))
    exit(1)
}
