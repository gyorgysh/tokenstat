// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@main struct Reference {
    static func main() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let rows = try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        let output = rows.map { row -> [String:Any] in
            let key = row["key"] as! String
            return ["key":key,"position":InsightDayAxis.position(key) as Any? ?? NSNull()]
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
    }
}
