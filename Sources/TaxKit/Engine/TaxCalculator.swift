import Foundation

extension BracketTable {

    /// The band containing `chargeable`. Income at exactly a band's `upperBound` belongs
    /// to that band, matching LHDN's "5,001 – 20,000" presentation.
    public func band(for chargeable: Money) -> Band? {
        let clamped = max(chargeable, .zero)
        return bands.last { band in
            clamped >= band.lowerBound
                && (band.upperBound.map { clamped <= $0 } ?? true)
        }
    }

    /// Total income tax owed on `chargeable`, before rebates.
    ///
    /// Table-driven: the cumulative base for each band is taken verbatim from LHDN's
    /// published figures, so there is no loop accumulating rounding error.
    public func tax(on chargeable: Money) -> Money {
        let clamped = max(chargeable, .zero)
        guard let band = band(for: clamped) else { return .zero }
        return band.cumulativeBase + (clamped - band.lowerBound).applying(band.rate)
    }

    /// The rate on the next ringgit of income.
    public func marginalRate(at chargeable: Money) -> Decimal {
        band(for: max(chargeable, .zero))?.rate ?? 0
    }

    /// The tax a relief actually saves.
    ///
    /// Computed as a difference of two `tax(on:)` calls rather than
    /// `relief.applying(marginalRate)`, because a relief that straddles a band boundary
    /// saves less than the higher rate implies. This figure is the headline number on the
    /// home screen, so the shortcut is not acceptable.
    public func taxSaved(reducing chargeable: Money, by relief: Money) -> Money {
        let before = max(chargeable, .zero)
        // A relief can legitimately arrive negative: SSPN is a *net* deposit, so a year
        // with more withdrawals than deposits produces one. A negative relief saves
        // nothing — it must never surface as a negative "saving" on the home screen.
        let claimed = max(relief, .zero)
        let after = max(before - claimed, .zero)
        return tax(on: before) - tax(on: after)
    }
}
