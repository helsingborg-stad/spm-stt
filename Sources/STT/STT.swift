import Combine
import Foundation

public typealias STTStatusSubject = PassthroughSubject<STTStatus, Never>
public typealias STTErrorSubject = PassthroughSubject<Error, Never>
public typealias STTRecognitionSubject = PassthroughSubject<STTResult, Never>

public typealias STTStatusPublisher = AnyPublisher<STTStatus, Never>
public typealias STTErrorPublisher = AnyPublisher<Error, Never>
public typealias STTRecognitionPublisher = AnyPublisher<STTResult, Never>

public struct STTResult: Identifiable, Equatable {
    public static func == (lhs: STTResult, rhs: STTResult) -> Bool {
        lhs.id == rhs.id
    }
    public struct Segment {
        public let string:String
        public let confidence:Double
        public init(string:String,confidence:Double) {
            self.string = string
            self.confidence = confidence
        }
    }
    public var id = UUID().uuidString
    public let string:String
    public let confidence:Double
    public let segments:[Segment]
    public let final:Bool
    public let locale:Locale
    public init(_ string:String, confidence:Double, locale:Locale, final:Bool = false) {
        self.string = string
        self.confidence = confidence
        self.final = final
        self.locale = locale
        self.segments = []
    }
    public init(_ string:String, segments:[Segment], locale:Locale, final:Bool = false) {
        self.segments = segments
        self.string = string
        self.confidence = segments.compactMap({ $0.confidence }).reduce(0, +) / Double(segments.count)
        self.final = final
        self.locale = locale
    }
    public init(_ segments:[Segment], locale:Locale, final:Bool = false) {
        self.segments = segments
        self.string = segments.compactMap({ $0.string }).joined(separator: " ")
        self.confidence = segments.compactMap({ $0.confidence }).reduce(0, +) / Double(segments.count)
        self.final = final
        self.locale = locale
    }
}

public enum STTStatus {
    case unavailable
    case idle
    case preparing
    case processing
    case recording
}

public enum STTMode {
    case task
    case search
    case dictation
    case unspecified
}
public protocol STTService : AnyObject {
    var locale:Locale { get set }
    var contextualStrings:[String] {get set}
    var mode:STTMode {get set}
    var resultPublisher: STTRecognitionPublisher { get }
    var statusPublisher: STTStatusPublisher { get }
    var errorPublisher:STTErrorPublisher { get }
    var available:Bool { get }
    func start()
    func stop()
    func done()
}
public class STT : ObservableObject {
    internal var service:STTService
    private var publishers = Set<AnyCancellable>()
    
    public final var contextualStrings:[String] {
        get { return service.contextualStrings }
        set { service.contextualStrings = newValue }
    }
    public final var mode:STTMode {
        get { return service.mode }
        set { service.mode = newValue }
    }
    public final var locale:Locale {
        get { return service.locale }
        set { service.locale = newValue }
    }
    public final var resultPublisher: STTRecognitionPublisher { service.resultPublisher }
    public final var statusPublisher: STTStatusPublisher { service.statusPublisher }
    public final var errorPublisher: STTErrorPublisher { service.errorPublisher }
    
    @Published public var status: STTStatus = .idle
    @Published public var disabled: Bool = false {
        didSet {
            if disabled {
                service.stop()
            }
        }
    }
    public init(service: STTService) {
        self.service = service
        service.statusPublisher.receive(on: DispatchQueue.main).sink { status in
            self.status = status
        }.store(in: &publishers)
    }
    public final func start() {
        guard service.available else {
            debugPrint("unavailable")
            return
        }
        if disabled {
            debugPrint("disabled")
            return
        }
        service.start()
    }
    public final func stop() {
        service.stop()
    }
    public final func done() {
        service.done()
    }
}
