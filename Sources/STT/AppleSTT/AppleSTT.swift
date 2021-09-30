import Foundation
import AVKit
import Speech
import Intents
import Combine
import STT
import FFTPublisher
import AudioSwitchboard

public enum AppleSTTError : Error {
    case microphonePermissionsDenied
    case speechRecognizerPermissionsDenied
    case unableToStartSpeechRecognition
    case unavailable
    case unsupportedLocale
}

public class AppleSTT: STTService, ObservableObject {
    public private(set) var available:Bool = true {
        didSet {
            if available == false {
                self.stop()
                self.status = .unavailable
            } else if oldValue == false && available{
                status = .idle
            }
        }
    }
    public var locale: Locale = Locale.current {
        didSet { settingsUpdated() }
    }
    public var maxSilence:TimeInterval = 2
    public var contextualStrings: [String] = [] {
        didSet { settingsUpdated() }
    }
    public var mode: STTMode = .unspecified {
        didSet { settingsUpdated() }
    }
    private let resultSubject: STTRecognitionSubject = .init()
    private let statusSubject: STTStatusSubject = .init()
    private let errorSubject: STTErrorSubject = .init()
    public let resultPublisher: STTRecognitionPublisher
    public let statusPublisher: STTStatusPublisher
    public let errorPublisher: STTErrorPublisher
    private var status:STTStatus = .idle {
        didSet {
            statusSubject.send(status)
        }
    }
    private var cancellables = Set<AnyCancellable>()
    private var switchboardCancellable:AnyCancellable?
    private weak var fft:FFTPublisher? = nil
    private let audioSwitchBoard:AudioSwitchboard
    private let bus:AVAudioNodeBus = 0
    private var recognizer:SFSpeechRecognizer? = nil
    private var recognitionRequest:SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var currentResult:STTResult?
    private var clearTimer:Timer?
    private func startTimer() {
        clearTimer?.invalidate()
        clearTimer = nil
        clearTimer = Timer.scheduledTimer(withTimeInterval: maxSilence, repeats: true, block: { [locale,currentResult] (timer) in
            guard let currentResult = currentResult else {
                return
            }
            let r = STTResult(currentResult.string, confidence: currentResult.confidence, locale:locale, final:true)
            self.resultSubject.send(r)
            if self.status == .recording {
                if self.mode == .dictation || self.mode == .unspecified {
                    self.restart()
                } else {
                    self.stop()
                }
            }
        })
    }
    private func internalStop() {
        clearTimer?.invalidate()
        clearTimer = nil
        recognitionRequest?.endAudio()
        audioSwitchBoard.stop(owner: "AppleSTT")
        recognitionRequest = nil
        recognitionTask = nil
        currentResult = nil
        fft?.end()
    }
    private func settingsUpdated() {
        if self.status == .recording {
            self.restart()
        }
    }
    private var permissionsResolved:Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    private func restart() {
        internalStop()
        if !available {
            return
        }
        status = .preparing
        func finalize() {
            do {
                try self.startRecording()
            } catch {
                self.status = .idle
                self.errorSubject.send(AppleSTTError.microphonePermissionsDenied)
            }
        }
        func resolveAccess() {
            let audioSession = AVAudioSession.sharedInstance()
            if audioSession.recordPermission == .denied {
                self.status = .idle
                self.errorSubject.send(AppleSTTError.microphonePermissionsDenied)
                return
            }
            if audioSession.recordPermission == .undetermined {
                audioSession.requestRecordPermission { status in
                    if audioSession.recordPermission == .denied {
                        self.status = .idle
                        self.errorSubject.send(AppleSTTError.microphonePermissionsDenied)
                    } else {
                        resolveAccess()
                    }
                }
                return
            }
            if SFSpeechRecognizer.authorizationStatus() == .denied {
                self.errorSubject.send(AppleSTTError.speechRecognizerPermissionsDenied)
                return
            }
            if SFSpeechRecognizer.authorizationStatus() == .authorized {
                DispatchQueue.main.async {
                    finalize()
                }
            } else {
                SFSpeechRecognizer.requestAuthorization { authStatus in
                    if authStatus == SFSpeechRecognizerAuthorizationStatus.authorized {
                        resolveAccess()
                    } else {
                        self.status = .idle
                        self.errorSubject.send(AppleSTTError.speechRecognizerPermissionsDenied)
                    }
                }
            }
        }
        if permissionsResolved {
            finalize()
        } else {
            resolveAccess()
        }
    }
    private func startRecording() throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            self.status = .idle
            self.errorSubject.send(AppleSTTError.unsupportedLocale)
            return
        }
        switchboardCancellable = audioSwitchBoard.claim(owner: "AppleSTT").sink { [weak self] in
            self?.stop()
        }
        let audioEngine = audioSwitchBoard.audioEngine
        self.recognizer = recognizer
        let inputNode = audioEngine.inputNode
        let inputNodeFormat = inputNode.inputFormat(forBus: bus)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            self.status = .idle
            self.errorSubject.send(AppleSTTError.unableToStartSpeechRecognition)
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        switch mode {
            case .dictation: recognitionRequest.taskHint = .dictation
            case .unspecified: recognitionRequest.taskHint = .unspecified
            case .task: recognitionRequest.taskHint = .confirmation
            case .search: recognitionRequest.taskHint = .search
        }
        
        recognitionRequest.contextualStrings = contextualStrings
        debugPrint(recognitionRequest.contextualStrings)
        recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let this = self else {
                return
            }
            if this.status == .idle {
                return
            }
            if let error = error as NSError? {
                if [203, 216].contains(error.code) {
                    this.restart()
                }
                return
            }
            guard let result = result else {
                return
            }
            if this.status == .recording && this.mode != .dictation {
                this.startTimer()
            }
            let parts = result.bestTranscription.segments.map { STTResult.Segment.init(string: $0.substring, confidence: Double($0.confidence)) }
            let r = STTResult(result.bestTranscription.formattedString, segments: parts,locale:this.locale, final: result.isFinal)
            if this.currentResult?.string == r.string && this.currentResult?.confidence == r.confidence && this.currentResult?.final == r.final  {
                return
            }
            this.currentResult = r
            this.resultSubject.send(r)
            if result.isFinal {
                if this.status == .recording {
                    if this.mode == .dictation || this.mode == .unspecified {
                        this.restart()
                    } else {
                        this.stop()
                    }
                } else if this.status == .processing {
                    this.status = .idle
                }
            }
        }
        let rate = Float(inputNodeFormat.sampleRate)
        inputNode.installTap(onBus: bus, bufferSize: 1024, format: inputNodeFormat) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            buffer.frameLength = 512
            self?.recognitionRequest?.append(buffer)
            self?.fft?.consume(buffer: buffer.audioBufferList, frames: buffer.frameLength, rate: rate)
        }
        try? audioSwitchBoard.start(owner: "AppleSTT")
        status = .recording
    }
    public init(audioSwitchBoard: AudioSwitchboard, fft:FFTPublisher? = nil, maxSilence:TimeInterval = 2) {
        self.resultPublisher = resultSubject.eraseToAnyPublisher()
        self.statusPublisher = statusSubject.eraseToAnyPublisher()
        self.errorPublisher = errorSubject.eraseToAnyPublisher()
        self.fft = fft
        self.maxSilence = maxSilence
        self.audioSwitchBoard = audioSwitchBoard
        self.available = audioSwitchBoard.availableServices.contains(.record)
        audioSwitchBoard.$availableServices.sink { [weak self] services in
            if services.contains(.record) == false {
                self?.stop()
                self?.available = false
            } else {
                self?.available = true
            }
        }.store(in: &cancellables)
    }
    public func start() {
        if !self.available {
            self.errorSubject.send(AppleSTTError.unavailable)
            return
        }
        guard status == .idle else {
            return
        }
        self.restart()
    }
    
    public func stop() {
        guard status == .recording || status == .preparing else {
            return
        }
        status = .idle
        recognitionTask?.cancel()
        internalStop()
    }
    
    public func done() {
        guard status == .recording || status == .preparing else {
            return
        }
        if currentResult == nil {
            status = .idle
        } else {
            status = .processing
        }
        recognitionTask?.finish()
        internalStop()
    }
}

