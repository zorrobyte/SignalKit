import HealthKit

/// The public SDK's known types, filtered for the running OS. This describes
/// type support, NOT the person's data or read authorization. No permissions
/// are requested until the host explicitly selects types and requests them.
public enum HealthTypeCatalog {
    public enum Family: String, CaseIterable, Sendable {
        case quantity, category, characteristic, correlation, document, clinical
        case workout, activitySummary, audiogram, electrocardiogram, series
        case visionPrescription, stateOfMind, assessment, medication, custom
    }
    public struct Entry: Identifiable {
        public let type: HKObjectType
        public let family: Family
        public var id: String { type.identifier }
        public var sampleType: HKSampleType? { type as? HKSampleType }
        public var requiresPerObjectAuthorization: Bool { type.requiresPerObjectAuthorization() }
    }
    /// Include clinical records only when the host is entitled for Health
    /// Records. `additional` allows new native types without a package release.
    public static func available(includeClinicalRecords: Bool = false,
                                 additional: [HKObjectType] = []) -> [Entry] {
        var entries: [String: Entry] = [:]
        func append(_ type: HKObjectType?, _ family: Family) {
            guard let type, includeClinicalRecords || family != .clinical else { return }
            entries[type.identifier] = Entry(type: type, family: family)
        }
        appendSDKTypes(append)
        append(HKObjectType.workoutType(), .workout)
        append(HKObjectType.activitySummaryType(), .activitySummary)
        append(HKObjectType.audiogramSampleType(), .audiogram)
        append(HKObjectType.electrocardiogramType(), .electrocardiogram)
        append(HKSeriesType.workoutRoute(), .series)
        append(HKSeriesType.heartbeat(), .series)
        append(HKObjectType.visionPrescriptionType(), .visionPrescription)
        if #available(iOS 18, *) { append(HKObjectType.stateOfMindType(), .stateOfMind) }
        if #available(iOS 26, *) {
            append(HKObjectType.medicationDoseEventType(), .medication)
            append(HKObjectType.userAnnotatedMedicationType(), .medication)
        }
        for type in additional where entries[type.identifier] == nil { append(type, .custom) }
        return entries.values.sorted { $0.id < $1.id }
    }
}
