//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

public enum PaymentsError: Error {
    case notEnabled
    case userNotRegisteredOrAppNotReady
    case userHasNoPublicAddress
    case invalidCurrency
    case invalidWalletKey
    case invalidAmount
    case invalidFee
    case insufficientFunds
    case timeout
    case invalidModel
    case tooOldToSubmit
    case indeterminateState
    case unknownSDKError
    case invalidInput
    case connectionFailure
    case authorizationFailure
    case invalidServerResponse
    case attestationVerificationFailed
    case outdatedClient
    case serverRateLimited
    case serializationError
    case verificationStatusUnknown
    case ledgerBlockTimestampUnknown
    case missingModel
    case defragmentationRequired
    case invalidTransaction
    case inputsAlreadySpent
    case defragmentationFailed
    case invalidPassphrase
    case invalidEntropy
    case killSwitch
}

// MARK: -

@objc
public protocol Payments: AnyObject {

    func walletAddressBase58() -> String?

    func walletAddressQRUrl() -> URL?

    func localPaymentAddressProtoData() -> Data?

    var arePaymentsEnabled: Bool { get }

    var shouldShowPaymentsUI: Bool { get }

    var paymentsEntropy: Data? { get }

    var mcRootEntropy: Data? { get }

    func mcRootEntropy(forPaymentsEntropy paymentsEntropy: Data) -> Data?

    func isValidMobileCoinPublicAddress(_ publicAddressData: Data) -> Bool

    func setArePaymentsEnabled(for address: SignalServiceAddress, hasPaymentsEnabled: Bool, transaction: SDSAnyWriteTransaction)
    func arePaymentsEnabled(for address: SignalServiceAddress, transaction: SDSAnyReadTransaction) -> Bool

    func processIncomingPaymentRequest(thread: TSThread,
                                       paymentRequest: TSPaymentRequest,
                                       transaction: SDSAnyWriteTransaction)

    func processIncomingPaymentNotification(thread: TSThread,
                                            paymentNotification: TSPaymentNotification,
                                            senderAddress: SignalServiceAddress,
                                            transaction: SDSAnyWriteTransaction)

    func processIncomingPaymentCancellation(thread: TSThread,
                                            paymentCancellation: TSPaymentCancellation,
                                            transaction: SDSAnyWriteTransaction)

    func processReceivedTranscriptPaymentRequest(thread: TSThread,
                                                 paymentRequest: TSPaymentRequest,
                                                 messageTimestamp: UInt64,
                                                 transaction: SDSAnyWriteTransaction)

    func processReceivedTranscriptPaymentNotification(thread: TSThread,
                                                      paymentNotification: TSPaymentNotification,
                                                      messageTimestamp: UInt64,
                                                      transaction: SDSAnyWriteTransaction)

    func processReceivedTranscriptPaymentCancellation(thread: TSThread,
                                                      paymentCancellation: TSPaymentCancellation,
                                                      messageTimestamp: UInt64,
                                                      transaction: SDSAnyWriteTransaction)

    func willInsertPayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction)
    func willUpdatePayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction)

    @objc(processIncomingPaymentSyncMessage:messageTimestamp:transaction:)
    func processIncomingPaymentSyncMessage(_ paymentProto: SSKProtoSyncMessageOutgoingPayment,
                                           messageTimestamp: UInt64,
                                           transaction: SDSAnyWriteTransaction)

    func scheduleReconciliationNow(transaction: SDSAnyWriteTransaction)

    func replaceAsUnidentified(paymentModel oldPaymentModel: TSPaymentModel,
                               transaction: SDSAnyWriteTransaction)

    func findPaymentModels(withMCLedgerBlockIndex mcLedgerBlockIndex: UInt64,
                           mcIncomingTransactionPublicKey: Data,
                           transaction: SDSAnyReadTransaction) -> [TSPaymentModel]

    func tryToInsertPaymentModel(_ paymentModel: TSPaymentModel,
                                 transaction: SDSAnyWriteTransaction) throws

    func didReceiveMCAuthError()

    func warmCaches()
}

// MARK: -

public protocol PaymentsSwift: Payments {

