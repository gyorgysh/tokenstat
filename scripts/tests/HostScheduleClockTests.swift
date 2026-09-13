// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HostScheduleClock.swift.
import Foundation

@main struct HostScheduleClockTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }

        check(HostScheduleClock.resolved(nil) == nil, "missing zone")
        check(HostScheduleClock.resolved("") == nil, "empty zone")
        check(HostScheduleClock.resolved("unknown") == nil, "unnamed zone")
        check(HostScheduleClock.resolved(" America/New_York ") == "America/New_York", "trim")
        check(HostScheduleClock.place("America/New_York") == "New York", "New York")
        check(HostScheduleClock.place("Europe/Budapest") == "Budapest", "Budapest")
        check(HostScheduleClock.place("America/Argentina/Buenos_Aires") == "Buenos Aires", "Buenos Aires")
        check(HostScheduleClock.place("UTC") == "UTC", "UTC")
        check(HostScheduleClock.place("unknown") == nil, "unknown has no place")

        // 14 Sep 2026 09:00 in New York is 15:00 in Budapest.
        let next = Date(timeIntervalSince1970: 1_789_390_800)
        let ny = HostScheduleClock.civilTime(next, timezone: "America/New_York")
        let budapest = HostScheduleClock.civilTime(next, timezone: "Europe/Budapest")
        check(ny?.hour == 9 && ny?.minute == 0, "New York stays 09:00")
        check(budapest?.hour == 15 && budapest?.minute == 0, "Budapest is 15:00, not the device clock")
        check(HostScheduleClock.civilTime(next, timezone: nil) == nil, "no zone means no civil time")

        let nyWall = HostScheduleClock.wallClock(next, timezone: "America/New_York") ?? ""
        let budapestWall = HostScheduleClock.wallClock(next, timezone: "Europe/Budapest") ?? ""
        check(nyWall.contains("14 Sep"), nyWall)
        check(nyWall.contains("9:00"), nyWall)
        check(!nyWall.contains("15:00"), nyWall)
        check(budapestWall.contains("15:00"), budapestWall)
        check(!budapestWall.contains("9:00"), budapestWall)

        let nyLine = HostScheduleClock.nextRun(next, timezone: "America/New_York")
        let budapestLine = HostScheduleClock.nextRun(next, timezone: "Europe/Budapest")
        check(nyLine == "\(nyWall) in New York", nyLine)
        check(budapestLine.contains("Budapest"), budapestLine)
        check(nyLine != budapestLine, "the named zone must change the words")
        check(
            HostScheduleClock.nextRun(next, timezone: nil) == "on the connected computer",
            "unknown zone does not use this device"
        )

        check(
            HostScheduleClock.timeCaption(hostName: "Studio", timezone: "America/New_York")
                == "This time is on Studio (New York).",
            "picker caption names the computer"
        )
        check(
            HostScheduleClock.timeCaption(hostName: "Studio", timezone: nil)
                == "This time is on Studio, not this device.",
            "picker caption without a zone"
        )
        check(
            HostScheduleClock.timesCaption(hostName: "Studio", timezone: "America/New_York")
                == "Times are on Studio (New York).",
            "history caption names the computer"
        )
        check(
            HostScheduleClock.timesCaption(hostName: "", timezone: nil)
                == "Times are on the connected computer, not this device.",
            "history caption without a host or zone"
        )

        let list = HostScheduleClock.listSubtitle(
            cadence: "daily at 9:00",
            next: next,
            enabled: true,
            repeats: true,
            timezone: "America/New_York"
        )
        check(list.hasPrefix("daily at 9:00 · 14 Sep"), list)
        check(list.hasSuffix("New York"), list)
        check(!list.contains("15:00"), list)
        check(
            HostScheduleClock.listSubtitle(
                cadence: "daily at 9:00",
                next: next,
                enabled: true,
                repeats: true,
                timezone: nil
            ) == "daily at 9:00",
            "list does not convert next run to this device"
        )
        check(
            HostScheduleClock.listSubtitle(
                cadence: "daily at 9:00",
                next: next,
                enabled: false,
                repeats: true,
                timezone: "America/New_York"
            ) == "daily at 9:00",
            "paused jobs do not advertise a next run"
        )
        print("Host schedule clock: host zone, DST civil time and unknown-zone honesty passed")
    }
}
