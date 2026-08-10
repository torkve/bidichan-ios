import Foundation

extension BinaryInteger {
    /// The number written out plainly, with no group separators.
    ///
    /// Interpolating a number directly into a SwiftUI string goes through
    /// `LocalizedStringKey`, which renders it as a *quantity* in the current
    /// locale — so port 3128 shows as "3.128" and an MTU of 1400 as "1.400"
    /// wherever the locale groups with a dot. Ports, MTUs, byte counts and
    /// channel identifiers are labels rather than quantities: they are typed
    /// back in, compared by eye, and copied into other tools, so they must read
    /// exactly as entered.
    ///
    /// Use this for any such value inside a `Text`, `Stepper`, `Label` or
    /// `navigationTitle`. Values that genuinely *are* quantities should keep
    /// the locale's formatting.
    var plain: String { "\(self)" }
}