    var paymentsState: PaymentsState { get }
    func setPaymentsState(_ value: PaymentsState,
                          updateStorageService: Bool,
                          transaction: SDSAnyWriteTransaction)
    func enablePayments(transaction: SDSAnyWriteTransaction)
    func enablePayments(withPaymentsEntropy: Data, transaction: SDSAnyWriteTransaction) -> Bool
    func disablePayments(transaction: SDSAnyWriteTransaction)

    var currentPaymentBalance: PaymentBalance? { get }
    func updateCurrentPaymentBalance()
    func updateCurrentPaymentBalancePromise() -> Promise<TSPaymentAmount>

    func getEstimatedFee(forPaymentAmount paymentAmount: TSPaymentAmount) -> Promise<TSPaymentAmount>

    func createNewOutgoingPayment(recipient: SendPaymentRecipient,
                                  paymentAmount: TSPaymentAmount,
                                  memoMessage: String?,
                                  paymentRequestModel: TSPaymentRequestModel?,
                                  isOutgoingTransfer: Bool) -> Promise<TSPaymentModel>

    func maximumPaymentAmount() -> Promise<TSPaymentAmount>

    var passphrase: PaymentsPassphrase? { get }

    func passphrase(forPaymentsEntropy paymentsEntropy: Data) -> PaymentsPassphrase?

    func paymentsEntropy(forPassphrase passphrase: PaymentsPassphrase) -> Data?

    func isValidPassphraseWord(_ word: String?) -> Bool

    func blockOnOutgoingVerification(paymentModel: TSPaymentModel) -> Promise<Bool>
}

// MARK: -

public protocol SendPaymentRecipient {
    var address: SignalServiceAddress? { get }
    var isIdentifiedPayment: Bool { get }
}

// MARK: -

public struct PaymentBalance {
    public let amount: TSPaymentAmount
    public let date: Date

    public init(amount: TSPaymentAmount, date: Date) {
        self.amount = amount
        self.date = date
    }
}

// MARK: -

public enum PaymentsState: Equatable {

    // MARK: - Dependencies

    private static var payments: Payments {
        SSKEnvironment.shared.payments
    }

    // MARK: -

    case disabled
    case disabledWithPaymentsEntropy(paymentsEntropy: Data)
    case enabled(paymentsEntropy: Data, mcRootEntropy: Data)

    // We should almost always construct instances of PaymentsState
    // using this method.  It enforces important invariants.
    //
    // * paymentsEntropy is not discarded.
    // * Payments are only enabled if mcRootEntropy can be derived from
    //   paymentsEntropy.
    // * Payments are only enabled if paymentsEntropy and mcRootEntropy
    //   have valid length.
    public static func build(arePaymentsEnabled: Bool,
                             paymentsEntropy: Data?) -> PaymentsState {
        guard let paymentsEntropy = paymentsEntropy else {
            return .disabled
        }
        guard paymentsEntropy.count == PaymentsConstants.paymentsEntropyLength else {
            owsFailDebug("paymentsEntropy has invalid length: \(paymentsEntropy.count) != \(PaymentsConstants.paymentsEntropyLength).")
            return .disabled
        }
        guard let mcRootEntropy = payments.mcRootEntropy(forPaymentsEntropy: paymentsEntropy) else {
            owsFailDebug("Could not derive mcRootEntropy from paymentsEntropy.")
            // It's essential that we _not_ discard paymentsEntropy even if we
            // can't derive a valid mcRootEntropy from it.
            return .disabledWithPaymentsEntropy(paymentsEntropy: paymentsEntropy)
        }
        guard mcRootEntropy.count == PaymentsConstants.mcRootEntropyLength else {
            owsFailDebug("mcRootEntropy has invalid length: \(mcRootEntropy.count) != \(PaymentsConstants.mcRootEntropyLength).")
            // It's essential that we _not_ discard paymentsEntropy even if we
            // can't derive a valid mcRootEntropy from it.
            return .disabledWithPaymentsEntropy(paymentsEntropy: paymentsEntropy)
        }
        if arePaymentsEnabled {
            return .enabled(paymentsEntropy: paymentsEntropy,
                            mcRootEntropy: mcRootEntropy)
        } else {
            return .disabledWithPaymentsEntropy(paymentsEntropy: paymentsEntropy)
        }
    }

    public var isEnabled: Bool {
        switch self {
        case .enabled:
            return true
        case .disabled, .disabledWithPaymentsEntropy:
            return false
        }
    }

    public var paymentsEntropy: Data? {
        switch self {
        case .enabled(let paymentsEntropy, _):
            return paymentsEntropy
        case .disabled:
            return nil
        case .disabledWithPaymentsEntropy(let paymentsEntropy):
            return paymentsEntropy
        }
    }

    public var mcRootEntropy: Data? {
        switch self {
        case .enabled(_, let mcRootEntropy):
            return mcRootEntropy
        case .disabled:
            return nil
        case .disabledWithPaymentsEntropy:
            return nil
        }
    }

    // MARK: Equatable

    public static func == (lhs: PaymentsState, rhs: PaymentsState) -> Bool {
        return (lhs.isEnabled == rhs.isEnabled &&
                    lhs.paymentsEntropy == rhs.paymentsEntropy &&
                    lhs.mcRootEntropy == rhs.mcRootEntropy)
    }
}

// MARK: -

public struct PaymentsPassphrase: Equatable {

    // MARK: - Dependencies

    private static var payments: PaymentsSwift {
        SSKEnvironment.shared.payments as! PaymentsSwift
    }

    // MARK: -

    public let words: [String]

    public init(words: [String]) throws {
        guard words.count == PaymentsConstants.passphraseWordCount else {
            owsFailDebug("words.count \(words.count) != \(PaymentsConstants.passphraseWordCount)")
            throw PaymentsError.invalidPassphrase
        }

        self.words = words
    }

    public var wordCount: Int { words.count }

    public var asPassphrase: String { words.joined(separator: " ") }

    public var debugDescription: String { asPassphrase }

    public static func parse(passphrase: String,
                             validateWords: Bool) throws -> PaymentsPassphrase {
        let words = Array(passphrase.lowercased().stripped.components(separatedBy: " ").compactMap { $0.nilIfEmpty })
        guard words.count == PaymentsConstants.passphraseWordCount else {
            Logger.warn("words.count \(words.count) != \(PaymentsConstants.passphraseWordCount)")
            throw PaymentsError.invalidPassphrase
        }
        if validateWords {
            for word in words {
                guard Self.payments.isValidPassphraseWord(word) else {
                    Logger.verbose("Invalid passphrase word: \(word).")
                    Logger.warn("Invalid passphrase word.")
                    throw PaymentsError.invalidPassphrase
                }
            }
        }
        return try PaymentsPassphrase(words: words)
    }
}

// MARK: -

public class MockPayments: NSObject {
}

// MARK: -

extension MockPayments: PaymentsSwift {

    public var paymentsState: PaymentsState { .disabled }

    public func setPaymentsState(_ value: PaymentsState,
                                 updateStorageService: Bool,
                                 transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func enablePayments(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func enablePayments(withPaymentsEntropy: Data, transaction: SDSAnyWriteTransaction) -> Bool {
        owsFail("Not implemented.")
    }

    public func disablePayments(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public var arePaymentsEnabled: Bool {
        owsFail("Not implemented.")
    }

    public var shouldShowPaymentsUI: Bool {
        owsFail("Not implemented.")
    }

    public var paymentsEntropy: Data? { nil }

    public var mcRootEntropy: Data? { nil }

    public func mcRootEntropy(forPaymentsEntropy paymentsEntropy: Data) -> Data? {
        owsFail("Not implemented.")
    }

    public func walletAddressBase58() -> String? {
        owsFail("Not implemented.")
    }

    public func walletAddressQRUrl() -> URL? {
        owsFail("Not implemented.")
    }

    public func localPaymentAddressProtoData() -> Data? {
        owsFail("Not implemented.")
    }

    public func warmCaches() {
        // Do nothing.
    }

    public var currentPaymentBalance: PaymentBalance? {
        owsFail("Not implemented.")
    }

    public func updateCurrentPaymentBalance() {
        owsFail("Not implemented.")
    }

    public func updateCurrentPaymentBalancePromise() -> Promise<TSPaymentAmount> {
        owsFail("Not implemented.")
    }

    public func getEstimatedFee(forPaymentAmount paymentAmount: TSPaymentAmount) -> Promise<TSPaymentAmount> {
        owsFail("Not implemented.")
    }

    public func createNewOutgoingPayment(recipient: SendPaymentRecipient,
                                         paymentAmount: TSPaymentAmount,
                                         memoMessage: String?,
                                         paymentRequestModel: TSPaymentRequestModel?,
                                         isOutgoingTransfer: Bool) -> Promise<TSPaymentModel> {
        owsFail("Not implemented.")
    }

    public func isValidMobileCoinPublicAddress(_ publicAddressData: Data) -> Bool {
        owsFail("Not implemented.")
    }

    public func setArePaymentsEnabled(for address: SignalServiceAddress, hasPaymentsEnabled: Bool, transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func arePaymentsEnabled(for address: SignalServiceAddress, transaction: SDSAnyReadTransaction) -> Bool {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentRequest(thread: TSThread,
                                              paymentRequest: TSPaymentRequest,
                                              transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentNotification(thread: TSThread,
                                                   paymentNotification: TSPaymentNotification,
                                                   senderAddress: SignalServiceAddress,
                                                   transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentCancellation(thread: TSThread,
                                                   paymentCancellation: TSPaymentCancellation,
                                                   transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processReceivedTranscriptPaymentRequest(thread: TSThread,
                                                        paymentRequest: TSPaymentRequest,
                                                        messageTimestamp: UInt64,
                                                        transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processReceivedTranscriptPaymentNotification(thread: TSThread,
                                                             paymentNotification: TSPaymentNotification,
                                                             messageTimestamp: UInt64,
                                                             transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processReceivedTranscriptPaymentCancellation(thread: TSThread,
                                                             paymentCancellation: TSPaymentCancellation,
                                                             messageTimestamp: UInt64,
                                                             transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentSyncMessage(_ paymentProto: SSKProtoSyncMessageOutgoingPayment,
                                                  messageTimestamp: UInt64,
                                                  transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func willInsertPayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func willUpdatePayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func scheduleReconciliationNow(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func replaceAsUnidentified(paymentModel oldPaymentModel: TSPaymentModel,
                                      transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func findPaymentModels(withMCLedgerBlockIndex mcLedgerBlockIndex: UInt64,
                                  mcIncomingTransactionPublicKey: Data,
                                  transaction: SDSAnyReadTransaction) -> [TSPaymentModel] {
        owsFail("Not implemented.")
    }

    public func tryToInsertPaymentModel(_ paymentModel: TSPaymentModel,
                                        transaction: SDSAnyWriteTransaction) throws {
        owsFail("Not implemented.")
    }

    public func didReceiveMCAuthError() {
        owsFail("Not implemented.")
    }

    public func maximumPaymentAmount() -> Promise<TSPaymentAmount> {
        owsFail("Not implemented.")
    }

    public var passphrase: PaymentsPassphrase? { nil }

    public func passphrase(forPaymentsEntropy paymentsEntropy: Data) -> PaymentsPassphrase? {
        owsFail("Not implemented.")
    }

    public func paymentsEntropy(forPassphrase passphrase: PaymentsPassphrase) -> Data? {
        owsFail("Not implemented.")
    }

    public func isValidPassphraseWord(_ word: String?) -> Bool {
        owsFail("Not implemented.")
    }

    public func blockOnOutgoingVerification(paymentModel: TSPaymentModel) -> Promise<Bool> {
        owsFail("Not implemented.")
    }
}

// MARK: -

@objc
public protocol PaymentsCurrencies: AnyObject {

    typealias CurrencyCode = String

    // Expressed as a ratio:
    //
    // price of fiat currency / price of payment currency (MobileCoin)
    typealias CurrencyConversionRate = Double

    var currentCurrencyCode: CurrencyCode { get }

    func setCurrentCurrencyCode(_ currencyCode: CurrencyCode, transaction: SDSAnyWriteTransaction)

    func updateConversationRatesIfStale()

    func warmCaches()
}

// MARK: -

public protocol PaymentsCurrenciesSwift: PaymentsCurrencies {

    var preferredCurrencyInfos: [CurrencyInfo] { get }

    var supportedCurrencyInfos: [CurrencyInfo] { get }

    var supportedCurrencyInfosWithCurrencyConversions: [CurrencyInfo] { get }

    func conversionInfo(forCurrencyCode currencyCode: CurrencyCode) -> CurrencyConversionInfo?
}

// MARK: -

public class PaymentsConstants {

    @available(*, unavailable, message: "Do not instantiate this class.")
    private init() {}

    @objc
    public static let picoMobPerMob: UInt64 = 1000 * 1000 * 1000 * 1000

    @objc
    public static let mobileCoinCurrencyIdentifier = "MOB"

    @objc
    public static let currencyCodeGBP = "GBP"

    public static func convertMobToPicoMob(_ mob: Double) -> UInt64 {
        UInt64(round(mob * Double(picoMobPerMob)))
    }

    public static func convertPicoMobToMob(_ picoMob: UInt64) -> Double {
        Double(picoMob) / Double(picoMobPerMob)
    }

    // The number of decimal digits in a picoMob.
    public static let maxMobDecimalDigits: UInt = 12

    // The largest number of non-decimal digits a user can enter
    // that can be safely expressed as picoMob in UInt64.
    //
    // Safe:    9,999,999.999,999,999,999.
    // Unsafe: 99,999,999.999,999,999,999.
    public static let maxMobNonDecimalDigits: UInt = 7

    public static let passphraseWordCount: Int = 24

    private struct DecimalFormattingInfo {
        let decimalSeparator: String
        let groupingSeparator: String
        let groupingSize: Int
        let shouldUseGroupingSeparatorsAfterDecimal: Bool
    }

    private static let decimalFormattingInfo: DecimalFormattingInfo = {
        let numberFormatter = NumberFormatter()
        let decimalSeparator = numberFormatter.decimalSeparator ?? ""
        let groupingSeparator = numberFormatter.groupingSeparator ?? ""
        let groupingSize = numberFormatter.groupingSize

        // NumberFormatter doesn't expose a property for this behavior,
        // but we can infer the appropriate behavior for the user's locale
        // by examining NumberFormatter's output.
        let shouldUseGroupingSeparatorsAfterDecimal: Bool = {
            let defaultValue = true

            // Build a decimal formatter for user locale.
            let formatter = NumberFormatter()
            formatter.locale = Locale.current
            formatter.numberStyle = .decimal
            formatter.usesSignificantDigits = false
            formatter.maximumSignificantDigits = 32
            formatter.maximumFractionDigits = 32
            formatter.minimumFractionDigits = 32

            // Format an exemplary value that should have a grouping separator
            // after the decimal if that's appropriate for the locale.
            guard let formatted = formatter.string(from: NSNumber(value: 1.23456789)) else {
                owsFailDebug("Could not format exemplary value.")
                return defaultValue
            }
            let components = formatted.components(separatedBy: formatter.decimalSeparator)
            guard components.count == 2,
                  let decimalComponent = components[safe: 1] else {
                owsFailDebug("Could not parse exemplary value.")
                return defaultValue
            }
            let shouldUseGroupingSeparatorsAfterDecimal = decimalComponent.contains(formatter.groupingSeparator)
            return shouldUseGroupingSeparatorsAfterDecimal
        }()

        // https://en.wikipedia.org/wiki/Decimal_separator
        let validDecimalSeparators = [",", ".", "'", "·"]
        let validGroupingSeparators = [",", ".", " ", "'"]
        let validGroupingSizes = [2, 3, 4]
        guard validDecimalSeparators.contains(decimalSeparator),
              validGroupingSeparators.contains(groupingSeparator),
              validGroupingSizes.contains(groupingSize),
              decimalSeparator != groupingSeparator else {

            if DebugFlags.paymentsInternalBeta {
                // Fall back to US/UK style formatting.
                return DecimalFormattingInfo(decimalSeparator: ".",
                                             groupingSeparator: ",",
                                             groupingSize: 3,
                                             shouldUseGroupingSeparatorsAfterDecimal: shouldUseGroupingSeparatorsAfterDecimal)
            } else {
                // Fall back to the most common international style formatting.
                return DecimalFormattingInfo(decimalSeparator: ",",
                                             groupingSeparator: ".",
                                             groupingSize: 3,
                                             shouldUseGroupingSeparatorsAfterDecimal: shouldUseGroupingSeparatorsAfterDecimal)
            }
        }
        return DecimalFormattingInfo(decimalSeparator: decimalSeparator,
                                     groupingSeparator: groupingSeparator,
                                     groupingSize: groupingSize,
                                     shouldUseGroupingSeparatorsAfterDecimal: shouldUseGroupingSeparatorsAfterDecimal)
    }()

    public static var decimalSeparator: String {
        decimalFormattingInfo.decimalSeparator
    }

    public static var groupingSeparator: String {
        decimalFormattingInfo.groupingSeparator
    }

    public static var groupingSize: Int {
        decimalFormattingInfo.groupingSize
    }

    public static var shouldUseGroupingSeparatorsAfterDecimal: Bool {
        decimalFormattingInfo.shouldUseGroupingSeparatorsAfterDecimal
    }

    public static let paymentsEntropyLength: UInt = 32

    public static let mcRootEntropyLength: UInt = 32
}

// MARK: -

public struct CurrencyInfo {
    public let currencyCode: PaymentsCurrencies.CurrencyCode
    public let name: String

    public init(currencyCode: PaymentsCurrencies.CurrencyCode, name: String) {
        self.currencyCode = currencyCode
        self.name = name
    }
}

// MARK: -

public struct CurrencyConversionInfo {
    public let currencyCode: PaymentsCurrencies.CurrencyCode
    public let name: String
    // Don't use this field; use convertToFiatCurrency() instead.
    private let conversionRate: PaymentsCurrencies.CurrencyConversionRate
    // How fresh is this conversion info?
    public let conversionDate: Date

    public init(currencyCode: PaymentsCurrencies.CurrencyCode,
                name: String,
                conversionRate: PaymentsCurrencies.CurrencyConversionRate,
                conversionDate: Date) {
        self.currencyCode = currencyCode
        self.name = name
        self.conversionRate = conversionRate
        self.conversionDate = conversionDate
    }

    public func convertToFiatCurrency(paymentAmount: TSPaymentAmount) -> Double? {
        guard paymentAmount.currency == .mobileCoin else {
            owsFailDebug("Unknown currency: \(paymentAmount.currency).")
            return nil
        }
        let mob = PaymentsConstants.convertPicoMobToMob(paymentAmount.picoMob)
        return conversionRate * mob
    }

    public func convertFromFiatCurrencyToMOB(_ value: Double) -> TSPaymentAmount {
        guard value >= 0 else {
            owsFailDebug("Invalid amount: \(value).")
            return TSPaymentAmount(currency: .mobileCoin, picoMob: 0)
        }
        let mob = value / conversionRate
        let picoMob = PaymentsConstants.convertMobToPicoMob(mob)
        return TSPaymentAmount(currency: .mobileCoin, picoMob: picoMob)
    }

    public var asCurrencyInfo: CurrencyInfo {
        CurrencyInfo(currencyCode: currencyCode, name: name)
    }

    public static func areEqual(_ left: CurrencyConversionInfo?,
                                _ right: CurrencyConversionInfo?) -> Bool {
        return (left?.currencyCode == right?.currencyCode &&
                    left?.conversionRate == right?.conversionRate)
    }
}

// MARK: -

public class MockPaymentsCurrencies: NSObject, PaymentsCurrenciesSwift {

    public let currentCurrencyCode: CurrencyCode = PaymentsConstants.currencyCodeGBP

    public func setCurrentCurrencyCode(_ currencyCode: PaymentsCurrencies.CurrencyCode, transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func warmCaches() {}

    public let preferredCurrencyInfos: [CurrencyInfo] = []

    public let supportedCurrencyInfos: [CurrencyInfo] = []

    public let supportedCurrencyInfosWithCurrencyConversions: [CurrencyInfo] = []

    public func updateConversationRatesIfStale() {}

    public func conversionInfo(forCurrencyCode currencyCode: CurrencyCode) -> CurrencyConversionInfo? {
        return nil
    }
}
